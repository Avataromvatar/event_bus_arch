abstract class EventDTO<T> {
  String get topic;
  T get data;
  String get uuid;
  EventDTO<T> copy({String? topic, T? data, String? uuid});
  factory EventDTO(String topic, T data, String uuid) {
    return BasicEventDTO<T>(topic, data, uuid);
  }
}

class BasicEventDTO<T> implements EventDTO<T> {
  @override
  String topic;
  @override
  T data;
  @override
  String uuid;
  BasicEventDTO(this.topic, this.data, this.uuid);
  @override
  EventDTO<T> copy({String? topic, T? data, String? uuid}) {
    return BasicEventDTO(topic ?? this.topic, data ?? this.data, uuid ?? this.uuid);
  }
}
