part of event_arch;

abstract class IEventBusMaster {
  ///<even bus, isAdd>
  Stream<MapEntry<EventBus, bool>> get changes;

  ///check the bus,
  bool contain(String name, {Type? type});

  EventBus? getEventBus(String name, {Type? type});
  List<String> get busNames;
  void add(EventBus bus);
  void remove(EventBus bus);
}

class EventBusMaster implements IEventBusMaster {
  final List<EventBus> _list = [];
  final StreamController<MapEntry<EventBus, bool>> _changes = StreamController<MapEntry<EventBus, bool>>.broadcast();
  @override
  Stream<MapEntry<EventBus, bool>> get changes => _changes.stream;
  static EventBusMaster _instance = EventBusMaster._();
  static IEventBusMaster get instance => _instance;
  EventBusMaster._() {}
  factory EventBusMaster() {
    return _instance;
  }
  @override
  List<String> get busNames => _list.map((e) => e.name).toList();
  @override
  EventBus? getEventBus(String name, {Type? type}) {
    for (var i = 0; i < _list.length; i++) {
      if (_list[i].name == name) {
        if (type == _list[i].runtimeType) {
          return _list[i];
        }
      }
    }
    return null;
  }

  @override
  bool contain(String name, {Type? type}) {
    for (var i = 0; i < _list.length; i++) {
      if (_list[i].name == name) {
        if (type == _list[i].runtimeType) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  void add(EventBus bus) {
    _list.add(bus);
    _changes.add(MapEntry(bus, true));
  }

  @override
  void remove(EventBus bus) {
    _list.remove(bus);
    _changes.add(MapEntry(bus, false));
  }
}
