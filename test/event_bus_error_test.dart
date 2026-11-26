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
      final listener = bus.subscribe(EventKey<int>('int.x'),
          onEvent: (_) => throw StateError('boom'));

      bus.fire(EventKey<int>('int.x'), 1);
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
      final listener = bus.subscribe(EventKey<int>('int.x'),
          bufferCapacity: 0,
          bufferOverflow: BufferOverflow.reject,
          onEvent: (_) {});

      listener.pause();
      bus.fire(EventKey<int>('int.x'), 1);
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
      final handler = bus.subscribe(EventKey<int>('int.x'),
          requestQueueCapacity: 0, handler: (dto, lastData) async {
        await gate.future;
        return dto.data;
      });

      final first = bus.request(EventKey<int>('int.x'), 1);
      await pump();
      final busyCheck = expectLater(bus.request(EventKey<int>('int.x'), 2),
          throwsA(isA<BusyException>()));
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
      final handler = bus.subscribe(EventKey<int>('int.x'),
          handlerConcurrency: 2,
          requestQueueCapacity: 0, handler: (dto, lastData) async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return dto.data;
      });

      final timeoutCheck = expectLater(
        bus.request(EventKey<int>('int.x'), 1,
            timeout: const Duration(milliseconds: 20)),
        throwsA(isA<RequestTimeoutException>()),
      );
      final token = CancelToken();
      final cancelCheck = expectLater(
        bus.request(EventKey<int>('int.x'), 2, cancelToken: token),
        throwsA(isA<RequestCanceledException>()),
      );
      token.cancel();

      await timeoutCheck;
      await cancelCheck;
      await pump();

      expect(
          errors.map((e) => e.kind),
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
      final handler = bus.subscribe(EventKey<int>('int.x'),
          handler: (dto, lastData) async => throw StateError('boom'));

      await expectLater(
          bus.request(EventKey<int>('int.x'), 1), throwsStateError);
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
      final handler = bus.subscribe(EventKey<int>('int.x'),
          requestQueueCapacity: 0, handler: (dto, lastData) async {
        await gate.future;
        return dto.data;
      });

      final first = bus.request(EventKey<int>('int.x'), 1);
      await pump();

      final checks = <Future<void>>[];
      for (var i = 0; i < 25; i++) {
        checks.add(expectLater(bus.request(EventKey<int>('int.x'), i + 2),
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

    final firstListener = first.subscribe(EventKey<int>('int.a'),
        onEvent: (_) => throw StateError('first'));
    final secondListener = second.subscribe(EventKey<int>('int.b'),
        onEvent: (_) => throw StateError('second'));

    first.fire(EventKey<int>('int.a'), 1);
    second.fire(EventKey<int>('int.b'), 2);
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
