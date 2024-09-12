#!/bin/bash

echo ">>>>>>>>>>>>>>>>>>>>>>>>>>"

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

sed -i "s/host-name=CONSUL_NODE_NAME/host-name=${CONSUL_NODE_NAME}/" /etc/avahi/avahi-daemon.conf

# Dynamically update /etc/resolv.conf to add the domain to the search list
if ! grep -q "search ${DOMAIN_NAME}" /etc/resolv.conf; then
  echo "search ${CONSUL_DOMAIN}" >> /etc/resolv.conf
fi

# Start D-Bus daemon (required for Avahi)
mkdir -p /run/dbus
/bin/rm -f /run/dbus/pid || true
dbus-daemon --system

# Start the Avahi daemon
avahi-daemon --no-chroot -D

# Let Avahi spin up
sleep 10

# Build out a consul "retry" list from avahi discoveries of amqp services
retry_join_args=""
rabbitmq_nodes=$(avahi-browse -r -t _amqp._tcp | awk '/^=/{getline; hostname=$3; getline; ip=$3; print ip, hostname}' | tr -d '[]')

while read -r line; do
    ip=$(echo $line | awk '{print $1}')
    hostname=$(echo $line | awk '{print $2}')
    retry_join_args="$retry_join_args -retry-join=$ip"
done <<< $rabbitmq_nodes

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
LEADER_IP=""
DOMAIN=""
I_AM_LEADER=0

echo "Waiting for Consul leader to be elected..."

# Set the RabbitMQ svc.host to the Consul leader
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

      if [ $CONSUL_NODE_NAME == $SHORT_HOSTNAME ]; then
        I_AM_LEADER=1
        echo "I AM THE LEADER"
      fi

      #echo "The domain for the Consul leader IP address $LEADER_IP is $DOMAIN"
      echo "cluster_formation.consul.host = $SHORT_HOSTNAME" >> /etc/rabbitmq/rabbitmq.conf
    else
      #echo "No domain found for the Consul leader IP address $LEADER_IP"
      echo "cluster_formation.consul.host = $LEADER_IP" >> /etc/rabbitmq/rabbitmq.conf
    fi
  else
    echo "No Consul leader yet, sleeping..."
    sleep 2
  fi
done

echo "Consul is available, proceeding with RabbitMQ startup..."

# Make sure ERLANG cookie provided by Balena is set for RabbitMQ
echo $RABBITMQ_ERLANG_COOKIE > /var/lib/rabbitmq/.erlang.cookie
chmod 400 /var/lib/rabbitmq/.erlang.cookie
chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie

rabbitmq-plugins enable --offline rabbitmq_peer_discovery_consul
rabbitmq-plugins enable --offline rabbitmq_mqtt
rabbitmq-plugins enable --offline rabbitmq_web_mqtt
rabbitmq-plugins enable --offline rabbitmq_web_mqtt_examples
rabbitmqctl set_policy ha-all "^" '{"ha-mode":"all"}'


# Start the RabbitMQ server
echo "Starting RabbitMQ server..."

# This should be run in detached mode and will be once there's more to do
exec rabbitmq-server -detached &

echo "<<<<<<<<<<<<<<<<<<<<<"

# Wait for RabbitMQ to spin up
RABBITMQ_AMQP_PORT=5672
RABBITMQ_HOST="localhost"

echo "Waiting for RabbitMQ to be ready on $RABBITMQ_HOST:$RABBITMQ_AMQP_PORT..."
while ! nc -z $RABBITMQ_HOST $RABBITMQ_AMQP_PORT; do
  echo "RabbitMQ is not ready yet, sleeping..."
  sleep 2
done
echo "RabbitMQ is up and running on $RABBITMQ_HOST:$RABBITMQ_AMQP_PORT."

# Output the result
if [ $I_AM_LEADER -eq 1 ]; then
    echo "This node is the Consul leader. Running producer."
    python3 mqtt_producer.py
else
    echo "This node is not the Consul leader. Running consumer."
    python3 mqtt_consumer.py
fi

# Keep the container running
while true; do sleep 100 ; done
