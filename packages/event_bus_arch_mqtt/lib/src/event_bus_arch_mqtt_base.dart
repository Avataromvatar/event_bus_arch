import 'package:event_bus_arch/event_bus_arch.dart' show ObservabilityConfig;
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

import 'mqtt5_client_connection.dart';
import 'mqtt_connection.dart';
import 'mqtt_reconnect_policy.dart';
import 'mqtt_subject.dart';

///A bus that mirrors its event addresses to an MQTT 5 broker.
///
///An address is published to the broker only when a codec with `encode`
///resolves for it; it is subscribed to only when a codec with `decode`
///resolves. `fire` to an address outside the registry behaves exactly like a
///local bus: if no local node exists, it returns false.
///
///The bus behavior itself is shared with every transport
///([TransportEventBus]); this class only supplies the MQTT connection and the
///MQTT topic grammar.
class EventBusMqtt extends TransportEventBus {
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

}
