import 'dart:async';

import 'package:dart_event_bus/src/event_controller.dart';
import 'package:dart_event_bus/src/event_dto.dart';
import 'package:intl/intl.dart';

abstract class IEventBusMaster {
  ///key: bus, value: connect or disconnect EventController
  // Stream<MapEntry<EventBus, bool>> get changes;

  ///check if there is a listener on the bus,
  bool contain<T>(
    String prefix, {
    String? eventName,
  });
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
  ///
  ///If prefix not set and [isBroadcastEvent]==true all bus get event
  bool send<T>(T event,
      {String? eventName,
      String? uuid,
      String? prefix,
      Duration? afterTime,
      Stream? afterEvent,
      Future? afterThis,
      bool isBroadcastEvent = false,
      bool needLog});

  ///can return value if handler do it or cancel if handler not complete Future or this even not have a handler
  ///
  ///if uuid not set, be use default uuid
  ///
  ///
  Future<dynamic> call<T>(T event, String prefix,
      {String? eventName, String? uuid, Duration? afterTime, Stream? afterEvent, Future? afterThis, bool needLog});

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

  ///set function to logging for all EventBus. If set [cb] null log canceled
  ///#t - topic, #u - uuid #d - date #s - status true or not(have listener or not)
  void setLoggerToAll({void Function(String)? cb, String format = '#d #t--#u--#s', DateFormat? dateFormat});

  ///set uuid generator. Default EventBus use Uuid().v1()
  void setUUIDGeneratorToAll({String Function(String topic)? uuidGenerator});
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

  @override
  bool contain<T>(
    String prefix, {
    String? eventName,
  }) {
    var bus = getEventBusByPrefix(prefix);
    return bus?.contain<T>(eventName) ?? false;
  }

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
  bool send<T>(T event,
      {String? eventName,
      String? uuid,
      String? prefix,
      Duration? afterTime,
      Stream? afterEvent,
      Future? afterThis,
      bool isBroadcastEvent = false,
      bool needLog = true}) {
    bool ret = false;
    for (var element in _list) {
      if (element.prefix == prefix || (prefix == null && isBroadcastEvent)) {
        element.send<T>(event,
            eventName: eventName,
            uuid: uuid,
            prefix: prefix,
            afterEvent: afterEvent,
            afterTime: afterTime,
            afterThis: afterThis,
            needLog: needLog);
        ret = true;
      }
    }
    return ret;
  }

  @override
  Future<dynamic> call<T>(T event, String prefix,
      {String? eventName,
      String? uuid,
      Duration? afterTime,
      Stream? afterEvent,
      Future? afterThis,
      bool needLog = true}) async {
    var bus = getEventBusByPrefix(prefix);
    if (bus != null) {
      return bus.call(event,
          afterEvent: afterEvent,
          afterThis: afterThis,
          afterTime: afterTime,
          eventName: eventName,
          needLog: needLog,
          uuid: uuid);
    }
    throw Exception('No EventBus with prefix: $prefix');
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

  void setLoggerToAll({void Function(String)? cb, String format = '#d #t--#u--#s', DateFormat? dateFormat}) {
    _list.forEach((element) {
      element.setLogger(cb: cb, format: format, dateFormat: dateFormat);
    });
  }

  void setUUIDGeneratorToAll({String Function(String topic)? uuidGenerator}) {
    _list.forEach((element) {
      element.setUUIDGenerator(uuidGenerator: uuidGenerator);
    });
  }
}
