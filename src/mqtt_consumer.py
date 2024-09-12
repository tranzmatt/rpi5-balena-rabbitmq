import socket
import paho.mqtt.client as mqtt
import time

# MQTT broker settings
broker_address = "localhost"  # Assuming RabbitMQ is running locally
broker_port = 1883
topic = "demo/topic"

# Callback function when a message is received
def on_message(client, userdata, message):
    print(f"Received message: {message.payload.decode()}")

hostname = socket.gethostname()
client_id = f"Consumer-{hostname}"

# Create an MQTT client with a unique client ID
client = mqtt.Client(client_id)

# Attach the on_message function to the client
client.on_message = on_message

# Connect to the MQTT broker (RabbitMQ)
client.connect(broker_address, broker_port)

# Subscribe to the topic
client.subscribe(topic)

# Start the MQTT client loop
client.loop_forever()
