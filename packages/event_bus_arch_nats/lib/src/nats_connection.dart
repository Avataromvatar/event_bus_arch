import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

export 'package:event_bus_arch_transport/event_bus_arch_transport.dart'
    show
        TransportConnection,
        TransportHeaderNames,
        TransportMessage,
        TransportStatus,
        TransportSubscription;

///NATS connection states. Kept as an alias so existing NATS code keeps its
///spelling while the lifecycle itself is transport-agnostic.
typedef NatsConnectionStatus = TransportStatus;

///One message received from the server.
typedef NatsMessage = TransportMessage;

///A handle to one registered subscription.
typedef NatsSubscription = TransportSubscription;

///The transport seam between the bus and a NATS client.
typedef NatsConnection = TransportConnection;

///Header names used by the NATS transport.
abstract final class NatsHeaderNames {
  ///Identifies the bus instance that published a message, so its own
  ///subscriptions can ignore the server echo.
  static const String origin = TransportHeaderNames.origin;

  ///JSON-encoded `EventDTO.arguments`.
  static const String arguments = TransportHeaderNames.arguments;
}

///Connection options that do not leak `dart_nats` types into the public API.
class NatsConnectionOptions {
  const NatsConnectionOptions({
    this.user,
    this.password,
    this.token,
    this.useHeaders = true,
    this.securityContext,
  });

  final String? user;
  final String? password;
  final String? token;

  ///Whether to use NATS headers (needs a server with header support, 2.2+).
  ///When false, `arguments` and the origin marker are not transmitted.
  final bool useHeaders;

  ///A `SecurityContext` from `dart:io`. Kept as [Object] so this API stays
  ///platform-neutral; the adapter passes it to the client.
  final Object? securityContext;
}
