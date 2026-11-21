import 'dart:async';
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- workers (top-level only: they run in separate isolates) ---

///Answers with the per-worker index from `initialDataFor`.
void identityWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribeEvents<int>(handler: (dto, lastData) async => index);
}

///Like [identityWorker], but a request with data 0 stays in flight long enough
///to observe the worker as busy.
void slowIndexWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribeEvents<int>(handler: (dto, lastData) async {
    if (dto.data == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return index;
  });
}

///Answers String requests with the per-worker index.
void stringIdentityWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribeEvents<String>(handler: (dto, lastData) async => index);
}

///Data 1 is slow, so two requests with the same key must complete in order.
void orderedWorker(EventBus bus, Object? initialData) {
  bus.subscribeEvents<int>(handler: (dto, lastData) async {
    if (dto.data == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return dto.data;
  });
}

///Reports a 'ping' fire to the SendPort from initialData.
void portWorker(EventBus bus, Object? initialData) {
  final port = initialData as SendPort;
  bus.subscribe<String>(paths: ['ping'], onData: (e) => port.send('$e:ok'));
}

///Answers with the worker index and kills the isolate on a 'die' fire.
void dieWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribe<String>(
      paths: ['die'],
      onData: (_) => Isolate.current.kill(priority: Isolate.immediate));
  bus.subscribeEvents<int>(handler: (dto, lastData) async => index);
}

///Kills the isolate while a request is being handled.
void dyingHandlerWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribeEvents<int>(handler: (dto, lastData) async {
    if (dto.data == 0) {
      Isolate.current.kill(priority: Isolate.immediate);
    }
    return index;
  });
}

Future<void> failingWorker(EventBus bus, Object? initialData) async {
  throw StateError('init failed');
}

