import 'package:event_bus_transport/event_bus_transport.dart';

export 'package:event_bus_transport/event_bus_transport.dart'
    show TopicRegistryIndex;

///Resolves an MQTT serializer or deserializer for a topic.
typedef MqttRegistryIndex<T> = TopicRegistryIndex<T>;
