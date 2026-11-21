part of event_arch;

///One event: its topic, the data, the call arguments and an optional
///correlation id.
abstract class EventDTO<T> {
  Topic get topic;
  T get data;
  Map<String, String>? get arguments;

  ///An optional id that ties an event and every event caused by it together.
  ///It crosses isolate and transport boundaries but is never required.
  String? get correlationId;

  ///A copy with some fields replaced. A null argument keeps the current value,
  ///so a correlation id cannot be cleared with this method.
  EventDTO<T> copyWith(
      {T? data,
      Topic? topic,
      Map<String, String>? arguments,
      String? correlationId});

  static EventDTO<T> create<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      String? correlationId}) {
    return EventDTO<T>(data,
        paths: paths,
        separator: separator,
        arguments: arguments,
        correlationId: correlationId);
  }

  factory EventDTO(T data,
      {Topic? topic,
      List<String>? paths,
      Map<String, String>? arguments,
      String? separator,
      String? correlationId}) {
    return EventDTOImpl<T>(
      topic ?? Topic.create<T>(paths: paths, separator: separator ?? '.'),
      data,
      arguments: arguments,
      correlationId: correlationId,
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
  Map<String, String>? arguments;
  @override
  final String? correlationId;
  EventDTOImpl(this.topic, this.data,
      {this.arguments, this.correlationId});

  @override
  EventDTO<T> copyWith(
      {T? data,
      Topic? topic,
      Map<String, String>? arguments,
      String? correlationId}) {
    return EventDTOImpl<T>(
      topic ?? this.topic,
      data ?? this.data,
      arguments: arguments ?? this.arguments,
      correlationId: correlationId ?? this.correlationId,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EventDTOImpl<T> &&
        other.topic == topic &&
        other.data == data;
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
      if (correlationId != null) 'correlationId': correlationId,
    };
  }

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json,
      {T Function(String topic, dynamic data)? dataConverter}) {
    return EventDTOImpl<T>(
        Topic.parse(json['topic']),
        dataConverter != null
            ? dataConverter.call(json['topic'], json['data'])
            : json['data'],
        correlationId: json['correlationId'] as String?);
  }
}
