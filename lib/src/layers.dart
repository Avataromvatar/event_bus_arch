part of event_arch;

///Layer init function. It runs INSIDE the layer isolate, so it must be
///top-level/static. It may be async: the layer is considered initialized only
///after it returns.
typedef fnInitLayer = FutureOr<void> Function(Layer, Object? initalData);

class _LayerInitDto {
  final List<(fnInitLayer, Object?, bool)> data;
  int index;
  _LayerInitDto({required this.data, this.index = 0});
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
  ///Layers create layer what split by isolate. Top layer have current and bottom eventbus, bottom eventbus this is EventBusIsolate,
  /// middle layer have top eventbus for connect to top layer and bottom eventbus for cnnect bottom layer if they present
  ///
  ///[(fnInitLayer,Object?,bool)] - inital function, inital data, flag what create model current bus in isolate
  ///
  ///The future completes when EVERY layer of the chain is initialized, including
  ///async init functions. An init failure of any layer surfaces here as well.
  ///[timeout] limits the wait (unlimited by default).
  static Future<Layer> createLayers(List<(fnInitLayer, Object?, bool)> layers,
      {bool currentIsModelBus = true, Duration? timeout}) async {
    if (layers.isEmpty) {
      throw EventBusException('Layers.createLayers: layers list must not be empty');
    }

    _LayerInitDto storage = _LayerInitDto(data: layers, index: 0);

    Layer l = Layer(
        current: EventBus(isModelBus: currentIsModelBus),
        bottom: EventBusIsolate(onInit: _initLayer, initalData: storage));
    var waitInit = (l.bottom as EventBusIsolate).waitInit;
    if (timeout != null) {
      await waitInit.timeout(timeout, onTimeout: () {
        throw EventBusException('Layers.createLayers: initialization timeout ($timeout)');
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
      bottom: dto.index < dto.data.length ? EventBusIsolate(onInit: _initLayer, initalData: dto) : null);
  if (l.bottom != null) {
    // wait not only for the next isolate to start, but for it to be initialized
    await (l.bottom as EventBusIsolate).waitInit;
  }
  await dto.data[index].$1.call(l, dto.data[index].$2);
}
