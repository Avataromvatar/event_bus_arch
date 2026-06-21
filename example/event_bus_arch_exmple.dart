
import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';

class TestIntData
{
  final int value;
  TestIntData(this.value);
}
class TestStrData
{
  final String value;
  TestStrData(this.value);
}


Future<void> main()async
{
  print('Main Isolate ${Isolate.current.hashCode}');
  var isolateBus = EventBusIsolate(onInit: _initIsolate,initalData: 'Test');
  await isolateBus.waitInit;  
  ///When subscribe or listen you can add some parametr for filtering event by path and target
  ///listen return Stream<T> 
  isolateBus.listen<TestStrData>(path: 'origin').listen((e){
    print(e.value);
  });
  ///subscribe return StreamSubscription<T> 
  isolateBus.subscribe<TestStrData>(onData: (e) {
    print(e.value);
  },);
  await isolateBus.send(TestStrData('Hello from main isolate'));
  ///If you sethandler for event you can call completer 
  ///what return result
  ///You can send arguments in dto 
  var ret = await isolateBus.send<TestIntData>(TestIntData(1),arguments: {'multiplier':10.toString()});
  print(ret);
  await Future.delayed(Duration(seconds: 1));
  await isolateBus.dispose();
}


void _initIsolate(EventBus bus,Object? initalData) async
{
  var name = initalData as String;
  print('Worker Isolate ${Isolate.current.hashCode}');
  bus.subscribe<TestStrData>(onData: (e) {
    bus.send(TestStrData('$name get ${e.value}'));
    bus.send(TestStrData(e.value),path: 'origin');
  },);
  ///sethandler what can return result
  (bus as EventBusHandlers).setHandler<TestIntData>(handler: (dto, lastData) async{

     print('Arguments:'+dto.topic.arguments.toString()); 
     var multStr = dto.topic.arguments?['multiplier']??'';
     dto.completer?.complete(dto.data.value*(int.tryParse(multStr)??1));
  },);
}