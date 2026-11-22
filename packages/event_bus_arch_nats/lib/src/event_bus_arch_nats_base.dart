import 'package:event_bus_arch/event_bus_arch.dart' show ObservabilityConfig;
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

import 'dart_nats_connection.dart';
import 'nats_connection.dart';
import 'nats_reconnect_policy.dart';
import 'nats_subject.dart';

///A bus that mirrors its event addresses to a NATS server.
///
///An address is published to the server only when a codec with `encode`
///resolves for it; it is subscribed to only when a codec with `decode`
///resolves. `fire` to an address outside the registry behaves exactly like a
///local bus: if no local node exists, it returns false.
///
///The bus behavior itself is shared with every transport
///([TransportEventBus]); this class only supplies the NATS connection and the
///NATS address grammar.
class EventBusNats extends TransportEventBus {
  ///Creates a NATS bus for the E address model.
  ///
  ///The wire subject is the event address; [codecs] resolve the encoder and the
  ///decoder by address. No Dart type name and no `typeTags` are involved.
  factory EventBusNats.keys(
    Uri server, {
    required EventCodecRegistry codecs,
    NatsConnectionOptions options = const NatsConnectionOptions(),
    NatsReconnectPolicy reconnect = const NatsReconnectPolicy(),
    Duration pingInterval = const Duration(seconds: 5),
    String? subjectPrefix,
    String? originId,
    NatsConnection? connection,
    ObservabilityConfig? observability,
  }) {
    final id = originId ?? newTransportOriginId();
    return EventBusNats._keys(
      connection: connection ??
          DartNatsConnection(
            server,
            options: options,
            reconnect: reconnect,
            pingInterval: pingInterval,
            originId: id,
          ),
      addresses: NatsAddressMapper(prefix: subjectPrefix),
      codecs: codecs,
      originId: id,
      observability: observability,
    );
  }

  EventBusNats._keys({
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
