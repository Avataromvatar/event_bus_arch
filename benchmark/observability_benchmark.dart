// Observability overhead benchmark: the same hot paths with collection off
// and on.
//
// Run:
//   dart run benchmark/observability_benchmark.dart
//
// The numbers are a smoke measurement, not a pass/fail test. Each scenario is
// measured several times with both settings, alternating, and the minimum is
// reported: that removes most of the JIT warm-up bias.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:event_bus_arch/event_bus_arch.dart';

const _fires = 200000;
const _requests = 20000;
const _rounds = 5;

Future<void> main() async {
  print('Observability overhead benchmark');
  print('Dart ${Platform.version.split(' ').first}, '
      '${Platform.operatingSystem}, CPUs: ${Platform.numberOfProcessors}');
  print('');
  print('| scenario | operations | off, ns/op | on, ns/op | overhead |');
  print('|---|---:|---:|---:|---:|');

  final fireOff = <double>[];
  final fireOn = <double>[];
  for (var round = 0; round < _rounds; round++) {
    fireOff.add(await _fireBenchmark(enabled: false));
    fireOn.add(await _fireBenchmark(enabled: true));
  }
  final fireBestOff = fireOff.reduce(math.min);
  final fireBestOn = fireOn.reduce(math.min);
  print('| fire | $_fires | ${_ns(fireBestOff)} | ${_ns(fireBestOn)} | '
      '${_percent(_overhead(fireBestOff, fireBestOn))} |');

  final requestOff = <double>[];
  final requestOn = <double>[];
  for (var round = 0; round < _rounds; round++) {
    requestOff.add(await _requestBenchmark(enabled: false));
    requestOn.add(await _requestBenchmark(enabled: true));
  }
  final requestBestOff = requestOff.reduce(math.min);
  final requestBestOn = requestOn.reduce(math.min);
  print('| request | $_requests | ${_ns(requestBestOff)} | '
      '${_ns(requestBestOn)} | '
      '${_percent(_overhead(requestBestOff, requestBestOn))} |');
}

Future<double> _fireBenchmark({required bool enabled}) async {
  final bus = EventBus(
      observability: ObservabilityConfig(enabled: enabled, metrics: enabled));
  final sub = bus.subscribeEventsLegacy<int>(
      paths: ['x'], deliveryMode: DeliveryMode.sync, onEvent: (_) {});

  for (var i = 0; i < 10000; i++) {
    bus.fireLegacy<int>(i, paths: ['x']);
  }
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < _fires; i++) {
    bus.fireLegacy<int>(i, paths: ['x']);
  }
  stopwatch.stop();

  await sub.cancel();
  await bus.dispose();
  return stopwatch.elapsedMicroseconds * 1000 / _fires;
}

Future<double> _requestBenchmark({required bool enabled}) async {
  final bus = EventBus(
      observability: ObservabilityConfig(enabled: enabled, metrics: enabled));
  final sub =
      bus.subscribeEventsLegacy<int>(handler: (dto, lastData) async => dto.data);

  for (var i = 0; i < 500; i++) {
    await bus.requestLegacy<int>(i);
  }
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < _requests; i++) {
    await bus.requestLegacy<int>(i);
  }
  stopwatch.stop();

  await sub.cancel();
  await bus.dispose();
  return stopwatch.elapsedMicroseconds * 1000 / _requests;
}

double _overhead(double off, double on) => off == 0 ? 0 : (on - off) / off;

String _ns(double value) => value.toStringAsFixed(1);

String _percent(double value) => '${(value * 100).toStringAsFixed(1)}%';
