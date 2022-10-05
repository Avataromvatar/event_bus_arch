import 'package:dart_event_bus/src/event_controller.dart';
import 'package:dart_event_bus/src/event_dto.dart';

abstract class IEventBusMaster {
  IEventBus? getEventBus<T>({String? prefix});
  IEventBus? getEventBusByPrefix(String prefix);
  List<String> get controllersPrefix;
  void add<T>(IEventBus bus);
  void remove<T>(IEventBus bus);

  bool send<T>(T event, {String? eventName, String? uuid, String? prefix});

  ///repeat last event by topic
  bool repeat<T>({String? eventName, String? uuid, String? prefix});
  T? lastEvent<T>({String? eventName, String? prefix});

  ///Возвращает поток события. Если нужно повторить предыдуще событие используйте [repeatLastEvent]
  Stream<EventDTO<T>>? listenEventDTO<T>({String? eventName, bool repeatLastEvent = false, String? prefix});
  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix});
}

class EventBusMaster implements IEventBusMaster {
  List<IEventBus> _list = [];
  static EventBusMaster _instance = EventBusMaster._();
  static IEventBusMaster get instance => _instance;
  EventBusMaster._() {}
  factory EventBusMaster() {
    return _instance;
  }
  List<String> get controllersPrefix => _list.where((element) => element.prefix != null).map((e) => e.prefix!).toList();
  IEventBus? getEventBus<T>({String? prefix}) {
    for (var element in _list) {
      if (element is T && (prefix == element.prefix || prefix == null)) {
        return element;
      }
    }
  }

  IEventBus? getEventBusByPrefix(String prefix) {
    for (var element in _list) {
      if (prefix == element.prefix) {
        return element;
      }
    }
  }

  ///repeat last event by topic
  bool repeat<T>({String? eventName, String? uuid, String? prefix}) {
    for (var element in _list) {
      if (element is T && (prefix == element.prefix || prefix == null)) {
        return element.repeat(eventName: eventName, uuid: uuid, prefix: prefix);
      }
    }
    return false;
  }

  void add<T>(IEventBus bus) {
    _list.add(bus);
  }

  void remove<T>(IEventBus bus) {
    _list.remove(bus);
  }

  T? lastEvent<T>({String? eventName, String? prefix}) {
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) /*&&
          element.contain<T>(eventName)*/
          ) {
        return element.lastEvent<T>(eventName: eventName);
      }
    }
  }

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
  Stream<EventDTO<T>>? listenEventDTO<T>({String? eventName, bool repeatLastEvent = false, String? prefix}) {
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) && element.contain<T>(eventName)) {
        return element.listenEventDTO<T>(eventName: eventName, repeatLastEvent: repeatLastEvent);
      }
    }
  }

  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix}) {
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) && element.contain<T>(eventName)) {
        return element.listenEvent<T>(eventName: eventName, repeatLastEvent: repeatLastEvent);
      }
    }
  }
}
