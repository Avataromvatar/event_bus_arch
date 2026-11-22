@TestOn('browser')
library;

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';
import 'legacy_compat.dart';

///A minimal web-target smoke test: the local bus must work in a browser.
///
///The isolate API is not available on the web; it throws `UnsupportedError`
///at construction, which the guard test below checks.
///The isolate APIs throw before these functions can be used; they only need
///the right signature.
void _silentWorker(EventBus bus, Object? initialData) {}

Future<void> _silentLayer(Layer layer, Object? initialData) async {}

void main() {
  test('the capability flag reports the web platform', () {
    expect(EventBusCapabilities.isWeb, isTrue);
    expect(EventBusCapabilities.isolateSupported, isFalse);
  });

  test('isolate APIs throw UnsupportedError on the web', () async {
    expect(() => EventBusIsolate(onInit: _silentWorker),
        throwsA(isA<UnsupportedError>()));
    expect(() => WorkerPool(onInit: _silentWorker),
        throwsA(isA<UnsupportedError>()));
    expect(() => Layers.supervise([LayerSpec(init: _silentLayer, isModelBus: false)]),
        throwsA(isA<UnsupportedError>()));
    await expectLater(Layers.createLayers([LayerSpec(init: _silentLayer, isModelBus: false)]),
        throwsA(isA<UnsupportedError>()));
  });

  test('observability works on the web target', () async {
    final bus = EventBus(
        observability: const ObservabilityConfig(enabled: true));
    final received = <int>[];
    final sub = bus.subscribeEventsLegacy<int>(
        paths: ['web', 'obs'], onEvent: received.add);

    expect(
        bus.fireLegacy<int>(1, paths: ['web', 'obs'], correlationId: 'web-correlation'),
        isTrue);
    await Future<void>.delayed(Duration.zero);

    final snapshot = bus.metrics.snapshot();
    expect(snapshot.fired, 1);
    expect(snapshot.delivered, 1);
    expect(received, [1]);

    await sub.cancel();
    await bus.dispose();
  });

  test('a common bus delivers fire to a listener on the web target', () async {
    final bus = EventBus();
    final received = <int>[];
    final sub = bus.subscribeLegacy<int>(paths: ['web'], onData: received.add);

    expect(bus.fireLegacy<int>(1, paths: ['web']), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(received, [1]);

    await sub.cancel();
    await bus.dispose();
  });

  test('a model bus retains currentData on the web target', () async {
    final bus = EventBus(isModelBus: true);

    bus.fireLegacy<String>('value', paths: ['web', 'model']);
    expect(bus.currentDataLegacy<String>(paths: ['web', 'model']), 'value');

    expect(bus.removeTopicLegacy<String>(paths: ['web', 'model']), isTrue);
    expect(bus.currentDataLegacy<String>(paths: ['web', 'model']), isNull);

    await bus.dispose();
  });

  test('subscribe delivers and cancels on the web target', () async {
    final bus = EventBus();
    final received = <int>[];
    final sub = bus.subscribeEventsLegacy<int>(
        paths: ['web', 'subscription'], onEvent: received.add);

    bus.fireLegacy<int>(1, paths: ['web', 'subscription']);
    await Future<void>.delayed(Duration.zero);
    expect(received, [1]);

    await sub.cancel();
    await bus.dispose();
  });
}
