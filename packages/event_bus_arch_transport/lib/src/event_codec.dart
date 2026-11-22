import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

///Encodes an event for the broker.
///
///Returns the subject to publish to and the payload. A null subject means
///“derive it from [EventDTO.address]”; a non-null subject is used as is and
///must already be a full wire subject.
typedef EventEncoder = (String?, Uint8List) Function(EventDTO dto);

///Builds an event from a payload received from the broker.
///
///[address] is the concrete wire address, already mapped to the local grammar.
typedef EventDecoder = EventDTO Function(
  Uint8List data,
  EventAddress address, {
  Map<String, String>? arguments,
});

///The encode/decode pair for one address (or address pattern).
///
///A codec may implement only one direction: a publisher needs [encode], a
///subscriber needs [decode].
class EventCodec {
  const EventCodec({this.encode, this.decode});

  final EventEncoder? encode;
  final EventDecoder? decode;

  ///Whether this codec can publish.
  bool get canEncode => encode != null;

  ///Whether this codec can decode incoming messages.
  bool get canDecode => decode != null;
}

///Resolves a codec by address: exact first, then the most specific pattern.
class EventCodecRegistry {
  EventCodecRegistry({
    Map<EventAddress, EventCodec>? exact,
    Map<EventPattern, EventCodec>? patterns,
  })  : _exact = Map.unmodifiable(exact ?? const {}),
        _patterns = Map.unmodifiable(patterns ?? const {});

  final Map<EventAddress, EventCodec> _exact;
  final Map<EventPattern, EventCodec> _patterns;

  ///The codec for a concrete address.
  EventCodec? resolve(EventAddress address) {
    final exact = _exact[address];
    if (exact != null) return exact;

    EventCodec? bestCodec;
    var bestScore = -1;
    for (final entry in _patterns.entries) {
      if (!entry.key.matches(address)) continue;
      final score = entry.key.specificity;
      if (score > bestScore) {
        bestCodec = entry.value;
        bestScore = score;
      }
    }
    return bestCodec;
  }

  ///The codec registered for an exact pattern, if any.
  EventCodec? forPattern(EventPattern pattern) => _patterns[pattern];

  ///The codec registered for an exact address, if any.
  EventCodec? forAddress(EventAddress address) => _exact[address];

  ///Whether any registered codec can decode an incoming message.
  bool get hasDecoders =>
      _exact.values.any((codec) => codec.canDecode) ||
      _patterns.values.any((codec) => codec.canDecode);
}
