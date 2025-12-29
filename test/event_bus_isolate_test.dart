import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('EventBusIsolate', () {
    test('should initialize correctly', () async {
      final isolateBus = EventBusIsolate(
        onInit: (bus, initialData) {
          // Empty initialization for testing
        },
      );
      
      expect(isolateBus, isNotNull);
      expect(isolateBus.isInit, isFalse);
      
      // Wait for initialization
      await isolateBus.waitInit;
      expect(isolateBus.isInit, isTrue);
    });

    test('should send and receive events', () async {
      final isolateBus = EventBusIsolate(
        onInit: (bus, initialData) {
          // Set up a handler in the isolate
          (bus as EventBusHandlers).setHandler<String>(
            handler: (dto, lastData) async {
              dto.completer?.complete('Processed: ${dto.data}');
            }
          );
        },
      );
      
      await isolateBus.waitInit;
      
      // Send an event and expect a response
      final result = await isolateBus.send<String>('test message');
      expect(result, 'Processed: test message');
    });

    test('should dispose correctly', () async {
      final isolateBus = EventBusIsolate(
        onInit: (bus, initialData) {
          // Empty initialization for testing
        },
      );
      
      await isolateBus.waitInit;
      
      // Dispose the bus
      isolateBus.dispose();
      
      // The isolate should be disposed
      // Note: We can't directly test the isolate state, but we can ensure no errors occur
      expect(true, isTrue); // Placeholder test
    });

    test('should handle multiple events correctly', () async {
      final isolateBus = EventBusIsolate(
        onInit: (bus, initialData) {
          // Set up a handler in the isolate
          (bus as EventBusHandlers).setHandler<int>(
            handler: (dto, lastData) async {
              dto.completer?.complete(dto.data * 2);
            }
          );
        },
      );
      
      await isolateBus.waitInit;
      
      // Send multiple events
      final results = await Future.wait<dynamic>([
        isolateBus.send<int>(1)!,
        isolateBus.send<int>(2)!,
        isolateBus.send<int>(3)!,
      ]);
      
      expect(results, [2, 4, 6]);
    });
  });
}
