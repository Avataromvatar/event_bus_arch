import 'package:event_bus_transport/event_bus_transport.dart';

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
    );
  }

  EventBusMqtt._({
    required super.connection,
    required super.subjects,
    super.serializers,
    super.deserializers,
    required super.originId,
  });

  ///The topic-to-subject mapper used by this bus.
  @override
  MqttSubjectMapper get subjects => super.subjects as MqttSubjectMapper;
}
