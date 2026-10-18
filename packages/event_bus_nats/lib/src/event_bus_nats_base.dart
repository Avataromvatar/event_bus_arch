// TODO: Put public facing types in this file.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_nats/dart_nats.dart' as NATS;
// import 'package:dart_nats/src/platform/platform_stub.dart' as NATS_P;
import 'package:event_bus_arch/event_bus_arch.dart';


///(topic?,data) if topic not set whey taked from dto.topic.topic 
typedef EventDTOSerialization = ( String?,Uint8List) Function(EventDTO dto);

typedef EventDTODeserialization =
    EventDTO Function(Uint8List data, String topic);

class EventNodeNatsImpl<T> implements EventNode<T> {
  NATS.Client client;
  @override
  Handler<T>? handler;

  @override
  T? currentData;
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
  Map<String, EventDTOSerialization> _serializator = {};
  Map<String, EventDTODeserialization> _deserializator= {};
  late NATS.Client client;
  late StreamSubscription<NATS.Status> subscriptionStatus;
  Exception? _extension;
  EventBusNats(Uri natsServer,{SecurityContext? security, Map<String, EventDTOSerialization>? serializator,Map<String, EventDTODeserialization>?deserializator})
  {
    
    client =NATS.Client();
    subscriptionStatus =  client.statusStream.listen(_updateClientStatus);
    client.connect(natsServer,pingInterval: Duration(seconds: 5),/*securityContext: security*/);

  }

  void _updateClientStatus(NATS.Status status)
  {

  }

  @override
  EventNode<T> createNode<T>({T? currentData, Handler<T>? handler}) {
    return EventNodeNatsImpl(currentData: currentData, handler: handler);
  }
}
