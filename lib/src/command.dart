part of event_arch;

abstract class Command<T> {
  static const int maxLen = 10;
  Future<dynamic> execute(T data, {String? fragment, Map<String, String>? arguments});
  Future<dynamic> undo();
  factory Command(EventBus busBinded, {String? path}) {
    return CommandImpl(busBinded, path: path);
  }
}

class CommandImpl<T> implements Command<T> {
  final EventBus _bus;
  final String? _path;

  ///data, argument, fragment
  Queue<(T, Map<String, String>?, String?)> _queue = Queue();

  CommandImpl(this._bus, {String? path}) : _path = path;
  Future<dynamic> execute(T data, {String? fragment, Map<String, String>? arguments}) async {
    if (Command.maxLen <= _queue.length) {
      _queue.removeFirst();
    }
    _queue.add((data, arguments, fragment));
    return _bus.send<T>(data, path: _path, arguments: arguments, fragment: fragment);
  }

  Future<dynamic> undo() async {
    if (_queue.isNotEmpty) {
      var last = _queue.removeLast();
      return _bus.send<T>(last.$1, path: _path, arguments: last.$2, fragment: last.$3);
    }
  }
}

// // import 'package:event_bus_arch/event_bus_arch.dart';
// // import 'package:event_bus_arch/src/topic.dart';

// typedef Executor<T> = Future<dynamic> Function(Topic topic, {T? data, T? oldData});

// ///if binded with EventBus use EventBus.call if bus contain topic
// abstract class Command<T> implements EventDTO<T> {
//   bool get isBinded;

//   bool get undoOn;
//   Executor<T>? get executorBinded;
//   EventBus? get eventBusBinded;

//   bool get canUndo;
//   Future<dynamic> undo();

//   ///if executor == null this Command send how Event to EventBus
//   ///if executer and EventBus not binded throw Exeption
//   Future<dynamic> execute({T? newData, String? fragment, Map<String, String>? arguments});
//   Future<void> send({T? newData, String? fragment, Map<String, String>? arguments});
//   Command<T> copy({T? newData, Executor<T>? newExecutorBinded, EventBus? newEventBusBinded});
//   EventDTO createEvent();
//   static Command<T> create<T>(
//       {T? data, String? target, String? path, Executor<T>? executorBinded, EventBus? eventBusBinded}) {
//     return Command<T>(Topic.create<T>(path: path, target: target),
//         data: data, eventBusBinded: eventBusBinded, executorBinded: executorBinded);
//   }

//   factory Command(Topic topic, {T? data, Executor<T>? executorBinded, EventBus? eventBusBinded, bool undoOn = true}) {
//     return CommandImpl(topic,
//         data: data, eventBusBinded: eventBusBinded, executorBinded: executorBinded, undoOn: undoOn);
//   }
//   Map<String, dynamic> toJson();
//   factory Command.fromMap(
//     Map<String, dynamic> json,
//     T? Function(dynamic data) dataFromJson, {
//     bool? undoOn,
//     int? maxLenUndo,
//     T? data,
//     EventBus? eventBusBinded,
//     Executor? executorBinded,
//   }) {
//     return CommandImpl.fromJson(json, dataFromJson,
//         undoOn: undoOn,
//         data: data,
//         eventBusBinded: eventBusBinded,
//         executorBinded: executorBinded,
//         maxLenUndo: maxLenUndo);
//   }
// }

// class CommandImpl<T> implements Command<T> {
//   final int maxLenUndo;
//   CommandImpl(this.topic,
//       {this.data, this.eventBusBinded, this.executorBinded, this.undoOn = true, this.maxLenUndo = 10});
//   factory CommandImpl.fromJson(
//     Map<String, dynamic> json,
//     T? Function(dynamic data) dataFromJson, {
//     bool? undoOn,
//     int? maxLenUndo,
//     T? data,
//     EventBus? eventBusBinded,
//     Executor? executorBinded,
//   }) {
//     var d = json['data'];

