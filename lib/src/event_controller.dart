import 'dart:async';

import 'package:dart_event_bus/src/event_dto.dart';
import 'package:dart_event_bus/src/event_master.dart';
import 'package:equatable/equatable.dart';

import 'package:uuid/uuid.dart';

class EventBusTopic extends Equatable {
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
    String? _eventTypeAndName = name != null ? '$type${EventBusTopic.divider}$name' : '$type';
    if (prefix != null) {
      topic = '$prefix${EventBusTopic.divider}$_eventTypeAndName';
    } else {
      topic = _eventTypeAndName;
    }
  }
  @override
  // TODO: implement props
  List<Object?> get props => [topic];
}

abstract class IEventNode<T> implements EventBusTopic {
  IEventBus get bus;
  Future<void> repeat({String? uuid});
  T? lastEvent();
}

abstract class EventBusHandlersGroup {
  bool get isConnected;

  ///Handler class must addHandler to bus
  void connect(IEventBusHandler bus);

  ///Handler class must removeHandler from bus
  void disconnect(IEventBusHandler bus);
}

abstract class IEventBus {
  /// Префикс контроллера
  String? get prefix;
  Type get type;

  /// проверяет есть ли те кто слушают событие
  bool contain<T>(String? eventName);

  ///вернет true если есть те кто слушает событие
  ///if uuid not set be use default uuid
  ///if prefix set - event send to EventMaster.
  ///You can use for example send(10) -> event topic = int
  bool send<T>(T event, {String? eventName, String? uuid, String? prefix});

  ///repeat last event by topic
  bool repeat<T>({String? eventName, String? uuid, String? prefix});

  ///Возвращает поток события. Если нужно повторить предыдуще событие используйте [repeatLastEvent]
  ///if prefix set - event listen from EventMaster
  ///can return null only if prefix set
  Stream<EventDTO<T>>? listenEventDTO<T>({String? eventName, bool repeatLastEvent = false, String? prefix});

  ///Возвращает поток события. Если нужно повторить предыдуще событие используйте [repeatLastEvent]
  ///if prefix set - event listen from EventMaster
  ///can return null only if prefix set
  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix});

  ///Возвращает значение последнего события если нам не нужно постоянное обновлеине
  T? lastEvent<T>({String? eventName, String? prefix});

  ///создает уникальный топик события
  static String topicCreate(Type type, {String? eventName, String? prefix}) {
    String? _eventTypeAndName = eventName != null ? '${type}${EventBusTopic.divider}$eventName' : '$type';
    if (prefix != null) return '$prefix${EventBusTopic.divider}$_eventTypeAndName';

    return _eventTypeAndName;
  }
  // static  final tes1 = topicCreate(10.runtimeType, eventName: 'Test');

}

typedef EventEmitter<T> = void Function(T data);

///if need notify about event call emit
typedef EventHandler<T> = Future<void> Function(
  EventDTO<T> event,

  ///send event to other listener
  EventEmitter<EventDTO<T>>? emit, {
  IEventBus? bus,
});

abstract class IEventBusHandler {
  void addHandler<T>(EventHandler<T> handler, {String? eventName});
  void removeHandler<T>({String? eventName});
  void connect(EventBusHandlersGroup externHandlers);
  void disconnect(EventBusHandlersGroup externHandlers);
}

class EventNode<T> extends EventBusTopic {
  // final String topic;
  final String? eventName;
  final IEventBus _bus;
  IEventBus get bus => _bus;
  Stream<EventDTO<T>> get stream => _streamController.stream;
  bool get hasListener => _streamController.hasListener;
  bool get hasHandler => _handler != null;
  bool _isDispose = false;
  bool get isDispose => _isDispose;
  late final StreamController<EventDTO<T>> _streamController;
  EventHandler<T>? _handler;
  Function(String topic)? onCancel;
  T? lastEvent;

  EventNode(
    String topic,
    this._handler,
    this._bus, {
    this.eventName,
    this.onCancel,
  }) : super.parse(topic) {
    _streamController = StreamController<EventDTO<T>>.broadcast(onCancel: _onCancel);
  }
  Future<void> call(EventDTO<T> event, {bool isRepeat = false}) async {
    if (!_isDispose) {
      lastEvent = event.data;
      if (_handler != null) {
        _handler!.call(event, (event) {
          if (_streamController.hasListener) {
            // if (needLogging) _logging(event, 'send');
            _streamController.add(event);
          } else {
            // if (needLogging) _loggingHasNoListener(event.topic, 'send');
          }
        }, bus: bus);
      } else {
        if (_streamController.hasListener) {
          // if (needLogging) _logging(event, 'send');
          _streamController.add(event);
        } else {
          // if (needLogging) _loggingHasNoListener(event.topic, 'send');
        }
        // _streamController.hasListener ? _streamController.add(event) : null;
      }
    }
  }

