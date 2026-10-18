import 'dart:async';
import 'dart:typed_data';

///Connection states exposed to the bus and to the application.
enum TransportStatus {
  connecting,
  connected,
  reconnecting,
  disconnected,
  closed,
}

///Header names shared by all transports that can carry metadata.
abstract final class TransportHeaderNames {
  ///Identifies the bus instance that published a message, so its own
  ///subscriptions can ignore the server echo.
  static const String origin = 'X-EventBus-Origin';

  ///JSON-encoded `EventDTO.arguments`.
  static const String arguments = 'X-EventBus-Arguments';
}

///One message received from the broker.
class TransportMessage {
  const TransportMessage({
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
abstract class TransportSubscription {
  Future<void> cancel();
}

///The transport seam between the bus and a broker client.
abstract class TransportConnection {
  bool get isConnected;

  TransportStatus get status;

  Stream<TransportStatus> get statusStream;

  ///Asynchronous transport errors: a dropped connection, a failed publish,
  ///a failed reconnect attempt.
  Stream<Object> get errors;

  ///Starts the first connection attempt. The returned future completes when
  ///that attempt finishes; reconnection continues in the background.
  Future<void> start();

  ///Publishes a message. Throws [TransportServerUnavailableException] when the
  ///connection is not established. [replyTo] names the subject a response must
  ///be published to; it is a wire subject, not a local topic.
  void publish(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    String? replyTo,
  });

  ///Sends a request and waits for the first response.
  ///
  ///Throws [TransportServerUnavailableException] when the connection is not
  ///established and [TimeoutException] when no response arrives within
  ///[timeout]. A null timeout waits until a response arrives.
  Future<TransportMessage> request(
    String subject,
    Uint8List data, {
    Map<String, String>? arguments,
    String? originId,
    Duration? timeout,
  });

  ///Registers a subscription. When the connection is down the subscription is
  ///remembered and established after the next successful connection.
  TransportSubscription subscribe(
    String subject,
    void Function(TransportMessage message) onMessage,
  );

  Future<void> close();
}
