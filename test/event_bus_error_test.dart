import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('EventBus.errors', () {
    test('listener errors are delivered as EventBusError data', () async {
      final bus = EventBus();
      final errors = <EventBusError>[];
      final errorsSub = bus.errors.listen(errors.add);
      final listener = bus.subscribeEventsLegacy<int>(
        paths: ['x'],
        onEvent: (_) => throw StateError('boom'),
      );

      bus.fireLegacy<int>(1, paths: ['x']);
      await pump();
      await pump();

      expect(errors, hasLength(1));
      expect(errors.single.kind, EventBusErrorKind.listener);
      expect(errors.single.topic, 'int.x');
      expect(errors.single.error, isA<StateError>());
      expect(bus.recentErrors, hasLength(1));

      await listener.cancel();
      await errorsSub.cancel();
      await bus.dispose();
    });

    test('buffer overflow is reported', () async {
      final bus = EventBus();
      final errors = <EventBusError>[];
      final errorsSub = bus.errors.listen(errors.add);
      final listener = bus.subscribeEventsLegacy<int>(
        paths: ['x'],
        bufferCapacity: 0,
        bufferOverflow: BufferOverflow.reject,
        onEvent: (_) {},
      );

      listener.pause();
      bus.fireLegacy<int>(1, paths: ['x']);
      await pump();

      expect(errors, hasLength(1));
      expect(errors.single.kind, EventBusErrorKind.bufferOverflow);

      await listener.cancel();
      await errorsSub.cancel();
      await bus.dispose();
    });

    test('busy requests are reported', () async {
      final bus = EventBus();
      final errors = <EventBusError>[];
      final errorsSub = bus.errors.listen(errors.add);
      final gate = Completer<void>();
      final handler = bus.subscribeEventsLegacy<int>(
        paths: ['x'],
        requestQueueCapacity: 0,
        handler: (dto, lastData) async {
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.requestLegacy<int>(1, paths: ['x']);
      await pump();
      final busyCheck = expectLater(
          bus.requestLegacy<int>(2, paths: ['x']), throwsA(isA<BusyException>()));
      await busyCheck;
      await pump();

      expect(errors, hasLength(1));
      expect(errors.single.kind, EventBusErrorKind.busy);

      gate.complete();
      await first;
      await pump();

      await handler.cancel();
      await errorsSub.cancel();
      await bus.dispose();
    });

    test('request timeout and cancellation are reported', () async {
      final bus = EventBus();
      final errors = <EventBusError>[];
      final errorsSub = bus.errors.listen(errors.add);
      final gates = <Completer<void>>[];
      final handler = bus.subscribeEventsLegacy<int>(
        paths: ['x'],
        handlerConcurrency: 2,
        requestQueueCapacity: 0,
        handler: (dto, lastData) async {
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return dto.data;
        },
      );

      final timeoutCheck = expectLater(
        bus.requestLegacy<int>(1,
            paths: ['x'], timeout: const Duration(milliseconds: 20)),
        throwsA(isA<RequestTimeoutException>()),
      );
      final token = CancelToken();
      final cancelCheck = expectLater(
        bus.requestLegacy<int>(2, paths: ['x'], cancelToken: token),
        throwsA(isA<RequestCanceledException>()),
      );
      token.cancel();

      await timeoutCheck;
      await cancelCheck;
      await pump();

      expect(errors.map((e) => e.kind),
          containsAll(<EventBusErrorKind>[
        EventBusErrorKind.requestTimeout,
        EventBusErrorKind.requestCanceled,
      ]));

      for (final gate in gates) {
        gate.complete();
      }
      await pump();

      await handler.cancel();
      await errorsSub.cancel();
      await bus.dispose();
    });

    test('handler errors are reported and still reach the caller', () async {
      final bus = EventBus();
      final errors = <EventBusError>[];
      final errorsSub = bus.errors.listen(errors.add);
      final handler = bus.subscribeEventsLegacy<int>(
        paths: ['x'],
        handler: (dto, lastData) async => throw StateError('boom'),
      );

      await expectLater(
          bus.requestLegacy<int>(1, paths: ['x']), throwsStateError);
      await pump();

      expect(errors, hasLength(1));
      expect(errors.single.kind, EventBusErrorKind.handler);
      expect(errors.single.error, isA<StateError>());

      await handler.cancel();
      await errorsSub.cancel();
      await bus.dispose();
    });

    test('the per-kind rate limit bounds a storm', () async {
      final bus = EventBus();
      final gate = Completer<void>();
      final handler = bus.subscribeEventsLegacy<int>(
        paths: ['x'],
        requestQueueCapacity: 0,
        handler: (dto, lastData) async {
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.requestLegacy<int>(1, paths: ['x']);
      await pump();

      final checks = <Future<void>>[];
      for (var i = 0; i < 25; i++) {
        checks.add(expectLater(
            bus.requestLegacy<int>(i + 2, paths: ['x']),
            throwsA(isA<BusyException>())));
      }
      await Future.wait(checks);

      final busyErrors = bus.recentErrors
          .where((error) => error.kind == EventBusErrorKind.busy)
          .length;
      expect(busyErrors, lessThanOrEqualTo(10));
      expect(bus.suppressedErrors, greaterThan(0));

      gate.complete();
      await first;
      await pump();

      await handler.cancel();
      await bus.dispose();
    });
  });

  test('EventBusErrorMonitor aggregates several buses', () async {
    final first = EventBus();
    final second = EventBus();
    final monitor = EventBusErrorMonitor();
    expect(monitor.add(first), isTrue);
    expect(monitor.add(first), isFalse);
    expect(monitor.add(second), isTrue);

    final firstListener = first.subscribeEventsLegacy<int>(
        paths: ['a'], onEvent: (_) => throw StateError('first'));
    final secondListener = second.subscribeEventsLegacy<int>(
        paths: ['b'], onEvent: (_) => throw StateError('second'));

    first.fireLegacy<int>(1, paths: ['a']);
    second.fireLegacy<int>(2, paths: ['b']);
    await pump();
    await pump();

    expect(monitor.recentErrors, hasLength(2));
    expect(monitor.counts[EventBusErrorKind.listener], 2);
    expect(monitor.recentErrors.map((error) => error.topic),
        containsAll(<String>['int.a', 'int.b']));

    expect(monitor.remove(first), isTrue);
    expect(monitor.remove(first), isFalse);

    await monitor.dispose();
    await firstListener.cancel();
    await secondListener.cancel();
    await first.dispose();
    await second.dispose();
  });
}
