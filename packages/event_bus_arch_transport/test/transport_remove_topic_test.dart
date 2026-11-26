import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:event_bus_arch_transport/testing.dart';
import 'package:test/test.dart';

class _TestGrammar extends SubjectGrammar {
  const _TestGrammar();

  @override
  String get separator => '.';

  @override
  String get singleWildcard => '*';

  @override
  String get tailWildcard => '>';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {}

  @override
  void validateSubscriptionToken(String token,
      {required bool isFirst, required bool isLast}) {}
}

EventCodec _intCodec() => EventCodec(
      encode: (dto) => (null, Uint8List(0)),
      decode: (data, address, {arguments}) =>
          EventDTO<int>.withKey(EventKey<int>(address.value), 1),
    );

void main() {
  group('TransportEventBus.remove', () {
    late FakeTransportConnection connection;
    late TransportEventBus bus;

    setUp(() {
      connection = FakeTransportConnection();
      bus = TransportEventBus.keys(
        connection: connection,
        addresses: EventAddressMapper(grammar: const _TestGrammar()),
        codecs:
            EventCodecRegistry(exact: {EventAddress('int.state'): _intCodec()}),
        originId: 'test-origin',
      );
    });

    tearDown(() async {
      await bus.dispose();
    });

    test('removes a transport node and cancels its subscription', () async {
      // The node is created by subscribe and subscribes to the broker.
      final sub = bus.subscribe(EventKey<int>('int.state'), onEvent: (_) {});
      expect(connection.subscribedSubjects, contains('int.state'));
      expect(bus.currentData(EventKey<int>('int.state')), isNull);

      expect(bus.remove(EventKey<int>('int.state')), isTrue);

      expect(connection.subscribedSubjects, isNot(contains('int.state')));
      expect(bus.probeFire(EventKey<int>('int.state'), 0).localListeners, 0);

      // A send with no local subscriber creates a node only for publication:
      // the node is detached again after delivery.
      expect(bus.fire(EventKey<int>('int.state'), 2), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(connection.subscribedSubjects, isNot(contains('int.state')));

      await sub.cancel();
    });

    test('returns false for an address without a node', () async {
      expect(bus.remove(EventKey<int>('int.missing')), isFalse);
    });
  });
}