//     return CommandImpl(Topic.parse(json['topic']),
//         data: data ?? (d != null ? dataFromJson(d) : null),
//         maxLenUndo: maxLenUndo ?? json['maxLenUndo'] ?? 10,
//         undoOn: undoOn ?? json['undoOn'] ?? true);
//   }
//   @override
//   final Executor<T>? executorBinded;

//   @override
//   bool get isBinded => executorBinded != null || eventBusBinded != null;

//   @override
//   late final Topic topic;

//   @override
//   T? data;
//   @override
//   late final bool undoOn;
//   @override
//   bool get canUndo => _list.length > 1;
//   final List<EventDTO<T?>> _list = [];
//   @override
//   final EventBus? eventBusBinded;

//   bool _blockUndoAdd = false;
//   @override
//   Future<bool> send({T? newData, String? fragment, Map<String, String>? arguments}) async {
//     if (!isBinded) {
//       throw EventBusException('Command $topic not binded ');
//     }
//     var d = EventDTO(topic.copy(fragment: fragment, arguments: arguments), newData ?? data);
//     _undoAddLogic(d);
//     var eb = eventBusBinded;
//     if (eb != null) {
//       if (eb.sendEvent<T>(event: d) != null) {
//         return true;
//       }
//     } else {
//       var ret = executorBinded!.call(topic.copy(fragment: fragment, arguments: arguments),
//           data: d.data, oldData: newData != null ? data : null);
//       return true;
//     }
//     return false;
//   }

//   void _undoAddLogic(EventDTO<T> event) {
//     //----- Undo section
//     if (undoOn && !_blockUndoAdd) {
//       if (_list.isNotEmpty) {
//         if (_list.last != event) {
//           _list.add(event);
//           if (_list.length > maxLenUndo) {
//             _list.removeAt(0);
//           }
//         }
//       } else {
//         _list.add(event);
//       }
//     }
//   }

//   @override
//   Future<dynamic> execute({T? newData, String? fragment, Map<String, String>? arguments}) {
//     if (!isBinded) {
//       throw EventBusException('Command $topic not binded ');
//     }

//     var d = EventDTO(topic.copy(fragment: fragment, arguments: arguments), newData ?? data);
//     _undoAddLogic(d);

//     //----- execute section
//     var ex = executorBinded;
//     if (ex != null) {
//       var ret = ex.call(topic.copy(fragment: fragment, arguments: arguments),
//           data: d.data, oldData: newData != null ? data : null);

//       return ret;
//     } else {
//       var bus = eventBusBinded;
//       var ret = bus!.call<T>(d.data as T, path: topic.path, fragment: fragment, arguments: arguments);

//       return ret;
//     }
//   }

//   @override
//   Future<dynamic> undo() async {
//     if (undoOn && canUndo) {
//       /*var current =*/ _list.removeLast();
//       var last = _list.removeLast();
//       _blockUndoAdd = true;
//       var ret = execute(newData: last.data, fragment: last.topic.fragment, arguments: last.topic.arguments);
//       _blockUndoAdd = false;
//       return ret;
//     }
//   }

//   @override
//   Command<T> copy({T? newData, Executor<T>? newExecutorBinded, EventBus? newEventBusBinded}) {
//     return Command(topic,
//         data: newData ?? data,
//         eventBusBinded: newEventBusBinded ?? eventBusBinded,
//         executorBinded: newExecutorBinded ?? executorBinded);
//   }

//   @override
//   EventDTO createEvent() {
//     return EventDTO(topic, data);
//   }

//   @override
//   String toString() {
//     return jsonEncode(toJson());
//   }

//   Map<String, dynamic> toJson() {
//     return {
//       'topic': topic.fullTopic,
//       'data': data != null ? jsonEncode(data) : null,
//       'maxLenUndo': maxLenUndo,
//       'undoOn': undoOn,
//     };
//   }
// }
