import socket
import paho.mqtt.client as mqtt
import time

# MQTT broker settings
broker_address = "localhost"  # Assuming RabbitMQ is running locally
broker_port = 1883
topic = "demo/topic"

hostname = socket.gethostname()
client_id = f"Producer-{hostname}"

# Create an MQTT client with a unique client ID
client = mqtt.Client(client_id)

# Connect to the MQTT broker (RabbitMQ)
client.connect(broker_address, broker_port)

def publish_messages():
    counter = 0
    while True:
        message = f"Message {counter} from Consul leader"
        client.publish(topic, message)
        print(f"Published: {message}")
        counter += 1
        time.sleep(5)  # Publish a message every 5 seconds

if __name__ == "__main__":
    publish_messages()
