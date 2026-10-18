import 'dart:async';
import 'dart:typed_data';

///Connection states exposed to the bus and to the application.
enum NatsConnectionStatus {
  connecting,
  connected,
  reconnecting,
  disconnected,
  closed,
}

///Header names used by the transport.
abstract final class NatsHeaderNames {
  ///Identifies the bus instance that published a message, so its own
  ///subscriptions can ignore the server echo.
  static const String origin = 'X-EventBus-Origin';

  ///JSON-encoded `EventDTO.arguments`.
  static const String arguments = 'X-EventBus-Arguments';
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

///One message received from the server.
class NatsMessage {
  const NatsMessage({
    required this.subject,
    required this.data,
    this.arguments,
    this.replyTo,
  });

  final String subject;
  final Uint8List data;
  final Map<String, String>? arguments;
  final String? replyTo;
}

///A handle to one registered subscription.
abstract class NatsSubscription {
  Future<void> cancel();
}

///The transport seam between the bus and a NATS client.
abstract class NatsConnection {
  bool get isConnected;

  NatsConnectionStatus get status;

  Stream<NatsConnectionStatus> get statusStream;

  ///Asynchronous transport errors: a dropped connection, a failed publish,
  ///a deserialization problem in the transport layer.
  Stream<Object> get errors;

  ///Starts the first connection attempt. The returned future completes when
  ///that attempt finishes; reconnection continues in the background.
  Future<void> start();

  ///Publishes a message. Throws [NatsServerUnavailableException] when the
  ///connection is not established.
  void publish(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
  });

  ///Registers a subscription. When the connection is down the subscription is
  ///remembered and established after the next successful connection.
  NatsSubscription subscribe(
    String subject,
    void Function(NatsMessage message) onMessage,
  );

  Future<void> close();
}
