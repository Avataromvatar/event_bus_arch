// Load benchmark for the local bus and the isolate bus.
//
// Run:
//   dart run benchmark/load_benchmark.dart
//   dart run benchmark/load_benchmark.dart --seconds=3 --rates=100,1000,10000
//
// The benchmark publishes at a target rate (open loop) and measures the
// latency from the publish call to the listener/handler completion.
// It is a measurement tool, not a pass/fail test: latency depends on the
// machine, the Dart VM, the build mode and the rest of the system.
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:event_bus_arch/event_bus_arch.dart';

///One event delivered through the bus. `sentAtUs` is main-isolate stopwatch
///time, so the worker needs a calibrated offset to interpret it.
class _FireEvent {
  const _FireEvent(this.seq, this.sentAtUs);
  final int seq;
  final int sentAtUs;
}

///A request event; its latency is measured on the main side (round trip).
class _RequestEvent {
  const _RequestEvent(this.seq);
  final int seq;
}

class _CalibrateRequest {
  const _CalibrateRequest();
}

class _SetOffsetRequest {
  const _SetOffsetRequest(this.offsetUs);
  final int offsetUs;
}

class _ResetFireRequest {
  const _ResetFireRequest();
}

class _CountFireRequest {
  const _CountFireRequest();
}

class _CollectFireRequest {
  const _CollectFireRequest();
}

class _FireIntegrityRequest {
  const _FireIntegrityRequest();
}

///Worker side: records `_FireEvent` latencies and answers the control
///requests. Runs inside the worker isolate.
Future<void> _workerInit(EventBus bus, Object? initialData) async {
  final workerClock = Stopwatch()..start();
  final fireLatencies = <int>[];
  final fireSeqs = <int>{};
  var fireReceived = 0;
  int? offsetUs;

  bus.listen<_FireEvent>().listen((event) {
    fireReceived++;
    fireSeqs.add(event.seq);
    final offset = offsetUs;
    if (offset == null) return;
    final latency = workerClock.elapsedMicroseconds + offset - event.sentAtUs;
    // Keep the raw value: negatives mean the calibrated offset is off by more
    // than the event latency. The main side clamps them for the statistics.
    fireLatencies.add(latency);
  });

  bus.handlers.setHandler<_RequestEvent>(
    handler: (dto, lastData) async => dto.data.seq,
  );
  bus.handlers.setHandler<_CalibrateRequest>(
    handler: (dto, lastData) async => workerClock.elapsedMicroseconds,
  );
  bus.handlers.setHandler<_SetOffsetRequest>(
    handler: (dto, lastData) async {
      offsetUs = dto.data.offsetUs;
      return null;
    },
  );
  bus.handlers.setHandler<_ResetFireRequest>(
    handler: (dto, lastData) async {
      fireLatencies.clear();
      fireSeqs.clear();
      fireReceived = 0;
      return null;
    },
  );
  bus.handlers.setHandler<_CountFireRequest>(
    handler: (dto, lastData) async => fireReceived,
  );
  bus.handlers.setHandler<_CollectFireRequest>(
    handler: (dto, lastData) async => List<int>.of(fireLatencies),
  );
  bus.handlers.setHandler<_FireIntegrityRequest>(
    handler: (dto, lastData) async => <int>[fireReceived, fireSeqs.length],
  );
}

class _Options {
  const _Options({
    required this.rates,
    required this.duration,
    required this.warmup,
  });

  final List<int> rates;
  final Duration duration;
  final Duration warmup;

  static _Options parse(List<String> args) {
    var rates = const [100, 500, 1000, 5000, 10000];
    var seconds = 2.0;
    var warmupMs = 500;
    for (final arg in args) {
      if (arg.startsWith('--rates=')) {
        rates = arg
            .substring('--rates='.length)
            .split(',')
            .map(int.parse)
            .toList(growable: false);
      } else if (arg.startsWith('--seconds=')) {
        seconds = double.parse(arg.substring('--seconds='.length));
      } else if (arg.startsWith('--warmup-ms=')) {
        warmupMs = int.parse(arg.substring('--warmup-ms='.length));
      }
    }
    return _Options(
      rates: rates,
      duration: Duration(microseconds: (seconds * 1000000).round()),
      warmup: Duration(milliseconds: warmupMs),
    );
  }
}

