import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('EventBusErrorMonitor', () {
    test('filters, bounds recent and snapshots by kind and topic', () async {
      final bus = EventBusImpl(false);
      final monitor = EventBusErrorMonitor(
        filter: (error) => error.kind == EventBusErrorKind.listener,
        recentLimit: 2,
        maxErrorsPerSecond: null,
      );
      monitor.add(bus);

      bus.reportError(EventBusError(
          kind: EventBusErrorKind.listener,
          topic: 'a',
          error: StateError('a')));
      bus.reportError(EventBusError(
          kind: EventBusErrorKind.busy, topic: 'b', error: StateError('b')));
      bus.reportError(EventBusError(
          kind: EventBusErrorKind.listener,
          topic: 'c',
          error: StateError('c')));
      bus.reportError(EventBusError(
          kind: EventBusErrorKind.listener,
          topic: 'a',
          error: StateError('d')));
      await Future<void>.delayed(Duration.zero);

      final snapshot = monitor.snapshot();
      expect(snapshot.total, 3); // busy filtered out
      expect(snapshot.byKind[EventBusErrorKind.listener], 3);
      expect(snapshot.byTopic['a'], 2);
      expect(snapshot.byTopic['c'], 1);
      expect(monitor.recentErrors, hasLength(2));
      expect(monitor.recentErrors.last.topic, 'a');

      monitor.resetCounters();
      expect(monitor.snapshot().total, 0);
      expect(monitor.recentErrors, hasLength(2)); // recent is kept

      await monitor.dispose();
      await bus.dispose();
    });

    test('the monitor-wide rate limit suppresses a storm', () async {
      final bus = EventBusImpl(false);
      final monitor = EventBusErrorMonitor(maxErrorsPerSecond: 2);
      monitor.add(bus);

      for (var i = 0; i < 5; i++) {
        bus.reportError(EventBusError(
            kind: EventBusErrorKind.listener,
            topic: 't$i',
            error: StateError('e$i')));
      }
      await Future<void>.delayed(Duration.zero);

      final snapshot = monitor.snapshot();
      expect(snapshot.total, 2);
      expect(snapshot.suppressed, 3);
      expect(monitor.suppressed, 3);

      await monitor.dispose();
      await bus.dispose();
    });

    test('a merged stream receives the accepted errors', () async {
      final bus = EventBusImpl(false);
      final monitor = EventBusErrorMonitor();
      monitor.add(bus);
      final received = <EventBusError>[];
      final subscription = monitor.errors.listen(received.add);

      bus.reportError(EventBusError(
          kind: EventBusErrorKind.other, topic: 'x', error: StateError('x')));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.topic, 'x');

      await subscription.cancel();
      await monitor.dispose();
      await bus.dispose();
    });
  });
}
