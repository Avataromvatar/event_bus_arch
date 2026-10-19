part of event_arch;

abstract class Command<T> {
  Future<dynamic> execute(T data, {Map<String, String>? arguments});

  ///Sends the PREVIOUS value from the history back to the bus (one step back).
  ///Returns null when there is nothing to roll back to (fewer than two calls).
  Future<dynamic> undo();

  EventBus get bindedBus;

  ///Call history length
  int get queueLength;

  List<String>? get paths;
  (T data, Map<String, String>? arguments)? get lastCall;

  ///[maxLen] is the call history length, at least 1.
  factory Command(EventBus busBinded, {List<String>? paths, int maxLen = 10}) {
    return CommandImpl(busBinded, paths: paths, maxLen: maxLen);
  }
}

class CommandImpl<T> implements Command<T> {
  final EventBus _bus;
  final List<String>? _paths;
  final int maxLen;
  @override
  List<String>? get paths => _paths;
  @override
  EventBus get bindedBus => _bus;
  @override
  int get queueLength => _queue.length;

  ///data, arguments
  final Queue<(T, Map<String, String>?)> _queue = Queue();
  @override
  (T data, Map<String, String>? arguments)? get lastCall => getLastCall();

  CommandImpl(this._bus, {List<String>? paths, int maxLen = 10})
      : _paths = paths,
        // a history depth below one makes no sense and used to crash on the
        // very first call
        maxLen = maxLen < 1 ? 1 : maxLen;

  @override
  Future<dynamic> execute(T data,
      {String? fragment, Map<String, String>? arguments}) async {
    if (_queue.length >= maxLen) {
      _queue.removeFirst();
    }
    _queue.add((
      data,
      arguments,
    ));
    return _call(data, arguments);
  }

  @override
  Future<dynamic> undo() async {
    if (_queue.length < 2) {
      return null;
    }
    _queue.removeLast();
    var previous = _queue.last;
    return _call(previous.$1, previous.$2);
  }

  ///A command is a request when a handler answers it. Without a handler the
  ///value still goes through the bus (a model bus stores it), and the result
  ///is null.
  Future<dynamic> _call(T data, Map<String, String>? arguments) {
    if (_bus.haveHandler<T>(paths: _paths)) {
      return _bus.request<T>(data, paths: _paths, arguments: arguments);
    }
    _bus.fire<T>(data, paths: _paths, arguments: arguments);
    return Future.value(null);
  }

  (T data, Map<String, String>? arguments)? getLastCall() {
    if (_queue.isNotEmpty) {
      return (_queue.last.$1, _queue.last.$2);
    }
    return null;
  }
}