class _Result {
  _Result({
    required this.scenario,
    required this.rate,
    required this.sent,
    required this.delivered,
    required this.unique,
    required this.rejected,
    required this.errors,
    required this.generationUs,
    required this.samples,
    this.negatives = 0,
  });

  final String scenario;
  final int rate;
  final int sent;
  final int delivered;

  ///Distinct sequence numbers among the delivered events.
  final int unique;
  final int rejected;
  final int errors;
  final int generationUs;
  final List<int> samples;

  ///Samples below zero (clamped): the cross-isolate clock offset is off by
  ///more than the event latency.
  final int negatives;

  double get achievedRate =>
      generationUs <= 0 ? 0 : sent * 1000000 / generationUs;

  String _percentile(double p) {
    if (samples.isEmpty) return '-';
    final sorted = List<int>.of(samples)..sort();
    final index = ((sorted.length - 1) * p).round();
    return (sorted[index] / 1000).toStringAsFixed(3);
  }

  String get mean {
    if (samples.isEmpty) return '-';
    final sum = samples.fold<int>(0, (a, b) => a + b);
    return (sum / samples.length / 1000).toStringAsFixed(3);
  }

  String row() {
    final lost = sent - unique;
    final duplicates = delivered - unique;
    final lostText = lost > 0 ? ' lost=$lost' : '';
    final duplicateText = duplicates > 0 ? ' dup=$duplicates' : '';
    final rejectedText = rejected > 0 ? ' rejected=$rejected' : '';
    final errorText = errors > 0 ? ' errors=$errors' : '';
    final negativeText = negatives > 0 ? ' neg=$negatives' : '';
    return '| $scenario | $rate | $sent$rejectedText$errorText | '
        '$delivered$lostText$duplicateText$negativeText | '
        '${achievedRate.toStringAsFixed(0)} | '
        '${_percentile(0.5)} | ${_percentile(0.9)} | '
        '${_percentile(0.99)} | ${_percentile(1.0)} | $mean |';
  }
}

