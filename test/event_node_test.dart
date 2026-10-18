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
      bus.handlers.setHandler<String>(
          initialData: 'INIT',
          handler: (dto, lastData) async {
            seen.add(lastData);
            dto.completer?.complete(dto.data);
          });

      await bus.request<String>('one');
      await bus.request<String>('two');

      expect(seen, ['INIT', 'one']);
      await bus.dispose();
    });

    test('lastData is updated synchronously, right after send', () async {
      final bus = EventBus();
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {});

      await bus.request<String>('data');

      expect(bus.currentData<String>(), 'data');
    });

    test('lastData in the handler does not depend on the initial value',
        () async {
      final bus = EventBus();
      int? previous;
      bus.handlers.setHandler<int>(
          initialData: 5,
          handler: (dto, lastData) async {
            previous = lastData;
          });

      await bus.request<int>(7);

      expect(previous, 5);
      expect(bus.currentData<int>(), 7);
    });
  });

  group('EventNode: handler errors', () {
    test('the error reaches the sender and the listener still gets the data',
        () async {
      final bus = EventBus();
      final received = <String>[];
      final sub = bus.subscribe<String>(onData: received.add);
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        throw StateError('boom');
      });

      await expectLater(bus.request<String>('x'), throwsStateError);

      await Future<void>.delayed(Duration.zero);
      expect(received, ['x']);
      await sub.cancel();
      await bus.dispose();
    });

    test('a synchronous handler throw also reaches the sender', () async {
      final bus = EventBus();
      bus.handlers.setHandler<String>(handler: syncThrowingHandler);

      await expectLater(bus.request<String>('x'), throwsStateError);
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

      await expectLater(bus.request<int>(1), throwsStateError);
      expect(await bus.request<int>(2), 20);
      expect(calls, 2);
      await bus.dispose();
    });

    test(
        'a handler that completes the completer and then throws does not surface StateError',
        () async {
      final bus = EventBus();
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        dto.completer?.complete('result');
        throw StateError('boom after complete');
      });

      expect(await bus.request<String>('x'), 'result');
      await bus.dispose();
    });
  });

  group('EventNode: delivery order', () {
    test('listeners receive the value before await send completes', () async {
      final bus = EventBus();
      final order = <String>[];
      final sub =
          bus.subscribe<String>(onData: (e) => order.add('listener:$e'));
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        order.add('handler-start');
        dto.completer?.complete('ok');
        order.add('handler-end');
      });

      await bus.request<String>('x');
      order.add('sender');

      // delivery to the listener runs in a separate microtask, but is scheduled BEFORE
      // the completer wakes up the sender
      expect(order.indexOf('listener:x'),
          greaterThan(order.indexOf('handler-start')));
      expect(order.indexOf('listener:x'), lessThan(order.indexOf('sender')));
      await sub.cancel();
      await bus.dispose();
    });

    test('fire schedules the value before a later cancel', () async {
      final bus = EventBus();
      final received = <String>[];
      final sub = bus.subscribe<String>(onData: received.add);

      expect(bus.fire<String>('x'), isTrue);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received, ['x']);
      await bus.dispose();
    });

    test('listeners receive the value even without a handler', () async {
      final bus = EventBus();
      final received = <String>[];
      bus.subscribe<String>(onData: received.add);

      expect(bus.fire<String>('x'), isTrue);
      await Future<void>.delayed(Duration.zero);
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

      await expectLater(
        bus.request<String>('x'),
        throwsA(isA<NoHandlerException>()),
      );
      await bus.dispose();
    });
  });

  group('EventNode: handlers are request-only', () {
    test('fire does not invoke a request handler', () async {
      final bus = EventBus();
      var called = false;
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {
        called = true;
      });

      expect(bus.fire<String>('x'), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(called, isFalse);
      await bus.dispose();
    });

    test('removeHandler keeps the node listeners', () async {
      final bus = EventBus();
      final received = <String>[];
      final subscription = bus.subscribe<String>(onData: received.add);
      bus.handlers.setHandler<String>(handler: (dto, lastData) async {});
      bus.handlers.removeHandler<String>();

      expect(bus.haveHandler<String>(), isFalse);
      expect(bus.haveListener<String>(), isTrue);
      expect(bus.fire<String>('x'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(received, ['x']);

      await subscription.cancel();
      await bus.dispose();
    });

    test('a registered handler keeps its node alive after listeners cancel',
        () async {
      final bus = EventBus();
      final subscription = bus.subscribe<String>(onData: (_) {});
      bus.handlers.setHandler<String>(handler: (dto, lastData) async => 'ok');

      await subscription.cancel();

      expect(bus.haveHandler<String>(), isTrue);
      expect(await bus.request<String>('x'), 'ok');
      await bus.dispose();
    });
  });

  group('EventNode: request validation', () {
    test('request rejects wildcard paths', () async {
      final bus = EventBus();

      await expectLater(
        bus.request<String>('x', paths: ['sensor', '*']),
        throwsA(isA<EventBusException>()),
      );
      await bus.dispose();
    });
  });
}
