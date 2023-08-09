import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:uuid/uuid.dart';

// abstract class Command<T> {
//   String get topic;
//   T get data;
//   Function
//   void execute({T newData});
//   factory Command() {}
// }

abstract class EventDTO<T> {
  String get topic;
  T get data;
  String? get uuid;
  EventDTO<T> copy({String? topic, T? data, String? uuid});
  factory EventDTO(String topic, T data, {String? uuid}) {
    return BasicEventDTO<T>(topic, data, uuid);
  }
  factory EventDTO.fromType(
    Type type,
    T data, {
    String? prefix,
    String? name,
    String? uuid,
  }) {
    return BasicEventDTO<T>(EventBus.topicCreate(type, eventName: name, prefix: prefix), data, uuid ?? Uuid().v1());
  }
}

class BasicEventDTO<T> implements EventDTO<T> {
  @override
  String topic;
  @override
  T data;
  @override
  String? uuid;
  BasicEventDTO(this.topic, this.data, this.uuid);
  @override
  EventDTO<T> copy({String? topic, T? data, String? uuid}) {
    return BasicEventDTO(topic ?? this.topic, data ?? this.data, uuid ?? this.uuid);
  }
}

// class EventDTOCommand<T> extends BasicEventDTO<T> implements Command<T> {
//   EventDTOCommand(super.topic,super.data,)
//   @override
//   void execute({T newData}) {
//     // TODO: implement execute
//   }
// }
