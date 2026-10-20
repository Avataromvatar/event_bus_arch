// Load benchmark for the NATS transport.
//
// Start a NATS server and run:
//   dart run benchmark/nats_load_benchmark.dart
//   dart run benchmark/nats_load_benchmark.dart --rates=100,1000,10000
//   dart run benchmark/nats_load_benchmark.dart --scenario=fire --rates=100000 --seconds=2
//
// `NATS_URL` (default nats://127.0.0.1:4222) or --url= selects the broker.
// `--scenario=fire|request|both` selects the scenarios.
//
// The benchmark runs a publisher and a subscriber (and, for requests, a
// requester and a responder) in one process. It is a measurement tool, not a
// pass/fail test: latency depends on the machine, the broker, the Dart VM and
// the build mode.
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_nats/event_bus_nats.dart';

///Fire-and-forget event. `sentAtUs` comes from the benchmark stopwatch; both
///buses live in this isolate, so the subscriber can read the same clock.
class LoadEvent {
  const LoadEvent(this.seq, this.sentAtUs);
  final int seq;
  final int sentAtUs;
}

///Request/response event. The response is an `int` (the sequence number).
class RequestEvent {
  const RequestEvent(this.seq);
  final int seq;
}

(String?, Uint8List) _encodeLoad(EventDTO dto) {
  final event = dto.data as LoadEvent;
  final bytes = ByteData(16)
    ..setInt64(0, event.seq)
    ..setInt64(8, event.sentAtUs);
  return (null, bytes.buffer.asUint8List());
}

EventDTO<LoadEvent> _decodeLoad(
  Uint8List data,
  String topic, {
  Map<String, String>? arguments,
}) {
  final bytes = ByteData.sublistView(data);
  return EventDTO<LoadEvent>(
    LoadEvent(bytes.getInt64(0), bytes.getInt64(8)),
    topic: Topic.parse(topic),
    arguments: arguments,
  );
}

///Tag 0 is a request, tag 1 is the integer response.
(String?, Uint8List) _encodeRequest(EventDTO dto) {
  final bytes = ByteData(9);
  final value = dto.data;
  if (value is RequestEvent) {
    bytes.setUint8(0, 0);
    bytes.setInt64(1, value.seq);
  } else {
    bytes.setUint8(0, 1);
    bytes.setInt64(1, value as int);
  }
  return (null, bytes.buffer.asUint8List());
}

EventDTO<dynamic> _decodeRequest(
  Uint8List data,
  String topic, {
  Map<String, String>? arguments,
}) {
  final bytes = ByteData.sublistView(data);
  final tag = bytes.getUint8(0);
  final value = bytes.getInt64(1);
  final localTopic = Topic.parse(topic);
  return tag == 0
      ? EventDTO<RequestEvent>(
          RequestEvent(value),
          topic: localTopic,
          arguments: arguments,
        )
      : EventDTO<int>(
          value,
          topic: localTopic,
          arguments: arguments,
        );
}

class _Options {
  const _Options({
    required this.rates,
    required this.duration,
    required this.warmup,
    required this.url,
    required this.scenario,
  });

  final List<int> rates;
  final Duration duration;
  final Duration warmup;
  final Uri url;

  ///`both` (default), `fire` or `request`.
  final String scenario;

  static _Options parse(List<String> args) {
    var rates = const [100, 500, 1000, 5000, 10000];
    var seconds = 2.0;
    var warmupMs = 500;
    var scenario = 'both';
    var url = Uri.parse(
      Platform.environment['NATS_URL'] ?? 'nats://127.0.0.1:4222',
    );
    for (final arg in args) {
      if (arg.startsWith('--scenario=')) {
        scenario = arg.substring('--scenario='.length);
      } else if (arg.startsWith('--rates=')) {
        rates = arg
            .substring('--rates='.length)
            .split(',')
            .map(int.parse)
            .toList(growable: false);
      } else if (arg.startsWith('--seconds=')) {
        seconds = double.parse(arg.substring('--seconds='.length));
      } else if (arg.startsWith('--warmup-ms=')) {
        warmupMs = int.parse(arg.substring('--warmup-ms='.length));
      } else if (arg.startsWith('--url=')) {
        url = Uri.parse(arg.substring('--url='.length));
      }
    }
    return _Options(
      rates: rates,
      duration: Duration(microseconds: (seconds * 1000000).round()),
      warmup: Duration(milliseconds: warmupMs),
      url: url,
      scenario: scenario,
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
  });

