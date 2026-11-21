part of event_arch;

///The worker init function of a [WorkerPool]. Like [EventBusIsolate.onInit],
///it runs INSIDE the worker isolate and must be top-level or static.
typedef WorkerInit = FutureOr<void> Function(EventBus bus, Object? initialData);

///How [WorkerPool] chooses a worker for an event or a request.
enum DispatchStrategy {
  ///Every event goes to every ready worker. A request cannot be broadcast: it
  ///would have several answers.
  broadcast,

  ///The next ready worker in order.
  roundRobin,

  ///A key selects one worker. By default the key is the topic path, so every
  ///event of a topic keeps its worker and its order. A custom [keySelector]
  ///replaces it.
  keyed,

  ///The ready worker with the fewest in-flight requests.
  leastBusy,

  ///One active worker; a ready standby takes over when the active one dies.
  single,
}

///A process-wide key selector for [DispatchStrategy.keyed].
typedef WorkerKeySelector = Object? Function(EventDTO dto);

///Restart limits and backoff for a supervised worker.
///
///The shape follows the transport `ReconnectPolicy`: an exponential delay
///between [initialBackoff] and [maxBackoff], and at most [maxRestarts] attempts
///inside a sliding [window].
class SupervisionPolicy {
  const SupervisionPolicy({
    this.maxRestarts = 5,
    this.window = const Duration(minutes: 1),
    this.initialBackoff = const Duration(milliseconds: 100),
    this.maxBackoff = const Duration(seconds: 10),
    this.multiplier = 2.0,
  })  : assert(maxRestarts >= 0),
        assert(multiplier >= 1.0);

  ///How many restarts are allowed inside [window]. Zero disables restarts.
  final int maxRestarts;

  ///The sliding window in which [maxRestarts] is counted.
  final Duration window;

  ///Delay before the first restart attempt.
  final Duration initialBackoff;

  ///Upper bound of a single delay.
  final Duration maxBackoff;

  ///Growth factor of the delay between attempts.
  final double multiplier;

  ///The delay before restart attempt number [attempt] (zero-based).
  Duration delayFor(int attempt) {
    if (attempt <= 0) return initialBackoff;
    final milliseconds =
        initialBackoff.inMilliseconds * math.pow(multiplier, attempt);
    if (milliseconds >= maxBackoff.inMilliseconds) return maxBackoff;
    return Duration(milliseconds: milliseconds.round());
  }
}

///Lifecycle of a [WorkerPool].
enum WorkerPoolState { starting, ready, restarting, failed, closed }

///A snapshot of the pool counters.
class WorkerPoolMetrics {
  const WorkerPoolMetrics({
    required this.state,
    required this.workers,
    required this.readyWorkers,
    required this.fired,
    required this.accepted,
    required this.dropped,
    required this.requests,
    required this.failedRequests,
    required this.restarts,
    required this.perWorker,
  });

  final WorkerPoolState state;
  final int workers;
  final int readyWorkers;

  ///`fire` calls made on the pool.
  final int fired;

  ///Worker `fire` calls that returned `true` (broadcast counts each worker).
  final int accepted;

  ///`fire` calls that reached no worker.
  final int dropped;

  ///`request` calls routed to a worker.
  final int requests;

  ///`request` calls that failed before or during dispatch.
  final int failedRequests;

  ///Restart attempts scheduled by supervision.
  final int restarts;

  final List<WorkerMetrics> perWorker;

  @override
  String toString() => 'WorkerPoolMetrics(state: ${state.name}, '
      'workers: $readyWorkers/$workers, fired: $fired, accepted: $accepted, '
      'dropped: $dropped, requests: $requests, failed: $failedRequests, '
      'restarts: $restarts)';
}

///Counters of one worker slot.
class WorkerMetrics {
  const WorkerMetrics({
    required this.index,
    required this.ready,
    required this.inFlight,
    required this.fired,
    required this.requests,
    required this.restarts,
  });

  final int index;
  final bool ready;
  final int inFlight;
  final int fired;
  final int requests;
  final int restarts;

  @override
  String toString() => 'WorkerMetrics(#$index, ready: $ready, '
      'inFlight: $inFlight, fired: $fired, requests: $requests, '
      'restarts: $restarts)';
}

