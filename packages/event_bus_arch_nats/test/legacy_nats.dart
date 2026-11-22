// Test-only bridge from the 3.x NATS serializer maps to keyed codecs.

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_nats/event_bus_arch_nats.dart';

import '../../event_bus_arch_transport/test/legacy_codecs.dart';

EventBusNats legacyNats(
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
  ObservabilityConfig? observability,
}) =>
    EventBusNats.keys(
      server,
      codecs: legacyCodecs(
          serializers: serializers, deserializers: deserializers),
      options: options,
      reconnect: reconnect,
      pingInterval: pingInterval,
      subjectPrefix: subjectPrefix,
      originId: originId,
      connection: connection,
      observability: observability,
    );
