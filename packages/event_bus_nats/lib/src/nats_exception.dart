import 'package:event_bus_arch/event_bus_arch.dart';

///Base class for errors raised by the NATS transport.
class EventBusNatsException extends EventBusException {
  EventBusNatsException([super.message]);
}

///The server cannot be reached, so the event was not published.
class NatsServerUnavailableException extends EventBusNatsException {
  NatsServerUnavailableException([this.subject])
    : super(
        subject == null
            ? 'NATS server is unavailable'
            : 'NATS server is unavailable (subject: $subject)',
      );

  ///The subject the caller tried to publish to, when known.
  final String? subject;
}

///A publish passed the connection check but still failed.
class NatsPublishException extends EventBusNatsException {
  NatsPublishException(super.message, {this.subject});

  ///The subject of the failed publish, when known.
  final String? subject;
}

///A connection-level failure: handshake, authentication, exhausted retries.
class NatsConnectionException extends EventBusNatsException {
  NatsConnectionException([super.message]);
}