void main() {
  group('WorkerPool: lifecycle', () {
    test('waitInit makes every worker ready and close is idempotent', () async {
      final pool = WorkerPool(
        onInit: identityWorker,
        workers: 3,
        initialDataFor: (index) => index,
      );
      await pool.waitInit;

      expect(pool.isReady, isTrue);
      expect(pool.state, WorkerPoolState.ready);
      expect(pool.metrics.readyWorkers, 3);

      await pool.close();
      await pool.close();
      expect(pool.state, WorkerPoolState.closed);
      expect(() => pool.fire<int>(1), throwsStateError);
    });

    test('a worker init failure fails the pool', () async {
      final pool = WorkerPool(onInit: failingWorker, workers: 1);

      await expectLater(pool.waitInit, throwsA(isA<EventBusException>()));
      expect(pool.state, WorkerPoolState.failed);

      await pool.close();
    });
  });

  group('WorkerPool: strategies', () {
    test('roundRobin cycles over ready workers', () async {
      final pool = WorkerPool(
        onInit: identityWorker,
        workers: 3,
        initialDataFor: (index) => index,
      );
      await pool.waitInit;

      final indices = <int>[];
      for (var i = 0; i < 6; i++) {
        indices.add(await pool.request<int>(i) as int);
      }

      expect(indices, [0, 1, 2, 0, 1, 2]);
      await pool.close();
    });

    test('keyed sends the same key to the same worker', () async {
      final pool = WorkerPool(
        onInit: stringIdentityWorker,
        workers: 2,
        dispatch: DispatchStrategy.keyed,
        keySelector: (dto) => dto.data,
        initialDataFor: (index) => index,
      );
      await pool.waitInit;

      String keyFor(int worker) {
        var i = 0;
        while (true) {
          final key = 'key-$i';
          if (((key.hashCode & 0x7fffffff) % 2) == worker) return key;
          i++;
        }
      }

      final key0 = keyFor(0);
      final key1 = keyFor(1);
      expect(await pool.request<String>(key0), 0);
      expect(await pool.request<String>(key0), 0);
      expect(await pool.request<String>(key1), 1);
      expect(await pool.request<String>(key1), 1);

      await pool.close();
    });

    test('keyed preserves the order of one key', () async {
      final pool = WorkerPool(
        onInit: orderedWorker,
        workers: 2,
        dispatch: DispatchStrategy.keyed,
        keySelector: (_) => 'same',
        initialDataFor: (index) => index,
      );
      await pool.waitInit;

      final order = <int>[];
      final first = pool.request<int>(1).then((value) => order.add(value as int));
      final second =
          pool.request<int>(2).then((value) => order.add(value as int));
      await Future.wait([first, second]);

      expect(order, [1, 2]);
      await pool.close();
    });

    test('leastBusy picks the worker with fewer in-flight requests', () async {
      final pool = WorkerPool(
        onInit: slowIndexWorker,
        workers: 2,
        dispatch: DispatchStrategy.leastBusy,
        initialDataFor: (index) => index,
      );
      await pool.waitInit;

      final slow = pool.request<int>(0); // both empty: worker 0
      final quick = await pool.request<int>(1); // worker 0 busy: worker 1

      expect(quick, 1);
      expect(await slow, 0);
      await pool.close();
    });

    test('single uses one active worker and fails over to a standby', () async {
      final pool = WorkerPool(
        onInit: dieWorker,
        workers: 2,
        dispatch: DispatchStrategy.single,
        initialDataFor: (index) => index,
        supervision: const SupervisionPolicy(
          maxRestarts: 1,
          window: Duration(minutes: 1),
          initialBackoff: Duration(seconds: 5),
        ),
      );
      await pool.waitInit;
      expect(await pool.request<int>(1), 0);

      final death = pool.errors
          .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
          .timeout(const Duration(seconds: 2));
      expect(pool.fire<String>('x', paths: ['die']), isTrue);
      await death;

      expect(await pool.request<int>(1), 1);
      await pool.close();
    });

    test('broadcast sends to every worker and forbids requests', () async {
      final receive = ReceivePort();
      final pool = WorkerPool(
        onInit: portWorker,
        workers: 3,
        dispatch: DispatchStrategy.broadcast,
        initialData: receive.sendPort,
      );
      await pool.waitInit;

      final hits = receive.take(3).toList();
      expect(pool.fire<String>('x', paths: ['ping']), isTrue);
      expect(await hits.timeout(const Duration(seconds: 2)),
          ['x:ok', 'x:ok', 'x:ok']);

      await expectLater(
          pool.request<String>('x'), throwsA(isA<UnsupportedError>()));

      await pool.close();
      receive.close();
    });
  });

  group('WorkerPool: supervision', () {
    test('a dead worker is restarted with backoff', () async {
      final pool = WorkerPool(
        onInit: dieWorker,
        workers: 1,
        initialDataFor: (index) => index,
        supervision: const SupervisionPolicy(
          maxRestarts: 2,
          window: Duration(minutes: 1),
          initialBackoff: Duration(milliseconds: 50),
        ),
      );
      await pool.waitInit;

      final death = pool.errors
          .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
          .timeout(const Duration(seconds: 2));
      expect(pool.fire<String>('x', paths: ['die']), isTrue);
      await death;

      await pool.waitReady().timeout(const Duration(seconds: 2));
      expect(pool.isReady, isTrue);
      expect(await pool.request<int>(1), 0);
      expect(pool.metrics.restarts, 1);

      await pool.close();
    });

    test('restart exhaustion fails the pool and reports supervision', () async {
      final pool = WorkerPool(
        onInit: dieWorker,
        workers: 1,
        initialDataFor: (index) => index,
        supervision: const SupervisionPolicy(
          maxRestarts: 0,
          window: Duration(minutes: 1),
        ),
      );
      await pool.waitInit;

      final failure = pool.errors
          .firstWhere(
              (error) => error.kind == EventBusErrorKind.supervision)
          .timeout(const Duration(seconds: 2));
      expect(pool.fire<String>('x', paths: ['die']), isTrue);
      final error = await failure;

      expect(error.source, EventBusErrorSource.supervision);
      expect(pool.state, WorkerPoolState.failed);
      expect(() => pool.fire<int>(1), throwsA(isA<EventBusException>()));
      await expectLater(
          pool.request<int>(1), throwsA(isA<EventBusException>()));

      await pool.close();
    });

    test('a pool with no ready worker rejects work', () async {      final pool = WorkerPool(
        onInit: dieWorker,
        workers: 1,
        initialDataFor: (index) => index,
        supervision: const SupervisionPolicy(
          maxRestarts: 1,
          window: Duration(minutes: 1),
          initialBackoff: Duration(seconds: 5),
        ),
      );
      await pool.waitInit;

      final death = pool.errors
          .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
          .timeout(const Duration(seconds: 2));
      expect(pool.fire<String>('x', paths: ['die']), isTrue);
      await death;

      await expectLater(pool.request<int>(1), throwsA(isA<BusyException>()));
      expect(pool.fire<int>(1), isFalse);
      expect(pool.metrics.dropped, greaterThan(0));

      await pool.close();
    });

    test('a saturated worker does not take a new request', () async {
      final pool = WorkerPool(
        onInit: slowIndexWorker,
        workers: 1,
        maxInFlightPerWorker: 1,
        initialDataFor: (index) => index,
      );
      await pool.waitInit;

      final slow = pool.request<int>(0); // occupies the only credit
      await expectLater(pool.request<int>(1), throwsA(isA<BusyException>()));
      expect(await slow, 0);

      await pool.close();
    });

    test('a request whose worker dies fails and is not retried', () async {
      final pool = WorkerPool(
        onInit: dyingHandlerWorker,
        workers: 1,
        initialDataFor: (index) => index,
        supervision: const SupervisionPolicy(
          maxRestarts: 0,
          window: Duration(minutes: 1),
        ),
      );
      await pool.waitInit;
      final failure = pool.errors
          .firstWhere(
              (error) => error.kind == EventBusErrorKind.supervision)
          .timeout(const Duration(seconds: 2));

      await expectLater(
          pool.request<int>(0), throwsA(isA<EventBusException>()));
      await failure;

      expect(pool.metrics.failedRequests, 1);
      expect(pool.metrics.requests, 1);
      await pool.close();
    });
  });
}
