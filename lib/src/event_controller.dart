import 'dart:async';

import 'package:event_bus_arch/src/event_dto.dart';
import 'package:event_bus_arch/src/event_master.dart';
// import 'package:equatable/equatable.dart';
import 'package:intl/intl.dart';

import 'package:uuid/uuid.dart';

class _Logger {
  final void Function(String) cb;

  ///#t - topic, #u - uuid #d - date #s - hasListener
  final String format;
  late final DateFormat dateFormat;

  _Logger(this.cb, {this.format = '#d #t--#u--#s', DateFormat? dateFormat}) {
    this.dateFormat = dateFormat ?? DateFormat('dd.MM hh:mm:ss');
  }
  void log(EventDTO event, bool hasListeners) {
    cb.call(_getMessage(event, hasListeners));
  }

  String _getMessage(EventDTO event, bool hasListeners) {
    String ret = '';
    var t = DateTime.now();
    for (var i = 0; i < format.length; i++) {
      if (format[i] == '#' && i + 1 < format.length) {
        if (format[i + 1] == 'd') {
          ret += dateFormat.format(t);
          i++;
        } else if (format[i + 1] == 'u') {
          ret += event.uuid;
          i++;
        } else if (format[i + 1] == 't') {
          ret += event.topic;
          i++;
        } else if (format[i + 1] == 's') {
          ret += hasListeners.toString();
          i++;
        } else {
          ret += format[i];
        }
      } else {
        ret += format[i];
      }
    }

    // ret = ret.replaceAll('#d', _dateFormat.format(t));
    // ret = ret.replaceAll('#b', body);
    // ret = ret.replaceAll('#m', t.millisecond.toString());
    return ret;
  }
}

class _UUIDGenerator {
  final String Function(String topic)? uuidGenerator;
  _UUIDGenerator({this.uuidGenerator});
  String getUuid(String topic) {
    return uuidGenerator != null ? uuidGenerator!.call(topic) : Uuid().v1();
  }
}

class EventBusTopic /*extends Equatable*/ {
  static const String divider = '^';
  late final String type;
  late final String? name;
  late final String? prefix;
  late final String topic;
  EventBusTopic.parse(this.topic) {
    var l = topic.split(divider);
    if (l.length <= 1) {
      //just a type
      name = null;
      prefix = null;
      type = topic;
    } else if (l.length == 2) {
      //just name and type
      prefix = null;
      name = l[1];
      type = l[0];
    } else if (l.length == 3) {
      prefix = l[0];
      name = l[2];
      type = l[1];
    }
  }
  EventBusTopic.create(Type type, {this.name, this.prefix}) {
    this.type = '$type';
    String? eventTypeAndName = name != null ? '$type${EventBusTopic.divider}$name' : '$type';
    if (prefix != null) {
      topic = '$prefix${EventBusTopic.divider}$eventTypeAndName';
    } else {
      topic = eventTypeAndName;
    }
  }
  // @override
  // List<Object?> get props => [topic];
}

// abstract class IEventNode<T> implements EventBusTopic {
//   EventBus get bus;
//   Future<void> repeat({String? uuid});
//   T? lastEvent();
// }

abstract class EventBusHandlersGroup {
  bool get isConnected;

  ///Handler class must addHandler to bus. For example:
  ///
  /// ```
  ///void connect(EventBusHandler bus) {
  ///_busHandler = bus;
  /// _busHandler!.addHandler<void>(init, eventName: eAppNamedEvent.init.name);
  /// }
  /// ```
  void connect(EventBusHandler bus);

  ///Handler class must removeHandler from bus
  ///
  /// ```
  /// void disconnect(EventBusHandler bus) {
  ///   bus!.removeHandler<void>(eventName: eAppNamedEvent.init.name);
  /// }
  /// ```
  void disconnect(EventBusHandler bus);
}

abstract class EventBus {
  /// prefix used for indentificator bus in EventBusMaster
  String? get prefix;
  Type get type;

  ///check if there is a listener on the bus
  bool contain<T>(String? eventName);

