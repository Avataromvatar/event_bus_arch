import 'dart:async';
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- functions that run IN THE WORKER (top-level only) ---

void silentWorker(EventBus bus, Object? initialData) {}

///A handler for int with no listener: it must not count for `fire` (D14).
void doublingWorker(EventBus bus, Object? initialData) {
  bus.subscribeEvents<int>(handler: (dto, lastData) async => dto.data * 2);
}

///Listens to 'in' and echoes every event to 'seen'.
void listenerWorker(EventBus bus, Object? initialData) {
  bus.subscribe<String>(
      paths: ['in'],
      onData: (e) => bus.fire<String>('seen: $e', paths: ['seen']));
}

///Echoes to the same path. With local delivery on the bridge this would be an
///endless loop: the listener would receive its own echo and fire again.
void sameTopicEchoWorker(EventBus bus, Object? initialData) {
  bus.subscribe<String>(
      paths: ['in'],
      onData: (e) => bus.fire<String>('echo: $e', paths: ['in']));
}

///The same listener, but created after an asynchronous onInit delay.
Future<void> slowListenerWorker(EventBus bus, Object? initialData) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  bus.subscribe<String>(
      paths: ['in'],
      onData: (e) => bus.fire<String>('seen: $e', paths: ['seen']));
}

///A pattern listener: interest for every topic of the type.
void patternEchoWorker(EventBus bus, Object? initialData) {
  bus.subscribe<String>(
      paths: ['*'], onData: (e) => bus.fire<String>('echo: $e'));
}

void pathWorker(EventBus bus, Object? initialData) {
  bus.subscribeEvents<int>(
      paths: ['counter'], handler: (dto, lastData) async => dto.data * 2);
}

///Answers once and then removes its own handler.
void oneShotHandlerWorker(EventBus bus, Object? initialData) {
  late EventSubscription<int> subscription;
  subscription = bus.subscribeEvents<int>(
      paths: ['once'], handler: (dto, lastData) async {
    await subscription.cancel();
    return dto.data;
  });
}

///A slow handler that reports every invocation to 'ran'.
void queuedWorker(EventBus bus, Object? initialData) {
  bus.subscribeEvents<int>(paths: ['work'], handler: (dto, lastData) async {
    bus.fire<int>(dto.data, paths: ['ran']);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return dto.data;
  });
}

///A slow handler plus a path that kills the worker.
void slowThenDieWorker(EventBus bus, Object? initialData) {
  bus.subscribeEvents<int>(
      paths: ['work', 'slow'], handler: (dto, lastData) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return dto.data;
  });
  bus.subscribe<String>(
      paths: ['die'],
      onData: (_) => Isolate.current.kill(priority: Isolate.immediate));
}