  Future<void> repeat({String? uuid}) async {
    String u = '';
    if (lastEvent != null) {
      if (uuid != null) {
        u = uuid;
      } else {
        u = Uuid().v1();
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

class EventController implements IEventBus, IEventBusHandler {
  String? _prefix;
  String? get prefix => _prefix;
  Map<String, EventNode> _eventsNode = {};
  Type get type => runtimeType;

  ///This handler use for event what not have special handler but hasListener.
  ///use bus for
  EventHandler? defaultHandler;

  EventController({String? prefix, this.defaultHandler}) : _prefix = prefix {
    EventBusMaster.instance.add(this);
  }
  void connect(EventBusHandlersGroup externHandlers) {
    externHandlers.connect(this);
  }

  void disconnect(EventBusHandlersGroup externHandlers) {
    externHandlers.disconnect(this);
  }

  bool contain<T>(String? eventName) {
    final _topic = IEventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: prefix);
    return _eventsNode.containsKey(_topic);
  }

  T? lastEvent<T>({String? eventName, String? prefix}) {
    if (prefix == null || prefix == this.prefix) {
      final _topic = IEventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      return _eventsNode[_topic]?.lastEvent;
    } else {
      return EventBusMaster.instance.lastEvent<T>(eventName: eventName, prefix: prefix);
    }
  }

  // bool sendToTopic(String topic, dynamic data) {}
  bool send<T>(T event, {String? eventName, String? uuid, String? prefix}) {
    if (prefix == null || prefix == this.prefix) {
      final topic = IEventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      if (_eventsNode.containsKey(topic)) {
        _eventsNode[topic]!.call(EventDTO<T>(topic, event, uuid ?? Uuid().v1()));
        return true;
      }
      return false;
    } else {
      return EventBusMaster.instance.send<T>(event, eventName: eventName, uuid: uuid, prefix: prefix);
    }
  }

  bool repeat<T>({String? eventName, String? uuid, String? prefix}) {
    if (prefix == null || prefix == this.prefix) {
      final topic = IEventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      var s = _eventsNode[topic];
      if (s != null) {
        s.repeat(uuid: uuid);
        return true;
      }
    } else {
      return EventBusMaster().repeat(eventName: eventName, uuid: uuid, prefix: prefix);
    }
    return false;
  }

  //Can return null only if set prefix != controller.prefix and EventBusMaster no have controller with this prefix
  Stream<T>? listenEvent<T>({String? eventName, bool repeatLastEvent = false, String? prefix}) {
    return listenEventDTO<T>(eventName: eventName, prefix: prefix, repeatLastEvent: repeatLastEvent)
        ?.map((event) => event.data!);
  }

  //Can return null only if set prefix != controller.prefix and EventBusMaster no have controller with this prefix
  Stream<EventDTO<T>>? listenEventDTO<T>({String? eventName, bool repeatLastEvent = false, String? prefix}) {
    if (prefix == null || prefix == this.prefix) {
      final topic = IEventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: this.prefix);
      var s = _eventsNode[topic];
      if (s == null) {
        _eventsNode[topic] = EventNode<T>(
            topic,
            defaultHandler != null
                ? (event, emit, {bus}) async {
                    defaultHandler!.call(event, (data) {
                      emit?.call(data as EventDTO<T>);
                    }, bus: bus);
                  }
                : null,
            this,
            eventName: eventName,
            onCancel: _cancelEventNode);
      }

      if (repeatLastEvent) {
        _eventsNode[topic]?.repeat();
      }
      return _eventsNode[topic]!.stream as Stream<EventDTO<T>>;
    } else {
      return EventBusMaster.instance
          .listenEventDTO<T>(eventName: eventName, prefix: prefix, repeatLastEvent: repeatLastEvent);
    }
  }

  void _cancelEventNode(String topic) {
    clearNotUseListeners();
  }

  ///Очищает узлы события если в них нет слушателей и обработчиков
  void clearNotUseListeners() {
    List<String> toDel = [];
    _eventsNode.forEach((key, value) {
      if (!value.hasListener && !value.hasHandler) {
        toDel.add(key);
      }
    });
    toDel.forEach((element) {
      _eventsNode[element]?.dispose();
      _eventsNode.remove(element);
    });
  }

  ///Добавляет обработчик к узлу.
  void addHandler<T>(EventHandler<T> handler, {String? eventName}) {
    final topic = IEventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: prefix);
    if (!_eventsNode.containsKey(topic)) {
      _eventsNode[topic] = EventNode<T>(topic, handler, this, eventName: eventName, onCancel: _cancelEventNode);
      return;
    }
    var t = _eventsNode[topic] as EventNode<T>;
    t._handler = handler;
  }

  void removeHandler<T>({String? eventName}) {
    final topic = IEventBus.topicCreate(T..runtimeType, eventName: eventName, prefix: prefix);
    if (_eventsNode.containsKey(topic)) {
      var t = _eventsNode[topic] as EventNode<T>;
      t._handler = null;
    }
  }
}

///This class always have inner listener if you send a event
///This class contain last event data and can use how temporary data holder with change notifications
class EventModelController extends EventController {
  EventModelController({
    String? prefix,
  }) : super(prefix: prefix);
  @override
  bool send<T>(T event, {String? eventName, String? uuid, String? prefix}) {
    if (!contain<T>(eventName)) {
      listenEventDTO<T>(eventName: eventName);
    }
    return super.send<T>(event, eventName: eventName, uuid: uuid, prefix: prefix);
  }

  @override
  void clearNotUseListeners() {
    // TODO: implement clearNotUseListeners
    // super.clearNotUseListeners();
  }
}
