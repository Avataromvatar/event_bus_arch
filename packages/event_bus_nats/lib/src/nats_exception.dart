import 'package:event_bus_transport/event_bus_transport.dart';

export 'package:event_bus_transport/event_bus_transport.dart'
    show
        EventBusTransportException,
        TransportConnectionException,
        TransportDeserializationException,
        TransportPublishException,
        TransportSerializationException,
        TransportServerUnavailableException,
        TransportSubjectException;

///Base class for errors raised by the NATS transport.
typedef EventBusNatsException = EventBusTransportException;

///The server cannot be reached, so the event was not published.
typedef NatsServerUnavailableException = TransportServerUnavailableException;

///A publish passed the connection check but still failed.
typedef NatsPublishException = TransportPublishException;

///A connection-level failure: handshake, authentication, exhausted retries.
typedef NatsConnectionException = TransportConnectionException;

///A topic cannot be represented as a NATS subject (or a pattern cannot be
///used as a subscription subject).
typedef NatsSubjectException = TransportSubjectException;

///A serializer failed to encode an outgoing event.
typedef NatsSerializationException = TransportSerializationException;

///A payload from the server could not be turned into a local event.
typedef NatsDeserializationException = TransportDeserializationException;
