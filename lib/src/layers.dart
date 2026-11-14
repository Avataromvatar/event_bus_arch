part of event_arch;

///Layer init function. It runs INSIDE the layer isolate, so it must be
///top-level/static. It may be async: the layer is considered initialized only
///after it returns.
typedef fnInitLayer = FutureOr<void> Function(Layer, Object? initialData);

class _LayerInitDto {
  ///(fnInitLayer, Object?, bool - current bus isModel)
  final List<(fnInitLayer, Object?, bool)> data;
  int index;

  ///`isModelBus` for every isolate bridge between the layers
  final bool bridgeIsModelBus;
  _LayerInitDto(
      {required this.data, this.index = 0, this.bridgeIsModelBus = false});
}

class Layer {
  ///For send/recive event from top layer
  EventBus? top;

  ///eventbus for local layer use
  EventBus current;

  ///For send/recive event from bottom layer
  EventBus? bottom;

  Layer({this.top, required this.current, this.bottom});

  ///Releases the layer resources: closes both isolate links and the local bus.
  ///Works in any layer and is safe to call twice.
  Future<void> close() async {
    var buses = [top, bottom, current];
    top = null;
    bottom = null;
    Object? firstError;
    StackTrace? firstStack;
    for (var bus in buses) {
      if (bus == null) {
        continue;
      }
      try {
        await bus.dispose();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack ?? StackTrace.current);
    }
  }
}

class Layers {
  ///Builds a chain of layers, each running in its own isolate.
  ///
  ///The top layer has [Layer.current] and the [EventBusIsolate] to the first
  ///worker in [Layer.bottom]. Every middle layer gets the [Layer.top] bus
  ///leading to the layer above and the [Layer.bottom] bus leading to the layer
  ///below, if it exists.
  ///
  ///Each entry of [layers] is `(init function, initial data, isModelBus)`,
  ///where the flag applies to that layer's [Layer.current] bus.
  ///
  ///[currentIsModelBus] applies to the [Layer.current] bus of the main isolate.
  ///[bridgeIsModelBus] applies to every [EventBusIsolate] that connects two
  ///layers, so both the main-side and the worker-side bus of each bridge are
  ///model buses.
  ///
  ///The future completes when EVERY layer of the chain is initialized, including
  ///async init functions. An init failure of any layer surfaces here as well.
  ///[timeout] limits the wait (unlimited by default).
  static Future<Layer> createLayers(List<(fnInitLayer, Object?, bool)> layers,
      {bool currentIsModelBus = true,
      bool bridgeIsModelBus = false,
      Duration? timeout}) async {
    if (layers.isEmpty) {
      throw EventBusException(
          'Layers.createLayers: layers list must not be empty');
    }

    _LayerInitDto storage = _LayerInitDto(
        data: layers, index: 0, bridgeIsModelBus: bridgeIsModelBus);

    Layer l = Layer(
        current: EventBus(isModelBus: currentIsModelBus),
        bottom: EventBusIsolate(
            onInit: _initLayer,
            initialData: storage,
            isModelBus: bridgeIsModelBus));
    var waitInit = (l.bottom as EventBusIsolate).waitInit;
    if (timeout != null) {
      await waitInit.timeout(timeout, onTimeout: () {
        throw EventBusException(
            'Layers.createLayers: initialization timeout ($timeout)');
      });
    } else {
      await waitInit;
    }
    return l;
  }
}

Future<void> _initLayer(EventBus bus, Object? initData) async {
  if (initData is! _LayerInitDto) {
    return;
  }
  _LayerInitDto dto = initData;
  int index = dto.index;
  if (index >= dto.data.length) {
    return;
  }
  dto.index++;
  Layer l = Layer(
      current: EventBus(isModelBus: dto.data[index].$3),
      top: bus,
      bottom: dto.index < dto.data.length
          ? EventBusIsolate(
              onInit: _initLayer,
              initialData: dto,
              isModelBus: dto.bridgeIsModelBus)
          : null);
  if (l.bottom != null) {
    // wait not only for the next isolate to start, but for it to be initialized
    await (l.bottom as EventBusIsolate).waitInit;
  }
  await dto.data[index].$1.call(l, dto.data[index].$2);
}
