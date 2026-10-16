part of event_arch;

abstract class EventDTO<T> {
  Topic get topic;
  T get data;
  Map<String, String>? get arguments;
  ///completed with null after call handler, if not completed in handler.
  ///If the handler throws, the completer is completed with that error.
  Completer? get completer;

  static EventDTO<T> create<T>(T data,
      {List<String>? paths, Map<String, String>? arguments, Completer? completer}) {
    return EventDTO<T>(data,
        paths: paths, completer: completer, arguments: arguments);
  }

  factory EventDTO(T data,
      {
      Topic? topic,
      List<String>? paths,
      Map<String, String>? arguments,
      String? separator,
      Completer? completer}) {
    return EventDTOImpl<T>(
        topic ?? Topic.create<T>(paths: paths, separator: separator??'.' ), data,
        completer: completer,
        arguments:arguments,
        /* route*/
        );
  }

  ///Event representation for logs and serialization.
  ///Data is returned as is: encoding is up to the caller, so an arbitrary
  ///object in [data] no longer breaks the method.
  Map<String, dynamic> toJson();
}

class EventDTOImpl<T> implements EventDTO<T> {
  @override
  Topic topic;
  @override
  T data;
  @override
  Completer? completer;
  Map<String, String>? arguments;
  EventDTOImpl(this.topic, this.data, {this.completer,this.arguments});
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EventDTOImpl<T> && other.topic == topic && other.data == data;
  }

  @override
  int get hashCode => Object.hashAll([topic, data]);

  @override
  String toString() {
    return 'EventDTO(${topic.topic}, data: $data)';
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'topic': topic.topic,
      'data': data,
    };
  }

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json, {T Function(String topic, dynamic data)? dataConverter}) {
    return EventDTOImpl<T>(Topic.parse(json['topic']),
        dataConverter != null ? dataConverter.call(json['topic'], json['data']) : json['data']);
  }
}
