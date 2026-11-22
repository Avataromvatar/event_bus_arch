import 'package:event_bus_arch/event_bus_arch.dart' show ObservabilityConfig;
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

import 'mqtt5_client_connection.dart';
import 'mqtt_connection.dart';
import 'mqtt_reconnect_policy.dart';
import 'mqtt_subject.dart';

///A bus that mirrors its topics to an MQTT 5 broker.
///
///A topic is published to the broker only when [serializers] has an entry for
///it; it is subscribed to only when [deserializers] has one. `fire` to a topic
///outside both registries behaves exactly like a local bus: if no local node
///exists, it returns false.
///
///The bus behavior itself is shared with every transport
///([TransportEventBus]); this class only supplies the MQTT connection and the
///MQTT topic grammar.
class EventBusMqtt extends TransportEventBus {
  ///[connection] replaces the default [MqttServerConnection]; when it is given,
  ///[broker], [options] and [reconnect] are ignored. The injected connection
  ///must use the same origin id as the bus to filter the bus's own echo.
  factory EventBusMqtt(
    Uri broker, {
    Map<String, EventDTOSerialization>? serializers,
    Map<String, EventDTODeserialization>? deserializers,
    MqttConnectionOptions options = const MqttConnectionOptions(),
    MqttReconnectPolicy reconnect = const MqttReconnectPolicy(),
    String? subjectPrefix,
    Map<String, String>? typeTags,
    String? originId,
    MqttConnection? connection,
    ObservabilityConfig? observability,
  }) {
    final id = originId ?? newTransportOriginId();
    return EventBusMqtt._(
      connection:
          connection ??
          MqttServerConnection(
            broker,
            options: options,
            reconnect: reconnect,
            originId: id,
          ),
      subjects: MqttSubjectMapper(prefix: subjectPrefix, typeTags: typeTags),
      serializers: serializers,
      deserializers: deserializers,
      originId: id,
      observability: observability,
    );
  }

  ///Creates an MQTT bus for the E address model.
  ///
  ///The wire topic is the event address; [codecs] resolve the encoder and the
  ///decoder by address. No Dart type name and no `typeTags` are involved.
  factory EventBusMqtt.keys(
    Uri broker, {
    required EventCodecRegistry codecs,
    MqttConnectionOptions options = const MqttConnectionOptions(),
    MqttReconnectPolicy reconnect = const MqttReconnectPolicy(),
    String? subjectPrefix,
    String? originId,
    MqttConnection? connection,
    ObservabilityConfig? observability,
  }) {
    final id = originId ?? newTransportOriginId();
    return EventBusMqtt._keys(
      connection: connection ??
          MqttServerConnection(
            broker,
            options: options,
            reconnect: reconnect,
            originId: id,
          ),
      addresses: MqttAddressMapper(prefix: subjectPrefix),
      codecs: codecs,
      originId: id,
      observability: observability,
    );
  }

  EventBusMqtt._({
    required super.connection,
    required super.subjects,
    super.serializers,
    super.deserializers,
    required super.originId,
    super.observability,
  });

  EventBusMqtt._keys({
    required TransportConnection connection,
    required EventAddressMapper addresses,
    required EventCodecRegistry codecs,
    required String originId,
    ObservabilityConfig? observability,
  }) : super.keys(
          connection: connection,
          addresses: addresses,
          codecs: codecs,
          originId: originId,
          observability: observability,
        );

  ///The topic-to-subject mapper used by a legacy bus.
  @override
  MqttSubjectMapper get subjects => super.subjects as MqttSubjectMapper;
}
