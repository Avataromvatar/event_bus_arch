import 'package:event_bus_transport/event_bus_transport.dart';

export 'package:event_bus_transport/event_bus_transport.dart'
    show ReconnectPolicy;

///Exponential backoff for NATS reconnection attempts.
typedef NatsReconnectPolicy = ReconnectPolicy;
