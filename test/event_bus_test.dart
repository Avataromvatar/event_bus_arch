import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';
import 'legacy_compat.dart';

void main() {
  group('EventBus Tests', () {
    test('Should create EventBus instance', () {
      final bus = EventBus();
      expect(bus, isNotNull);
    });

    test('Should send and receive events', () async {
      final bus = EventBus();
      final Completer<String> completer = Completer<String>();

      // Set up handler
      bus.subscribeEventsLegacy<String>(
        handler: (dto, lastData) async {
          return 'handled';
        },
      );

      // Listen to events
      final stream = bus.listenLegacy<String>();
      final subscription = stream.listen((data) {
        completer.complete(data);
      });

      // Send event
      final result = await bus.requestLegacy('test data');

      // Verify result
      expect(result, isNotNull);

      // Clean up
      await subscription.cancel();
    });

    test('Should handle multiple listeners', () async {
      final bus = EventBus();
      final results = <String>[];

      // Set up handler
      bus.subscribeEventsLegacy<String>(
        handler: (dto, lastData) async {
          return 'handled';
        },
      );

      // Create multiple listeners
      final stream1 = bus.listenLegacy<String>();
      final stream2 = bus.listenLegacy<String>();

      final subscription1 = stream1.listen((data) {
        results.add('listener1: $data');
      });

      final subscription2 = stream2.listen((data) {
        results.add('listener2: $data');
      });

      // Send event
      await bus.requestLegacy('test data');
      await Future.delayed(Duration(milliseconds: 10));
      // Verify both listeners received the event
      expect(results.length, 2);

      // Clean up
      await subscription1.cancel();
      await subscription2.cancel();
    });

    test('Should get last data', () async {
      final bus = EventBus();

      // Set initial data
      bus.subscribeEventsLegacy<String>(
        handler: (dto, lastData) async {
          return 'handled';
        },
      );

      // Send event
      await bus.requestLegacy('test data');

      // Get last data
      final last = bus.currentDataLegacy<String>();
      expect(last, 'test data');
    });

    test('Should have handler', () {
      final bus = EventBus();

      // Initially should not have handler
      expect(bus.haveHandlerLegacy<String>(), false);

      // Set handler
      bus.subscribeEventsLegacy<String>(
        handler: (dto, lastData) async {
          return 'handled';
        },
      );

      // Should now have handler
      expect(bus.haveHandlerLegacy<String>(), true);
    });

    test('Should have listener', () {
      final bus = EventBus();

      // Initially should not have listener
      expect(bus.haveListenerLegacy<String>(), false);

      // Create listener
      final stream = bus.listenLegacy<String>();
      final subscription = stream.listen((data) {});

      // Should now have listener
      expect(bus.haveListenerLegacy<String>(), true);

      // Clean up
      subscription.cancel();
    });

    test('Should remove handler', () async {
      final bus = EventBus();

      // Set handler
      final handler = bus.subscribeEventsLegacy<String>(
        handler: (dto, lastData) async {
          return 'handled';
        },
      );

      // Should have handler
      expect(bus.haveHandlerLegacy<String>(), true);

      // Remove handler
      await handler.cancel();

      // Should not have handler anymore
      expect(bus.haveHandlerLegacy<String>(), false);
    });

    test('Should return the handler result', () async {
      final bus = EventBus();

      // Set up handler that returns a result
      bus.subscribeEventsLegacy<int>(
        handler: (dto, lastData) async {
          return 42;
        },
      );

      // Send event and get result
      final result = await bus.requestLegacy(10);

      // Verify result
      expect(result, 42);
    });

    test('Should handle model bus behavior', () {
      final bus = EventBus(isModelBus: true);
      expect(bus.isModelBus, true);
    });

    test('Should fire an event without handler', () {
      final bus = EventBus();

      // Nobody listens and no transport knows the topic.
      expect(bus.fireLegacy('test data'), isFalse);
    });

    test('Should send event with different topic paths', () async {
      final bus = EventBus();

      // Set up handler for specific path
      bus.subscribeEventsLegacy<String>(
        paths: ['test'],
        handler: (dto, lastData) async {
          return 'handled';
        },
      );

      // Send event to specific path
      final result = await bus.requestLegacy('test data', paths: ['test']);

      // Should return a future
      expect(result, isNotNull);
    });

    test('Should handle event with arguments', () async {
      final bus = EventBus();
      Map<String, String>? seen;

      // Set up handler
      bus.subscribeEventsLegacy<String>(
        handler: (dto, lastData) async {
          seen = dto.arguments;
          return 'handled';
        },
      );

      // Send event with arguments
      final result =
          await bus.requestLegacy('test data', arguments: {'key': 'value'});

      // Should return a future
      expect(result, isNotNull);
      // the handler reads the arguments of the call from the dto
      expect(seen, {'key': 'value'});
    });

    test('Should handle event with a multi-token path', () async {
      final bus = EventBus();

      // Set up handler for a path of two tokens
      bus.subscribeEventsLegacy<String>(
        paths: ['specific', 'path'],
        handler: (dto, lastData) async {
          return 'handled';
        },
      );

      // Send event to a different path: a different node, no handler.
      await expectLater(
        bus.requestLegacy('test data', paths: ['specific']),
        throwsA(isA<NoHandlerException>()),
      );
    });

    test('Should keep paths of the same type apart', () async {
      final bus = EventBus();
      final received = <String>[];

      bus.subscribeEventsLegacy<String>(
        paths: ['a'],
        handler: (dto, lastData) async {
          received.add('a: ${dto.data}');
        },
      );
      bus.subscribeEventsLegacy<String>(
        paths: ['b'],
        handler: (dto, lastData) async {
          received.add('b: ${dto.data}');
        },
      );

      await bus.requestLegacy('to a', paths: ['a']);
      await bus.requestLegacy('to b', paths: ['b']);

      expect(received, ['a: to a', 'b: to b']);
    });

  });
}
