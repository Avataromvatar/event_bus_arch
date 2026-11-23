import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

EventBusError _error(String address, {DateTime? timestamp}) => EventBusError(
      kind: EventBusErrorKind.other,
      address: address,
      error: StateError('boom'),
      timestamp: timestamp,
    );

void main() {
  group('error window store', () {
    test('never tracks more than 256 keys', () {
      final bus = EventBusImpl(false);
      for (var i = 0; i < 1000; i++) {
        bus.reportError(_error('address-$i'));
        expect(bus.errorWindowCount, lessThanOrEqualTo(256));
      }
      expect(bus.errorWindowCount, 256);
    });

    test('a key keeps the 10-per-second limit', () {
      final bus = EventBusImpl(false);
      for (var i = 0; i < 10; i++) {
        bus.reportError(_error('active'));
      }
      expect(bus.suppressedErrors, 0);

      bus.reportError(_error('active'));
      expect(bus.suppressedErrors, 1);
    });

    test('the least recently used key is evicted and can be inserted again',
        () {
      final bus = EventBusImpl(false);
      for (var i = 0; i < 10; i++) {
        bus.reportError(_error('active'));
      }
      bus.reportError(_error('active'));
      final suppressed = bus.suppressedErrors;
      expect(suppressed, 1);

      for (var i = 0; i < 300; i++) {
        bus.reportError(_error('filler-$i'));
      }
      expect(bus.errorWindowCount, 256);

      // "active" was the oldest key, so it was evicted; its next error starts
      // a fresh window instead of being suppressed.
      bus.reportError(_error('active'));
      expect(bus.suppressedErrors, suppressed);
    });

    test('timestamps older than one second are pruned', () {
      final bus = EventBusImpl(false);
      final now = DateTime.now();
      final stale = now.subtract(const Duration(seconds: 2));
      for (var i = 0; i < 10; i++) {
        bus.reportError(_error('active', timestamp: stale));
      }
      expect(bus.suppressedErrors, 0);

      bus.reportError(_error('active', timestamp: now));
      expect(bus.suppressedErrors, 0);
    });
  });
}
