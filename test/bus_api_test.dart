import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('EventBus: handlers and dispose', () {
    test('subscribeEvents creates and cancels a handler', () async {
      final bus = EventBus();

      final handler = bus.subscribeEventsLegacy<String>(
          handler: (dto, lastData) async => 'ok');
      expect(bus.haveHandlerLegacy<String>(), true);
      expect(await bus.requestLegacy<String>('x'), 'ok');

      await handler.cancel();
      expect(bus.haveHandlerLegacy<String>(), false);
      await bus.dispose();
    });

    test('dispose is available on a variable of type EventBus', () async {
      final EventBus bus = EventBus();

      await bus.dispose();

      expect(bus.isDisposed, true);
    });

    test('a repeated dispose is safe', () async {
      final bus = EventBus();

      await bus.dispose();
      await bus.dispose();

      expect(bus.isDisposed, true);
    });

    test('send after dispose throws StateError', () async {
      final bus = EventBus();
      await bus.dispose();

      expect(() => bus.fireLegacy<String>('x'), throwsStateError);
      await expectLater(bus.requestLegacy<String>('x'), throwsStateError);
    });

    test('listen and subscribeEvents after dispose throw StateError', () async {
      final bus = EventBus();
      await bus.dispose();

      expect(() => bus.listenLegacy<String>(), throwsStateError);
      expect(
          () => bus.subscribeEventsLegacy<String>(
              handler: (dto, lastData) async {}),
          throwsStateError);
    });

    test('dispose closes the node streams', () async {
      final bus = EventBus();
      var done = false;
      bus.subscribeLegacy<String>(onData: (_) {}, onDone: () => done = true);

      await bus.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(done, true);
    });
  });

  group('EventBus: handler initial data', () {
    test('initialData is applied to an already existing node as well',
        () async {
      final bus = EventBus(isModelBus: true);
      final first = bus.subscribeEventsLegacy<int>(
          initialData: 1, handler: (dto, lastData) async {});
      await bus.requestLegacy<int>(2);
      expect(bus.currentDataLegacy<int>(), 2);

      await first.cancel();
      bus.subscribeEventsLegacy<int>(
          initialData: 10, handler: (dto, lastData) async {});

      expect(bus.currentDataLegacy<int>(), 10);
      await bus.dispose();
    });

    test('initialData is applied to a topic with paths', () async {
      final bus = EventBus(isModelBus: true);

      bus.subscribeEventsLegacy<int>(
          initialData: 5,
          paths: ['counter'],
          handler: (dto, lastData) async {});

      expect(bus.currentDataLegacy<int>(paths: ['counter']), 5);
      // another topic of the same type is untouched
      expect(bus.currentDataLegacy<int>(), null);
      await bus.dispose();
    });
  });
}
