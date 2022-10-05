import 'package:dart_event_bus/dart_event_bus.dart';

class TestEventHandlerGroup implements EventBusHandlersGroup {
  IEventBusHandler? _bus;
  @override
  // TODO: implement isConnected
  bool get isConnected => _bus != null;
  @override
  void connect(IEventBusHandler bus) {
    _bus = bus;
    bus.addHandler<int>(plusNoEmit, eventName: 'no_emit');
    bus.addHandler<int>(plusEmit, eventName: 'emit');
  }

  @override
  void disconnect(IEventBusHandler bus) {
    // TODO: implement disconnect
  }
  Future<void> plusNoEmit(EventDTO<int> event, EventEmitter<EventDTO<int>>? emit, {IEventBus? bus}) async {
    print('plusNoEmit: ${event.data + 1}');
  }

  Future<void> plusEmit(EventDTO<int> event, EventEmitter<EventDTO<int>>? emit, {IEventBus? bus}) async {
    var e = event.copy(data: event.data + 1);
    print('plusEmit: ${e.data}');
    emit?.call(e);
  }
}

Future<void> externPlusEmit(EventDTO<int> event, EventEmitter<EventDTO<int>>? emit, {IEventBus? bus}) async {
  var e = event.copy(data: event.data + 1);
  print('Extern plusEmit: ${e.data}');
  emit?.call(e);
}

Future<void> main() async {
  //You can create many bus with prefix. Use for example, prefix for layer divider
  var appEBus = EventController(
    prefix: 'app',
    defaultHandler: (event, emit, {bus}) async {
      print('App Def Event ${event.topic} uuid:${event.uuid} data:${event.data}');
      emit?.call(event);
    },
  );
  appEBus.addHandler(externPlusEmit);
  appEBus.connect(TestEventHandlerGroup());
  var serviceEBus = EventController(
    prefix: 'service',
    defaultHandler: (event, emit, {bus}) async {
      print('Service Def Event ${event.topic} uuid:${event.uuid} data:${event.data}');
      emit?.call(event);
    },
  );
  serviceEBus.connect(TestEventHandlerGroup());
  //This Event no arrive to listener because no emit call
  appEBus.listenEvent<int>(eventName: 'no_emit')!.listen((event) {
    print('App Event no_emit data:$event');
  });
  serviceEBus.listenEvent<int>(eventName: 'emit')!.listen((event) {
    print('Service Event no_emit data:$event');
  });
  //This event have listener but handler no emit event
  EventBusMaster.instance.send(10, eventName: 'no_emit', prefix: 'app');
  //This event no have listener
  EventBusMaster.instance.send(20, eventName: 'emit', prefix: 'app');
  EventBusMaster.instance.send(30, eventName: 'no_emit', prefix: 'service');
  EventBusMaster.instance.send(40, eventName: 'emit', prefix: 'service');
  await Future.delayed(Duration(seconds: 1));
  //You can use only type for event
  //This event <String> not have special handler and controller use default handler
  appEBus.listenEvent<String>()!.listen((event) {
    print('App Get Event $event');
  });
  appEBus.send<String>('Yhohohoh');
  appEBus.send(1111);
  await Future.delayed(Duration(seconds: 1));
  //------ model controller
  EventModelController modelControler = EventModelController(prefix: 'model');
  modelControler.send<int>(10);
  modelControler.send('save this string');
  await Future.delayed(Duration(seconds: 1));
  print('Model String ${modelControler.lastEvent<String>()}');
  print('Model int ${modelControler.lastEvent<int>()}');
}
