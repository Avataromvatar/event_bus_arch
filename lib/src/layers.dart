part of event_arch;

///Layer init function. It runs INSIDE the layer isolate, so it must be
///top-level/static. It may be async: the layer is considered initialized only
///after it returns.
typedef fnInitLayer = FutureOr<void> Function(Layer, Object? initialData);

class _LayerInitDto {
  ///(fnInitLayer, Object?, bool - current bus isModel)
  final List<(fnInitLayer, Object?, bool)> data;
  final int index;

  ///`isModelBus` for every isolate bridge between the layers
  final bool bridgeIsModelBus;

  const _LayerInitDto(
      {required this.data, this.index = 0, this.bridgeIsModelBus = false});

  ///The descriptor for the next layer. The object is never mutated, so a
  ///restart of the chain starts from the same index again.
  _LayerInitDto next() => _LayerInitDto(
      data: data, index: index + 1, bridgeIsModelBus: bridgeIsModelBus);
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
    _requireIsolates('Layers.createLayers');
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

  ///Builds a supervised chain: any worker layer failure restarts the whole
  ///worker chain, while the top layer (this isolate) and its subscriptions
  ///survive.
  ///
  ///The returned supervisor exposes the top [Layer] immediately; await
  ///[LayersSupervisor.waitInit] for the first chain. Pending requests fail on
  ///restart and are not retried; calls on the bridge throw `StateError` while
  ///the chain is restarting.
  static LayersSupervisor supervise(
    List<(fnInitLayer, Object?, bool)> layers, {
    bool currentIsModelBus = true,
    bool bridgeIsModelBus = false,
    Duration? timeout,
    SupervisionPolicy policy = const SupervisionPolicy(),
  }) {
    _requireIsolates('Layers.supervise');
    if (layers.isEmpty) {
      throw EventBusException(
          'Layers.supervise: layers list must not be empty');
    }
    final supervisor = LayersSupervisor._(layers, currentIsModelBus,
        bridgeIsModelBus, timeout, policy);
    supervisor._start();
    return supervisor;
  }
}

///Lifecycle of a [LayersSupervisor].
enum LayersState { starting, ready, restarting, failed, closed }

///Owns a supervised layer chain. Created by [Layers.supervise].
///
///A failure of any worker layer (direct or forwarded from a deeper layer)
///restarts every worker layer. The top [layer] object survives, and so do
///subscriptions on its `bottom` bridge and on `current`: the bridge is
///restarted in place and re-handshakes its interest registry.
class LayersSupervisor {
  LayersSupervisor._(this._layers, this._currentIsModelBus,
      this._bridgeIsModelBus, this._timeout, this._policy);

  final List<(fnInitLayer, Object?, bool)> _layers;
  final bool _currentIsModelBus;
  final bool _bridgeIsModelBus;
  final Duration? _timeout;
  final SupervisionPolicy _policy;

  late final Layer _layer;
  final Completer<void> _initialReady = Completer<void>();
  final List<Completer<void>> _readyWaiters = <Completer<void>>[];
  final StreamController<EventBusError> _errors =
      StreamController<EventBusError>.broadcast();
  final List<DateTime> _restartTimes = <DateTime>[];

  StreamSubscription<EventBusError>? _bridgeErrors;
  Timer? _restartTimer;
  Future<void>? _closeFuture;
  bool _closing = false;
  bool _failed = false;
  bool _restarting = false;
  bool _failureDuringRestart = false;
  int _restarts = 0;
  LayersState _state = LayersState.starting;

  ///The top layer. Its `current` bus and the `bottom` bridge object survive a
  ///restart; the bridge reconnects to a new worker chain.
  Layer get layer => _layer;

  ///Completes when the first chain is ready.
  Future<void> get waitInit => _initialReady.future;

  ///The current lifecycle state.
  LayersState get state => _state;

  ///True when every worker layer is ready.
  bool get isReady => _state == LayersState.ready;

  ///Completed whole-chain restarts.
  int get restarts => _restarts;

  ///Worker failures and supervision errors of the chain.
  Stream<EventBusError> get errors => _errors.stream;

  ///Waits until the chain is ready. Fails when the supervisor becomes failed
  ///or closed first.
  Future<void> waitReady() {
    if (_state == LayersState.ready) return Future.value();
    if (_closing) return Future.error(StateError('LayersSupervisor is closed'));
    if (_failed) {
      return Future.error(EventBusException('LayersSupervisor is failed'));
    }
    final completer = Completer<void>();
    _readyWaiters.add(completer);
    return completer.future;
  }

  ///Closes the whole chain: timers and listeners are cancelled, the bridge and
  ///the top local bus are disposed. Never restarts. Safe to call twice.
  Future<void> close() => _closeFuture ??= _close();

  void _start() {
    final dto = _LayerInitDto(
        data: _layers, index: 0, bridgeIsModelBus: _bridgeIsModelBus);
    _layer = Layer(
      current: EventBus(isModelBus: _currentIsModelBus),
      bottom: EventBusIsolate(
          onInit: _initLayer,
          initialData: dto,
          isModelBus: _bridgeIsModelBus),
    );
    final bridge = _layer.bottom as EventBusIsolate;
    _bridgeErrors = bridge.errors.listen(_onBridgeError);
    _initialReady.future.ignore();
    unawaited(_waitInitial(bridge));
  }

