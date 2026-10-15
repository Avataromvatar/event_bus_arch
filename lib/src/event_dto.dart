part of event_arch;

abstract class EventDTO<T> {
  Topic get topic;
  T get data;

  ///completed with null after call handler, if not completed in handler.
  ///If the handler throws, the completer is completed with that error.
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

  EventDTOImpl(this.topic, this.data, {this.completer});
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EventDTOImpl<T> && other.topic == topic && other.data == data;
  }

  @override
  int get hashCode => Object.hashAll([topic, data]);

  @override
  String toString() {
    return 'EventDTO(${topic.fullTopic}, data: $data)';
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'topic': topic.fullTopic,
      'data': data,
    };
  }

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json, {T Function(String topic, dynamic data)? dataConverter}) {
    return EventDTOImpl<T>(Topic.parse(json['topic']),
        dataConverter != null ? dataConverter.call(json['topic'], json['data']) : json['data']);
  }
}