  final String scenario;
  final int rate;
  final int sent;
  final int delivered;
  final int unique;
  final int rejected;
  final int errors;
  final int generationUs;
  final List<int> samples;

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
    return '| $scenario | $rate | $sent$rejectedText$errorText | '
        '$delivered$lostText$duplicateText | ${achievedRate.toStringAsFixed(0)} | '
        '${_percentile(0.5)} | ${_percentile(0.9)} | '
        '${_percentile(0.99)} | ${_percentile(1.0)} | $mean |';
  }
}

///Drives [send] at approximately [rate] events per second, open loop.
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
      if (nextUs < elapsed - 4 * intervalUs) {
        nextUs = elapsed + intervalUs;
      }
    } else {
      yields++;
      if (yields % 32 == 0) {
        await Future<void>.delayed(Duration.zero);
      } else {
        await null;
      }
    }
  }
  return sent;
}

///Waits until [count] reaches [expected], or until it stops growing for
///~500 ms (the broker has nothing more to deliver), or the timeout expires.
Future<void> _waitUntilCount(
  int Function() count,
  int expected, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  var lastCount = -1;
  var stableTicks = 0;
  while (DateTime.now().isBefore(deadline)) {
    final current = count();
    if (current >= expected) return;
    if (current == lastCount) {
      stableTicks++;
      if (stableTicks >= 50) return;
    } else {
      stableTicks = 0;
      lastCount = current;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForSubscriptions() async {
  // SUB is sent by the client when the node is created; give the server a
  // moment to install it before publishing.
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

Future<_Result> _fireRun(
  EventBusNats publisher,
  List<int> samples,
  Set<int> seen,
  _Options options,
  int rate,
  Stopwatch clock,
) async {
  var rejected = 0;
  final start = clock.elapsedMicroseconds;
  final sent = await _drive(
    rate: rate,
    duration: options.duration,
    clock: clock,
    send: (seq, at) {
      if (!publisher.fire<LoadEvent>(LoadEvent(seq, at))) rejected++;
    },
  );
  final generationUs = clock.elapsedMicroseconds - start;

  await _waitUntilCount(() => seen.length, sent);

  return _Result(
    scenario: 'nats fire',
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

Future<_Result> _requestRun(
  EventBusNats requester,
  List<int> samples,
  Set<int> seen,
  _Options options,
  int rate,
  Stopwatch clock,
) async {
  final pending = <Future<void>>[];
  var errors = 0;

  Future<void> one(int seq, int sentAt) {
    return requester
        .request<RequestEvent>(
      RequestEvent(seq),
      timeout: const Duration(seconds: 10),
    )
        .then(
      (value) {
        seen.add(value as int);
        samples.add(max(0, clock.elapsedMicroseconds - sentAt));
      },
      onError: (Object _) => errors++,
    );
  }

  final start = clock.elapsedMicroseconds;
  final sent = await _drive(
    rate: rate,
    duration: options.duration,
    clock: clock,
    send: (seq, at) => pending.add(one(seq, at)),
  );
  final generationUs = clock.elapsedMicroseconds - start;
  await Future.wait(pending).timeout(const Duration(seconds: 90));

  return _Result(
    scenario: 'nats request',
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
  if (!const {'both', 'fire', 'request'}.contains(options.scenario)) {
    print('Unknown scenario "${options.scenario}": use both, fire or request');
    exitCode = 64;
    return;
  }
  final clock = Stopwatch()..start();

  print('EventBus NATS load benchmark');
  print('Dart ${Platform.version.split(' ').first}, '
      '${Platform.operatingSystem}, CPUs: ${Platform.numberOfProcessors}');
  print('broker: ${options.url}');
  print('scenario: ${options.scenario}, '
      'duration: ${options.duration.inMilliseconds} ms, '
      'warm-up: ${options.warmup.inMilliseconds} ms, '
      'rates: ${options.rates.join(', ')} events/s');
  print('');
  print('| scenario | target/s | sent | delivered | achieved/s | '
      'p50 ms | p90 ms | p99 ms | max ms | mean ms |');
  print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|');

  final fireErrors = <Object>[];
  final requestErrors = <Object>[];

  final publisher = EventBusNats(
    options.url,
    serializers: {'LoadEvent': _encodeLoad},
  );
  final subscriber = EventBusNats(
    options.url,
    deserializers: {'LoadEvent': _decodeLoad},
  );
  final responder = EventBusNats(
    options.url,
    serializers: {'RequestEvent': _encodeRequest},
    deserializers: {'RequestEvent': _decodeRequest},
  );
  final requester = EventBusNats(
    options.url,
    serializers: {'RequestEvent': _encodeRequest},
    deserializers: {'RequestEvent': _decodeRequest},
  );

  try {
    await Future.wait([
      publisher.waitConnected(timeout: const Duration(seconds: 5)),
      subscriber.waitConnected(timeout: const Duration(seconds: 5)),
      responder.waitConnected(timeout: const Duration(seconds: 5)),
      requester.waitConnected(timeout: const Duration(seconds: 5)),
    ]);
  } catch (error) {
    print('Cannot connect to the broker: $error');
    print('Start a NATS server (nats-server -p 4222) or pass --url=...');
    await Future.wait([
      publisher.dispose(),
      subscriber.dispose(),
      responder.dispose(),
      requester.dispose(),
    ]);
    exitCode = 2;
    return;
  }

  final publisherErrors = publisher.errors.listen(fireErrors.add);
  final subscriberErrors = subscriber.errors.listen(fireErrors.add);
  final responderErrors = responder.errors.listen(requestErrors.add);
  final requesterErrors = requester.errors.listen(requestErrors.add);

  final fireSamples = <int>[];
  final fireSeen = <int>{};
  final fireSubscription = subscriber.listen<LoadEvent>().listen((event) {
    fireSeen.add(event.seq);
    fireSamples.add(max(0, clock.elapsedMicroseconds - event.sentAtUs));
  });
  responder.setHandler<RequestEvent>(
    handler: (dto, lastData) async => dto.data.seq,
  );
  await _waitForSubscriptions();

  try {
    if (options.scenario == 'fire' || options.scenario == 'both') {
      // Fire scenario: warm-up, then every rate.
      final warmupSent = await _drive(
        rate: 1000,
        duration: options.warmup,
        clock: clock,
        send: (seq, at) => publisher.fire<LoadEvent>(LoadEvent(seq, at)),
      );
      await _waitUntilCount(() => fireSeen.length, warmupSent);
      fireSamples.clear();
      fireSeen.clear();

      for (final rate in options.rates) {
        final result = await _fireRun(
          publisher,
          fireSamples,
          fireSeen,
          options,
          rate,
          clock,
        );
        print(result.row());
        fireSamples.clear();
        fireSeen.clear();
      }
    }

    if (options.scenario == 'request' || options.scenario == 'both') {
      // Request scenario: warm-up, then every rate.
      final warmupSamples = <int>[];
      final warmupSeen = <int>{};
      await _requestRun(
        requester,
        warmupSamples,
        warmupSeen,
        _Options(
          rates: options.rates,
          duration: options.warmup,
          warmup: options.warmup,
          url: options.url,
          scenario: 'request',
        ),
        1000,
        clock,
      );
      final requestSamples = <int>[];
      final requestSeen = <int>{};
      for (final rate in options.rates) {
        final result = await _requestRun(
          requester,
          requestSamples,
          requestSeen,
          options,
          rate,
          clock,
        );
        print(result.row());
        requestSamples.clear();
        requestSeen.clear();
      }
    }
  } finally {
    await fireSubscription.cancel();
    await publisherErrors.cancel();
    await subscriberErrors.cancel();
    await responderErrors.cancel();
    await requesterErrors.cancel();
    await Future.wait([
      publisher.dispose(),
      subscriber.dispose(),
      responder.dispose(),
      requester.dispose(),
    ]);
  }

  print('');
  if (fireErrors.isNotEmpty || requestErrors.isNotEmpty) {
    print('async errors: fire=${fireErrors.length}, '
        'request=${requestErrors.length}');
    for (final error in [...fireErrors, ...requestErrors].take(5)) {
      print('  $error');
    }
  } else {
    print('async errors: none');
  }
  print('Latency is measured in this isolate: publish/request call to the '
      'listener/handler completion.');
  print('NATS core is at-most-once; lost/dup markers mean the broker or a '
      'socket did not deliver a sequence number.');
}
