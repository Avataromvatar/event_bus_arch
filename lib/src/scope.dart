part of event_arch;

///EventBus, if is not model bus, delete node what not have handler and listeners
///Scope add listener for T event and use Command for call event
mixin class Scope<T> {
  StreamSubscription<T>? _scopeStreamSubscription;
  Command<T>? _scopeCommand;
  T? lastData;
  (T?, Map<String, String>?)? get lastCall => _scopeCommand != null
      ? _scopeCommand!.lastCall
      : throw EventBusException("Scope<${T..runtimeType}> not initalize");
  void Function(T newData)? onUpdate;
  EventBus? get scopeBus => _scopeCommand != null
      ? _scopeCommand!.bindedBus
      : throw EventBusException("Scope<${T..runtimeType}> not initalize");

  ///Initializes the scope: subscribes to the bus and creates the call history.
  ///
  ///The returned future is worth awaiting: it completes once the initial value
  ///has gone through the bus (or with a handler error).
  ///[maxLenForUndo] is the history depth, at least 2 (otherwise there is
  ///nothing to roll back to).
  Future<void> initScope(EventBus bus,
      {T? initialData,
      
      bool initialDataNeedExecute = true,
      
      List<String>? paths,
      int maxLenForUndo = 10,
      void Function(T newData)? onUpdate}) async {
    var data = initialData ;
    var needExecute = initialDataNeedExecute;

    if (_scopeCommand != null) {
      // re-initialization: drop the previous subscription and handler
      disposeScope();
    }

    this.onUpdate = onUpdate;
    _scopeCommand = Command(bus, paths: paths, maxLen: maxLenForUndo);

    _scopeStreamSubscription = bus.listen<T>(paths: paths).listen((event) {
      lastData = event;
      this.onUpdate?.call(event);
    });
    if (data != null) {
      if (needExecute) {
        await _scopeCommand!.execute(data);
      } else {
        lastData = data;
      }
    }
  }

  Future<dynamic> call(T newData, {String? fragment, Map<String, String>? arguments}) {
    if (_scopeCommand == null) {
      throw EventBusException("Scope<${T..runtimeType}> not initalize");
    }
    return _scopeCommand!.execute(newData, arguments: arguments);
  }

  ///Rolls back to the previous value from the history
  Future<dynamic> undo() {
    if (_scopeCommand == null) {
      throw EventBusException("Scope<${T..runtimeType}> not initalize");
    }
    return _scopeCommand!.undo();
  }

  void disposeScope({bool removeHandler = true}) {
    if (_scopeCommand != null && removeHandler) {
      scopeBus!.handlers.removeHandler<T>(paths: _scopeCommand?.paths);
    }
    _scopeStreamSubscription?.cancel();
    _scopeStreamSubscription = null;
    _scopeCommand = null;
  }
}
