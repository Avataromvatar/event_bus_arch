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

///Base class for errors raised by the MQTT transport.
typedef EventBusMqttException = EventBusTransportException;

///The broker cannot be reached, so the event was not published.
typedef MqttServerUnavailableException = TransportServerUnavailableException;

///A publish passed the connection check but still failed.
typedef MqttPublishException = TransportPublishException;

///A connection-level failure: handshake, authentication, exhausted retries.
typedef MqttConnectionException = TransportConnectionException;

///A topic cannot be represented as an MQTT topic, or a wildcard cannot be
///used in that position.
typedef MqttSubjectException = TransportSubjectException;

///A serializer failed to encode an outgoing event.
typedef MqttSerializationException = TransportSerializationException;

///A payload from the broker could not be turned into a local event.
typedef MqttDeserializationException = TransportDeserializationException;
