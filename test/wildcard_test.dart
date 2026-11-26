// ignore_for_file: deprecated_member_use
import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('EventBus: wildcard listeners', () {
    test('a pattern listener receives matching concrete events', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub =
          bus.listen(EventPatternKey<int>('int.sensor.*')).listen(received.add);

      expect(bus.fire(EventKey<int>('int.sensor.temp'), 1), isTrue);
      expect(bus.fire(EventKey<int>('int.sensor.humidity'), 2), isTrue);
      expect(bus.fire(EventKey<int>('int.sensor'), 3), isFalse);
      expect(bus.fire(EventKey<int>('int.other.temp'), 4), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(received, [1, 2]);
      expect(bus.currentData(EventPatternKey<int>('int.sensor.*')), 2);
      expect(bus.currentData(EventKey<int>('int.sensor.temp')), isNull);
      expect(bus.haveListener(EventKey<int>('int.sensor.temp')), isTrue);
      expect(bus.haveListener(EventPatternKey<int>('int.sensor.*')), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('fire rejects wildcard paths', () async {
      final bus = EventBus();

      expect(() => bus.fire(EventKey<int>('int.sensor.*'), 1),
          throwsA(isA<EventBusException>()));
      await bus.dispose();
    });
  });

  group('EventBus: wildcard request handlers', () {
    test('a request is answered by a pattern handler', () async {
      final bus = EventBus();
      String? seenTopic;
      int? seenLast;
      bus.subscribe(EventPatternKey<int>('int.sensor.*'),
          handler: (dto, lastData) async {
        seenTopic = dto.address;
        seenLast = lastData;
        return dto.data * 2;
      });

      // The pattern node's previous value is updated by fire events.
      bus.fire(EventKey<int>('int.sensor.temp'), 5);
      await Future<void>.delayed(Duration.zero);

      expect(await bus.request(EventKey<int>('int.sensor.temp'), 7), 14);
      expect(seenTopic, 'int.sensor.temp');
      expect(seenLast, 5);
      expect(bus.haveHandler(EventKey<int>('int.sensor.temp')), isTrue);
      await bus.dispose();
    });

    test('an exact handler wins over a pattern handler', () async {
      final bus = EventBus();
      bus.subscribe(EventPatternKey<int>('int.sensor.*'),
          handler: (dto, lastData) async => 'pattern');
      bus.subscribe(EventKey<int>('int.sensor.temp'),
          handler: (dto, lastData) async => 'exact');

      expect(await bus.request(EventKey<int>('int.sensor.temp'), 1), 'exact');
      await bus.dispose();
    });

    test('the most specific pattern handler wins', () async {
      final bus = EventBus();
      bus.subscribe(EventPatternKey<int>('int.*.*'),
          handler: (dto, lastData) async => 'short');
      bus.subscribe(EventPatternKey<int>('int.sensor.*'),
          handler: (dto, lastData) async => 'long');

      expect(await bus.request(EventKey<int>('int.sensor.temp'), 1), 'long');
      await bus.dispose();
    });

    test('cancelling a pattern responder removes it', () async {
      final bus = EventBus();
      final handler = bus.subscribe(EventPatternKey<int>('int.sensor.*'),
          handler: (dto, lastData) async => 1);
      await handler.cancel();

      expect(bus.haveHandler(EventPatternKey<int>('int.sensor.*')), isFalse);
      await expectLater(
        bus.request(EventKey<int>('int.sensor.temp'), 1),
        throwsA(isA<NoHandlerException>()),
      );
      await bus.dispose();
    });
  });
}
