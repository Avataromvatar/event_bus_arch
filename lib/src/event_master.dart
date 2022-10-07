import 'dart:async';

import 'package:dart_event_bus/src/event_controller.dart';
import 'package:dart_event_bus/src/event_dto.dart';

abstract class IEventBusMaster {
  ///key: prefix bus, value: connect or disconnect
  Stream<MapEntry<String, bool>> get changes;
  EventBus? getEventBus<T>({String? prefix});
  EventBus? getEventBusByPrefix(String prefix);
  List<String> get busPrefixes;
  void add<T>(EventBus bus);
  void remove<T>(EventBus bus);

  bool send<T>(T event, {String? eventName, String? uuid, String? prefix});

  ///repeat last event by topic
  bool repeat<T>({String? eventName, String? uuid, String? prefix});
  T? lastEvent<T>({String? eventName, String? prefix});

  ///Возвращает поток события. Если нужно повторить предыдуще событие используйте [repeatLastEvent]
  Stream<EventDTO<T>>? listenEventDTO<T>({String? eventName, bool repeatLastEvent = false, String? prefix});
  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix});
}

class EventBusMaster implements IEventBusMaster {
  final List<EventBus> _list = [];
  final StreamController<MapEntry<String, bool>> _changes = StreamController<MapEntry<String, bool>>.broadcast();
  @override
  Stream<MapEntry<String, bool>> get changes => _changes.stream;
  static EventBusMaster _instance = EventBusMaster._();
  static IEventBusMaster get instance => _instance;
  EventBusMaster._() {}
  factory EventBusMaster() {
    return _instance;
  }
  @override
  List<String> get busPrefixes => _list.where((element) => element.prefix != null).map((e) => e.prefix!).toList();
  @override
  EventBus? getEventBus<T>({String? prefix}) {
    for (var element in _list) {
      if (element is T && (prefix == element.prefix || prefix == null)) {
        return element;
      }
    }
  }

  @override
  EventBus? getEventBusByPrefix(String prefix) {
    for (var element in _list) {
      if (prefix == element.prefix) {
        return element;
      }
    }
  }

  ///repeat last event by topic
  @override
  bool repeat<T>({String? eventName, String? uuid, String? prefix}) {
    for (var element in _list) {
      if (element is T && (prefix == element.prefix || prefix == null)) {
        return element.repeat(eventName: eventName, uuid: uuid, prefix: prefix);
      }
    }
    return false;
  }

  @override
  void add<T>(EventBus bus) {
    _list.add(bus);
  }

  @override
  void remove<T>(EventBus bus) {
    _list.remove(bus);
  }

  @override
  T? lastEvent<T>({String? eventName, String? prefix}) {
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) /*&&
          element.contain<T>(eventName)*/
          ) {
        return element.lastEvent<T>(eventName: eventName);
      }
    }
  }

  @override
  bool send<T>(T event, {String? eventName, String? uuid, String? prefix}) {
    bool ret = false;
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) /*&&
          element.contain<T>(eventName)*/
          ) {
        element.send<T>(event, eventName: eventName);
        ret = true;
      }
    }
    return ret;
  }

  ///Возвращает поток события. Если нужно повторить предыдуще событие используйте [repeatLastEvent]
  @override
  Stream<EventDTO<T>>? listenEventDTO<T>({String? eventName, bool repeatLastEvent = false, String? prefix}) {
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) && element.contain<T>(eventName)) {
        return element.listenEventDTO<T>(eventName: eventName, repeatLastEvent: repeatLastEvent);
      }
    }
    return null;
  }

  @override
  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix}) {
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) && element.contain<T>(eventName)) {
        return element.listenEvent<T>(eventName: eventName, repeatLastEvent: repeatLastEvent);
      }
    }
    return null;
  }
}
