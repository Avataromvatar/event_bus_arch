import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- workers (top-level only: they run in separate isolates) ---

final workerKey = EventKey<int>('work');

void keyedIdentityWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribe(workerKey, handler: (dto, last) async => index);
}

///Throws a handler StateError for data 0; answers the data otherwise.
void stateErrorWorker(EventBus bus, Object? initialData) {
  bus.subscribe(workerKey, handler: (dto, last) async {
    if (dto.data == 0) throw StateError('handler boom');
    return dto.data;
  });
}

///Kills the isolate while handling data 0.
void dyingKeyedWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribe(workerKey, handler: (dto, last) async {
    if (dto.data == 0) {
      Isolate.current.kill(priority: Isolate.immediate);
    }
    return index;
  });
}

void main() {
  group('WorkerPool: reliability', () {
    test('leastBusy rotates between equally idle workers', () async {
      final pool = WorkerPool(
        onInit: keyedIdentityWorker,
        workers: 3,
        dispatch: DispatchStrategy.leastBusy,
        initialDataFor: (index) => index,
      );
      await pool.waitInit;

      final indices = <int>[];
      for (var i = 0; i < 6; i++) {
        indices.add(await pool.request(workerKey, i) as int);
      }

      expect(indices, [0, 1, 2, 0, 1, 2]);
      await pool.close();
    });

    test('a StateError from a ready worker handler reaches the caller',
        () async {
      final pool = WorkerPool(onInit: stateErrorWorker, workers: 1);
      await pool.waitInit;

      await expectLater(pool.request(workerKey, 0), throwsA(isA<StateError>()));
      expect(pool.metrics.failedRequests, 1);

      // The worker is still ready: the pool did not mistake a handler error
      // for a routing failure.
      expect(await pool.request(workerKey, 7), 7);
      await pool.close();
    });

    test('a killed worker is not routable and reports BusyException', () async {
      final pool = WorkerPool(
        onInit: dyingKeyedWorker,
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
      await pool
          .request(workerKey, 0)
          .then<void>((_) {}, onError: (Object _) {});
      await death;

      await expectLater(
          pool.request(workerKey, 1), throwsA(isA<BusyException>()));
      await pool.close();
    });
  });
}
