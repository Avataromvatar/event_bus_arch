import 'package:event_bus_arch/event_bus_arch.dart';

///Base class for errors raised by a transport.
class EventBusTransportException extends EventBusException {
  EventBusTransportException([super.message]);
}

///The broker cannot be reached, so the event was not published.
class TransportServerUnavailableException extends EventBusTransportException {
  TransportServerUnavailableException([this.subject])
      : super(subject == null
            ? 'transport server is unavailable'
            : 'transport server is unavailable (subject: $subject)');

  ///The subject the caller tried to publish to, when known.
  final String? subject;
}

///A publish passed the connection check but still failed.
class TransportPublishException extends EventBusTransportException {
  TransportPublishException(super.message, {this.subject});

  ///The subject of the failed publish, when known.
  final String? subject;
}

///A connection-level failure: handshake, authentication, exhausted retries.
class TransportConnectionException extends EventBusTransportException {
  TransportConnectionException([super.message]);
}

///A topic cannot be represented as a broker subject.
class TransportSubjectException extends EventBusTransportException {
  TransportSubjectException(super.message, {this.subject});

  ///The topic or subject that failed validation, when known.
  final String? subject;
}

///A serializer failed to encode an outgoing event.
class TransportSerializationException extends EventBusTransportException {
  TransportSerializationException(super.message, {this.subject, this.cause});

  ///The topic being serialized, when known.
  final String? subject;

  ///The error the serializer threw.
  final Object? cause;
}

///A payload from the broker could not be turned into a local event.
class TransportDeserializationException extends EventBusTransportException {
  TransportDeserializationException(super.message, {this.subject, this.cause});

  ///The wire subject being decoded, when known.
  final String? subject;

  ///The error the deserializer threw, when any.
  final Object? cause;
}
