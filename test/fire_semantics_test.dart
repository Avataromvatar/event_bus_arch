import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('fire return semantics (D14)', () {
    test('true when a listener subscription accepts', () async {
      final bus = EventBus();
      final sub = bus.subscribe(EventKey<int>('int.x'), onEvent: (_) {});

      expect(bus.fire(EventKey<int>('int.x'), 1), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('true for a legacy stream listener', () async {
      final bus = EventBus();
      final sub = bus.listen(EventKey<int>('int.x')).listen((_) {});

      expect(bus.fire(EventKey<int>('int.x'), 1), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('false for a handler-only node', () async {
      final bus = EventBus();
      final handler =
          bus.subscribe(EventKey<int>('int.x'), handler: (dto, last) async {});

      expect(bus.fire(EventKey<int>('int.x'), 1), isFalse);

      await handler.cancel();
      await bus.dispose();
    });

    test('false when every listener rejects the event', () async {
      final bus = EventBus();
      final sub = bus.subscribe(EventKey<int>('int.x'),
          bufferCapacity: 0,
          bufferOverflow: BufferOverflow.reject,
          onEvent: (_) {});
      sub.pause();

      expect(bus.fire(EventKey<int>('int.x'), 1), isFalse);

      await sub.cancel();
      await bus.dispose();
    });

    test('true on a model bus even when nobody is listening', () async {
      final bus = EventBus(isModelBus: true);

      expect(bus.fire(EventKey<int>('int.x'), 1), isTrue);
      expect(bus.currentData(EventKey<int>('int.x')), 1);

      await bus.dispose();
    });

    test('true when a pattern listener matches a concrete fire', () async {
      final bus = EventBus();
      final sub =
          bus.subscribe(EventPatternKey<int>('int.a.*'), onEvent: (_) {});

      expect(bus.fire(EventKey<int>('int.a.b'), 1), isTrue);

      await sub.cancel();
      await bus.dispose();
    });
  });
}
