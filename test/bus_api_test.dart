// ignore_for_file: deprecated_member_use
import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('EventBus: handlers and dispose', () {
    test('subscribe creates and cancels a handler', () async {
      final bus = EventBus();

      final handler = bus.subscribe(EventKey<String>('String'),
          handler: (dto, lastData) async => 'ok');
      expect(bus.haveHandler(EventKey<String>('String')), true);
      expect(await bus.request(EventKey<String>('String'), 'x'), 'ok');

      await handler.cancel();
      expect(bus.haveHandler(EventKey<String>('String')), false);
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

      expect(() => bus.fire(EventKey<String>('String'), 'x'), throwsStateError);
      await expectLater(
          bus.request(EventKey<String>('String'), 'x'), throwsStateError);
    });

    test('listen and subscribe after dispose throw StateError', () async {
      final bus = EventBus();
      await bus.dispose();

      expect(() => bus.listen(EventKey<String>('String')), throwsStateError);
      expect(
          () => bus.subscribe(EventKey<String>('String'),
              handler: (dto, lastData) async {}),
          throwsStateError);
    });

    test('dispose closes the node streams', () async {
      final bus = EventBus();
      var done = false;
      bus
          .listen(EventKey<String>('String'))
          .listen((_) {}, onDone: () => done = true);

      await bus.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(done, true);
    });
  });

  group('EventBus: handler initial data', () {
    test('initialData is applied to an already existing node as well',
        () async {
      final bus = EventBus(isModelBus: true);
      final first = bus.subscribe(EventKey<int>('int'),
          initialData: 1, handler: (dto, lastData) async {});
      await bus.request(EventKey<int>('int'), 2);
      expect(bus.currentData(EventKey<int>('int')), 2);

      await first.cancel();
      bus.subscribe(EventKey<int>('int'),
          initialData: 10, handler: (dto, lastData) async {});

      expect(bus.currentData(EventKey<int>('int')), 10);
      await bus.dispose();
    });

    test('initialData is applied to a topic with paths', () async {
      final bus = EventBus(isModelBus: true);

      bus.subscribe(EventKey<int>('int.counter'),
          initialData: 5, handler: (dto, lastData) async {});

      expect(bus.currentData(EventKey<int>('int.counter')), 5);
      // another topic of the same type is untouched
      expect(bus.currentData(EventKey<int>('int')), null);
      await bus.dispose();
    });
  });
}
