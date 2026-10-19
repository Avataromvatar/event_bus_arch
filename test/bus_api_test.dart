import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('EventBus: handlers and dispose', () {
    test('handlers gives handler management without a cast', () async {
      final bus = EventBus();

      expect(bus.handlers, isA<EventBusHandlers>());
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        return 'ok';
      });
      expect(bus.haveHandler<String>(), true);
      expect(await bus.request<String>('x'), 'ok');

      bus.handlers.removeHandler<String>();
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

    test('listen and setHandler after dispose throw StateError', () async {
      final bus = EventBus();
      await bus.dispose();

      expect(() => bus.listen<String>(), throwsStateError);
      expect(
          () => bus.handlers
              .setHandler<String>(handler: (dto, lastData) async {}),
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

  group('EventBus: transferring handlers', () {
    test('nodes are copied: disposing one bus does not break the other',
        () async {
      final busA = EventBus();
      final busB = EventBus();
      busB.handlers.setHandler<int>(
          initialData: 1,
          handler: (dto, lastData) async {
            return 'from B: ${dto.data}';
          });

      busA.handlers.addAllHandlerFromOtherBus(busB);
      expect(busA.haveHandler<int>(), true);
      expect(await busA.request<int>(2), 'from B: 2');

      await busA.dispose();

      expect(await busB.request<int>(3), 'from B: 3');
      expect(busB.currentData<int>(), 3);
      await busB.dispose();
    });

    test(
        'removeAllHandlerPresentInOtherBus removes only topics of the other bus',
        () async {
      final busA = EventBus();
      final busB = EventBus();
      busB.handlers.setHandler<int>(handler: (dto, lastData) async {});
      busA.handlers.setHandler<int>(handler: (dto, lastData) async {});
      busA.handlers.setHandler<String>(handler: (dto, lastData) async {});

      busA.handlers.removeAllHandlerPresentInOtherBus(busB);

      expect(busA.haveHandler<int>(), false);
      expect(busA.haveHandler<String>(), true);
      await busA.dispose();
      await busB.dispose();
    });
  });

  group('EventBus: handler initial data', () {
    test('initialData is applied to an already existing node as well',
        () async {
      final bus = EventBus(isModelBus: true);
      bus.handlers
          .setHandler<int>(initialData: 1, handler: (dto, lastData) async {});
      await bus.request<int>(2);
      expect(bus.currentData<int>(), 2);

      bus.handlers
          .setHandler<int>(initialData: 10, handler: (dto, lastData) async {});

      expect(bus.currentData<int>(), 10);
      await bus.dispose();
    });

    test('initialData is applied to a topic with paths', () async {
      final bus = EventBus(isModelBus: true);

      bus.handlers.setHandler<int>(
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
