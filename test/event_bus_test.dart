// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

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
      bus.subscribe(EventKey<String>('String'), handler: (dto, lastData) async {
        return 'handled';
      });

      // Listen to events
      final stream = bus.listen(EventKey<String>('String'));
      final subscription = stream.listen((data) {
        completer.complete(data);
      });

      // Send event
      final result = await bus.request(EventKey<String>('String'), 'test data');

      // Verify result
      expect(result, isNotNull);

      // Clean up
      await subscription.cancel();
    });

    test('Should handle multiple listeners', () async {
      final bus = EventBus();
      final results = <String>[];

      // Set up handler
      bus.subscribe(EventKey<String>('String'), handler: (dto, lastData) async {
        return 'handled';
      });

      // Create multiple listeners
      final stream1 = bus.listen(EventKey<String>('String'));
      final stream2 = bus.listen(EventKey<String>('String'));

      final subscription1 = stream1.listen((data) {
        results.add('listener1: $data');
      });

      final subscription2 = stream2.listen((data) {
        results.add('listener2: $data');
      });

      // Send event
      await bus.request(EventKey<String>('String'), 'test data');
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
      bus.subscribe(EventKey<String>('String'), handler: (dto, lastData) async {
        return 'handled';
      });

      // Send event
      await bus.request(EventKey<String>('String'), 'test data');

      // Get last data
      final last = bus.currentData(EventKey<String>('String'));
      expect(last, 'test data');
    });

    test('Should have handler', () {
      final bus = EventBus();

      // Initially should not have handler
      expect(bus.haveHandler(EventKey<String>('String')), false);

      // Set handler
      bus.subscribe(EventKey<String>('String'), handler: (dto, lastData) async {
        return 'handled';
      });

      // Should now have handler
      expect(bus.haveHandler(EventKey<String>('String')), true);
    });

    test('Should have listener', () {
      final bus = EventBus();

      // Initially should not have listener
      expect(bus.haveListener(EventKey<String>('String')), false);

      // Create listener
      final stream = bus.listen(EventKey<String>('String'));
      final subscription = stream.listen((data) {});

      // Should now have listener
      expect(bus.haveListener(EventKey<String>('String')), true);

      // Clean up
      subscription.cancel();
    });

    test('Should remove handler', () async {
      final bus = EventBus();

      // Set handler
      final handler = bus.subscribe(EventKey<String>('String'),
          handler: (dto, lastData) async {
        return 'handled';
      });

      // Should have handler
      expect(bus.haveHandler(EventKey<String>('String')), true);

      // Remove handler
      await handler.cancel();

      // Should not have handler anymore
      expect(bus.haveHandler(EventKey<String>('String')), false);
    });

    test('Should return the handler result', () async {
      final bus = EventBus();

      // Set up handler that returns a result
      bus.subscribe(EventKey<int>('int'), handler: (dto, lastData) async {
        return 42;
      });

      // Send event and get result
      final result = await bus.request(EventKey<int>('int'), 10);

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
      expect(bus.fire(EventKey<String>('String'), 'test data'), isFalse);
    });

    test('Should send event with different topic paths', () async {
      final bus = EventBus();

      // Set up handler for specific path
      bus.subscribe(EventKey<String>('String.test'),
          handler: (dto, lastData) async {
        return 'handled';
      });

      // Send event to specific path
      final result =
          await bus.request(EventKey<String>('String.test'), 'test data');

      // Should return a future
      expect(result, isNotNull);
    });

    test('Should handle event with arguments', () async {
      final bus = EventBus();
      Map<String, String>? seen;

      // Set up handler
      bus.subscribe(EventKey<String>('String'), handler: (dto, lastData) async {
        seen = dto.arguments;
        return 'handled';
      });

      // Send event with arguments
      final result = await bus.request(EventKey<String>('String'), 'test data',
          arguments: {'key': 'value'});

      // Should return a future
      expect(result, isNotNull);
      // the handler reads the arguments of the call from the dto
      expect(seen, {'key': 'value'});
    });

    test('Should handle event with a multi-token path', () async {
      final bus = EventBus();

      // Set up handler for a path of two tokens
      bus.subscribe(EventKey<String>('String.specific.path'),
          handler: (dto, lastData) async {
        return 'handled';
      });

      // Send event to a different path: a different node, no handler.
      await expectLater(
        bus.request(EventKey<String>('String.specific'), 'test data'),
        throwsA(isA<NoHandlerException>()),
      );
    });

    test('Should keep paths of the same type apart', () async {
      final bus = EventBus();
      final received = <String>[];

      bus.subscribe(EventKey<String>('String.a'),
          handler: (dto, lastData) async {
        received.add('a: ${dto.data}');
      });
      bus.subscribe(EventKey<String>('String.b'),
          handler: (dto, lastData) async {
        received.add('b: ${dto.data}');
      });

      await bus.request(EventKey<String>('String.a'), 'to a');
      await bus.request(EventKey<String>('String.b'), 'to b');

      expect(received, ['a: to a', 'b: to b']);
    });
  });
}
