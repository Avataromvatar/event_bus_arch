import 'package:event_bus_transport/event_bus_transport.dart';

export 'package:event_bus_transport/event_bus_transport.dart'
    show TopicRegistryIndex;

///Resolves a NATS serializer or deserializer for a topic.
typedef NatsRegistryIndex<T> = TopicRegistryIndex<T>;
