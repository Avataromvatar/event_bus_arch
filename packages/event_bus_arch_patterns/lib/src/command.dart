import 'dart:collection';

import 'package:event_bus_arch/event_bus_arch.dart';

///The command abstraction behind a [Scope].
///
///The command is bound to an exact [EventKey]; it sends the value through the
///bus and keeps a bounded call history for [undo].
abstract class Command<T> {
  Future<dynamic> execute(T data, {Map<String, String>? arguments});

  ///Sends the PREVIOUS value from the history back to the bus (one step back).
  ///Returns null when there is nothing to roll back to (fewer than two calls).
  Future<dynamic> undo();

  EventBus get bindedBus;

  ///The exact key this command addresses.
  EventKey<T> get key;

  ///Call history length
  int get queueLength;

  (T data, Map<String, String>? arguments)? get lastCall;

  ///[maxLen] is the call history length, at least 1.
  factory Command(EventBus busBinded, EventKey<T> key, {int maxLen = 10}) {
    return CommandImpl(busBinded, key, maxLen: maxLen);
  }
}

class CommandImpl<T> implements Command<T> {
  CommandImpl(this._bus, this._key, {int maxLen = 10})
      : maxLen = maxLen < 1 ? 1 : maxLen;

  final EventBus _bus;
  final EventKey<T> _key;
  final int maxLen;

  @override
  EventKey<T> get key => _key;

  @override
  EventBus get bindedBus => _bus;

  @override
  int get queueLength => _queue.length;

  ///data, arguments
  final Queue<(T, Map<String, String>?)> _queue = Queue();

  @override
  (T data, Map<String, String>? arguments)? get lastCall => getLastCall();

  @override
  Future<dynamic> execute(T data,
      {Map<String, String>? arguments}) async {
    if (_queue.length >= maxLen) {
      _queue.removeFirst();
    }
    _queue.add((data, arguments));
    return _call(data, arguments);
  }

  @override
  Future<dynamic> undo() async {
    if (_queue.length < 2) {
      return null;
    }
    _queue.removeLast();
    final previous = _queue.last;
    return _call(previous.$1, previous.$2);
  }

  ///A command is a request when a handler answers it. Without a handler the
  ///value still goes through the bus (a model bus stores it), and the result
  ///is null.
  Future<dynamic> _call(T data, Map<String, String>? arguments) {
    if (_bus.probeRequest(_key, data).localHandlers > 0) {
      return _bus.request<T>(_key, data, arguments: arguments);
    }
    _bus.fire<T>(_key, data, arguments: arguments);
    return Future.value(null);
  }

  (T data, Map<String, String>? arguments)? getLastCall() {
    if (_queue.isNotEmpty) {
      return (_queue.last.$1, _queue.last.$2);
    }
    return null;
  }
}
