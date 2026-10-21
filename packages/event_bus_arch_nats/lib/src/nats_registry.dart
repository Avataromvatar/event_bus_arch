import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

export 'package:event_bus_arch_transport/event_bus_arch_transport.dart'
    show TopicRegistryIndex;

///Resolves a NATS serializer or deserializer for a topic.
typedef NatsRegistryIndex<T> = TopicRegistryIndex<T>;