///A fixed set of N [EventBusIsolate]s with one dispatch strategy and
///supervision.
///
///[broadcast] fans an event out to every ready worker; every other strategy
///selects exactly one. Requests are never broadcast. A request that lost its
///worker to a crash fails and is not retried (ADR-0003, ADR-0007).
///
///A dead worker is restarted with [SupervisionPolicy]; after
///[SupervisionPolicy.maxRestarts] attempts inside the window the pool emits an
///[EventBusError] of kind [EventBusErrorKind.supervision] and becomes failed.
///[close] marks the shutdown as intentional and never restarts anything.
///
///Backpressure is a per-worker request credit ([maxInFlightPerWorker]): a
///saturated worker is skipped by the selector. When no worker has a free
///credit, `fire` returns false and `request` throws [BusyException]. 4.0.0 has
///no pool-level dispatch queue: callers fail fast instead of waiting.
///
///A pool is not an [EventBus]: `broadcast` has no request semantics, and model
///state is per worker, not aggregated.
class WorkerPool {
  WorkerPool({
    required this.onInit,
    this.workers = 1,
    this.dispatch = DispatchStrategy.roundRobin,
    this.supervision = const SupervisionPolicy(),
    this.maxInFlightPerWorker = 64,
    this.initialData,
    this.initialDataFor,
    this.isModelBus = false,
    this.keySelector,
  }) {
    if (workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'must be >= 1');
    }
    if (maxInFlightPerWorker != null && maxInFlightPerWorker! < 1) {
      throw ArgumentError.value(maxInFlightPerWorker, 'maxInFlightPerWorker',
          'must be null or >= 1');
    }
    for (var index = 0; index < workers; index++) {
      _slots.add(_WorkerSlot(index));
    }
    // A caller that never awaits waitInit must not turn a start failure into an
    // unhandled zone error; listeners of waitInit still receive the error.
    _initialReady.future.ignore();
    unawaited(_start());
  }

  ///The init function run in every worker.
  final WorkerInit onInit;

  ///How many isolates the pool owns.
  final int workers;

  ///How an event or a request picks its worker.
  final DispatchStrategy dispatch;

  ///Restart limits and backoff.
  final SupervisionPolicy supervision;

  ///How many requests one worker may have in flight before the pool treats it
  ///as saturated and stops routing new work to it. Null means unlimited.
  final int? maxInFlightPerWorker;

  ///Initial data for every worker when [initialDataFor] is not set.
  final Object? initialData;

  ///Per-worker initial data, for example a worker index or a role. Takes
  ///precedence over [initialData].
  final Object? Function(int index)? initialDataFor;

  ///Whether every worker bus is a model bus.
  final bool isModelBus;

  ///The key used by [DispatchStrategy.keyed]; null means the topic path.
  final WorkerKeySelector? keySelector;

  final List<_WorkerSlot> _slots = <_WorkerSlot>[];
  final StreamController<EventBusError> _errors =
      StreamController<EventBusError>.broadcast();
  final Completer<void> _initialReady = Completer<void>();
  final List<Completer<void>> _readyWaiters = <Completer<void>>[];
  final _PoolCounters _counters = _PoolCounters();

  int _roundRobin = 0;
  int _active = 0;
  bool _closing = false;
  bool _failed = false;
  bool _started = false;
  WorkerPoolState _state = WorkerPoolState.starting;
  Future<void>? _closeFuture;

  ///Completes when every worker has finished its `onInit`.
  Future<void> get waitInit => _initialReady.future;

  ///The current lifecycle state.
  WorkerPoolState get state => _state;

  ///True when every worker is ready.
  bool get isReady => _state == WorkerPoolState.ready;

  ///True while the pool accepts work: at least one worker is ready and the
  ///pool is neither failed nor closed.
  bool get isUsable =>
      !_closing && !_failed && _slots.any((slot) => slot.ready);

  ///Worker failures plus supervision errors.
  Stream<EventBusError> get errors => _errors.stream;

  ///A snapshot of the counters.
  WorkerPoolMetrics get metrics => WorkerPoolMetrics(
        state: _state,
        workers: workers,
        readyWorkers: _slots.where((slot) => slot.ready).length,
        fired: _counters.fired,
        accepted: _counters.accepted,
        dropped: _counters.dropped,
        requests: _counters.requests,
        failedRequests: _counters.failedRequests,
        restarts: _counters.restarts,
        perWorker: List<WorkerMetrics>.unmodifiable([
          for (final slot in _slots)
            WorkerMetrics(
              index: slot.index,
              ready: slot.ready,
              inFlight: slot.inFlight,
              fired: slot.fired,
              requests: slot.requests,
              restarts: slot.restarts,
            ),
        ]),
      );

  ///Waits until every worker is ready. Fails when the pool becomes failed or
  ///closed first.
  Future<void> waitReady() {
    if (_state == WorkerPoolState.ready) return Future.value();
    if (_closing) return Future.error(StateError('WorkerPool is closed'));
    if (_failed) return Future.error(EventBusException('WorkerPool is failed'));
    final completer = Completer<void>();
    _readyWaiters.add(completer);
    return completer.future;
  }

  ///Sends an event according to [dispatch]. Returns true when at least one
  ///worker accepted it; false when it reached no worker.
  bool fire<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments}) {
    _checkOpen();
    final topic =
        Topic.create<T>(paths: paths, separator: separator ?? '.');
    final dto = EventDTO<T>(data, topic: topic, arguments: arguments);
    _counters.fired++;

    if (dispatch == DispatchStrategy.broadcast) {
      var accepted = false;
      var delivered = false;
      for (final slot in _slots) {
        final bus = slot.bus;
        if (!slot.ready || bus == null) continue;
        delivered = true;
        accepted =
            _fireOn<T>(slot, bus, data, paths, separator, arguments) || accepted;
      }
      if (!delivered) _counters.dropped++;
      return accepted;
    }

    final slot = _select(dto);
    return _fireOnSelected<T>(slot, data, paths, separator, arguments);
  }

  ///Sends a request to the worker selected by [dispatch] and waits for its
  ///answer. [DispatchStrategy.broadcast] is rejected with [UnsupportedError].
  Future<dynamic> request<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      Duration? timeout,
      CancelToken? cancelToken}) async {
    _checkOpen();
    if (dispatch == DispatchStrategy.broadcast) {
      throw UnsupportedError(
          'DispatchStrategy.broadcast cannot route requests: a request needs '
          'exactly one answering worker');
    }
    final topic =
        Topic.create<T>(paths: paths, separator: separator ?? '.');
    final dto = EventDTO<T>(data, topic: topic, arguments: arguments);
    final slot = _select(dto);
    if (slot == null || !_available(slot)) {
      _counters.failedRequests++;
      throw BusyException(topic.topic,
          'no ready worker with a free credit for dispatch strategy ${dispatch.name}');
    }
    final bus = slot.bus!;

    _counters.requests++;
    slot.requests++;
    slot.inFlight++;
    try {
      return await bus.request<T>(data,
          paths: paths,
          separator: separator,
          arguments: arguments,
          timeout: timeout,
          cancelToken: cancelToken);
    } on StateError {
      // the worker died between the readiness check and the send
      _counters.failedRequests++;
      throw BusyException(
          topic.topic, 'worker ${slot.index} is not ready any more');
    } catch (_) {
      _counters.failedRequests++;
      rethrow;
    } finally {
      slot.inFlight--;
    }
  }

  ///Stops the pool: cancels timers and error listeners, disposes every worker
  ///and closes [errors]. Intentionally closed workers are never restarted.
  ///Safe to call twice.
  Future<void> close() => _closeFuture ??= _close();

  ///An alias for [close].
  Future<void> dispose() => close();

  _WorkerSlot? _select(EventDTO dto) {
    switch (dispatch) {
      case DispatchStrategy.broadcast:
        return null; // handled before selection
      case DispatchStrategy.roundRobin:
        return _roundRobinSlot();
      case DispatchStrategy.keyed:
        return _keyedSlot(dto);
      case DispatchStrategy.leastBusy:
        return _leastBusySlot();
      case DispatchStrategy.single:
        return _singleSlot();
    }
  }

  _WorkerSlot? _roundRobinSlot() {
    for (var offset = 0; offset < _slots.length; offset++) {
      final index = (_roundRobin + offset) % _slots.length;
      final slot = _slots[index];
      if (_available(slot)) {
        _roundRobin = (index + 1) % _slots.length;
        return slot;
      }
    }
    return null;
  }

  _WorkerSlot? _keyedSlot(EventDTO dto) {
    final key = keySelector?.call(dto) ?? dto.topic.topic;
    final slot = _slots[_positiveHash(key) % _slots.length];
    // Never reroute a key to another worker: that would break per-key order.
    return _available(slot) ? slot : null;
  }

  _WorkerSlot? _leastBusySlot() {
    _WorkerSlot? best;
    for (final slot in _slots) {
      if (!_available(slot)) continue;
      if (best == null || slot.inFlight < best.inFlight) {
        best = slot;
      }
    }
    return best;
  }

  _WorkerSlot? _singleSlot() {
    for (var offset = 0; offset < _slots.length; offset++) {
      final index = (_active + offset) % _slots.length;
      final slot = _slots[index];
      if (_available(slot)) {
        _active = index;
        return slot;
      }
    }
    return null;
  }

  ///A worker with a free request credit.
  bool _available(_WorkerSlot slot) {
    if (!slot.ready || slot.bus == null) return false;
    final limit = maxInFlightPerWorker;
    return limit == null || slot.inFlight < limit;
  }

  int _positiveHash(Object? key) => (key ?? '').hashCode & 0x7fffffff;

  bool _fireOnSelected<T>(_WorkerSlot? slot, T data, List<String>? paths,
      String? separator, Map<String, String>? arguments) {
    if (slot == null || !_available(slot)) {
      _counters.dropped++;
      return false;
    }
    return _fireOn<T>(slot, slot.bus!, data, paths, separator, arguments);
  }

  bool _fireOn<T>(_WorkerSlot slot, EventBusIsolate bus, T data,
      List<String>? paths, String? separator, Map<String, String>? arguments) {
    slot.fired++;
    try {
      final accepted = bus.fire<T>(data,
          paths: paths, separator: separator, arguments: arguments);
      if (accepted) _counters.accepted++;
      return accepted;
    } on StateError {
      // the worker died between the readiness check and the send
      _counters.dropped++;
      return false;
    }
  }

  void _checkOpen() {
    if (_closing) throw StateError('WorkerPool is closed');
    if (_failed) throw EventBusException('WorkerPool is failed');
  }

  Future<void> _start() async {
    try {
      await Future.wait(_slots.map(_spawn));
      if (_closing) return;
      _started = true;
      _updateState();
      if (!_initialReady.isCompleted) _initialReady.complete();
    } catch (error, stackTrace) {
      if (_closing) {
        if (!_initialReady.isCompleted) {
          _initialReady.completeError(StateError('WorkerPool is closed'));
        }
        return;
      }
      _failed = true;
      _updateState();
      final failure = EventBusException('WorkerPool did not start: $error');
      if (!_initialReady.isCompleted) {
        _initialReady.completeError(failure, stackTrace);
      }
      _reportSupervision(failure, stackTrace);
      _failWaiters(failure);
      await _disposeWorkers();
    }
  }

  Future<void> _spawn(_WorkerSlot slot) async {
    final data = initialDataFor?.call(slot.index) ?? initialData;
    final bus = EventBusIsolate(
      onInit: onInit,
      initialData: data,
      isModelBus: isModelBus,
    );
    slot.bus = bus;
    slot.errorSub = bus.errors.listen((error) => _onWorkerError(slot, bus, error));
    final ready = await bus.waitInit;
    if (!ready) {
      throw EventBusException('worker ${slot.index} did not become ready');
    }
    slot.ready = true;
  }

  void _onWorkerError(_WorkerSlot slot, EventBusIsolate bus, EventBusError error) {
    if (!identical(slot.bus, bus)) return;
    if (!_closing && !_errors.isClosed) {
      _errors.add(error);
    }
    if (error.kind == EventBusErrorKind.isolateDeath) {
      _handleDeath(slot, bus);
    }
  }

  void _handleDeath(_WorkerSlot slot, EventBusIsolate bus) {
    if (_closing || _failed) return;
    // During the initial start the failure is owned by _start; supervision
    // applies to a pool that was ready at least once.
    if (!_started || slot.restarting) return;

    slot.ready = false;
    slot.bus = null;
    final sub = slot.errorSub;
    slot.errorSub = null;
    unawaited(sub?.cancel());
    unawaited(bus.dispose());
    _updateState();
    _scheduleRestart(slot);
  }

  void _scheduleRestart(_WorkerSlot slot) {
    if (_closing || _failed) return;
    final now = DateTime.now();
    slot.restartTimes
        .removeWhere((time) => now.difference(time) > supervision.window);
    if (slot.restartTimes.length >= supervision.maxRestarts) {
      _failPool(slot);
      return;
    }
    final attempt = slot.restartTimes.length;
    slot.restartTimes.add(now);
    slot.restarts++;
    _counters.restarts++;
    final delay = supervision.delayFor(attempt);
    slot.restartTimer?.cancel();
    slot.restartTimer = Timer(delay, () {
      slot.restartTimer = null;
      unawaited(_restart(slot));
    });
    _updateState();
  }

  Future<void> _restart(_WorkerSlot slot) async {
    if (_closing || _failed) return;
    slot.restarting = true;
    try {
      await _spawn(slot);
      if (_closing) {
        final bus = slot.bus;
        slot.bus = null;
        slot.ready = false;
        if (bus != null) await bus.dispose();
        return;
      }
      slot.restarting = false;
      _updateState();
    } catch (_) {
      slot.restarting = false;
      if (_closing || _failed) return;
      final bus = slot.bus;
      slot.bus = null;
      final sub = slot.errorSub;
      slot.errorSub = null;
      unawaited(sub?.cancel());
      if (bus != null) unawaited(bus.dispose());
      slot.ready = false;
      _scheduleRestart(slot);
    }
  }

  void _failPool(_WorkerSlot slot) {
    if (_failed || _closing) return;
    _failed = true;
    final failure = EventBusException(
        'worker ${slot.index} exhausted ${supervision.maxRestarts} restart(s) '
        'in ${supervision.window}');
    _updateState();
    _reportSupervision(failure, null,
        context: {'worker': '${slot.index}'});
    _failWaiters(failure);
    unawaited(_disposeWorkers());
  }

  void _reportSupervision(Object error, StackTrace? stackTrace,
      {Map<String, String>? context}) {
    if (_errors.isClosed) return;
    _errors.add(EventBusError(
      kind: EventBusErrorKind.supervision,
      source: EventBusErrorSource.supervision,
      error: error,
      stackTrace: stackTrace,
      context: context ?? const <String, String>{},
    ));
  }

  void _updateState() {
    if (_closing) {
      _state = WorkerPoolState.closed;
      return;
    }
    if (_failed) {
      _state = WorkerPoolState.failed;
      return;
    }
    final ready = _slots.where((slot) => slot.ready).length;
    if (ready == _slots.length) {
      _state = WorkerPoolState.ready;
      _flushWaiters();
    } else if (ready > 0) {
      _state = WorkerPoolState.restarting;
    } else {
      _state = _started ? WorkerPoolState.restarting : WorkerPoolState.starting;
    }
  }

  void _flushWaiters() {
    final waiters = List<Completer<void>>.of(_readyWaiters);
    _readyWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _failWaiters(Object error) {
    final waiters = List<Completer<void>>.of(_readyWaiters);
    _readyWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }

  Future<void> _disposeWorkers() async {
    final buses = <EventBusIsolate>[];
    for (final slot in _slots) {
      slot.restartTimer?.cancel();
      slot.restartTimer = null;
      final sub = slot.errorSub;
      slot.errorSub = null;
      unawaited(sub?.cancel());
      final bus = slot.bus;
      slot.bus = null;
      slot.ready = false;
      if (bus != null) buses.add(bus);
    }
    await Future.wait(buses.map((bus) => bus.dispose()));
  }

  Future<void> _close() async {
    _closing = true;
    _state = WorkerPoolState.closed;
    await _disposeWorkers();
    final failure = EventBusException('WorkerPool is closed');
    _failWaiters(failure);
    if (!_initialReady.isCompleted) {
      _initialReady.completeError(StateError('WorkerPool is closed'));
    }
    if (!_errors.isClosed) await _errors.close();
  }
}

class _WorkerSlot {
  _WorkerSlot(this.index);

  final int index;
  EventBusIsolate? bus;
  StreamSubscription<EventBusError>? errorSub;
  Timer? restartTimer;
  bool ready = false;
  bool restarting = false;
  int inFlight = 0;
  int fired = 0;
  int requests = 0;
  int restarts = 0;
  final List<DateTime> restartTimes = <DateTime>[];
}

class _PoolCounters {
  int fired = 0;
  int accepted = 0;
  int dropped = 0;
  int requests = 0;
  int failedRequests = 0;
  int restarts = 0;
}
