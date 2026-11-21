import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('EventBus: handlers and dispose', () {
    test('subscribeEvents creates and cancels a handler', () async {
      final bus = EventBus();

      final handler = bus.subscribeEvents<String>(
          handler: (dto, lastData) async => 'ok');
      expect(bus.haveHandler<String>(), true);
      expect(await bus.request<String>('x'), 'ok');

      await handler.cancel();
      expect(bus.haveHandler<String>(), false);
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

      expect(() => bus.fire<String>('x'), throwsStateError);
      await expectLater(bus.request<String>('x'), throwsStateError);
    });

    test('listen and subscribeEvents after dispose throw StateError', () async {
      final bus = EventBus();
      await bus.dispose();

      expect(() => bus.listen<String>(), throwsStateError);
      expect(
          () => bus.subscribeEvents<String>(
              handler: (dto, lastData) async {}),
          throwsStateError);
    });

    test('dispose closes the node streams', () async {
      final bus = EventBus();
      var done = false;
      bus.subscribe<String>(onData: (_) {}, onDone: () => done = true);

      await bus.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(done, true);
    });
  });

  group('EventBus: handler initial data', () {
    test('initialData is applied to an already existing node as well',
        () async {
      final bus = EventBus(isModelBus: true);
      final first = bus.subscribeEvents<int>(
          initialData: 1, handler: (dto, lastData) async {});
      await bus.request<int>(2);
      expect(bus.currentData<int>(), 2);

      await first.cancel();
      bus.subscribeEvents<int>(
          initialData: 10, handler: (dto, lastData) async {});

      expect(bus.currentData<int>(), 10);
      await bus.dispose();
    });

    test('initialData is applied to a topic with paths', () async {
      final bus = EventBus(isModelBus: true);

      bus.subscribeEvents<int>(
          initialData: 5,
          paths: ['counter'],
          handler: (dto, lastData) async {});

      expect(bus.currentData<int>(paths: ['counter']), 5);
      // another topic of the same type is untouched
      expect(bus.currentData<int>(), null);
      await bus.dispose();
    });
  });
}
