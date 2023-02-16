import 'package:dart_event_bus/dart_event_bus.dart';
import 'package:test/test.dart';

void main() async {
  EventBus bus = EventBus();
  //----- Without EventDTO
  ///topic = 'int'
  bus.listenEvent<int>()!.listen((event) => print('int event:$event'));

  ///topic = 'int^test'
  bus.listenEvent<int>(eventName: 'test')!.listen((event) => print('int^test event:$event'));
  //----- With EventDTO
  bus.listenEventDTO<int>()!.listen((event) => print('topic ${event.topic} uuid:${event.uuid} event:${event.data}'));
  bus
      .listenEventDTO<int>(eventName: 'test')!
      .listen((event) => print('topic ${event.topic} uuid:${event.uuid} event:${event.data}'));
  //---- Sending event
  ///topic = 'int'
  bus.send<int>(1); //'int event:1'
  bus.send(2); //'int event:2'
  ///topic = 'int^test'
  bus.send<int>(3, eventName: 'test'); ////'int^test event:3'
  await Future.delayed(Duration(seconds: 1));

  EventBus busServices = EventBus(prefix: 'services');
  EventBusMaster.instance.listenEvent<int>()!.listen((event) => print('int master event:$event'));
  EventBusMaster.instance
      .listenEvent<int>(prefix: 'services')!
      .listen((event) => print('int master services bus event:$event'));
  bus.send<int>(5);
  EventBusMaster.instance.send(6);
  EventBusMaster.instance.send(7, prefix: 'services');

  await Future.delayed(Duration(seconds: 1));
  // group('A group of tests', () {
  //   final awesome = Awesome();

  //   setUp(() {
  //     // Additional setup goes here.
  //   });

  //   test('First Test', () {
  //     expect(awesome.isAwesome, isTrue);
  //   });
  // });
}
