import 'package:event_bus_transport/event_bus_transport.dart';

export 'package:event_bus_transport/event_bus_transport.dart'
    show
        TransportConnection,
        TransportHeaderNames,
        TransportMessage,
        TransportStatus,
        TransportSubscription;

///MQTT connection states. Kept as an alias so MQTT code keeps its spelling
///while the lifecycle itself is transport-agnostic.
typedef MqttConnectionStatus = TransportStatus;

///One message received from the broker.
typedef MqttMessage = TransportMessage;

///A handle to one registered subscription.
typedef MqttSubscription = TransportSubscription;

///The transport seam between the bus and an MQTT client.
typedef MqttConnection = TransportConnection;

///The delivery guarantee used for publishes and subscriptions.
enum MqttQosLevel { atMostOnce, atLeastOnce, exactlyOnce }

///Connection options that do not leak `mqtt5_client` types into the public
///API.
class MqttConnectionOptions {
  const MqttConnectionOptions({
    this.clientId,
    this.username,
    this.password,
    this.keepAlive = const Duration(seconds: 30),
    this.cleanStart = true,
    this.qos = MqttQosLevel.atMostOnce,
    this.useUserProperties = true,
    this.noLocal = true,
    this.sessionExpiryInterval = 0,
    this.connectTimeout = const Duration(seconds: 5),
  });

  ///The MQTT client identifier. When null, a unique id is derived from the
  ///bus's origin id.
  final String? clientId;

  final String? username;
  final String? password;

  ///The keep-alive interval sent to the broker; zero disables it.
  final Duration keepAlive;

  ///Whether the broker should discard a previous session for this client id.
  final bool cleanStart;

  ///The QoS for published events and subscriptions.
  final MqttQosLevel qos;

  ///Whether to transmit `arguments` and the origin marker as MQTT 5 user
  ///properties. When false, `arguments` are not transmitted and self-echo is
  ///not filtered by the origin property.
  final bool useUserProperties;

  ///Whether subscriptions set the MQTT 5 `noLocal` option. When true, the
  ///broker does not send a client its own publications.
  final bool noLocal;

  ///The session expiry interval for a persistent session. Ignored when
  ///[cleanStart] is true.
  final int sessionExpiryInterval;

  ///How long the client waits for the connection handshake.
  final Duration connectTimeout;
}
