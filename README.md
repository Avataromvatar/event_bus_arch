This package is a part of Event-driven architecture providing sending, listening, processing and receiving the last event. 
## Simple Usage 
The event(EventDTO) consists of 3 parts: a header (topic), a unique identifier and data. The topic consists of the type of the transmitted object (required) and the name of the event.  
EventDTO class transporting Event in bus, but user can use clear data without EventDTO for example:
```dart
EventBus bus = EventBus();
//----- Without EventDTO
///topic = 'int' 
bus.listenEvent<int>()!.listen((event)=>print('int event:$event'));
///topic = 'int^test' 
bus.listenEvent<int>(eventName:'test')!.listen((event)=>print('int^test event:$event'));
///topic = 'int' 
bus.send<int>(1); //'int event:1'
bus.send(2); //'int event:2' in this case type event get automated
///topic = 'int^test' 
bus.send<int>(3,eventName:'test');////'int@test event:3'
//----- With EventDTO
bus
      .listenEventDTO<int>()!
      .listen((event) => print('topic ${event.topic} uuid:${event.uuid} event:${event.data}'));
bus
      .listenEventDTO<int>(eventName: 'test')!
      .listen((event) => print('topic ${event.topic} uuid:${event.uuid} event:${event.data}'));
```
When you call listenEvent method, you can set flag repeatLastEvent what send event after wait 1 millisecond or [Duration] 
## Used with prefix and EventBusMaster
EventBusMaster is a singltone what have knowledg about all created EventBus and use prefix to sort them.
The Event Bus Master also provides the ability to send and receive events from different business, but if there is no bus, it will return null or false. If you use any bus to send by prefix and the bus prefix does not match the specified prefix, event will be send to EventBusMaster.
```dart
EventBus bus = EventBus();
EventBus busServices = EventBus(prefix: 'services');
/// get event from bus
EventBusMaster.instance.listenEvent<int>()!.listen((event) => print('int master event:$event'));
/// get event from busServices
EventBusMaster.instance
      .listenEvent<int>(prefix: 'services')!
      .listen((event) => print('int master services bus event:$event'));
  bus.send<int>(5);
  EventBusMaster.instance.send(6);
  EventBusMaster.instance.send(7, prefix: 'services');
```
The prefix can be used to divide the application into layers, for example:
ViewModel - layers for stores the latest state of the models and does not delete unused nodes (more on this later).  
App - layer in which the business logic.  
AppModel the layer, like ViewModel , stores the latest data models necessary for the operation of the application.  
Services and ServicesModel , respectively.  

## EventBus for Model
By default EventBus, clear not use(where event listeners ==0) event node, but if you add flag 'isBusForModel' in constructor, you get EventBus(EventModelController) what not clear event node.
This EventModelController can be used by hold and update object(models, providers, command, interface and other). 

## EventBus Handler










This Event Bus with Event Bus Master(singletone) what collect other EventController divided into layers/group by prefix. EventDTO have uuid and you can use it for sorting,logging, tracing and other.

Event type and event name(optionally) create topic what used for holding event node. 

## Getting started

## Usage

## Example
```dart
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
```


