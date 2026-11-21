import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('handler subscription: basics', () {
    test('answers a request and cancels the responder', () async {
      final bus = EventBus();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        handler: (dto, lastData) async => dto.data * 2,
      );

      expect(bus.haveHandler<int>(paths: ['x']), isTrue);
      expect(await bus.request<int>(21, paths: ['x']), 42);

      await sub.cancel();
      expect(bus.haveHandler<int>(paths: ['x']), isFalse);
      await expectLater(bus.request<int>(1, paths: ['x']),
          throwsA(isA<NoHandlerException>()));
      await bus.dispose();
    });

    test('a dual subscription listens to fire and answers requests', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        onEvent: received.add,
        handler: (dto, lastData) async => dto.data + 1,
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(received, [1]);

      expect(await bus.request<int>(2, paths: ['x']), 3);
      await pump();
      expect(received, [1, 2]);

      await sub.cancel();
      await bus.dispose();
    });

    test('fire does not invoke a handler-only subscription', () async {
      final bus = EventBus();
      var called = false;
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        handler: (dto, lastData) async {
          called = true;
          return dto.data;
        },
      );

      bus.fire<int>(1, paths: ['x']);
      await pump();
      expect(called, isFalse);

      await sub.cancel();
      await bus.dispose();
    });
  });

  group('handler subscription: queue and concurrency', () {
    test('queues up to requestQueueCapacity and rejects the overflow', () async {
      final bus = EventBus();
      final gates = <Completer<void>>[];
      final started = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        requestQueueCapacity: 2,
        handler: (dto, lastData) async {
          started.add(dto.data);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request<int>(1, paths: ['x']);
      final second = bus.request<int>(2, paths: ['x']);
      final third = bus.request<int>(3, paths: ['x']);
      final fourth = bus.request<int>(4, paths: ['x']);
      final fourthCheck =
          expectLater(fourth, throwsA(isA<BusyException>()));

      await pump();
      expect(started, [1]);
      expect(sub.bufferedRequests, 2);
      expect(sub.inFlight, 1);
      await fourthCheck;

      gates[0].complete();
      expect(await first, 1);
      await pump();
      expect(started, [1, 2]);

      gates[1].complete();
      expect(await second, 2);
      await pump();
      expect(started, [1, 2, 3]);

      gates[2].complete();
      expect(await third, 3);
      await pump();
      expect(sub.inFlight, 0);
      expect(sub.bufferedRequests, 0);

      await sub.cancel();
      await bus.dispose();
    });

    test('handlerConcurrency allows parallel handler invocations', () async {
      final bus = EventBus();
      final gates = <Completer<void>>[];
      final started = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        handlerConcurrency: 2,
        requestQueueCapacity: 0,
        handler: (dto, lastData) async {
          started.add(dto.data);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request<int>(1, paths: ['x']);
      final second = bus.request<int>(2, paths: ['x']);
      final third = bus.request<int>(3, paths: ['x']);
      final thirdCheck = expectLater(third, throwsA(isA<BusyException>()));

      await pump();
      expect(started, [1, 2]);
      expect(sub.inFlight, 2);
      await thirdCheck;

      gates[0].complete();
      gates[1].complete();
      expect(await first, 1);
      expect(await second, 2);
      await pump();

      await sub.cancel();
      await bus.dispose();
    });

    test('pause rejects requests until resume', () async {
      final bus = EventBus();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        handler: (dto, lastData) async => dto.data,
      );

      sub.pause();
      expect(bus.haveHandler<int>(paths: ['x']), isTrue);
      expect(bus.haveAvailableHandler<int>(paths: ['x']), isFalse);
      await expectLater(bus.request<int>(1, paths: ['x']),
          throwsA(isA<BusyException>()));

      sub.resume();
      expect(bus.haveAvailableHandler<int>(paths: ['x']), isTrue);
      expect(await bus.request<int>(2, paths: ['x']), 2);

      await sub.cancel();
      await bus.dispose();
    });

    test('haveAvailableHandler follows queue capacity', () async {
      final bus = EventBus();
      final gate = Completer<void>();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        requestQueueCapacity: 0,
        handler: (dto, lastData) async {
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request<int>(1, paths: ['x']);
      await pump();
      expect(bus.haveHandler<int>(paths: ['x']), isTrue);
      expect(bus.haveAvailableHandler<int>(paths: ['x']), isFalse);

      gate.complete();
      expect(await first, 1);
      await pump();
      expect(bus.haveAvailableHandler<int>(paths: ['x']), isTrue);

      await sub.cancel();
      await bus.dispose();
    });
  });

  group('handler subscription: tiers and fairness', () {
    test('competition is inside the exact tier only', () async {
      final bus = EventBus();
      final exactGate = Completer<void>();
      final patternStarted = <int>[];
      final exact = bus.subscribeEvents<int>(
        paths: ['a', 'b'],
        requestQueueCapacity: 0,
        handler: (dto, lastData) async {
          await exactGate.future;
          return 'exact:${dto.data}';
        },
      );
      final pattern = bus.subscribeEvents<int>(
        paths: ['a', '*'],
        handler: (dto, lastData) async {
          patternStarted.add(dto.data);
          return 'pattern:${dto.data}';
        },
      );

      final first = bus.request<int>(1, paths: ['a', 'b']);
      await pump();
      await expectLater(bus.request<int>(2, paths: ['a', 'b']),
          throwsA(isA<BusyException>()));
      expect(patternStarted, isEmpty);

      exactGate.complete();
      expect(await first, 'exact:1');

      expect(await bus.request<int>(3, paths: ['a', 'b']), 'exact:3');
      expect(await bus.request<int>(4, paths: ['a', 'c']), 'pattern:4');
      expect(patternStarted, [4]);

      await exact.cancel();
      await pattern.cancel();
      await bus.dispose();
    });

    test('round-robin distributes requests across free handlers', () async {
      final bus = EventBus();
      final first = <int>[];
      final second = <int>[];
      final sub1 = bus.subscribeEvents<int>(
        paths: ['x'],
        handler: (dto, lastData) async {
          first.add(dto.data);
          return dto.data;
        },
      );
      final sub2 = bus.subscribeEvents<int>(
        paths: ['x'],
        handler: (dto, lastData) async {
          second.add(dto.data);
          return dto.data;
        },
      );

      for (var value = 1; value <= 4; value++) {
        expect(await bus.request<int>(value, paths: ['x']), value);
      }

      expect(first, [1, 3]);
      expect(second, [2, 4]);

      await sub1.cancel();
      await sub2.cancel();
      await bus.dispose();
    });
  });

  group('handler subscription: request lifecycle', () {
    test('a timed-out request fails and frees its handler slot', () async {
      final bus = EventBus();
      final gate = Completer<void>();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        handler: (dto, lastData) async {
          await gate.future;
          return dto.data;
        },
      );

      await expectLater(
        bus.request<int>(1,
            paths: ['x'], timeout: const Duration(milliseconds: 20)),
        throwsA(isA<RequestTimeoutException>()),
      );
      expect(sub.inFlight, 1);

      gate.complete();
      await pump();
      expect(sub.inFlight, 0);

      await sub.cancel();
      await bus.dispose();
    });

    test('a queued request can be cancelled and never reaches the handler',
        () async {
      final bus = EventBus();
      final gates = <Completer<void>>[];
      final started = <int>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        requestQueueCapacity: 1,
        handler: (dto, lastData) async {
          started.add(dto.data);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request<int>(1, paths: ['x']);
      final token = CancelToken();
      final second =
          bus.request<int>(2, paths: ['x'], cancelToken: token);
      await pump();
      expect(started, [1]);

      token.cancel();
      await expectLater(second, throwsA(isA<RequestCanceledException>()));
      expect(sub.bufferedRequests, 0);

      gates[0].complete();
      expect(await first, 1);
      await pump();
      expect(started, [1]);

      await sub.cancel();
      await bus.dispose();
    });

    test('lastData is snapshotted when the request is accepted', () async {
      final bus = EventBus(isModelBus: true);
      final gates = <Completer<void>>[];
      final seen = <int?>[];
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        requestQueueCapacity: 1,
        handler: (dto, lastData) async {
          seen.add(lastData);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request<int>(1, paths: ['x']);
      await pump();
      final second = bus.request<int>(2, paths: ['x']);
      bus.fire<int>(99, paths: ['x']);

      gates[0].complete();
      expect(await first, 1);
      await pump();
      gates[1].complete();
      expect(await second, 2);
      await pump();

      expect(seen, [null, 1]);

      await sub.cancel();
      await bus.dispose();
    });

    test('a Busy rejection does not notify listeners', () async {
      final bus = EventBus();
      final received = <int>[];
      final gate = Completer<void>();
      final listener =
          bus.subscribeEvents<int>(paths: ['x'], onEvent: received.add);
      final handlerSub = bus.subscribeEvents<int>(
        paths: ['x'],
        requestQueueCapacity: 0,
        handler: (dto, lastData) async {
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request<int>(1, paths: ['x']);
      await pump();
      await expectLater(bus.request<int>(2, paths: ['x']),
          throwsA(isA<BusyException>()));
      await pump();
      expect(received, [1]);

      gate.complete();
      await first;
      await pump();

      await listener.cancel();
      await handlerSub.cancel();
      await bus.dispose();
    });

    test('cancelling a handler subscription fails its queued requests',
        () async {
      final bus = EventBus();
      final gate = Completer<void>();
      final sub = bus.subscribeEvents<int>(
        paths: ['x'],
        requestQueueCapacity: 1,
        handler: (dto, lastData) async {
          await gate.future;
          return dto.data;
        },
      );

      final first = bus.request<int>(1, paths: ['x']);
      final second = bus.request<int>(2, paths: ['x']);
      final secondCheck =
          expectLater(second, throwsA(isA<NoHandlerException>()));
      await pump();

      await sub.cancel();
      await secondCheck;

      gate.complete();
      expect(await first, 1);

      await bus.dispose();
    });
  });
}
