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
      bus.subscribeEventsLegacy<String>(
          initialData: 'INIT',
          handler: (dto, lastData) async {
            seen.add(lastData);
            return dto.data;
          });

      await bus.requestLegacy<String>('one');
      await bus.requestLegacy<String>('two');

      expect(seen, ['INIT', 'one']);
      await bus.dispose();
    });

    test('lastData is updated synchronously, right after send', () async {
      final bus = EventBus();
      bus.subscribeEventsLegacy<String>(handler: (dto, lastData) async {});

      await bus.requestLegacy<String>('data');

      expect(bus.currentDataLegacy<String>(), 'data');
    });

    test('lastData in the handler does not depend on the initial value',
        () async {
      final bus = EventBus();
      int? previous;
      bus.subscribeEventsLegacy<int>(
          initialData: 5,
          handler: (dto, lastData) async {
            previous = lastData;
          });

      await bus.requestLegacy<int>(7);

      expect(previous, 5);
      expect(bus.currentDataLegacy<int>(), 7);
    });
  });

  group('EventNode: handler errors', () {
    test('the error reaches the sender and the listener still gets the data',
        () async {
      final bus = EventBus();
      final received = <String>[];
      final sub = bus.subscribeLegacy<String>(onData: received.add);
      bus.subscribeEventsLegacy<String>(handler: (dto, lastData) async {
        throw StateError('boom');
      });

      await expectLater(bus.requestLegacy<String>('x'), throwsStateError);

      await Future<void>.delayed(Duration.zero);
      expect(received, ['x']);
      await sub.cancel();
      await bus.dispose();
    });

    test('a synchronous handler throw also reaches the sender', () async {
      final bus = EventBus();
      bus.subscribeEventsLegacy<String>(handler: syncThrowingHandler);

      await expectLater(bus.requestLegacy<String>('x'), throwsStateError);
      await bus.dispose();
    });

    test('the bus keeps working after a handler error', () async {
      final bus = EventBus();
      var calls = 0;
      bus.subscribeEventsLegacy<int>(handler: (dto, lastData) async {
        calls++;
        if (dto.data == 1) {
          throw StateError('boom');
        }
        return dto.data * 10;
      });

      await expectLater(bus.requestLegacy<int>(1), throwsStateError);
      expect(await bus.requestLegacy<int>(2), 20);
      expect(calls, 2);
      await bus.dispose();
    });
  });

  group('EventNode: delivery order', () {
    test('listeners receive the value before await send completes', () async {
      final bus = EventBus();
      final order = <String>[];
      final sub =
          bus.subscribeLegacy<String>(onData: (e) => order.add('listener:$e'));
      bus.subscribeEventsLegacy<String>(handler: (dto, lastData) async {
        order.add('handler-start');
        order.add('handler-end');
        return 'ok';
      });

      await bus.requestLegacy<String>('x');
      order.add('sender');

      // delivery to the listener runs in a separate microtask, but is scheduled BEFORE
      // the handler future wakes up the sender
      expect(order.indexOf('listener:x'),
          greaterThan(order.indexOf('handler-start')));
      expect(order.indexOf('listener:x'), lessThan(order.indexOf('sender')));
      await sub.cancel();
      await bus.dispose();
    });

    test('fire schedules the value before a later cancel', () async {
      final bus = EventBus();
      final received = <String>[];
      final sub = bus.subscribeLegacy<String>(onData: received.add);

      expect(bus.fireLegacy<String>('x'), isTrue);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received, ['x']);
      await bus.dispose();
    });

    test('listeners receive the value even without a handler', () async {
      final bus = EventBus();
      final received = <String>[];
      bus.subscribeLegacy<String>(onData: received.add);

      expect(bus.fireLegacy<String>('x'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(received, ['x']);
      await bus.dispose();
    });
  });

  group('EventNode: mismatched data type', () {
    test('an event of a mismatched type does not hang the sender', () async {
      final bus = EventBus(isModelBus: true);
      // the node is created for Object, but a String arrives
      bus.subscribeEventsLegacy<Object>(handler: (dto, lastData) async {
        return 'handled';
      });

      await expectLater(
        bus.requestLegacy<String>('x'),
        throwsA(isA<NoHandlerException>()),
      );
      await bus.dispose();
    });
  });

  group('EventNode: handlers are request-only', () {
    test('fire does not invoke a request handler', () async {
      final bus = EventBus();
      var called = false;
      bus.subscribeEventsLegacy<String>(handler: (dto, lastData) async {
        called = true;
      });

      // A handler-only node is not a listener, so fire returns false (D14).
      expect(bus.fireLegacy<String>('x'), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(called, isFalse);
      await bus.dispose();
    });

    test('cancelling a handler keeps the node listeners', () async {
      final bus = EventBus();
      final received = <String>[];
      final subscription = bus.subscribeLegacy<String>(onData: received.add);
      final handler =
          bus.subscribeEventsLegacy<String>(handler: (dto, lastData) async {});
      await handler.cancel();

      expect(bus.haveHandlerLegacy<String>(), isFalse);
      expect(bus.haveListenerLegacy<String>(), isTrue);
      expect(bus.fireLegacy<String>('x'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(received, ['x']);

      await subscription.cancel();
      await bus.dispose();
    });

    test('a registered handler keeps its node alive after listeners cancel',
        () async {
      final bus = EventBus();
      final subscription = bus.subscribeLegacy<String>(onData: (_) {});
      bus.subscribeEventsLegacy<String>(handler: (dto, lastData) async => 'ok');

      await subscription.cancel();

      expect(bus.haveHandlerLegacy<String>(), isTrue);
      expect(await bus.requestLegacy<String>('x'), 'ok');
      await bus.dispose();
    });
  });

  group('EventNode: request validation', () {
    test('request rejects wildcard paths', () async {
      final bus = EventBus();

      await expectLater(
        bus.requestLegacy<String>('x', paths: ['sensor', '*']),
        throwsA(isA<EventBusException>()),
      );
      await bus.dispose();
    });
  });
}
