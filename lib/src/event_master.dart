import 'dart:async';

import 'package:dart_event_bus/src/event_controller.dart';
import 'package:dart_event_bus/src/event_dto.dart';

abstract class IEventBusMaster {
  ///key: bus, value: connect or disconnect EventController
  Stream<MapEntry<EventBus, bool>> get changes;
  EventBus? getEventBus<T>({String? prefix});
  EventBus? getEventBusByPrefix(String prefix);
  List<String> get busPrefixes;
  void add<T>(EventBus bus);
  void remove<T>(EventBus bus);

  ///return true if hasListener.
  ///
  ///if uuid not set, be use default uuid
  ///
  ///Master can have many Events what use same prefix and all they get event
  bool send<T>(T event, {String? eventName, String? uuid, String? prefix, Duration? afterTime, Stream? afterEvent});

  ///repeat last event by topic
  bool repeat<T>({String? eventName, String? uuid, String? prefix, Duration? duration});
  T? lastEvent<T>({String? eventName, String? prefix});

  ///Use [repeatLastEvent] if need send lastEvent. @attention event be sended after wait 1 millisecond or [Duration]
  ///
  ///return null if prefix != bus.prefix
  Stream<EventDTO<T>>? listenEventDTO<T>(
      {String? eventName, bool repeatLastEvent = false, String? prefix, Duration? duration});

  ///Use [repeatLastEvent] if need send lastEvent. @attention event be sended after wait 1 millisecond or [Duration]
  ///
  ///return null if prefix != bus.prefix
  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix, Duration? duration});
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
  bool repeat<T>({String? eventName, String? uuid, String? prefix, Duration? duration}) {
    for (var element in _list) {
      if (element is T && (prefix == element.prefix || prefix == null)) {
        return element.repeat(eventName: eventName, uuid: uuid, prefix: prefix, duration: duration);
      }
    }
    return false;
  }

  @override
  void add<T>(EventBus bus) {
    _list.add(bus);
    _changes.add(MapEntry(bus, true));
  }

  @override
  void remove<T>(EventBus bus) {
    _list.remove(bus);
    _changes.add(MapEntry(bus, false));
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
  bool send<T>(T event, {String? eventName, String? uuid, String? prefix, Duration? afterTime, Stream? afterEvent}) {
    bool ret = false;
    for (var element in _list) {
      if ((prefix != null && element.prefix == prefix) /*&&
          element.contain<T>(eventName)*/
          ) {
        element.send<T>(event,
            eventName: eventName, uuid: uuid, prefix: prefix, afterEvent: afterEvent, afterTime: afterTime);
        ret = true;
      }
    }
    return ret;
  }

  ///Возвращает поток события. Если нужно повторить предыдуще событие используйте [repeatLastEvent]
  @override
  Stream<EventDTO<T>>? listenEventDTO<T>(
      {String? eventName, bool repeatLastEvent = false, String? prefix, Duration? duration}) {
    for (var element in _list) {
      if ((/*prefix != null &&*/ element.prefix == prefix) /*&& element.contain<T>(eventName)*/) {
        return element.listenEventDTO<T>(eventName: eventName, repeatLastEvent: repeatLastEvent, duration: duration);
      }
    }
    return null;
  }

  @override
  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix, Duration? duration}) {
    for (var element in _list) {
      if ((/*prefix != null &&*/ element.prefix == prefix) /* && element.contain<T>(eventName)*/) {
        return element.listenEvent<T>(eventName: eventName, repeatLastEvent: repeatLastEvent, duration: duration);
      }
    }
    return null;
  }
}
