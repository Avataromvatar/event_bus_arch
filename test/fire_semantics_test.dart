import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('fire return semantics (D14)', () {
    test('true when a listener subscription accepts', () async {
      final bus = EventBus();
      final sub = bus.subscribeEvents<int>(paths: ['x'], onEvent: (_) {});

      expect(bus.fire<int>(1, paths: ['x']), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('true for a legacy stream listener', () async {
      final bus = EventBus();
      final sub = bus.subscribe<int>(paths: ['x'], onData: (_) {});

      expect(bus.fire<int>(1, paths: ['x']), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('false for a handler-only node', () async {
      final bus = EventBus();
      final handler =
          bus.subscribeEvents<int>(paths: ['x'], handler: (dto, last) async {});

      expect(bus.fire<int>(1, paths: ['x']), isFalse);

      await handler.cancel();
      await bus.dispose();
    });

    test('false when every listener rejects the event', () async {
      final bus = EventBus();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        bufferCapacity: 0,
        bufferOverflow: BufferOverflow.reject,
        onEvent: (_) {},
      );
      sub.pause();

      expect(bus.fire<int>(1, paths: ['x']), isFalse);

      await sub.cancel();
      await bus.dispose();
    });

    test('true on a model bus even when nobody is listening', () async {
      final bus = EventBus(isModelBus: true);

      expect(bus.fire<int>(1, paths: ['x']), isTrue);
      expect(bus.currentData<int>(paths: ['x']), 1);

      await bus.dispose();
    });

    test('true when a pattern listener matches a concrete fire', () async {
      final bus = EventBus();
      final sub =
          bus.subscribeEvents<int>(paths: ['a', '*'], onEvent: (_) {});

      expect(bus.fire<int>(1, paths: ['a', 'b']), isTrue);

      await sub.cancel();
      await bus.dispose();
    });
  });
}