  ///return true if hasListener.
  ///
  ///if uuid not set, be use default uuid
  ///
  ///if prefix set - event send to EventMaster.
  ///
  ///if use afterEvent you Event will be sending when get event from afterEvent - One time
  ///
  ///if use afterThis you Event will be sending when future be comleted
  ///
  ///if you use afterTime, Event will be send after Duration
  ///
  ///You can use for example send(10) -> event topic = int
  bool send<T>(T event,
      {String? eventName,
      String? uuid,
      String? prefix,
      Duration? afterTime,
      Stream? afterEvent,
      Future? afterThis,
      bool needLog});

  ///can return value if handler do it(call needComplete) or cancel if handler not complete Future or this even not have a handler
  ///
  ///
  Future<dynamic> call<T>(T event,
      {String? eventName,
      String? uuid,
      String? prefix,
      Duration? afterTime,
      Stream? afterEvent,
      Future? afterThis,
      bool needLog});

  ///repeat last event by topic.
  ///If set duration event be repeated when duration time end
  bool repeat<T>({String? eventName, String? uuid, String? prefix, Duration? duration});

  ///Use [repeatLastEvent] if need send lastEvent. @attention event be sended after wait 1 millisecond or [Duration]
  ///
  ///if prefix set and he != bus.prefix, event search be in EventMaster and @attention EventMaster can return null
  Stream<EventDTO<T>>? listenEventDTO<T>(
      {String? eventName, bool repeatLastEvent = false, Duration? duration, String? prefix});

  ///Use [repeatLastEvent] if need send lastEvent. @attention event be sended after wait 1 millisecond or [Duration]
  ///
  ///if prefix set and they != bus.prefix, event search in EventMaster and @attention EventMaster can return null
  Stream<T>? listenEvent<T>({
    String? eventName,
    bool repeatLastEvent = false,
    Duration? duration,
    String? prefix,
  });

  ///return the last event
  T? lastEvent<T>({String? eventName, String? prefix});

  ///Return map where:
  ///
  ///key = topic name from [EventBusTopic]
  ///
  ///value = last event
  Map<String, dynamic> getAllTopics();

  ///create unique topic
  static String topicCreate(Type type, {String? eventName, String? prefix}) {
    String? eventTypeAndName = eventName != null ? '$type${EventBusTopic.divider}$eventName' : '$type';
    if (prefix != null) return '$prefix${EventBusTopic.divider}$eventTypeAndName';

    return eventTypeAndName;
  }

  ///if you whant add/remove Handlers or connect HandlerGroup use [EventBusHandler]
  ///```
  ///EventBusHandler busHandlers = eventBus as EventBusHandler;
  ///```
  factory EventBus({String? prefix, EventHandler? defaultHandler, bool isBusForModel = false}) {
    if (isBusForModel) {
      return EventModelController(prefix: prefix);
    } else {
      return EventController(prefix: prefix, defaultHandler: defaultHandler);
    }
  }

  ///set function to log. If set [cb] null log canceled
  ///#t - topic, #u - uuid #d - date #s - status true or not(have listener or not)
  void setLogger({void Function(String)? cb, String format = '#d #t--#u--#s', DateFormat? dateFormat});

  ///set uuid generator. Default EventBus use Uuid().v1()
  void setUUIDGenerator({String Function(String topic)? uuidGenerator});
}

typedef EventEmitter<T> = void Function(T data);

typedef EventHandler<T> = Future<void> Function(
    EventDTO<T> event,

    ///send event to other listener
    EventEmitter<EventDTO<T>>? emit,
    {EventBus? bus,
    Completer<dynamic>? needComplete});

///Interface for add/remove handlers
abstract class EventBusHandler {
  void addHandler<T>(EventHandler<T> handler, {String? eventName});
  void removeHandler<T>({String? eventName});
  void connect(EventBusHandlersGroup externHandlers);
  void disconnect(EventBusHandlersGroup externHandlers);
}

