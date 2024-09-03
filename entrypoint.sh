#!/bin/bash

# Set the RabbitMQ node name based on the device's hostname
export RABBITMQ_NODENAME="rabbit@$(hostname)"

# Write the Erlang cookie to the .erlang.cookie file
echo $RABBITMQ_ERLANG_COOKIE > /var/lib/rabbitmq/.erlang.cookie
chmod 400 /var/lib/rabbitmq/.erlang.cookie
chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie

# Start RabbitMQ server in the background
rabbitmq-server -detached

sleep 10

# Determine the network interface used by the default gateway
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}')

# Get the IP address and subnet mask of the network interface used by the default gateway
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}')
IP_ADDRESS=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
SUBNET_MASK=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | cut -d'/' -f2)

printf "IP: %s\n" $IP_ADDRESS
printf "MASK: %s\n" $SUBNET_MASK

# Convert CIDR subnet mask to dotted decimal format
CIDR_TO_DECIMAL() {
  local i mask=""
  for ((i=0; i<4; i++)); do
    [ $SUBNET_MASK -ge 8 ] && { mask+=255; SUBNET_MASK=$((SUBNET_MASK-8)); } || { mask+=$((256-2**(8-SUBNET_MASK))); SUBNET_MASK=0; }
    [ $i -lt 3 ] && mask+=.
  done
  echo $mask
}

DECIMAL_MASK=$(CIDR_TO_DECIMAL)

printf "Dotted Decimal Mask: %s\n" $DECIMAL_MASK

# Calculate the network address and broadcast address based on the IP and subnet mask
IFS=. read -r i1 i2 i3 i4 <<<"$IP_ADDRESS"
IFS=. read -r m1 m2 m3 m4 <<<"$DECIMAL_MASK"

NETWORK_ADDRESS=$(printf "%d.%d.%d.%d" $((i1 & m1)) $((i2 & m2)) $((i3 & m3)) $((i4 & m4)))
BROADCAST_ADDRESS=$(printf "%d.%d.%d.%d" $((i1 | ~m1 & 255)) $((i2 | ~m2 & 255)) $((i3 | ~m3 & 255)) $((i4 | ~m4 & 255)))

printf "Network Address: %s\n" $NETWORK_ADDRESS
printf "Broadcast Address: %s\n" $BROADCAST_ADDRESS

# Convert IPs to start and end range
IFS=. read -r b1 b2 b3 b4 <<<"$BROADCAST_ADDRESS"
IFS=. read -r n1 n2 n3 n4 <<<"$NETWORK_ADDRESS"

## Attempt to join any node within the calculated subnet range
for i1 in $(seq $n1 $b1); do
  for i2 in $(seq $n2 $b2); do
    for i3 in $(seq $n3 $b3); do
      for i4 in $(seq $((n4+1)) $((b4-1))); do
        TARGET="$i1.$i2.$i3.$i4"
        if [ "$TARGET" != "$IP_ADDRESS" ]; then
          rabbitmqctl stop_app
	  echo "${RABBITMQ_NODENAME} is joining rabbit@${TARGET}"
          rabbitmqctl join_cluster "rabbit@$TARGET" 2>/dev/null && break 4
          rabbitmqctl start_app
        fi
      done
    done
  done
done

# Bring RabbitMQ server to the foreground
#rabbitmqctl await_startup

while true; do sleep 10000; done


# Keep the container running
tail -f /var/log/rabbitmq/*
