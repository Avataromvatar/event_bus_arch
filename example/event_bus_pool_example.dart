// ignore_for_file: avoid_print

import 'package:event_bus_arch/event_bus_arch.dart';

///The pool routes by the event key; the address is the routing identity.
final jobsKey = EventKey<int>('jobs');
final noteKey = EventKey<String>('note');

///Runs in every worker isolate. `initialData` is the worker index.
void poolWorker(EventBus bus, Object? initialData) {
  final index = initialData as int;
  bus.subscribe(jobsKey, handler: (dto, lastData) async {
    print('worker $index handled ${dto.data}');
    return index * 100 + dto.data;
  });
  bus.subscribe(noteKey, onEvent: (note) => print('worker $index got note: $note'));
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
    final answer = await pool.request(jobsKey, i);
    print('request $i -> $answer');
  }

  print('fire accepted: ${pool.fire(noteKey, 'hello')}');
  print(pool.metrics);

  await pool.close();
}
