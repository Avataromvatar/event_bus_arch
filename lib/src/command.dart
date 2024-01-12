part of event_arch;

abstract class Command<T> {
  Future<dynamic> execute(T data, {String? fragment, Map<String, String>? arguments});
  Future<dynamic> undo();
  EventBus get bindedBus;
  int get queueLenght;
  String? get path;
  (T data, String? fragment, Map<String, String>? arguments)? get lastCall;
  factory Command(EventBus busBinded, {String? path, int maxLen = 10}) {
    return CommandImpl(busBinded, path: path, maxLen: maxLen);
  }
}

class CommandImpl<T> implements Command<T> {
  final EventBus _bus;
  final String? _path;
  final int maxLen;
  String? get path => _path;
  @override
  EventBus get bindedBus => _bus;
  @override
  int get queueLenght => _queue.length;

  ///data, argument, fragment
  Queue<(T, Map<String, String>?, String?)> _queue = Queue();
  @override
  (T data, String? fragment, Map<String, String>? arguments)? get lastCall => getLastCall();

  CommandImpl(this._bus, {String? path, this.maxLen = 10}) : _path = path;
  Future<dynamic> execute(T data, {String? fragment, Map<String, String>? arguments}) async {
    if (maxLen <= _queue.length) {
      _queue.removeFirst();
    }
    _queue.add((data, arguments, fragment));
    return _bus.send<T>(data, path: _path, arguments: arguments, fragment: fragment);
  }

  Future<dynamic> undo() async {
    if (_queue.isNotEmpty) {
      var last = _queue.removeLast();
      return _bus.send<T>(last.$1, path: _path, arguments: last.$2, fragment: last.$3);
    }
  }

  (T data, String? fragment, Map<String, String>? arguments)? getLastCall() {
    if (_queue.isNotEmpty) {
      return (_queue.last.$1, _queue.last.$3, _queue.last.$2);
    }
    return null;
  }
}
