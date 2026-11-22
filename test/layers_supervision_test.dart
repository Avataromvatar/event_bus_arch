import 'dart:async';
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- layer init functions (top-level only: they run inside isolates) ---

///The middle worker: forwards a kill signal down, echoes on the top bridge,
///answers `who` and delegates `who-bottom` to the layer below.
void initForwardingLayer(Layer layer, Object? initialData) {
  final port = initialData as SendPort;
  port.send('init-top');
  layer.top!.subscribeLegacy<String>(
      paths: ['die'],
      onData: (e) => layer.bottom!.fireLegacy<String>(e, paths: ['die']));
  layer.top!.subscribeLegacy<String>(
      paths: ['die-top'],
      onData: (_) => Isolate.current.kill(priority: Isolate.immediate));
  layer.top!.subscribeLegacy<String>(
      paths: ['echo'],
      onData: (e) => layer.top!.fireLegacy<String>('echo: $e', paths: ['echo']));
  layer.top!.subscribeEventsLegacy<int>(
      paths: ['who'], handler: (dto, lastData) async => 1);
  layer.top!.subscribeEventsLegacy<int>(
      paths: ['who-bottom'],
      handler: (dto, lastData) async =>
          await layer.bottom!.requestLegacy<int>(dto.data, paths: ['who']));
  layer.top!.subscribeEventsLegacy<int>(
      paths: ['slow'], handler: (dto, lastData) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return 1;
  });
}

///The bottom worker: kills itself on `die` and answers `who`.
void initKillableLayer(Layer layer, Object? initialData) {
  final port = initialData as SendPort;
  port.send('init-bottom');
  layer.top!.subscribeLegacy<String>(
      paths: ['die'],
      onData: (_) => Isolate.current.kill(priority: Isolate.immediate));
  layer.top!.subscribeEventsLegacy<int>(
      paths: ['who'], handler: (dto, lastData) async => 2);
}

Future<void> failingLayer(Layer layer, Object? initialData) async {
  throw StateError('layer init failed');
}

const _policy = SupervisionPolicy(
  maxRestarts: 3,
  window: Duration(minutes: 1),
  initialBackoff: Duration(milliseconds: 50),
);

void main() {
  test('a deep worker failure restarts the whole chain and keeps the top',
      () async {
    final port = ReceivePort();
    final inits = <String>[];
    port.listen((message) => inits.add(message as String));

    final supervisor = Layers.supervise([
      (initForwardingLayer, port.sendPort, false),
      (initKillableLayer, port.sendPort, false),
    ], policy: _policy);

    await supervisor.waitInit;
    expect(supervisor.state, LayersState.ready);
    expect(inits.toSet(), {'init-top', 'init-bottom'});

    final layer = supervisor.layer;
    final bridge = layer.bottom!;
    final echoed = <String>[];
    final sub =
        layer.bottom!.subscribeLegacy<String>(paths: ['echo'], onData: echoed.add);

    expect(layer.bottom!.fireLegacy<String>('one', paths: ['echo']), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(echoed, ['echo: one']);
    expect(await layer.bottom!.requestLegacy<int>(1, paths: ['who-bottom']), 2);

    final initsBefore = inits.length;
    final death = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
        .timeout(const Duration(seconds: 2));
    expect(layer.bottom!.fireLegacy<String>('x', paths: ['die']), isTrue);
    await death;
    await supervisor.waitReady().timeout(const Duration(seconds: 5));

    expect(supervisor.state, LayersState.ready);
    expect(supervisor.restarts, 1);
    // both workers ran onInit again
    expect(inits.length, initsBefore + 2);
    // the same bridge object and the same subscription survived
    expect(identical(supervisor.layer.bottom, bridge), isTrue);
    expect(layer.bottom!.fireLegacy<String>('two', paths: ['echo']), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(echoed, ['echo: one', 'echo: two']);
    expect(await layer.bottom!.requestLegacy<int>(1, paths: ['who']), 1);
    expect(await layer.bottom!.requestLegacy<int>(1, paths: ['who-bottom']), 2);

    await sub.cancel();
    await supervisor.close();
    port.close();
  });

  test('a direct top worker failure restarts the chain', () async {
    final port = ReceivePort();
    port.listen((_) {});
    final supervisor = Layers.supervise([
      (initForwardingLayer, port.sendPort, false),
      (initKillableLayer, port.sendPort, false),
    ], policy: _policy);
    await supervisor.waitInit;

    final death = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
        .timeout(const Duration(seconds: 2));
    expect(
        supervisor.layer.bottom!.fireLegacy<String>('x', paths: ['die-top']),
        isTrue);
    await death;
    await supervisor.waitReady().timeout(const Duration(seconds: 5));

    expect(supervisor.state, LayersState.ready);
    expect(supervisor.restarts, 1);
    expect(await supervisor.layer.bottom!.requestLegacy<int>(1, paths: ['who-bottom']),
        2);

    await supervisor.close();
    port.close();
  });

  test('a pending request fails when the chain restarts and is not retried',
      () async {
    final port = ReceivePort();
    port.listen((_) {});
    final supervisor = Layers.supervise([
      (initForwardingLayer, port.sendPort, false),
      (initKillableLayer, port.sendPort, false),
    ], policy: _policy);
    await supervisor.waitInit;

    final pending = supervisor.layer.bottom!.requestLegacy<int>(1, paths: ['slow']);
    final failed = expectLater(pending, throwsA(isA<EventBusException>()));
    final death = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
        .timeout(const Duration(seconds: 2));
    expect(supervisor.layer.bottom!.fireLegacy<String>('x', paths: ['die']), isTrue);
    await death;
    await failed;
    await supervisor.waitReady().timeout(const Duration(seconds: 5));

    expect(await supervisor.layer.bottom!.requestLegacy<int>(1, paths: ['who']), 1);
    await supervisor.close();
    port.close();
  });

  test('restart exhaustion fails the supervisor and releases the bridge',
      () async {
    final port = ReceivePort();
    port.listen((_) {});
    final supervisor = Layers.supervise([
      (initForwardingLayer, port.sendPort, false),
      (initKillableLayer, port.sendPort, false),
    ], policy: const SupervisionPolicy(
      maxRestarts: 0,
      window: Duration(minutes: 1),
    ));
    await supervisor.waitInit;
    final bridge = supervisor.layer.bottom!;

    final failure = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.supervision)
        .timeout(const Duration(seconds: 2));
    expect(bridge.fireLegacy<String>('x', paths: ['die']), isTrue);
    await failure;

    expect(supervisor.state, LayersState.failed);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(supervisor.layer.bottom, isNull);
    expect(() => bridge.fireLegacy<int>(1), throwsStateError);

    await supervisor.close();
    port.close();
  });

  test('an initial chain init failure fails the supervisor', () async {
    final supervisor = Layers.supervise([(failingLayer, null, false)]);

    await expectLater(
        supervisor.waitInit, throwsA(isA<EventBusException>()));
    expect(supervisor.state, LayersState.failed);

    await supervisor.close();
  });
}
