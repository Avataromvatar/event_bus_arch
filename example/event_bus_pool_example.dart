// ignore_for_file: avoid_print

import 'package:event_bus_arch/event_bus_arch.dart';

///Runs in every worker isolate. `initialData` is the worker index.
void poolWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribeEvents<int>(
    handler: (dto, lastData) async {
      print('worker $index handled ${dto.data}');
      return index * 100 + dto.data;
    },
  );
  bus.subscribe<String>(
    paths: ['note'],
    onData: (note) => print('worker $index got note: $note'),
  );
}

Future<void> main() async {
  final pool = WorkerPool(
    onInit: poolWorker,
    workers: 3,
    dispatch: DispatchStrategy.roundRobin,
    initialDataFor: (index) => index,
    supervision: const SupervisionPolicy(maxRestarts: 2),
  );

  await pool.waitInit;
  print('ready with ${pool.metrics.readyWorkers} workers');

  for (var i = 0; i < 6; i++) {
    final answer = await pool.request<int>(i);
    print('request $i -> $answer');
  }

  print('fire accepted: ${pool.fire<String>('hello', paths: ['note'])}');
  print(pool.metrics);

  await pool.close();
}
