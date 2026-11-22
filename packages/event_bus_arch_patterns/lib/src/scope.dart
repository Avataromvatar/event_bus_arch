import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'command.dart';

///A value with call history and undo, addressed by an exact [EventKey].
///
///[Scope] subscribes to the key as a latest-value consumer and uses [Command]
///to send values through the bus.
mixin class Scope<T> {
  EventSubscription<T>? _scopeSubscription;
  Command<T>? _scopeCommand;
  T? lastData;
  (T?, Map<String, String>?)? get lastCall => _scopeCommand != null
      ? _scopeCommand!.lastCall
      : throw EventBusException("Scope<$T> not initialize");
  void Function(T newData)? onUpdate;
  EventBus? get scopeBus => _scopeCommand != null
      ? _scopeCommand!.bindedBus
      : throw EventBusException("Scope<$T> not initialize");

  ///Initializes the scope: subscribes to [key] and creates the call history.
  ///
  ///The returned future is worth awaiting: it completes once the initial value
  ///has gone through the bus (or with a handler error).
  ///[maxLenForUndo] is the history depth, at least 2 (otherwise there is
  ///nothing to roll back to).
  Future<void> initScope(EventBus bus, EventKey<T> key,
      {T? initialData,
      bool initialDataNeedExecute = true,
      int maxLenForUndo = 10,
      void Function(T newData)? onUpdate}) async {
    final data = initialData;
    final needExecute = initialDataNeedExecute;

    if (_scopeCommand != null) {
      // re-initialization: drop the previous subscription and handler
      disposeScope();
    }

    this.onUpdate = onUpdate;
    _scopeCommand = Command(bus, key, maxLen: maxLenForUndo);

    // A scope is a latest-value consumer: keep only the newest update while
    // the callback is busy. Older values are dropped and counted by the
    // subscription.
    _scopeSubscription = bus.subscribe<T>(
      key,
      bufferCapacity: 1,
      bufferOverflow: BufferOverflow.latest,
      onEvent: (event) {
        lastData = event;
        this.onUpdate?.call(event);
      },
    );
    if (data != null) {
      if (needExecute) {
        await _scopeCommand!.execute(data);
      } else {
        lastData = data;
      }
    }
  }

  Future<dynamic> call(T newData, {Map<String, String>? arguments}) {
    if (_scopeCommand == null) {
      throw EventBusException("Scope<$T> not initialize");
    }
    return _scopeCommand!.execute(newData, arguments: arguments);
  }

  ///Rolls back to the previous value from the history
  Future<dynamic> undo() {
    if (_scopeCommand == null) {
      throw EventBusException("Scope<$T> not initialize");
    }
    return _scopeCommand!.undo();
  }

  void disposeScope() {
    unawaited(_scopeSubscription?.cancel());
    _scopeSubscription = null;
    _scopeCommand = null;
  }
}
