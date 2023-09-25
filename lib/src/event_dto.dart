part of event_arch;
// / import 'package:event_bus_arch/event_bus_arch.dart';
// import 'package:event_bus_arch/src/command.dart';
// import 'package:event_bus_arch/src/topic.dart';

// abstract class EventData<T> {
//   Topic get topic;
//   T get data;
// }

abstract class EventDTO<T> {
  Topic get topic;
  T? get data;
  //--------
  ///all bus save self name in this field for check many resend for EventBusStream.
  ///when send(event)  _traversedPath clear
  List<String> get _traversedPath;
  void _clearTraversedPath();

  bool _checkTraversedPath(String name);

  void _addTraversedPath(String name);

  //---------
  // List<Topic> get route;
  static EventDTO<T> copy<T>(
    EventDTO<T> event, {
    Topic? topic,
    T? newData,
    /*List<Topic>? route*/
  }) {
    return EventDTO<T>(topic: topic ?? event.topic, data: newData ?? event.data);
  }

  // static Command<T> createCommand<T>(EventDTO<T> dto, {Executor<T>? executor, EventBus? eventBus}) {
  //   return Command<T>(dto.topic, data: dto.data, executorBinded: executor, eventBusBinded: eventBus);
  // }

  // link new event and parent event
  // EventDTO<R> next<R>(
  //   Topic topic,
  //   R data,
  // ) {

  // }

  static EventDTO<T> create<T>(T data, {String? target, String? path, Map<String, String>? arguments, String? fragment

      //List<Topic>? route,
      }) {
    return EventDTO<T>(
        data: data,
        target: target,
        path: path,
        /* route: route*/
        fragment: fragment,
        arguments: arguments);
  }

// factory EventDTO(
//     Topic topic,
//     T? data,
//   ) {
//     return EventDTOImpl<T>(
//       topic,
//       data, /* route*/
//     );
//   }
  factory EventDTO({
    Topic? topic,
    String? target,
    String? path,
    Map<String, String>? arguments,
    String? fragment,
    T? data,
  }) {
    return EventDTOImpl<T>(
      topic ?? Topic.create<T>(target: target, path: path, fragment: fragment, arguments: arguments),
      data, /* route*/
    );
  }
  // factory EventDTO.fromType(Type type, T data,
  //     {String? target, String? path, Map<String, String>? arguments, String? fragment
  //     //List<Topic>? route,
  //     }) {
  //   return EventDTOImpl<T>(
  //     Topic.fromParametr(type: type, target: target, path: path, fragment: fragment, arguments: arguments),
  //     data, /*route*/
  //   );
  // }
}

// class ChainEventDTO<T> extends EventDTOImpl<T> {
//   ChainEventDTO(super.topic, super.data);
// }

class EventDTOImpl<T> implements EventDTO<T> {
  @override
  Topic topic;
  @override
  T? data;
  @override
  List<String> _traversedPath = [];
  // @override
  // List<Topic>? route;
  EventDTOImpl(
    this.topic,
    this.data,
    /* this.route*/
  );
  factory EventDTOImpl.fromJson(
    Map<String, dynamic> json,
    T? Function(dynamic data) dataFromJson, {
    T? data,
  }) {
    var d = json['data'];
    return EventDTOImpl(Topic.parse(json['topic']), d != null ? dataFromJson(json['data']) : null);
  }
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EventDTOImpl<T> && other.topic == topic && other.data == data;
  }

  @override
  void _clearTraversedPath() {
    _traversedPath.clear();
  }

  @override
  bool _checkTraversedPath(String name) {
    return _traversedPath.contains(name);
  }

  @override
  void _addTraversedPath(String name) {
    _traversedPath.add(name);
  }

  @override
  int get hashCode => Object.hashAll([topic, data]);

  @override
  String toString() {
    return jsonEncode(toJson());
  }

  Map<String, dynamic> toJson() {
    return {
      'topic': topic.fullTopic,
      'data': data != null ? jsonEncode(data) : null,
    };
  }
}