///Drives [send] at approximately [rate] events per second, open loop.
///Returns the number of events handed to [send].
Future<int> _drive({
  required int rate,
  required Duration duration,
  required Stopwatch clock,
  required void Function(int seq, int sentAtUs) send,
}) async {
  final intervalUs = 1000000 / rate;
  final startUs = clock.elapsedMicroseconds;
  final endUs = duration.inMicroseconds;
  var nextUs = 0.0;
  var sent = 0;
  var yields = 0;

  while (true) {
    final elapsed = clock.elapsedMicroseconds - startUs;
    if (elapsed >= endUs) break;
    if (elapsed >= nextUs) {
      send(sent, clock.elapsedMicroseconds);
      sent++;
      nextUs += intervalUs;
      // If the VM stalled, do not fire a burst to catch up.
      if (nextUs < elapsed - 4 * intervalUs) {
        nextUs = elapsed + intervalUs;
      }
    } else {
      yields++;
      // Microtasks are much faster than timers; give the event loop (ports,
      // timers) a chance regularly so the isolate can make progress.
      if (yields % 32 == 0) {
        await Future<void>.delayed(Duration.zero);
      } else {
        await null;
      }
    }
  }
  return sent;
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<_Result> _localFire(
  _Options options,
  int rate,
  Stopwatch clock,
) async {
  final bus = EventBus();
  final samples = <int>[];
  final seen = <int>{};
  var sent = 0;
  var rejected = 0;
  final sub = bus.listen<_FireEvent>().listen((event) {
    seen.add(event.seq);
    final latency = clock.elapsedMicroseconds - event.sentAtUs;
    samples.add(latency < 0 ? 0 : latency);
  });

  // Warm-up.
  final warmupSent = await _drive(
    rate: 1000,
    duration: options.warmup,
    clock: clock,
    send: (seq, at) => bus.fire(_FireEvent(seq, at)),
  );
  await _waitUntil(() => samples.length >= warmupSent);
  samples.clear();
  seen.clear();

  var generationUs = 0;
  sent = 0;
  final start = clock.elapsedMicroseconds;
  sent = await _drive(
    rate: rate,
    duration: options.duration,
    clock: clock,
    send: (seq, at) {
      if (!bus.fire(_FireEvent(seq, at))) rejected++;
    },
  );
  generationUs = clock.elapsedMicroseconds - start;
  await _waitUntil(() => samples.length >= sent);

  await sub.cancel();
  await bus.dispose();
  return _Result(
    scenario: 'local fire',
    rate: rate,
    sent: sent,
    delivered: samples.length,
    unique: seen.length,
    rejected: rejected,
    errors: 0,
    generationUs: generationUs,
    samples: samples,
  );
}

Future<_Result> _localRequest(
  _Options options,
  int rate,
  Stopwatch clock,
) async {
  final bus = EventBus();
  bus.handlers.setHandler<_RequestEvent>(
    handler: (dto, lastData) async => dto.data.seq,
  );
  final samples = <int>[];
  final seen = <int>{};
  var errors = 0;

  Future<void> one(int seq, int sentAt) {
    return bus.request<_RequestEvent>(_RequestEvent(seq)).then(
      (value) {
        seen.add(value as int);
        samples.add(max(0, clock.elapsedMicroseconds - sentAt));
      },
      onError: (Object _) => errors++,
    );
  }

  // Warm-up.
  final warmup = <Future<void>>[];
  await _drive(
    rate: 1000,
    duration: options.warmup,
    clock: clock,
    send: (seq, at) => warmup.add(one(seq, at)),
  );
  await Future.wait(warmup);
  samples.clear();
  seen.clear();

  final pending = <Future<void>>[];
  var sent = 0;
  final start = clock.elapsedMicroseconds;
  sent = await _drive(
    rate: rate,
    duration: options.duration,
    clock: clock,
    send: (seq, at) => pending.add(one(seq, at)),
  );
  final generationUs = clock.elapsedMicroseconds - start;
  await Future.wait(pending).timeout(const Duration(seconds: 30));

  await bus.dispose();
  return _Result(
    scenario: 'local request',
    rate: rate,
    sent: sent,
    delivered: samples.length,
    unique: seen.length,
    rejected: 0,
    errors: errors,
    generationUs: generationUs,
    samples: samples,
  );
}

///Estimates the offset between the main and worker stopwatches.
///
///The offset is `mainTime - workerTime`. One calibration round trip has an
///unknown one-way delay; the best round (smallest RTT) is used and the RTT is
///split in half.
Future<int> _calibrate(EventBusIsolate iso, Stopwatch clock) async {
  var bestRtt = 1 << 62;
  var bestOffset = 0;
  for (var i = 0; i < 7; i++) {
    final t0 = clock.elapsedMicroseconds;
    final workerAt = (await iso.request<_CalibrateRequest>(
      const _CalibrateRequest(),
    )) as int;
    final t1 = clock.elapsedMicroseconds;
    final rtt = t1 - t0;
    if (rtt < bestRtt) {
      bestRtt = rtt;
      bestOffset = t0 + rtt ~/ 2 - workerAt;
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await iso.request<_SetOffsetRequest>(_SetOffsetRequest(bestOffset));
  return bestOffset;
}

Future<int> _workerCount(EventBusIsolate iso) async {
  return (await iso.request<_CountFireRequest>(const _CountFireRequest()))
      as int;
}

Future<_Result> _isolateFire(
  EventBusIsolate iso,
  _Options options,
  int rate,
  Stopwatch clock,
) async {
  await _calibrate(iso, clock);
  await iso.request<_ResetFireRequest>(const _ResetFireRequest());

  // Warm-up.
  final warmupSent = await _drive(
    rate: 1000,
    duration: options.warmup,
    clock: clock,
    send: (seq, at) => iso.fire(_FireEvent(seq, at)),
  );
  await _waitForWorker(iso, warmupSent);
  await iso.request<_ResetFireRequest>(const _ResetFireRequest());

  var rejected = 0;
  final start = clock.elapsedMicroseconds;
  final sent = await _drive(
    rate: rate,
    duration: options.duration,
    clock: clock,
    send: (seq, at) {
      if (!iso.fire(_FireEvent(seq, at))) rejected++;
    },
  );
  final generationUs = clock.elapsedMicroseconds - start;

  await _waitForWorker(iso, sent);
  final raw = (await iso
      .request<_CollectFireRequest>(const _CollectFireRequest())) as List<int>;
  final integrity = (await iso.request<_FireIntegrityRequest>(
    const _FireIntegrityRequest(),
  )) as List<int>;
  final negatives = raw.where((value) => value < 0).length;
  final samples = raw.map((value) => value < 0 ? 0 : value).toList();

  return _Result(
    scenario: 'isolate fire',
    rate: rate,
    sent: sent,
    delivered: integrity[0],
    unique: integrity[1],
    rejected: rejected,
    errors: 0,
    generationUs: generationUs,
    samples: samples,
    negatives: negatives,
  );
}

Future<void> _waitForWorker(
  EventBusIsolate iso,
  int expected, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await _workerCount(iso) >= expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<_Result> _isolateRequest(
  EventBusIsolate iso,
  _Options options,
  int rate,
  Stopwatch clock,
) async {
  final samples = <int>[];
  final seen = <int>{};
  var errors = 0;

  Future<void> one(int seq, int sentAt) {
    return iso.request<_RequestEvent>(_RequestEvent(seq)).then(
      (value) {
        seen.add(value as int);
        samples.add(max(0, clock.elapsedMicroseconds - sentAt));
      },
      onError: (Object _) => errors++,
    );
  }

  // Warm-up.
  final warmup = <Future<void>>[];
  await _drive(
    rate: 1000,
    duration: options.warmup,
    clock: clock,
    send: (seq, at) => warmup.add(one(seq, at)),
  );
  await Future.wait(warmup);
  samples.clear();
  seen.clear();

  final pending = <Future<void>>[];
  var sent = 0;
  final start = clock.elapsedMicroseconds;
  sent = await _drive(
    rate: rate,
    duration: options.duration,
    clock: clock,
    send: (seq, at) => pending.add(one(seq, at)),
  );
  final generationUs = clock.elapsedMicroseconds - start;
  await Future.wait(pending).timeout(const Duration(seconds: 30));

  return _Result(
    scenario: 'isolate request',
    rate: rate,
    sent: sent,
    delivered: samples.length,
    unique: seen.length,
    rejected: 0,
    errors: errors,
    generationUs: generationUs,
    samples: samples,
  );
}

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final clock = Stopwatch()..start();

  print('EventBus load benchmark');
  print('Dart ${Platform.version.split(' ').first}, '
      '${Platform.operatingSystem}, CPUs: ${Platform.numberOfProcessors}');
  print('duration: ${options.duration.inMilliseconds} ms, '
      'warm-up: ${options.warmup.inMilliseconds} ms, '
      'rates: ${options.rates.join(', ')} events/s');
  print('');
  print('| scenario | target/s | sent | delivered | achieved/s | '
      'p50 ms | p90 ms | p99 ms | max ms | mean ms |');
  print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|');

  // Local scenarios reuse one bus each; the isolate scenario reuses one
  // worker for all rates.
  for (final rate in options.rates) {
    final result = await _localFire(options, rate, clock);
    print(result.row());
  }
  for (final rate in options.rates) {
    final result = await _localRequest(options, rate, clock);
    print(result.row());
  }

  final port = ReceivePort();
  final iso = EventBusIsolate(
    onInit: _workerInit,
    initialData: port.sendPort,
  );
  try {
    await iso.waitInit;
    for (final rate in options.rates) {
      final result = await _isolateFire(iso, options, rate, clock);
      print(result.row());
    }
    for (final rate in options.rates) {
      final result = await _isolateRequest(iso, options, rate, clock);
      print(result.row());
    }
  } finally {
    port.close();
    await iso.dispose();
  }

  print('');
  print('Latency is measured from the publish call to the listener/handler '
      'completion on the main side; isolate fire latency uses a calibrated '
      'stopwatch offset (best of 7 calibration round trips).');
  print('An open-loop sender can run ahead of the consumer; compare '
      '"achieved/s" with "target/s" and check "missed".');
}
