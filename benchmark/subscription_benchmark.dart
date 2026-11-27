// Microbenchmark for the 4.0 subscription model.
//
// Run:
//   dart run benchmark/subscription_benchmark.dart
//
// The numbers are a smoke measurement, not a pass/fail test. Compare them on
// the same machine and in the same build mode.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:event_bus_arch/event_bus_arch.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> main() async {
  print('Subscription benchmark');
  print('Dart ${Platform.version.split(' ').first}, '
      '${Platform.operatingSystem}, CPUs: ${Platform.numberOfProcessors}');
  print('');
  print('| scenario | events | elapsed ms | events/s | note |');
  print('|---|---:|---:|---:|---|');

  await _fireScenario('raw listen', DeliveryMode.async, legacy: true);
  await _fireScenario('subscribe async', DeliveryMode.async);
  await _fireScenario('subscribe sync', DeliveryMode.sync);
  await _requestSequential();
  await _requestBurst(concurrency: 1);
  await _requestBurst(concurrency: 4);
  await _busyScenario();
  await _memoryScenario(capacity: 16);
  await _memoryScenario(capacity: null);
}

Future<void> _fireScenario(
  String name,
  DeliveryMode mode, {
  bool legacy = false,
  int events = 100000,
}) async {
  final bus = EventBus();
  final completer = Completer<void>();
  var received = 0;

  void count() {
    received++;
    if (received == events && !completer.isCompleted) {
      completer.complete();
    }
  }

  if (legacy) {
    bus.listen(EventKey<int>('int.x')).listen((_) => count());
  } else {
    bus.subscribe(
      EventKey<int>('int.x'),
      deliveryMode: mode,
      onEvent: (_) => count(),
    );
  }

  final clock = Stopwatch()..start();
  for (var i = 0; i < events; i++) {
    bus.fire(EventKey<int>('int.x'), i);
  }
  await completer.future;
  clock.stop();

  _row(name, events, clock.elapsedMilliseconds,
      'listener callback count reached');
  await bus.dispose();
}

Future<void> _requestSequential({int events = 20000}) async {
  final bus = EventBus();
  bus.subscribe(
    EventKey<int>('int.x'),
    handler: (dto, lastData) async => dto.data,
  );

  final clock = Stopwatch()..start();
  for (var i = 0; i < events; i++) {
    await bus.request(EventKey<int>('int.x'), i);
  }
  clock.stop();

  _row('request sequential', events, clock.elapsedMilliseconds,
      'one handler, concurrency 1');
  await bus.dispose();
}

Future<void> _requestBurst(
    {required int concurrency, int events = 2000}) async {
  final bus = EventBus();
  bus.subscribe(
    EventKey<int>('int.x'),
    handlerConcurrency: concurrency,
    requestQueueCapacity: events,
    handler: (dto, lastData) async {
      await Future<void>.delayed(Duration.zero);
      return dto.data;
    },
  );

  final clock = Stopwatch()..start();
  final futures = <Future<dynamic>>[];
  for (var i = 0; i < events; i++) {
    futures.add(bus.request(EventKey<int>('int.x'), i));
  }
  await Future.wait(futures);
  clock.stop();

  _row('request burst', events, clock.elapsedMilliseconds,
      'concurrency $concurrency, queue $events');
  await bus.dispose();
}

Future<void> _busyScenario({int events = 2000}) async {
  final bus = EventBus();
  final gate = Completer<void>();
  bus.subscribe(
    EventKey<int>('int.x'),
    requestQueueCapacity: 0,
    handler: (dto, lastData) async {
      await gate.future;
      return dto.data;
    },
  );

  var busy = 0;
  final clock = Stopwatch()..start();
  final checks = <Future<void>>[];
  for (var i = 0; i < events; i++) {
    checks.add(bus.request(EventKey<int>('int.x'), i).then<void>(
      (_) {},
      onError: (Object error) {
        if (error is BusyException) busy++;
      },
    ));
  }
  gate.complete();
  await Future.wait(checks);
  clock.stop();
  await _pump();

  _row('request busy', events, clock.elapsedMilliseconds,
      '$busy BusyException, no queue');
  await bus.dispose();
}

Future<void> _memoryScenario(
    {required int? capacity, int subscriptions = 1000}) async {
  final bus = EventBus();
  final subs = <EventSubscription<int>>[];
  for (var i = 0; i < subscriptions; i++) {
    final sub = bus.subscribe(
      EventKey<int>('int.x'),
      bufferCapacity: capacity,
      onEvent: (_) {},
    );
    sub.pause();
    subs.add(sub);
  }

  final rssBefore = ProcessInfo.currentRss;
  for (var i = 0; i < 100; i++) {
    bus.fire(EventKey<int>('int.x'), i);
  }
  final rssAfter = ProcessInfo.currentRss;

  var buffered = 0;
  var dropped = 0;
  for (final sub in subs) {
    buffered += sub.buffered;
    dropped += sub.dropped;
  }
  _row(
    'memory bound',
    subscriptions * 100,
    0,
    'capacity ${capacity ?? 'unbounded'}: buffered=$buffered '
        'dropped=$dropped rssDelta=${(rssAfter - rssBefore) ~/ 1024} KiB '
        '(logical occupancy + RSS delta)',
  );

  for (final sub in subs) {
    await sub.cancel();
  }
  await bus.dispose();
}

void _row(String scenario, int events, int elapsedMs, String note) {
  final rate = elapsedMs <= 0 ? '-' : (events * 1000 / elapsedMs).round();
  print('| $scenario | $events | $elapsedMs | $rate | $note |');
}
