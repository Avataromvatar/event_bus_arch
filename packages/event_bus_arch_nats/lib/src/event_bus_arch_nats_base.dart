import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

import 'dart_nats_connection.dart';
import 'nats_connection.dart';
import 'nats_reconnect_policy.dart';
import 'nats_subject.dart';

///A bus that mirrors its topics to a NATS server.
///
///A topic is published to the server only when [serializers] has an entry for
///it; it is subscribed to only when [deserializers] has one. `fire` to a topic
///outside both registries behaves exactly like a local bus: if no local node
///exists, it returns false.
///
///The bus behavior itself is shared with every transport
///([TransportEventBus]); this class only supplies the NATS connection and the
///NATS subject grammar.
class EventBusNats extends TransportEventBus {
  ///[connection] replaces the default [DartNatsConnection]; when it is given,
  ///[server], [options], [reconnect] and [pingInterval] are ignored. The
  ///injected connection must use the same origin id as the bus to filter the
  ///bus's own echo.
  factory EventBusNats(
    Uri server, {
    Map<String, EventDTOSerialization>? serializers,
    Map<String, EventDTODeserialization>? deserializers,
    NatsConnectionOptions options = const NatsConnectionOptions(),
    NatsReconnectPolicy reconnect = const NatsReconnectPolicy(),
    Duration pingInterval = const Duration(seconds: 5),
    String? subjectPrefix,
    Map<String, String>? typeTags,
    String? originId,
    NatsConnection? connection,
  }) {
    final id = originId ?? newTransportOriginId();
    return EventBusNats._(
      connection:
          connection ??
          DartNatsConnection(
            server,
            options: options,
            reconnect: reconnect,
            pingInterval: pingInterval,
            originId: id,
          ),
      subjects: NatsSubjectMapper(prefix: subjectPrefix, typeTags: typeTags),
      serializers: serializers,
      deserializers: deserializers,
      originId: id,
    );
  }

  EventBusNats._({
    required super.connection,
    required super.subjects,
    super.serializers,
    super.deserializers,
    required super.originId,
  });

  ///The topic-to-subject mapper used by this bus.
  @override
  NatsSubjectMapper get subjects => super.subjects as NatsSubjectMapper;
}
