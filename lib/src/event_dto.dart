part of event_arch;

abstract class EventDTO<T> {
  Topic get topic;
  T get data;

  ///completed with null after call handler, if not completed in handler
  Completer? get completer;

  static EventDTO<T> create<T>(T data,
      {String? target, String? path, Map<String, String>? arguments, String? fragment, Completer? completer}) {
    return EventDTO<T>(data,
        target: target, path: path, completer: completer, fragment: fragment, arguments: arguments);
  }

  factory EventDTO(T data,
      {Topic? topic,
      String? target,
      String? path,
      Map<String, String>? arguments,
      String? fragment,
      Completer? completer}) {
    return EventDTOImpl<T>(
        topic ?? Topic.create<T>(target: target, path: path, fragment: fragment, arguments: arguments), data,
        completer: completer
        /* route*/
        );
  }
  Map<String, dynamic> toJson();
}

class EventDTOImpl<T> implements EventDTO<T> {
  @override
  Topic topic;
  @override
  T data;
  @override
  Completer? completer;

  @override
  EventDTOImpl(this.topic, this.data, {Completer? completer}) : completer = completer;
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EventDTOImpl<T> && other.topic == topic && other.data == data;
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

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json, {T Function(String topic, dynamic data)? dataConverter}) {
    return EventDTOImpl<T>(Topic.parse(json['topic']),
        dataConverter != null ? dataConverter.call(json['topic'], json['data']) : json['data']);
  }
}