  Future<void> _waitInitial(EventBusIsolate bridge) async {
    try {
      var wait = bridge.waitInit;
      if (_timeout != null) {
        wait = wait.timeout(_timeout, onTimeout: () {
          throw EventBusException(
              'Layers.supervise: initialization timeout ($_timeout)');
        });
      }
      await wait;
      if (_closing) return;
      _state = LayersState.ready;
      _flushWaiters();
      if (!_initialReady.isCompleted) _initialReady.complete();
    } catch (error, stackTrace) {
      if (_closing) {
        if (!_initialReady.isCompleted) {
          _initialReady.completeError(StateError('LayersSupervisor is closed'));
        }
        return;
      }
      _failed = true;
      _state = LayersState.failed;
      final failure =
          EventBusException('Layers.supervise did not start: $error');
      if (!_initialReady.isCompleted) {
        _initialReady.completeError(failure, stackTrace);
      }
      _reportSupervision(failure, stackTrace);
      _failWaiters(failure);
      unawaited(_disposeBridge());
    }
  }

  void _onBridgeError(EventBusError error) {
    if (!_closing && !_errors.isClosed) _errors.add(error);
    if (error.kind == EventBusErrorKind.isolateDeath) {
      _onChainFailure();
    }
  }

  void _onChainFailure() {
    if (_closing || _failed) return;
    if (_restarting) {
      // the new chain died while it was starting; the restart attempt owns it
      _failureDuringRestart = true;
      return;
    }
    _scheduleRestart();
  }

  void _scheduleRestart() {
    if (_closing || _failed) return;
    _restarting = true;
    _state = LayersState.restarting;
    final now = DateTime.now();
    _restartTimes
        .removeWhere((time) => now.difference(time) > _policy.window);
    if (_restartTimes.length >= _policy.maxRestarts) {
      _fail();
      return;
    }
    final attempt = _restartTimes.length;
    _restartTimes.add(now);
    final delay = _policy.delayFor(attempt);
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      unawaited(_restart());
    });
  }

  Future<void> _restart() async {
    if (_closing || _failed) return;
    final bridge = _layer.bottom;
    if (bridge is! EventBusIsolate) return;
    _restarting = true;
    _state = LayersState.restarting;
    try {
      var restarted = bridge.restart();
      if (_timeout != null) {
        restarted = restarted.timeout(_timeout, onTimeout: () {
          throw EventBusException(
              'Layers.supervise: restart timeout ($_timeout)');
        });
      }
      await restarted;
      if (_closing) return;
      _restarting = false;
      _restarts++;
      _state = LayersState.ready;
      _flushWaiters();
      if (_failureDuringRestart) {
        _failureDuringRestart = false;
        _onChainFailure();
      }
    } catch (error, stackTrace) {
      if (_closing || _failed) return;
      _restarting = false;
      _failureDuringRestart = false;
      _reportSupervision(
          EventBusException('layer chain restart failed: $error'), stackTrace);
      _scheduleRestart();
    }
  }

  void _fail() {
    if (_failed || _closing) return;
    _failed = true;
    _restarting = false;
    _state = LayersState.failed;
    final failure = EventBusException(
        'layer chain exhausted ${_policy.maxRestarts} restart(s) '
        'in ${_policy.window}');
    _reportSupervision(failure, null);
    _failWaiters(failure);
    unawaited(_disposeBridge());
  }

  ///Disposes the top bridge but keeps the top local bus; used when the chain
  ///can no longer be restarted.
  Future<void> _disposeBridge() async {
    final bridge = _layer.bottom;
    _layer.bottom = null;
    if (bridge != null) {
      try {
        await bridge.dispose();
      } catch (_) {
        // a dead bridge may already be gone
      }
    }
  }

  void _reportSupervision(Object error, StackTrace? stackTrace) {
    if (_errors.isClosed) return;
    _errors.add(EventBusError(
      kind: EventBusErrorKind.supervision,
      source: EventBusErrorSource.supervision,
      error: error,
      stackTrace: stackTrace,
    ));
  }

  void _flushWaiters() {
    final waiters = List<Completer<void>>.of(_readyWaiters);
    _readyWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    if (_state == LayersState.ready && !_initialReady.isCompleted) {
      _initialReady.complete();
    }
  }

  void _failWaiters(Object error) {
    final waiters = List<Completer<void>>.of(_readyWaiters);
    _readyWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }

  Future<void> _close() async {
    _closing = true;
    _state = LayersState.closed;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _bridgeErrors?.cancel();
    _bridgeErrors = null;
    await _layer.close();
    final failure = EventBusException('LayersSupervisor is closed');
    _failWaiters(failure);
    if (!_initialReady.isCompleted) {
      _initialReady.completeError(StateError('LayersSupervisor is closed'));
    }
    if (!_errors.isClosed) await _errors.close();
  }
}

Future<void> _initLayer(EventBus bus, Object? initData) async {
  if (initData is! _LayerInitDto) {
    return;
  }
  final dto = initData;
  final index = dto.index;
  if (index >= dto.data.length) {
    return;
  }
  final Layer l = Layer(
      current: EventBus(isModelBus: dto.data[index].$3),
      top: bus,
      bottom: index + 1 < dto.data.length
          ? EventBusIsolate(
              onInit: _initLayer,
              initialData: dto.next(),
              isModelBus: dto.bridgeIsModelBus)
          : null);
  final bottom = l.bottom;
  if (bottom != null) {
    // Only the top bridge is directly observable by the chain owner. A failure
    // of a deeper layer is forwarded up this link so the owner can restart the
    // whole chain.
    bottom.errors.listen((error) {
      if (error.kind != EventBusErrorKind.isolateDeath) return;
      final top = l.top;
      if (top is _EventBusForIsolate) {
        top._sendFailure('layer ${index + 1} failed: ${error.error}');
      }
    });
    // wait not only for the next isolate to start, but for it to be initialized
    await (bottom as EventBusIsolate).waitInit;
  }
  await dto.data[index].$1.call(l, dto.data[index].$2);
}
