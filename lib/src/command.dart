part of event_arch;

abstract class Command<T> {
  Future<dynamic> execute(T data, {String? fragment, Map<String, String>? arguments});

  ///Sends the PREVIOUS value from the history back to the bus (one step back).
  ///Returns null when there is nothing to roll back to (fewer than two calls).
  Future<dynamic> undo();

  EventBus get bindedBus;

  ///Call history length
  int get queueLength;

  @Deprecated('Use queueLength')
  int get queueLenght => queueLength;

  String? get path;
  (T data, String? fragment, Map<String, String>? arguments)? get lastCall;

  ///[maxLen] is the call history length, at least 1.
  factory Command(EventBus busBinded, {String? path, int maxLen = 10}) {
    return CommandImpl(busBinded, path: path, maxLen: maxLen);
  }
}

class CommandImpl<T> implements Command<T> {
  final EventBus _bus;
  final String? _path;
  final int maxLen;
  @override
  String? get path => _path;
  @override
  EventBus get bindedBus => _bus;
  @override
  int get queueLength => _queue.length;

  @override
  @Deprecated('Use queueLength')
  int get queueLenght => queueLength;

  ///data, arguments, fragment
  final Queue<(T, Map<String, String>?, String?)> _queue = Queue();
  @override
  (T data, String? fragment, Map<String, String>? arguments)? get lastCall => getLastCall();

  CommandImpl(this._bus, {String? path, int maxLen = 10})
      : _path = path,
        // a history depth below one makes no sense and used to crash on the
        // very first call
        maxLen = maxLen < 1 ? 1 : maxLen;

  @override
  Future<dynamic> execute(T data, {String? fragment, Map<String, String>? arguments}) async {
    if (_queue.length >= maxLen) {
      _queue.removeFirst();
    }
    _queue.add((data, arguments, fragment));
    return _bus.send<T>(data, path: _path, arguments: arguments, fragment: fragment);
  }

  @override
  Future<dynamic> undo() async {
    if (_queue.length < 2) {
      return null;
    }
    _queue.removeLast();
    var previous = _queue.last;
    return _bus.send<T>(previous.$1, path: _path, arguments: previous.$2, fragment: previous.$3);
  }

  (T data, String? fragment, Map<String, String>? arguments)? getLastCall() {
    if (_queue.isNotEmpty) {
      return (_queue.last.$1, _queue.last.$3, _queue.last.$2);
    }
    return null;
  }
}
