// Test-only bridge from the 3.x serializer/deserializer maps to the keyed
// transport codec registry. Production code no longer exposes these maps.

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

import 'dart:typed_data';

typedef EventDTOSerialization = (String?, Uint8List) Function(EventDTO dto);
typedef EventDTODeserialization = EventDTO Function(
  Uint8List data,
  String topic, {
  Map<String, String>? arguments,
});

EventCodecRegistry legacyCodecs({
  Map<String, EventDTOSerialization>? serializers,
  Map<String, EventDTODeserialization>? deserializers,
}) {
  final exact = <EventAddress, EventCodec>{};
  final patterns = <EventPattern, EventCodec>{};

  EventCodec merge(EventCodec? old, EventCodec add) => EventCodec(
        encode: add.encode ?? old?.encode,
        decode: add.decode ?? old?.decode,
      );

  void put(String key, EventCodec codec) {
    if (key.contains('*') || key.contains('>')) {
      final pattern = EventPattern(key);
      patterns[pattern] = merge(patterns[pattern], codec);
    } else {
      final address = EventAddress(key);
      exact[address] = merge(exact[address], codec);
      // The old registry fell back to the type token (the first token) for
      // any concrete topic. A tail pattern reproduces that lookup.
      final tail = EventPattern('$key.>');
      patterns[tail] = merge(patterns[tail], codec);
    }
  }

  for (final entry in (serializers ?? const {}).entries) {
    put(
      entry.key,
      EventCodec(encode: entry.value),
    );
  }
  for (final entry in (deserializers ?? const {}).entries) {
    put(
      entry.key,
      EventCodec(
        decode: (data, address, {arguments}) {
          final decoded = entry.value(data, address.value,
              arguments: arguments);
          return EventDTO<dynamic>.withKey(
            EventKey<dynamic>(address.value),
            decoded.data,
            arguments: decoded.arguments ?? arguments,
            correlationId: decoded.correlationId,
          );
        },
      ),
    );
  }
  return EventCodecRegistry(exact: exact, patterns: patterns);
}

///Builds a keyed transport bus from a grammar and the old serializer maps.
TransportEventBus legacyTransportBus({
  required TransportConnection connection,
  required SubjectGrammar grammar,
  String? prefix,
  Map<String, EventDTOSerialization>? serializers,
  Map<String, EventDTODeserialization>? deserializers,
  required String originId,
  ObservabilityConfig? observability,
}) =>
    TransportEventBus.keys(
      connection: connection,
      addresses: EventAddressMapper(grammar: grammar, prefix: prefix),
      codecs: legacyCodecs(
          serializers: serializers, deserializers: deserializers),
      originId: originId,
      observability: observability,
    );
