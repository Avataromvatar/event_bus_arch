import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';
import 'legacy_compat.dart';

void main() {
  group('EventBus: wildcard listeners', () {
    test('a pattern listener receives matching concrete events', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.listenLegacy<int>(paths: ['sensor', '*']).listen(received.add);

      expect(bus.fireLegacy<int>(1, paths: ['sensor', 'temp']), isTrue);
      expect(bus.fireLegacy<int>(2, paths: ['sensor', 'humidity']), isTrue);
      expect(bus.fireLegacy<int>(3, paths: ['sensor']), isFalse);
      expect(bus.fireLegacy<int>(4, paths: ['other', 'temp']), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(received, [1, 2]);
      expect(bus.currentDataLegacy<int>(paths: ['sensor', '*']), 2);
      expect(bus.currentDataLegacy<int>(paths: ['sensor', 'temp']), isNull);
      expect(bus.haveListenerLegacy<int>(paths: ['sensor', 'temp']), isTrue);
      expect(bus.haveListenerLegacy<int>(paths: ['sensor', '*']), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('fire rejects wildcard paths', () async {
      final bus = EventBus();

      expect(() => bus.fireLegacy<int>(1, paths: ['sensor', '*']),
          throwsA(isA<EventBusException>()));
      await bus.dispose();
    });
  });

  group('EventBus: wildcard request handlers', () {
    test('a request is answered by a pattern handler', () async {
      final bus = EventBus();
      String? seenTopic;
      int? seenLast;
      bus.subscribeEventsLegacy<int>(
          paths: ['sensor', '*'],
          handler: (dto, lastData) async {
            seenTopic = dto.address;
            seenLast = lastData;
            return dto.data * 2;
          });

      // The pattern node's previous value is updated by fire events.
      bus.fireLegacy<int>(5, paths: ['sensor', 'temp']);
      await Future<void>.delayed(Duration.zero);

      expect(await bus.requestLegacy<int>(7, paths: ['sensor', 'temp']), 14);
      expect(seenTopic, 'int.sensor.temp');
      expect(seenLast, 5);
      expect(bus.haveHandlerLegacy<int>(paths: ['sensor', 'temp']), isTrue);
      await bus.dispose();
    });

    test('an exact handler wins over a pattern handler', () async {
      final bus = EventBus();
      bus.subscribeEventsLegacy<int>(
          paths: ['sensor', '*'], handler: (dto, lastData) async => 'pattern');
      bus.subscribeEventsLegacy<int>(
          paths: ['sensor', 'temp'], handler: (dto, lastData) async => 'exact');

      expect(await bus.requestLegacy<int>(1, paths: ['sensor', 'temp']), 'exact');
      await bus.dispose();
    });

    test('the most specific pattern handler wins', () async {
      final bus = EventBus();
      bus.subscribeEventsLegacy<int>(
          paths: ['*', '*'], handler: (dto, lastData) async => 'short');
      bus.subscribeEventsLegacy<int>(
          paths: ['sensor', '*'], handler: (dto, lastData) async => 'long');

      expect(await bus.requestLegacy<int>(1, paths: ['sensor', 'temp']), 'long');
      await bus.dispose();
    });

    test('cancelling a pattern responder removes it', () async {
      final bus = EventBus();
      final handler = bus.subscribeEventsLegacy<int>(
          paths: ['sensor', '*'], handler: (dto, lastData) async => 1);
      await handler.cancel();

      expect(bus.haveHandlerLegacy<int>(paths: ['sensor', '*']), isFalse);
      await expectLater(
        bus.requestLegacy<int>(1, paths: ['sensor', 'temp']),
        throwsA(isA<NoHandlerException>()),
      );
      await bus.dispose();
    });
  });
}
