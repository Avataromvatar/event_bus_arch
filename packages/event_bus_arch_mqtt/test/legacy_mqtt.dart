// Test-only bridge from the 3.x MQTT serializer maps to keyed codecs.

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';

import '../../event_bus_arch_transport/test/legacy_codecs.dart';

EventBusMqtt legacyMqtt(
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
}) =>
    EventBusMqtt.keys(
      broker,
      codecs: legacyCodecs(
          serializers: serializers, deserializers: deserializers),
      options: options,
      reconnect: reconnect,
      subjectPrefix: subjectPrefix,
      originId: originId,
      connection: connection,
      observability: observability,
    );