void main() {
  group('EventBusIsolate: fire delivery (D14)', () {
    test('a fire with no listener on either side returns false', () async {
      final iso = EventBusIsolate(onInit: silentWorker);
      await iso.waitInit;

      expect(iso.fire<String>('hi', paths: ['in']), isFalse);

      await iso.dispose();
    });

    test('a fire on a bridge is outbound and skips local listeners', () async {
      final iso = EventBusIsolate(onInit: silentWorker);
      await iso.waitInit;
      final local = <String>[];
      final sub = iso.subscribe<String>(paths: ['in'], onData: local.add);

      // there is a local listener, but it is an inbound listener: the worker
      // has no interest, so the fire goes nowhere and returns false
      expect(iso.fire<String>('hi', paths: ['in']), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(local, isEmpty);
      await sub.cancel();
      await iso.dispose();
    });

    test('a local handler alone does not make fire true', () async {
      final iso = EventBusIsolate(onInit: silentWorker);
      await iso.waitInit;
      final sub = iso.subscribeEvents<int>(handler: (dto, lastData) async {
        return dto.data;
      });

      expect(iso.fire<int>(1), isFalse);

      await sub.cancel();
      await iso.dispose();
    });

    test('a remote handler alone does not make fire true', () async {
      final iso = EventBusIsolate(onInit: doublingWorker);
      await iso.waitInit;

      expect(iso.fire<int>(1), isFalse);
      // the handler is still reachable by a request
      expect(await iso.request<int>(1), 2);

      await iso.dispose();
    });

    test('a remote listener receives the fire and makes it true', () async {
      final iso = EventBusIsolate(onInit: listenerWorker);
      await iso.waitInit;
      final seen = <String>[];
      final sub = iso.subscribe<String>(paths: ['seen'], onData: seen.add);

      expect(iso.fire<String>('hi', paths: ['in']), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(seen, ['seen: hi']);
      await sub.cancel();
      await iso.dispose();
    });

    test('a same-topic echo in the worker does not re-enter its listener',
        () async {
      final iso = EventBusIsolate(onInit: sameTopicEchoWorker);
      await iso.waitInit;
      final seen = <String>[];
      final sub = iso.subscribe<String>(paths: ['in'], onData: seen.add);

      expect(iso.fire<String>('hi', paths: ['in']), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // only the worker's echo crossed back; the main-side fire itself was
      // not delivered locally and the worker did not loop on its own echo
      expect(seen, ['echo: hi']);
      await sub.cancel();
      await iso.dispose();
    });

    test('a remote pattern listener is interest for a matching topic',
        () async {
      final iso = EventBusIsolate(onInit: patternEchoWorker);
      await iso.waitInit;
      final echoed = <String>[];
      final sub = iso.subscribe<String>(onData: echoed.add);

      // no local listener for "x": true is only possible through the pattern
      // interest of the worker
      expect(iso.fire<String>('hi', paths: ['x']), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(echoed, ['echo: hi']);
      await sub.cancel();
      await iso.dispose();
    });
  });

  group('EventBusIsolate: request routing', () {
    test('a local handler answers before the worker handler', () async {
      final iso = EventBusIsolate(onInit: pathWorker);
      await iso.waitInit;
      final local = iso.subscribeEvents<int>(
          paths: ['counter'],
          handler: (dto, lastData) async => dto.data + 1000);

      expect(await iso.request<int>(21, paths: ['counter']), 1021);

      await local.cancel();
      await iso.dispose();
    });

    test('a request without a handler on either side fails immediately',
        () async {
      final iso = EventBusIsolate(onInit: silentWorker);
      await iso.waitInit;

      await expectLater(
        iso.request<String>('nobody').timeout(const Duration(seconds: 1)),
        throwsA(isA<NoHandlerException>()),
      );
      await iso.dispose();
    });

    test('a withdrawn remote handler fails later requests immediately',
        () async {
      final iso = EventBusIsolate(onInit: oneShotHandlerWorker);
      await iso.waitInit;

      expect(await iso.request<int>(7, paths: ['once']), 7);
      // the interest withdrawal is sent before the response, so it is already
      // known when the first request completes
      await expectLater(
        iso.request<int>(8, paths: ['once']).timeout(const Duration(seconds: 1)),
        throwsA(isA<NoHandlerException>()),
      );
      await iso.dispose();
    });
  });

  group('EventBusIsolate: request cancellation', () {
    test('cancelling a queued request prevents it from running', () async {
      final iso = EventBusIsolate(onInit: queuedWorker);
      await iso.waitInit;
      final ran = <int>[];
      final firstStarted = Completer<void>();
      final sub = iso.subscribe<int>(paths: ['ran'], onData: (value) {
        ran.add(value);
        if (value == 1 && !firstStarted.isCompleted) {
          firstStarted.complete();
        }
      });

      final first = iso.request<int>(1, paths: ['work']);
      await firstStarted.future.timeout(const Duration(seconds: 1));

      final token = CancelToken();
      final second =
          iso.request<int>(2, paths: ['work'], cancelToken: token);
      final canceled =
          expectLater(second, throwsA(isA<RequestCanceledException>()));
      // the second request reaches the worker and is queued behind the first
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel();

      await canceled;
      expect(await first, 1);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ran, [1]);
      await sub.cancel();
      await iso.dispose();
    });

    test('a timed out queued request is removed from the worker queue',
        () async {
      final iso = EventBusIsolate(onInit: queuedWorker);
      await iso.waitInit;
      final ran = <int>[];
      final firstStarted = Completer<void>();
      final sub = iso.subscribe<int>(paths: ['ran'], onData: (value) {
        ran.add(value);
        if (value == 1 && !firstStarted.isCompleted) {
          firstStarted.complete();
        }
      });

      final first = iso.request<int>(1, paths: ['work']);
      await firstStarted.future.timeout(const Duration(seconds: 1));

      await expectLater(
        iso.request<int>(2,
            paths: ['work'], timeout: const Duration(milliseconds: 50)),
        throwsA(isA<RequestTimeoutException>()),
      );

      expect(await first, 1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ran, [1]);
      await sub.cancel();
      await iso.dispose();
    });
  });

  group('EventBusIsolate: interest snapshot and removal', () {
    test('waitInit sees the interest of an asynchronous onInit', () async {
      final iso = EventBusIsolate(onInit: slowListenerWorker);
      await iso.waitInit;
      final seen = <String>[];
      final sub = iso.subscribe<String>(paths: ['seen'], onData: seen.add);

      // fired immediately after waitInit: the worker interest is already known
      expect(iso.fire<String>('hi', paths: ['in']), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(seen, ['seen: hi']);
      await sub.cancel();
      await iso.dispose();
    });

    test('removeTopic withdraws the remote listener interest', () async {
      final iso = EventBusIsolate(onInit: listenerWorker);
      await iso.waitInit;
      final seen = <String>[];
      final sub = iso.subscribe<String>(paths: ['seen'], onData: seen.add);

      expect(iso.fire<String>('one', paths: ['in']), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, ['seen: one']);

      iso.removeTopic<String>(paths: ['in']);
      // the delete and the interest withdrawal travel through the same port
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(iso.fire<String>('two', paths: ['in']), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, ['seen: one']);
      await sub.cancel();
      await iso.dispose();
    });
  });

  group('EventBusIsolate: worker death', () {
    test('a dead worker is reported and the bus stops accepting work', () async {
      final iso = EventBusIsolate(onInit: slowThenDieWorker);
      await iso.waitInit;
      final death = iso.errors
          .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
          .timeout(const Duration(seconds: 2));

      expect(iso.fire<String>('now', paths: ['die']), isTrue);
      await death;

      expect(iso.isInit, isFalse);
      expect(await iso.ping(), isFalse);
      // the stale remote interest is gone; the bus is not ready any more
      expect(() => iso.fire<String>('x', paths: ['die']), throwsStateError);
      await expectLater(iso.dispose(), completes);
    });

    test('a pending request fails when the worker dies', () async {
      final iso = EventBusIsolate(onInit: slowThenDieWorker);
      await iso.waitInit;
      final pending = iso.request<int>(1, paths: ['work', 'slow']);
      final failed = expectLater(pending, throwsA(isA<EventBusException>()));

      expect(iso.fire<String>('now', paths: ['die']), isTrue);
      await failed;
      await iso.dispose();
    });
  });
}
