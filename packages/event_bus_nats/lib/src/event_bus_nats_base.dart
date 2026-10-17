// TODO: Put public facing types in this file.

import 'dart:async';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

//Serialization. Deserialization
typedef EventDTOSerialization = (Uint8List, String?) Function(EventDTO dto);
typedef EventDTODeserialization =
    EventDTO Function(Uint8List data, String topic);

class EventNodeNatsImpl<T> implements EventNode<T> {
  @override
  Handler<T>? handler;

  @override
  T? lastData;
  @override
  // TODO: implement isDisposed
  bool get isDisposed => throw UnimplementedError();

  @override
  // TODO: implement isHaveHandler
  bool get isHaveHandler => throw UnimplementedError();

  @override
  EventNode<T> copy() {
    // TODO: implement copy
    throw UnimplementedError();
  }

  @override
  Future<void> dispose() {
    // TODO: implement dispose
    throw UnimplementedError();
  }

  @override
  void send(EventDTO<dynamic> dto) {
    // TODO: implement send
  }

  @override
  // TODO: implement streamControllerValue
  StreamController<T> get streamControllerValue => throw UnimplementedError();
}

class EventBusNats with EventBusMixin {
  Map<String, EventDTOSerialization> serializator;
  Map<String, EventDTODeserialization> deserializator;
}
