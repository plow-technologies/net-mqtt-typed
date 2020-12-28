# net-mqtt-typed

Provides a set of servant-inspired types to define an API over a set of MQTT
topics. It provides functions to create a set of publishing functions to topics
of this API or to create a subscriber given a set of functions to handle its
messages.

See the [example app](./examples/Demo.hs) to see how it can be used. The
[tests](./spec/Network/MQTT/Typed/SubscriberSpec.hs) can aslo give a clue.