class EventNode<T> extends EventBusTopic {
  // final String topic;
  final String? eventName;
  final EventBus _bus;
  EventBus get bus => _bus;
  Stream<EventDTO<T>> get stream => _streamController.stream;
  bool get hasListener => _streamController.hasListener;
  bool get hasHandler => _handler != null;
  bool _isDispose = false;
  bool get isDispose => _isDispose;
  late final StreamController<EventDTO<T>> _streamController;
  EventHandler<T>? _handler;
  Function(String topic)? onCancel;
  T? lastEvent;
  String? _lastUUID;
  EventNode(
    String topic,
    this._handler,
    this._bus, {
    this.eventName,
    this.onCancel,
  }) : super.parse(topic) {
    _streamController = StreamController<EventDTO<T>>.broadcast(onCancel: _onCancel);
  }
  Future<void> call(EventDTO<T> event, {bool isRepeat = false, Completer<dynamic>? needComplete}) async {
    if (!_isDispose) {
      lastEvent = event.data;
      _lastUUID = event.uuid;
      if (_handler != null) {
        _handler!.call(event, (event) {
          if (_streamController.hasListener) {
            // if (needLogging) _logging(event, 'send');
            _streamController.add(event);
          } else {
            // if (needLogging) _loggingHasNoListener(event.topic, 'send');
          }
        }, bus: bus, needComplete: needComplete).then((value) {
          if (needComplete != null && !needComplete.isCompleted) {
            needComplete.completeError('$topic Handler not complete call');
          }
        });
      } else {
        if (_streamController.hasListener) {
          // if (needLogging) _logging(event, 'send');
          _streamController.add(event);
          if (needComplete != null) {
            needComplete.completeError('No handlers');
          }
        } else {
          // if (needLogging) _loggingHasNoListener(event.topic, 'send');
        }
        // _streamController.hasListener ? _streamController.add(event) : null;
      }
    }
  }

  Future<void> repeat({String? uuid, Duration? duration}) async {
    String u = '';
    if (lastEvent != null) {
      if (uuid != null) {
        u = uuid;
      } else {
        u = _lastUUID!; // Uuid().v1();
      }
      if (duration != null) {
        await Future.delayed(duration);
      }
      await call(EventDTO<T>(topic, lastEvent!, u), isRepeat: true);
    }
  }

  void _onCancel() {
    onCancel?.call(topic);
  }

  Future<void> dispose() async {
    _isDispose = true;
    _handler = null;
    await _streamController.close();
    onCancel = null;
  }
}

class EventController implements EventBus, EventBusHandler {
  final String? _prefix;
  @override
  String? get prefix => _prefix;
  final Map<String, EventNode> _eventsNode = {};
  @override
  Type get type => runtimeType;
  _Logger? _logger;
  _UUIDGenerator _uuid = _UUIDGenerator();

  ///This handler use for event what not have special handler but hasListener.
  ///use bus for
  EventHandler? defaultHandler;

  EventController({String? prefix, this.defaultHandler}) : _prefix = prefix {
    EventBusMaster.instance.add(this);
  }
  @override
  void connect(EventBusHandlersGroup externHandlers) {
    externHandlers.connect(this);
  }

  @override
  void disconnect(EventBusHandlersGroup externHandlers) {
    externHandlers.disconnect(this);
  }

