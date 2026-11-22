// ignore_for_file: avoid_print

import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';

final counterKey = EventKey<int>('counter');
final workKey = EventKey<int>('work');

///A small 4.0 tour: bounded listener buffers, handler queues, request
///cancellation, errors, metrics and a correlation id.
Future<void> main() async {
  final bus = EventBus(
    observability: const ObservabilityConfig(enabled: true),
  );
  final errors = bus.errors.listen((error) {
    print('error ${error.kind.name} ${error.address}: ${error.error}');
  });

  // A listener that keeps only the newest value while it is busy.
  final values = bus.subscribe(
    counterKey,
    bufferCapacity: 1,
    bufferOverflow: BufferOverflow.latest,
    onEvent: (value) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      print('render $value');
    },
  );
  for (var i = 1; i <= 5; i++) {
    bus.fire(counterKey, i);
  }
  await Future<void>.delayed(const Duration(milliseconds: 80));
  print('listener buffered=${values.buffered} dropped=${values.dropped}');

  // A handler with concurrency 1 and a bounded queue.
  final handler = bus.subscribe(
    workKey,
    handlerConcurrency: 1,
    requestQueueCapacity: 2,
    handler: (dto, lastData) async {
      print('work ${dto.data} correlation=${dto.correlationId}');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (dto.data == 4) throw StateError('handler failed');
      return dto.data * 10;
    },
  );

  final first = bus.request(workKey, 1, correlationId: 'job-1');
  final second = bus.request(workKey, 2);
  final token = CancelToken();
  final third = bus.request(workKey, 3, cancelToken: token);
  final thirdFailed = third.then((_) => false, onError: (Object _) => true);
  token.cancel();

  print('results: ${await first}, ${await second}, canceled=${await thirdFailed}');
  try {
    await bus.request(workKey, 4);
  } on StateError catch (error) {
    print('handler error reaches the caller: $error');
  }

  // A timed-out request is removed from the queue; its handler slot is released.
  try {
    await bus.request(workKey, 5, timeout: const Duration(milliseconds: 1));
  } on RequestTimeoutException catch (error) {
    print('timeout: ${error.address}');
  }
  await Future<void>.delayed(const Duration(milliseconds: 80));

  final snapshot = bus.metrics.snapshot();
  final work = snapshot.topics.firstWhere((t) => t.key == 'work');
  print('metrics: fired=${snapshot.fired} '
      'requests=${work.requestsStarted} completed=${work.requestsCompleted}');
  print('buffered requests=${handler.bufferedRequests} inFlight=${handler.inFlight}');

  await values.cancel();
  await handler.cancel();
  await errors.cancel();
  await bus.dispose();
}
