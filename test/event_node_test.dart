import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///A handler that throws SYNCHRONOUSLY (not an async function).
Future<void> syncThrowingHandler(EventDTO<String> dto, String? lastData) {
  throw StateError('sync boom');
}

void main() {
  group('EventNode: handler data', () {
    test('handler receives the previous value, not the current one', () async {
      final bus = EventBus();
      final seen = <String?>[];
      bus.handlers.setHandler<String>(initialData: 'INIT', handler: (dto, lastData) async {
        seen.add(lastData);
        dto.completer?.complete(dto.data);
      });

      await bus.send<String>('one');
      await bus.send<String>('two');

      expect(seen, ['INIT', 'one']);
      await bus.dispose();
    });

    test('lastData is updated synchronously, right after send', () {
      final bus = EventBus();
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {});

      bus.send<String>('data');

      expect(bus.lastData<String>(), 'data');
    });

    test('lastData in the handler does not depend on the initial value', () async {
      final bus = EventBus();
      int? previous;
      bus.handlers.setHandler<int>(initialData: 5, handler: (dto, lastData) async {
        previous = lastData;
      });

      await bus.send<int>(7);

      expect(previous, 5);
      expect(bus.lastData<int>(), 7);
    });
  });

  group('EventNode: handler errors', () {
    test('the error reaches the sender and the listener still gets the data', () async {
      final bus = EventBus();
      final received = <String>[];
      final sub = bus.subscribe<String>(onData: received.add);
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        throw StateError('boom');
      });

      await expectLater(bus.send<String>('x'), throwsStateError);

      await Future<void>.delayed(Duration.zero);
      expect(received, ['x']);
      await sub.cancel();
      await bus.dispose();
    });

    test('a synchronous handler throw also reaches the sender', () async {
      final bus = EventBus();
      bus.handlers.setHandler<String>(handler: syncThrowingHandler);

      await expectLater(bus.send<String>('x'), throwsStateError);
      await bus.dispose();
    });

    test('the bus keeps working after a handler error', () async {
      final bus = EventBus();
      var calls = 0;
      bus.handlers.setHandler<int>(handler: (dto, lastData) async {
        calls++;
        if (dto.data == 1) {
          throw StateError('boom');
        }
        dto.completer?.complete(dto.data * 10);
      });

      await expectLater(bus.send<int>(1), throwsStateError);
      expect(await bus.send<int>(2), 20);
      expect(calls, 2);
      await bus.dispose();
    });

    test('a handler that completes the completer and then throws does not surface StateError',
        () async {
      final bus = EventBus();
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        dto.completer?.complete('result');
        throw StateError('boom after complete');
      });

      expect(await bus.send<String>('x'), 'result');
      await bus.dispose();
    });
  });

  group('EventNode: delivery order', () {
    test('listeners receive the value before await send completes', () async {
      final bus = EventBus();
      final order = <String>[];
      final sub = bus.subscribe<String>(onData: (e) => order.add('listener:$e'));
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        order.add('handler-start');
        dto.completer?.complete('ok');
        order.add('handler-end');
      });

      await bus.send<String>('x');
      order.add('sender');

      // delivery to the listener runs in a separate microtask, but is scheduled BEFORE
      // the completer wakes up the sender
      expect(order.indexOf('listener:x'), greaterThan(order.indexOf('handler-start')));
      expect(order.indexOf('listener:x'), lessThan(order.indexOf('sender')));
      await sub.cancel();
      await bus.dispose();
    });

    test('cancel right after await send does not swallow the event', () async {
      final bus = EventBus();
      final received = <String>[];
      final sub = bus.subscribe<String>(onData: received.add);

      await bus.send<String>('x');
      await sub.cancel();

      expect(received, ['x']);
      await bus.dispose();
    });

    test('listeners receive the value even without a handler', () async {
      final bus = EventBus();
      final received = <String>[];
      bus.subscribe<String>(onData: received.add);

      expect(await bus.send<String>('x'), null);
      expect(received, ['x']);
      await bus.dispose();
    });
  });

  group('EventNode: mismatched data type', () {
    test('an event of a mismatched type does not hang the sender', () async {
      final bus = EventBus(isModelBus: true);
      // the node is created for Object, but a String arrives
      bus.handlers.setHandler<Object>(handler: (dto, lastData) async {
        dto.completer?.complete('handled');
      });

      final result = await bus.send<String>('x');

      expect(result, null);
      await bus.dispose();
    });
  });
}
