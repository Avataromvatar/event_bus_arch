part of event_arch;
// import 'package:event_bus_arch/event_bus_arch.dart';
// import 'package:event_bus_arch/src/topic.dart';

typedef Executor<T> = Future<dynamic> Function(Topic topic, {T? data, T? oldData});

///if binded with EventBus use EventBus.call if bus contain topic
abstract class Command<T> implements EventDTO<T> {
  bool get isBinded;

  bool get undoOn;
  Executor<T>? get executorBinded;
  EventBus? get eventBusBinded;

  bool get canUndo;
  Future<dynamic> undo();

  ///if executor == null this Command send how Event to EventBus
  ///if executer and EventBus not binded throw Exeption
  Future<dynamic> execute({
    T? newData,
  });
  Command<T> copy({T? newData, Executor<T>? newExecutorBinded, EventBus? newEventBusBinded});
  EventDTO createEvent();
  static Command<T> create<T>(
      {T? data, String? target, String? path, Executor<T>? executorBinded, EventBus? eventBusBinded}) {
    return Command<T>(Topic.create<T>(path: path, target: target),
        data: data, eventBusBinded: eventBusBinded, executorBinded: executorBinded);
  }

  factory Command(Topic topic, {T? data, Executor<T>? executorBinded, EventBus? eventBusBinded, bool undoOn = true}) {
    return CommandImpl(topic,
        data: data, eventBusBinded: eventBusBinded, executorBinded: executorBinded, undoOn: undoOn);
  }
}

class CommandImpl<T> implements Command<T> {
  final int maxLenUndo;
  CommandImpl(this.topic,
      {this.data, this.eventBusBinded, this.executorBinded, this.undoOn = true, this.maxLenUndo = 10});
  @override
  final Executor<T>? executorBinded;

  @override
  bool get isBinded => executorBinded != null || eventBusBinded != null;

  @override
  late final Topic topic;

  @override
  T? data;
  @override
  late final bool undoOn;
  @override
  bool get canUndo => _list.isNotEmpty;
  final List<T?> _list = [];
  @override
  final EventBus? eventBusBinded;

  bool _blockUndoAdd = false;

  @override
  Future<dynamic> execute({
    T? newData,
  }) {
    if (!isBinded) {
      throw Exception('Command $topic not binded ');
    }
    var d = newData ?? data;

    //----- Undo section
    if (undoOn && !_blockUndoAdd) {
      if (_list.isNotEmpty) {
        if (_list.last != data) {
          _list.add(data);
          if (_list.length > maxLenUndo) {
            _list.removeAt(0);
          }
        }
      } else {
        _list.add(d);
      }
    }
    //----- execute section
    var ex = executorBinded;
    if (ex != null) {
      var ret = ex.call(topic, data: d, oldData: newData != null ? data : null);
      data = d;
      return ret;
    } else {
      var bus = eventBusBinded;
      var ret = bus!.call<T>(d as T, path: topic.path);
      data = d;
      return ret;
    }
  }

  @override
  Future<dynamic> undo() async {
    if (undoOn && canUndo) {
      var d = _list.removeLast();
      _blockUndoAdd = true;
      var ret = execute(newData: d);
      _blockUndoAdd = false;
      return ret;
    }
  }

  @override
  Command<T> copy({T? newData, Executor<T>? newExecutorBinded, EventBus? newEventBusBinded}) {
    return Command(topic,
        data: newData ?? data,
        eventBusBinded: newEventBusBinded ?? eventBusBinded,
        executorBinded: newExecutorBinded ?? executorBinded);
  }

  @override
  EventDTO createEvent() {
    return EventDTO(topic, data);
  }

  @override
  String toString() {
    // TODO: implement toString
    return '$topic  Data:$data';
  }
}
