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
  layer.top!
      .listen(EventKey<String>('String.die'))
      .listen((e) => layer.bottom!.fire(EventKey<String>('String.die'), e));
  layer.top!
      .listen(EventKey<String>('String.die-top'))
      .listen((_) => Isolate.current.kill(priority: Isolate.immediate));
  layer.top!.listen(EventKey<String>('String.echo')).listen(
      (e) => layer.top!.fire(EventKey<String>('String.echo'), 'echo: $e'));
  layer.top!
      .subscribe(EventKey<int>('int.who'), handler: (dto, lastData) async => 1);
  layer.top!.subscribe(EventKey<int>('int.who-bottom'),
      handler: (dto, lastData) async =>
          await layer.bottom!.request(EventKey<int>('int.who'), dto.data));
  layer.top!.subscribe(EventKey<int>('int.slow'),
      handler: (dto, lastData) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return 1;
  });
}

///The bottom worker: kills itself on `die` and answers `who`.
void initKillableLayer(Layer layer, Object? initialData) {
  final port = initialData as SendPort;
  port.send('init-bottom');
  layer.top!
      .listen(EventKey<String>('String.die'))
      .listen((_) => Isolate.current.kill(priority: Isolate.immediate));
  layer.top!
      .subscribe(EventKey<int>('int.who'), handler: (dto, lastData) async => 2);
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
      LayerSpec(
          init: initForwardingLayer,
          initialData: port.sendPort,
          isModelBus: false),
      LayerSpec(
          init: initKillableLayer,
          initialData: port.sendPort,
          isModelBus: false),
    ], policy: _policy);

    await supervisor.waitInit;
    expect(supervisor.state, LayersState.ready);
    expect(inits.toSet(), {'init-top', 'init-bottom'});

    final layer = supervisor.layer;
    final bridge = layer.bottom!;
    final echoed = <String>[];
    final sub = layer.bottom!
        .listen(EventKey<String>('String.echo'))
        .listen(echoed.add);

    expect(layer.bottom!.fire(EventKey<String>('String.echo'), 'one'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(echoed, ['echo: one']);
    expect(await layer.bottom!.request(EventKey<int>('int.who-bottom'), 1), 2);

    final initsBefore = inits.length;
    final death = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
        .timeout(const Duration(seconds: 2));
    expect(layer.bottom!.fire(EventKey<String>('String.die'), 'x'), isTrue);
    await death;
    await supervisor.waitReady().timeout(const Duration(seconds: 5));

    expect(supervisor.state, LayersState.ready);
    expect(supervisor.restarts, 1);
    // both workers ran onInit again
    expect(inits.length, initsBefore + 2);
    // the same bridge object and the same subscription survived
    expect(identical(supervisor.layer.bottom, bridge), isTrue);
    expect(layer.bottom!.fire(EventKey<String>('String.echo'), 'two'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(echoed, ['echo: one', 'echo: two']);
    expect(await layer.bottom!.request(EventKey<int>('int.who'), 1), 1);
    expect(await layer.bottom!.request(EventKey<int>('int.who-bottom'), 1), 2);

    await sub.cancel();
    await supervisor.close();
    port.close();
  });

  test('a direct top worker failure restarts the chain', () async {
    final port = ReceivePort();
    port.listen((_) {});
    final supervisor = Layers.supervise([
      LayerSpec(
          init: initForwardingLayer,
          initialData: port.sendPort,
          isModelBus: false),
      LayerSpec(
          init: initKillableLayer,
          initialData: port.sendPort,
          isModelBus: false),
    ], policy: _policy);
    await supervisor.waitInit;

    final death = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
        .timeout(const Duration(seconds: 2));
    expect(
        supervisor.layer.bottom!.fire(EventKey<String>('String.die-top'), 'x'),
        isTrue);
    await death;
    await supervisor.waitReady().timeout(const Duration(seconds: 5));

    expect(supervisor.state, LayersState.ready);
    expect(supervisor.restarts, 1);
    expect(
        await supervisor.layer.bottom!
            .request(EventKey<int>('int.who-bottom'), 1),
        2);

    await supervisor.close();
    port.close();
  });

  test('a pending request fails when the chain restarts and is not retried',
      () async {
    final port = ReceivePort();
    port.listen((_) {});
    final supervisor = Layers.supervise([
      LayerSpec(
          init: initForwardingLayer,
          initialData: port.sendPort,
          isModelBus: false),
      LayerSpec(
          init: initKillableLayer,
          initialData: port.sendPort,
          isModelBus: false),
    ], policy: _policy);
    await supervisor.waitInit;

    final pending =
        supervisor.layer.bottom!.request(EventKey<int>('int.slow'), 1);
    final failed = expectLater(pending, throwsA(isA<EventBusException>()));
    final death = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.isolateDeath)
        .timeout(const Duration(seconds: 2));
    expect(supervisor.layer.bottom!.fire(EventKey<String>('String.die'), 'x'),
        isTrue);
    await death;
    await failed;
    await supervisor.waitReady().timeout(const Duration(seconds: 5));

    expect(
        await supervisor.layer.bottom!.request(EventKey<int>('int.who'), 1), 1);
    await supervisor.close();
    port.close();
  });

  test('restart exhaustion fails the supervisor and releases the bridge',
      () async {
    final port = ReceivePort();
    port.listen((_) {});
    final supervisor = Layers.supervise([
      LayerSpec(
          init: initForwardingLayer,
          initialData: port.sendPort,
          isModelBus: false),
      LayerSpec(
          init: initKillableLayer,
          initialData: port.sendPort,
          isModelBus: false),
    ],
        policy: const SupervisionPolicy(
          maxRestarts: 0,
          window: Duration(minutes: 1),
        ));
    await supervisor.waitInit;
    final bridge = supervisor.layer.bottom!;

    final failure = supervisor.errors
        .firstWhere((error) => error.kind == EventBusErrorKind.supervision)
        .timeout(const Duration(seconds: 2));
    expect(bridge.fire(EventKey<String>('String.die'), 'x'), isTrue);
    await failure;

    expect(supervisor.state, LayersState.failed);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(supervisor.layer.bottom, isNull);
    expect(() => bridge.fire(EventKey<int>('int'), 1), throwsStateError);

    await supervisor.close();
    port.close();
  });

  test('an initial chain init failure fails the supervisor', () async {
    final supervisor =
        Layers.supervise([LayerSpec(init: failingLayer, isModelBus: false)]);

    await expectLater(supervisor.waitInit, throwsA(isA<EventBusException>()));
    expect(supervisor.state, LayersState.failed);

    await supervisor.close();
  });
}
