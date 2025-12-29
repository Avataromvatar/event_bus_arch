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
      (bus as EventBusHandlers).setHandler<String>(
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Listen to events
      final stream = bus.listen<String>();
      final subscription = stream.listen((data) {
        completer.complete(data);
      });
      
      // Send event
      final result = await bus.send('test data');
      
      // Verify result
      expect(result, isNotNull);
      
      // Clean up
      await subscription.cancel();
    });

    test('Should handle multiple listeners', () async {
      final bus = EventBus();
      final results = <String>[];
      
      // Set up handler
      (bus as EventBusHandlers).setHandler<String>(
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Create multiple listeners
      final stream1 = bus.listen<String>();
      final stream2 = bus.listen<String>();
      
      final subscription1 = stream1.listen((data) {
        results.add('listener1: $data');
      });
      
      final subscription2 = stream2.listen((data) {
        results.add('listener2: $data');
      });
      
      // Send event
      await bus.send('test data');
      await Future.delayed(Duration(milliseconds: 10));
      // Verify both listeners received the event
      expect(results.length, 2);
      
      // Clean up
      await subscription1.cancel();
      await subscription2.cancel();
    });

    test('Should get last data', () {
      final bus = EventBus();
      
      // Set initial data
      (bus as EventBusHandlers).setHandler<String>(
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Send event
      bus.send('test data');
      
      // Get last data
      final last = bus.lastData<String>();
      expect(last, 'test data');
    });

    test('Should have handler', () {
      final bus = EventBus();
      
      // Initially should not have handler
      expect(bus.haveHandler<String>(), false);
      
      // Set handler
      (bus as EventBusHandlers).setHandler<String>(
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Should now have handler
      expect(bus.haveHandler<String>(), true);
    });

    test('Should have listener', () {
      final bus = EventBus();
      
      // Initially should not have listener
      expect(bus.haveListener<String>(), false);
      
      // Create listener
      final stream = bus.listen<String>();
      final subscription = stream.listen((data) {});
      
      // Should now have listener
      expect(bus.haveListener<String>(), true);
      
      // Clean up
      subscription.cancel();
    });

    test('Should remove handler', () {
      final bus = EventBus();
      
      // Set handler
      (bus as EventBusHandlers).setHandler<String>(
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Should have handler
      expect(bus.haveHandler<String>(), true);
      
      // Remove handler
      (bus as EventBusHandlers).removeHandler<String>();
      
      // Should not have handler anymore
      expect(bus.haveHandler<String>(), false);
    });

    test('Should send event with completer result', () async {
      final bus = EventBus();
      
      // Set up handler that returns a result
      (bus as EventBusHandlers).setHandler<int>(
        handler: (dto, lastData) async {
          dto.completer?.complete(42);
        },
      );
      
      // Send event and get result
      final result = await bus.send(10);
      
      // Verify result
      expect(result, 42);
    });

    test('Should handle model bus behavior', () {
      final bus = EventBus(isModelBus: true);
      expect(bus.isModelBus, true);
    });

    test('Should send event without handler', () async {
      final bus = EventBus();
      
      // Send event without handler
      final result = await bus.send('test data');
      
      // Should return null when no handler
      expect(result, null);
    });

    test('Should send event with different topic paths', () async {
      final bus = EventBus();
      
      // Set up handler for specific path
      (bus as EventBusHandlers).setHandler<String>(
        path: 'test',
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Send event to specific path
      final result = await bus.send('test data', path: 'test');
      
      // Should return a future
      expect(result, isNotNull);
    });

    test('Should handle event with arguments', () async {
      final bus = EventBus();
      
      // Set up handler
      (bus as EventBusHandlers).setHandler<String>(
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Send event with arguments
      final result = await bus.send('test data', arguments: {'key': 'value'});
      
      // Should return a future
      expect(result, isNotNull);
    });

    test('Should handle event with target', () async {
      final bus = EventBus();
      
      // Set up handler for specific target
      (bus as EventBusHandlers).setHandler<String>(
        target: 'specific_target',
        handler: (dto, lastData) async {
          dto.completer?.complete('handled');
        },
      );
      
      // Send event to specific target
      final result = await bus.send('test data', target: 'specific_target');
      
      // Should return a future
      expect(result, isNotNull);
    });
  });
}
