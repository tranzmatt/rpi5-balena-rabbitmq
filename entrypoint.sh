#!/bin/bash

# Exit immediately if a command exits with a non-zero status
# set -e

# Check if the RABBITMQ_NODENAME environment variable is set, otherwise set a default
if [ -z "$RABBITMQ_NODENAME" ]; then
  export RABBITMQ_NODENAME="rabbit@$(hostname -s)"
fi

# Set Consul configuration
export CONSUL_NODE_NAME="$(hostname -s)"
export CONSUL_BIND_INTERFACE=$(ip route | grep default | awk '{print $5}')
export CONSUL_BIND_ADDRESS=$(ip -4 addr show $CONSUL_BIND_INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
export CONSUL_FULL_HOSTNAME=$(nslookup $CONSUL_BIND_ADDRESS | awk '/name =/ {print $4}' | sed 's/\.$//')
export CONSUL_DOMAIN=$(echo $CONSUL_FULL_HOSTNAME | cut -d'.' -f2-)

echo CONSUL_NODE_NAME $CONSUL_NODE_NAME
echo CONSUL_BIND_INTERFACE $CONSUL_BIND_INTERFACE
echo CONSUL_BIND_ADDRESS $CONSUL_BIND_ADDRESS
echo CONSUL_FULL_HOSTNAME $CONSUL_FULL_HOSTNAME
echo CONSUL_DOMAIN $CONSUL_DOMAIN

sed -i "s/host-name=CONSUL_NODE_NAME/host-name=${CONSUL_NODE_NAME}/" /etc/avahi/avahi-daemon.conf
#sed -i "s/^domain-name=.*/domain-name=${CONSUL_DOMAIN}/" /etc/avahi/avahi-daemon.conf

# Dynamically update /etc/resolv.conf to add the domain to the search list
if ! grep -q "search ${DOMAIN_NAME}" /etc/resolv.conf; then
  echo "search ${CONSUL_DOMAIN}" >> /etc/resolv.conf
fi

# Start D-Bus daemon (required for Avahi)
dbus-daemon --system

# Start the Avahi daemon
avahi-daemon --no-chroot -D

sleep 10

retry_join_args=""

# Create and advertise mDNS entries for RabbitMQ nodes
rabbitmq_nodes=$(avahi-browse -r -t _amqp._tcp | awk '/^=/{getline; hostname=$3; getline; ip=$3; print ip, hostname}' | tr -d '[]')

echo $rabbitmq_nodes

retry_join_args=""

while read -r line; do
    #printf "line %s\n" $line
    ip=$(echo $line | awk '{print $1}')
    hostname=$(echo $line | awk '{print $2}')

    #echo "Checking IP $ip Hostname $hostname"

    retry_join_args="$retry_join_args -retry-join=$ip"
done <<< $rabbitmq_nodes

echo $retry_join_args

# Restart the Avahi daemon
avahi-daemon -k && avahi-daemon --no-chroot -D

# Start Consul agent
consul agent -server -bind=$CONSUL_BIND_ADDRESS -node=$CONSUL_NODE_NAME \
    -client=0.0.0.0 -bootstrap-expect=3 $retry_join_args \
    -data-dir=/tmp/consul -ui \
    > /var/log/consul.log 2>&1 &

# Ensure that Consul is available before starting RabbitMQ
CONSUL_URL="http://localhost:8500/v1/agent/self"
echo "Waiting for Consul to be available..."
until curl -s $CONSUL_URL > /dev/null; do
  echo "Consul not available yet, sleeping..."
  sleep 2
done

# Ensure that a Consul leader is available before starting RabbitMQ
CONSUL_LEADER_URL="http://localhost:8500/v1/status/leader"
echo "Waiting for Consul leader to be elected..."
LEADER_IP=""
DOMAIN=""

until [ -n "$LEADER_IP" ]; do
  # Get the leader IP from the Consul API
  CONSUL_LEADER=$(curl -s $CONSUL_LEADER_URL)

  # Extract the IP address from the response
  LEADER_IP=$(echo $CONSUL_LEADER | awk -F':' '{print $1}' | tr -d '"')

  if [ -n "$LEADER_IP" ]; then
    echo "Consul leader elected with IP: $LEADER_IP"

    FULL_HOSTNAME=$(nslookup $LEADER_IP | awk '/name =/ {print $4}' | sed 's/\.$//')

    if [ -n "$FULL_HOSTNAME" ]; then
      # Extract the domain by removing the node name part
      SHORT_HOSTNAME=$(echo $FULL_HOSTNAME | cut -d'.' -f1)
      DOMAIN=$(echo $FULL_HOSTNAME | cut -d'.' -f2-)

      echo "The domain for the Consul leader IP address $LEADER_IP is $DOMAIN"
      #echo "cluster_formation.consul.host = $FULL_HOSTNAME" >> /etc/rabbitmq/rabbitmq.conf
      #echo "cluster_formation.consul.host = $LEADER_IP" >> /etc/rabbitmq/rabbitmq.conf
      echo "cluster_formation.consul.host = $SHORT_HOSTNAME" >> /etc/rabbitmq/rabbitmq.conf
    else
      echo "No domain found for the Consul leader IP address $LEADER_IP"
      echo "cluster_formation.consul.host = $LEADER_IP" >> /etc/rabbitmq/rabbitmq.conf
    fi
  else
    echo "No Consul leader yet, sleeping..."
    sleep 2
  fi
done

echo "Consul is available, proceeding with RabbitMQ startup..."

# Run any necessary configuration or setup tasks here
echo "$LEADER_IP	$FULL_HOSTNAME $SHORT_HOSTNAME" >> /etc/hosts
echo $RABBITMQ_ERLANG_COOKIE > /var/lib/rabbitmq/.erlang.cookie
chmod 400 /var/lib/rabbitmq/.erlang.cookie
chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie

# Start the RabbitMQ server
echo "Starting RabbitMQ server..."
exec rabbitmq-server

# Keep the container running
while true; do sleep 100 ; done
