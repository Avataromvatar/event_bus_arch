import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///Answers requests on `counter`; the response carries the worker index.
void keyWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribeEventsKey<int>(EventKey<int>('counter'),
      handler: (dto, lastData) async => '$index:${dto.data}');
}

///Reports fires on `counter` to the SendPort from initialData.
void keyPortWorker(EventBus bus, Object? initialData) {
  final port = initialData as SendPort;
  bus.subscribeEventsKey<int>(EventKey<int>('counter'),
      onEvent: (value) => port.send(value));
}

void main() {
  test('WorkerPool.requestKey reaches a worker handler', () async {
    final pool = WorkerPool(
      onInit: keyWorker,
      workers: 2,
      initialDataFor: (index) => index,
    );
    await pool.waitInit;

    final result = await pool.requestKey(EventKey<int>('counter'), 7);
    expect(result, anyOf('0:7', '1:7'));

    await pool.close();
  });

  test('WorkerPool.fireKey reaches a worker listener', () async {
    final port = ReceivePort();
    final pool = WorkerPool(
      onInit: keyPortWorker,
      workers: 1,
      initialData: port.sendPort,
    );
    await pool.waitInit;

    expect(pool.fireKey(EventKey<int>('counter'), 7), isTrue);
    expect(await port.first.timeout(const Duration(seconds: 2)), 7);

    port.close();
    await pool.close();
  });

  test('keyed dispatch keeps one address on one worker', () async {
    final pool = WorkerPool(
      onInit: keyWorker,
      workers: 2,
      dispatch: DispatchStrategy.keyed,
      initialDataFor: (index) => index,
    );
    await pool.waitInit;

    final first = await pool.requestKey(EventKey<int>('counter'), 1);
    final second = await pool.requestKey(EventKey<int>('counter'), 2);
    expect(first.toString().split(':').first,
        second.toString().split(':').first);

    await pool.close();
  });
}