  @override
  bool contain<T>(String? eventName) {
    final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: prefix);
    return _eventsNode.containsKey(topic);
  }

  @override
  Map<String, dynamic> getAllTopics() {
    return _eventsNode.map((key, value) => MapEntry(key, value.lastEvent));
  }

  @override
  T? lastEvent<T>({String? eventName, String? prefix}) {
    if (prefix == null || prefix == this.prefix) {
      final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      return _eventsNode[topic]?.lastEvent;
    } else {
      return EventBusMaster.instance.lastEvent<T>(eventName: eventName, prefix: prefix);
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
      bool needLog = true}) {
    if (prefix == null || prefix == this.prefix) {
      final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      EventDTO<T> eventDTO = EventDTO<T>(topic, event, uuid ?? _uuid.getUuid(topic));
      if (_eventsNode.containsKey(topic)) {
        if (afterThis != null) {
          afterThis.then((value) => _eventsNode[topic]?.call(eventDTO));
        } else if (afterTime != null) {
          Future.delayed(afterTime).then((value) => _eventsNode[topic]?.call(eventDTO));
        } else if (afterEvent != null) {
          afterEvent.first.then((value) => _eventsNode[topic]?.call(eventDTO));
          // afterEvent.listen((event1) {
          //   _eventsNode[topic]!.call(EventDTO<T>(topic, event, uuid ?? Uuid().v1()));
          // });
        } else {
          _eventsNode[topic]!.call(eventDTO);
        }
        if (needLog) {
          _logger?.log(eventDTO, true);
        }
        return true;
      }
      if (needLog) {
        _logger?.log(eventDTO, false);
      }
      return false;
    } else {
      return EventBusMaster.instance.send<T>(event, eventName: eventName, uuid: uuid, prefix: prefix);
    }
  }

  @override
  Future<dynamic> call<T>(T event,
      {String? eventName,
      String? uuid,
      String? prefix,
      Duration? afterTime,
      Stream? afterEvent,
      Future? afterThis,
      bool needLog = true}) async {
    if (prefix == null || prefix == this.prefix) {
      final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      EventDTO<T> eventDTO = EventDTO<T>(topic, event, uuid ?? _uuid.getUuid(topic));
      if (_eventsNode.containsKey(topic)) {
        Completer completer = Completer<dynamic>();

        if (afterThis != null) {
          afterThis.then((value) => _eventsNode[topic]?.call(eventDTO, needComplete: completer));
        } else if (afterTime != null) {
          Future.delayed(afterTime).then((value) => _eventsNode[topic]?.call(eventDTO, needComplete: completer));
        } else if (afterEvent != null) {
          afterEvent.first.then((value) => _eventsNode[topic]?.call(eventDTO, needComplete: completer));
          // afterEvent.listen((event1) {
          //   _eventsNode[topic]!.call(EventDTO<T>(topic, event, uuid ?? Uuid().v1()));
          // });
        } else {
          _eventsNode[topic]!.call(eventDTO, needComplete: completer);
        }
        if (needLog) {
          _logger?.log(eventDTO, true);
        }
        return completer.future;
      }
      if (needLog) {
        _logger?.log(eventDTO, false);
      }
    } else {
      // return EventBusMaster.instance.call<T>(event, eventName: eventName, uuid: uuid, prefix: prefix);
    }
  }

  // Future<void> _callAfterTime(Duration afterTime,EventNode node, {})
  @override
  bool repeat<T>({
    String? eventName,
    String? uuid,
    String? prefix,
    Duration? duration,
  }) {
    if (prefix == null || prefix == this.prefix) {
      final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      var s = _eventsNode[topic];
      if (s != null) {
        s.repeat(uuid: uuid, duration: duration);
        return true;
      }
    } else {
      return EventBusMaster().repeat(eventName: eventName, uuid: uuid, prefix: prefix, duration: duration);
    }
    return false;
  }

  //Can return null only if set prefix != controller.prefix and EventBusMaster no have controller with this prefix
  @override
  Stream<T>? listenEvent<T>({
    String? eventName,
    bool repeatLastEvent = false,
    String? prefix,
    Duration? duration,
  }) {
    // var s =
    //     listenEventDTO<T>(eventName: eventName, prefix: prefix, repeatLastEvent: repeatLastEvent, duration: duration);
    // if (s != null) {
    //   var str = StreamController<T>();
    //   var l = s.listen((event) {
    //     str.add(event.data);
    //   }, onDone: () => str.sink.close());
    //   str.onCancel = () {
    //     l.cancel();
    //   };
    //   return str.stream;
    // }
    return listenEventDTO<T>(eventName: eventName, prefix: prefix, repeatLastEvent: repeatLastEvent, duration: duration)
        ?.map((event) => event.data!);
  }

  //Can return null only if set prefix != controller.prefix and EventBusMaster no have controller with this prefix
  @override
  Stream<EventDTO<T>>? listenEventDTO<T>({
    String? eventName,
    bool repeatLastEvent = false,
    String? prefix,
    Duration? duration,
  }) {
    if (prefix == null || prefix == this.prefix) {
      final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      var s = _eventsNode[topic];
      if (s == null) {
        _eventsNode[topic] = EventNode<T>(
            topic,
            defaultHandler != null
                ? (event, emit, {bus, needComplete}) async {
                    defaultHandler!.call(event, (data) {
                      emit?.call(data as EventDTO<T>);
                    }, bus: bus, needComplete: needComplete);
                  }
                : null,
            this,
            eventName: eventName,
            onCancel: _cancelEventNode);
      }

      if (repeatLastEvent) {
        _eventsNode[topic]?.repeat(duration: duration ?? Duration(milliseconds: 1));
      }
      return _eventsNode[topic]!.stream as Stream<EventDTO<T>>;
    } else {
      return EventBusMaster.instance
          .listenEventDTO<T>(eventName: eventName, prefix: prefix, repeatLastEvent: repeatLastEvent);
    }
  }

  void _cancelEventNode(String topic) {
    _eventsNode[topic]?.dispose();
    _eventsNode.remove(topic);
    // clearNotUseListeners();
  }

  ///Очищает узлы события если в них нет слушателей и обработчиков
  void clearNotUseListeners() {
    List<String> toDel = [];
    for (var key in _eventsNode.keys) {
      var element = _eventsNode[key]!;
      if (!element.hasListener && !element.hasHandler) {
        toDel.add(key);
      }
    }
    // _eventsNode.forEach((key, value) {
    //   if (!value.hasListener && !value.hasHandler) {
    //     toDel.add(key);
    //   }
    // });
    for (var element in toDel) {
      _eventsNode[element]?.dispose();
      _eventsNode.remove(element);
    }
  }

  @override
  void addHandler<T>(EventHandler<T> handler, {String? eventName}) {
    final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: prefix);
    if (!_eventsNode.containsKey(topic)) {
      _eventsNode[topic] = EventNode<T>(topic, handler, this, eventName: eventName, onCancel: _cancelEventNode);
      return;
    }
    var t = _eventsNode[topic] as EventNode<T>;
    t._handler = handler;
  }

  @override
  void removeHandler<T>({String? eventName}) {
    final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: prefix);
    if (_eventsNode.containsKey(topic)) {
      var t = _eventsNode[topic] as EventNode<T>;
      t._handler = null;
    }
  }

  @override
  void setLogger({void Function(String)? cb, String format = '#d #t--#u--#s', DateFormat? dateFormat}) {
    if (cb != null) {
      _logger = _Logger(cb, format: format, dateFormat: dateFormat);
    } else {
      _logger = null;
    }
  }

  @override
  void setUUIDGenerator({String Function(String topic)? uuidGenerator}) {
    _uuid = _UUIDGenerator(uuidGenerator: uuidGenerator);
  }
}

///This class always have inner listener if you send a event
///This class contain last event data and can use how temporary data holder with change notifications
class EventModelController extends EventController {
  EventModelController({
    String? prefix,
  }) : super(prefix: prefix);
  @override
  bool send<T>(T event,
      {String? eventName,
      String? uuid,
      String? prefix,
      Duration? afterTime,
      Stream? afterEvent,
      Future? afterThis,
      bool needLog = true}) {
    if (!contain<T>(eventName)) {
      listenEventDTO<T>(eventName: eventName);
    }
    return super.send<T>(event,
        eventName: eventName,
        uuid: uuid,
        prefix: prefix,
        afterEvent: afterEvent,
        afterTime: afterTime,
        afterThis: afterThis,
        needLog: needLog);
  }

  @override
  void _cancelEventNode(String topic) {
    // _eventsNode[topic]?.dispose();
    // _eventsNode.remove(topic);
    // clearNotUseListeners();
  }
  bool clearModel<T>({String? eventName}) {
    final topic = EventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: prefix);
    var node = _eventsNode[topic];
    if (node != null) {
      node.dispose();
      _eventsNode.remove(topic);
      return true;
    }
    return false;
  }

  @override
  void clearNotUseListeners() {
    // super.clearNotUseListeners();
  }
}
