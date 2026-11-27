import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- functions that run IN A WORKER ISOLATE (top-level only) ---

///Reports `bus.isModelBus` from inside the worker.
void modelFlagWorker(EventBus bus, Object? initialData) {
  bus.subscribe(EventKey<bool>('bool.model_flag'),
      handler: (dto, lastData) async => bus.isModelBus);
}

///Cancels its only listener, then answers with the data retained for the topic.
///A model bus keeps the node and its `currentData`; a common bus removes it.
void canceledListenerWorker(EventBus bus, Object? initialData) async {
  final sub = bus.listen(EventKey<int>('int.state')).listen(null);
  await sub.cancel();
  bus.subscribe(EventKey<int>('int.read_state'),
      handler: (dto, lastData) async =>
          bus.currentData(EventKey<int>('int.state')) ?? -1);
}

///Fires an event back to main; the main-side bus decides whether to keep it.
void emitToMainWorker(EventBus bus, Object? initialData) {
  bus.subscribe(EventKey<int>('int.emit'), handler: (dto, lastData) async {
    bus.fire(EventKey<int>('int.state'), dto.data);
    return dto.data;
  });
}

// --- functions that run INSIDE a layer isolate ---

///Reports the flags of the three buses the layer can see.
void inspectBusesLayer(Layer layer, Object? initialData) {
  layer.top!.subscribe(EventKey<bool>('bool.top_is_model'),
      handler: (dto, lastData) async => layer.top!.isModelBus);
  layer.top!.subscribe(EventKey<bool>('bool.bottom_is_model'),
      handler: (dto, lastData) async => layer.bottom?.isModelBus ?? false);
  layer.top!.subscribe(EventKey<bool>('bool.current_is_model'),
      handler: (dto, lastData) async => layer.current.isModelBus);
}

void silentLayer(Layer layer, Object? initialData) {}

void main() {
  group('EventBusIsolate: isModelBus', () {
    test('defaults to a common bus on both sides', () async {
      final iso = EventBusIsolate(onInit: modelFlagWorker);
      expect(iso.isModelBus, isFalse);

      await iso.waitInit;
      expect(
          await iso.request(EventKey<bool>('bool.model_flag'), true), isFalse);

      await iso.dispose();
    });

    test('isModelBus reaches both the main-side bus and the worker bus',
        () async {
      final iso = EventBusIsolate(onInit: modelFlagWorker, isModelBus: true);
      expect(iso.isModelBus, isTrue);

      await iso.waitInit;
      expect(
          await iso.request(EventKey<bool>('bool.model_flag'), true), isTrue);

      await iso.dispose();
    });

    test('a model worker bus keeps currentData after its last listener cancels',
        () async {
      final iso =
          EventBusIsolate(onInit: canceledListenerWorker, isModelBus: true);
      await iso.waitInit;

      iso.fire(EventKey<int>('int.state'), 42);

      expect(await iso.request(EventKey<int>('int.read_state'), 0), 42);
      await iso.dispose();
    });

    test('a common worker bus drops the node when its last listener cancels',
        () async {
      final iso = EventBusIsolate(onInit: canceledListenerWorker);
      await iso.waitInit;

      iso.fire(EventKey<int>('int.state'), 42);

      expect(await iso.request(EventKey<int>('int.read_state'), 0), -1);
      await iso.dispose();
    });

    test(
        'a model main-side bus keeps currentData after its last listener cancels',
        () async {
      final iso = EventBusIsolate(onInit: emitToMainWorker, isModelBus: true);
      await iso.waitInit;
      final sub = iso.listen(EventKey<int>('int.state')).listen((_) {});

      await iso.request(EventKey<int>('int.emit'), 1);
      await sub.cancel();
      await iso.request(EventKey<int>('int.emit'), 2);

      expect(iso.currentData(EventKey<int>('int.state')), 2);
      await iso.dispose();
    });

    test('a common main-side bus drops the node when its last listener cancels',
        () async {
      final iso = EventBusIsolate(onInit: emitToMainWorker);
      await iso.waitInit;
      final sub = iso.listen(EventKey<int>('int.state')).listen((_) {});

      await iso.request(EventKey<int>('int.emit'), 1);
      await sub.cancel();
      await iso.request(EventKey<int>('int.emit'), 2);

      expect(iso.currentData(EventKey<int>('int.state')), isNull);
      await iso.dispose();
    });
  });

  group('Layers: bridgeIsModelBus', () {
    test('isolate bridges are common buses by default', () async {
      final layer = await Layers.createLayers([
        LayerSpec(init: inspectBusesLayer, isModelBus: false),
        LayerSpec(init: silentLayer, isModelBus: false),
      ]);

      expect((layer.bottom as EventBusIsolate).isModelBus, isFalse);
      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.top_is_model'), true),
          isFalse);
      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.bottom_is_model'), true),
          isFalse);
      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.current_is_model'), true),
          isFalse);

      await layer.close();
    });

    test('bridgeIsModelBus applies to every isolate bridge', () async {
      final layer = await Layers.createLayers([
        LayerSpec(init: inspectBusesLayer, isModelBus: false),
        LayerSpec(init: silentLayer, isModelBus: false),
      ], bridgeIsModelBus: true);

      // the bridge to the first worker and the bridge from it to the second
      expect((layer.bottom as EventBusIsolate).isModelBus, isTrue);
      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.top_is_model'), true),
          isTrue);
      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.bottom_is_model'), true),
          isTrue);

      await layer.close();
    });

    test('layer.current follows its own flag, not bridgeIsModelBus', () async {
      final layer = await Layers.createLayers([
        LayerSpec(init: inspectBusesLayer, isModelBus: true),
        LayerSpec(init: silentLayer, isModelBus: false),
      ]);

      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.current_is_model'), true),
          isTrue);
      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.top_is_model'), true),
          isFalse);
      expect(
          await layer.bottom!
              .request(EventKey<bool>('bool.bottom_is_model'), true),
          isFalse);

      await layer.close();
    });
  });
}
