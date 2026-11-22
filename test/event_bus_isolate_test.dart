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
          bus.subscribeEvents<String>(handler: (dto, lastData) async {
            return 'Processed: ${dto.data}';
          });
        },
      );

      await isolateBus.waitInit;

      // Send an event and expect a response
      final result = await isolateBus.request<String>('test message');
      expect(result, 'Processed: test message');
    });

    test('a custom separator is used on both sides of the bridge', () async {
      final isolateBus = EventBusIsolate(
        separator: '/',
        onInit: (bus, initialData) {
          bus.subscribeEvents<int>(
              paths: ['a', 'b'], handler: (dto, lastData) async => dto.data);
        },
      );

      await isolateBus.waitInit;

      // The worker registered `int/a/b`; the main side must address the same
      // topic, otherwise the interest lookup misses and the request fails.
      expect(await isolateBus.request<int>(7, paths: ['a', 'b']), 7);
      await isolateBus.dispose();
    });

    test('should dispose correctly', () async {
      final isolateBus = EventBusIsolate(
        onInit: (bus, initialData) {
          // Empty initialization for testing
        },
      );

      await isolateBus.waitInit;

      // Dispose the bus
      await isolateBus.dispose();

      // The isolate should be disposed
      // Note: We can't directly test the isolate state, but we can ensure no errors occur
      expect(true, isTrue); // Placeholder test
    });

    test('should handle multiple events correctly', () async {
      final isolateBus = EventBusIsolate(
        onInit: (bus, initialData) {
          // Set up a handler in the isolate
          bus.subscribeEvents<int>(handler: (dto, lastData) async {
            return dto.data * 2;
          });
        },
      );

      await isolateBus.waitInit;

      // Send multiple events
      final results = await Future.wait<dynamic>([
        isolateBus.request<int>(1),
        isolateBus.request<int>(2),
        isolateBus.request<int>(3),
      ]);

      expect(results, [2, 4, 6]);
    });
  });
}
