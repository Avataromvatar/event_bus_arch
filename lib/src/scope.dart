part of event_arch;

///EventBus, if is not model bus, delete node what not have handler and listeners
///Scope add listener for T event and use Command for call event
mixin class Scope<T> {
  StreamSubscription<T>? _scopeStreamSubscription;
  Command<T>? _scopeCommand;
  T? lastData;
  (T?, String?, Map<String, String>?)? get lastCall =>
      _scopeCommand != null ? _scopeCommand!.lastCall : throw Exception("Scope<${T..runtimeType}> not initalize");
  void Function(T newData)? onUpdate;
  EventBus? get scopeBus =>
      _scopeCommand != null ? _scopeCommand!.bindedBus : throw Exception("Scope<${T..runtimeType}> not initalize");
  void initScope(EventBus bus,
      {T? initalData,
      bool initalDataNeedExecute = true,
      String? path,
      int maxLenForUndo = 0,
      void Function(T newData)? onUpdate}) {
    this.onUpdate = onUpdate;
    _scopeCommand = Command(bus, path: path, maxLen: maxLenForUndo);

    _scopeStreamSubscription?.cancel();
    _scopeStreamSubscription = null;
    _scopeStreamSubscription = bus
        .listen<T>(
      path: path,
    )
        .listen((event) {
      lastData = event;
      onUpdate?.call(event);
    });
    if (initalData != null) {
      if (initalDataNeedExecute) {
        _scopeCommand!.execute(initalData);
      } else {
        lastData = initalData;
      }
    }
  }

  Future<dynamic> call(T newData, {String? fragment, Map<String, String>? arguments}) {
    if (_scopeCommand == null) {
      throw Exception("Scope<${T..runtimeType}> not initalize");
    }
    return _scopeCommand!.execute(newData, fragment: fragment, arguments: arguments);
  }

  ///call last event
  Future<dynamic> undo() {
    if (_scopeCommand == null) {
      throw Exception("Scope<${T..runtimeType}> not initalize");
    }
    return _scopeCommand!.undo();
  }

  void disposeScope({bool removeHandler = true}) {
    if (_scopeCommand != null && removeHandler) {
      (scopeBus as EventBusHandlers).removeHandler<T>(path: _scopeCommand?.path);
    }
    _scopeStreamSubscription?.cancel();
    _scopeStreamSubscription = null;
    _scopeCommand = null;
  }
}
