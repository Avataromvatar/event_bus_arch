import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

export 'package:event_bus_arch_transport/event_bus_arch_transport.dart'
    show ReconnectPolicy;

///Exponential backoff for NATS reconnection attempts.
typedef NatsReconnectPolicy = ReconnectPolicy;
