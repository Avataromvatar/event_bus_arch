import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

// --- functions that run IN A WORKER ISOLATE (top-level only) ---

///Reports `bus.isModelBus` from inside the worker.
void modelFlagWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<bool>(
      paths: ['model_flag'], handler: (dto, lastData) async => bus.isModelBus);
}

///Cancels its only listener, then answers with the data retained for the topic.
///A model bus keeps the node and its `currentData`; a common bus removes it.
void canceledListenerWorker(EventBus bus, Object? initialData) async {
  final sub = bus.subscribe<int>(paths: ['state']);
  await sub.cancel();
  bus.handlers.setHandler<int>(
      paths: ['read_state'],
      handler: (dto, lastData) async =>
          bus.currentData<int>(paths: ['state']) ?? -1);
}

///Fires an event back to main; the main-side bus decides whether to keep it.
void emitToMainWorker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<int>(
      paths: ['emit'],
      handler: (dto, lastData) async {
        bus.fire<int>(dto.data, paths: ['state']);
        return dto.data;
      });
}

// --- functions that run INSIDE a layer isolate ---

///Reports the flags of the three buses the layer can see.
void inspectBusesLayer(Layer layer, Object? initialData) {
  layer.top!.handlers.setHandler<bool>(
      paths: ['top_is_model'],
      handler: (dto, lastData) async => layer.top!.isModelBus);
  layer.top!.handlers.setHandler<bool>(
      paths: ['bottom_is_model'],
      handler: (dto, lastData) async => layer.bottom?.isModelBus ?? false);
  layer.top!.handlers.setHandler<bool>(
      paths: ['current_is_model'],
      handler: (dto, lastData) async => layer.current.isModelBus);
}

void silentLayer(Layer layer, Object? initialData) {}

void main() {
  group('EventBusIsolate: isModelBus', () {
    test('defaults to a common bus on both sides', () async {
      final iso = EventBusIsolate(onInit: modelFlagWorker);
      expect(iso.isModelBus, isFalse);

      await iso.waitInit;
      expect(await iso.request<bool>(true, paths: ['model_flag']), isFalse);

      await iso.dispose();
    });

    test('isModelBus reaches both the main-side bus and the worker bus',
        () async {
      final iso = EventBusIsolate(onInit: modelFlagWorker, isModelBus: true);
      expect(iso.isModelBus, isTrue);

      await iso.waitInit;
      expect(await iso.request<bool>(true, paths: ['model_flag']), isTrue);

      await iso.dispose();
    });

    test('a model worker bus keeps currentData after its last listener cancels',
        () async {
      final iso =
          EventBusIsolate(onInit: canceledListenerWorker, isModelBus: true);
      await iso.waitInit;

      iso.fire<int>(42, paths: ['state']);

      expect(await iso.request<int>(0, paths: ['read_state']), 42);
      await iso.dispose();
    });

    test('a common worker bus drops the node when its last listener cancels',
        () async {
      final iso = EventBusIsolate(onInit: canceledListenerWorker);
      await iso.waitInit;

      iso.fire<int>(42, paths: ['state']);

      expect(await iso.request<int>(0, paths: ['read_state']), -1);
      await iso.dispose();
    });

    test(
        'a model main-side bus keeps currentData after its last listener cancels',
        () async {
      final iso = EventBusIsolate(onInit: emitToMainWorker, isModelBus: true);
      await iso.waitInit;
      final sub = iso.subscribe<int>(paths: ['state'], onData: (_) {});

      await iso.request<int>(1, paths: ['emit']);
      await sub.cancel();
      await iso.request<int>(2, paths: ['emit']);

      expect(iso.currentData<int>(paths: ['state']), 2);
      await iso.dispose();
    });

    test('a common main-side bus drops the node when its last listener cancels',
        () async {
      final iso = EventBusIsolate(onInit: emitToMainWorker);
      await iso.waitInit;
      final sub = iso.subscribe<int>(paths: ['state'], onData: (_) {});

      await iso.request<int>(1, paths: ['emit']);
      await sub.cancel();
      await iso.request<int>(2, paths: ['emit']);

      expect(iso.currentData<int>(paths: ['state']), isNull);
      await iso.dispose();
    });
  });

  group('Layers: bridgeIsModelBus', () {
    test('isolate bridges are common buses by default', () async {
      final layer = await Layers.createLayers([
        (inspectBusesLayer, null, false),
        (silentLayer, null, false),
      ]);

      expect((layer.bottom as EventBusIsolate).isModelBus, isFalse);
      expect(await layer.bottom!.request<bool>(true, paths: ['top_is_model']),
          isFalse);
      expect(
          await layer.bottom!.request<bool>(true, paths: ['bottom_is_model']),
          isFalse);
      expect(
          await layer.bottom!.request<bool>(true, paths: ['current_is_model']),
          isFalse);

      await layer.close();
    });

    test('bridgeIsModelBus applies to every isolate bridge', () async {
      final layer = await Layers.createLayers([
        (inspectBusesLayer, null, false),
        (silentLayer, null, false),
      ], bridgeIsModelBus: true);

      // the bridge to the first worker and the bridge from it to the second
      expect((layer.bottom as EventBusIsolate).isModelBus, isTrue);
      expect(await layer.bottom!.request<bool>(true, paths: ['top_is_model']),
          isTrue);
      expect(
          await layer.bottom!.request<bool>(true, paths: ['bottom_is_model']),
          isTrue);

      await layer.close();
    });

    test('layer.current follows its own flag, not bridgeIsModelBus', () async {
      final layer = await Layers.createLayers([
        (inspectBusesLayer, null, true),
        (silentLayer, null, false),
      ]);

      expect(
          await layer.bottom!.request<bool>(true, paths: ['current_is_model']),
          isTrue);
      expect(await layer.bottom!.request<bool>(true, paths: ['top_is_model']),
          isFalse);
      expect(
          await layer.bottom!.request<bool>(true, paths: ['bottom_is_model']),
          isFalse);

      await layer.close();
    });
  });
}
