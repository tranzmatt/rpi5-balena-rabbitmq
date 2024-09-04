#!/bin/bash

# Set the RabbitMQ node name based on the device's hostname
export HOSTNAME_FULL=$(hostname -f 2>/dev/null || hostname)
export RABBITMQ_NODENAME="rabbit@$HOSTNAME_FULL"

# Set Consul configuration
export CONSUL_NODE_NAME="${BALENA_DEVICE_NAME_AT_INIT}"
export CONSUL_BIND_INTERFACE=$(ip route | grep default | awk '{print $5}')
export CONSUL_BIND_ADDRESS=$(ip -4 addr show $CONSUL_BIND_INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

sed -i "s/host-name=HOSTNAME_FULL/host-name=${HOSTNAME_FULL}/" /etc/avahi/avahi-daemon.conf

# Start D-Bus daemon (required for Avahi)
dbus-daemon --system

# Start the Avahi daemon
avahi-daemon --no-chroot -D

sleep 10

retry_join_args=""

# Create and advertise mDNS entries for RabbitMQ nodes
rabbitmq_nodes=$(avahi-browse -r -t _amqp._tcp | awk '/^=/{getline; hostname=$3; getline; ip=$3; print ip, hostname}' | tr -d '[]')

while read -r line; do
    #printf "line %s\n" $line
    ip=$(echo $line | awk '{print $1}')
    hostname=$(echo $line | awk '{print $2}')

    #echo "Checking IP $ip Hostname $hostname"

    retry_join_args="$retry_join_args -retry-join=$ip"
    #echo "current retry = $retry_join_args"

    # Create an mDNS service file for RabbitMQ (port 5672 for AMQP)
    cat <<EOL > /etc/avahi/services/${hostname}_amqp.service
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">

<service-group>
  <name replace-wildcards="yes">$hostname RabbitMQ</name>
  <service>
    <type>_amqp._tcp</type>
    <port>5672</port>
    <host-name>$hostname.local</host-name>
    <address>$ip</address>
  </service>
</service-group>
EOL

    # Optionally, create an mDNS service file for the RabbitMQ management interface (port 15672)
    cat <<EOL > /etc/avahi/services/${hostname}_mgmt.service
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">

<service-group>
  <name replace-wildcards="yes">$hostname RabbitMQ Management</name>
  <service>
    <type>_http._tcp</type>
    <port>15672</port>
    <host-name>$hostname.local</host-name>
    <address>$ip</address>
  </service>
</service-group>
EOL

    echo "this is retry = $retry_join_args"

done <<< $rabbitmq_nodes

#echo "final retry = $retry_join_args"

# Start Consul agent
consul agent -server -bind=$CONSUL_BIND_ADDRESS -node=$CONSUL_NODE_NAME \
    -client=0.0.0.0 -bootstrap-expect=3 $retry_join_args \
    -data-dir=/tmp/consul -ui \
    > /var/log/consul.log 2>&1 &

# Give Consul a few seconds to start and join the cluster
sleep 10

consul services register -name=rabbitmq

# Write the Erlang cookie to the .erlang.cookie file
echo $RABBITMQ_ERLANG_COOKIE > /var/lib/rabbitmq/.erlang.cookie
chmod 400 /var/lib/rabbitmq/.erlang.cookie
chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie

# Start RabbitMQ server in the background
rabbitmq-server -detached

sleep 10

# Register RabbitMQ with Consul and start the RabbitMQ app
rabbitmqctl start_app

# Tail both RabbitMQ and Consul logs for easier debugging
tail -f /var/log/rabbitmq/${RABBITMQ_NODENAME}.log /var/log/consul.log

# Keep the container running
while true; do sleep 100 ; done
