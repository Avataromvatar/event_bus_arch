import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() async {
  ///The EventBusIsolate it consists of two Event busbars, one on the side of the main isolate and the other in the working isolate.
  /// They exchange EventDTO and the results of the handlers' work among themselves.
  EventBusIsolate isolateBus = EventBusIsolate(onInit: _initIsolate);
  await isolateBus.waitInit;
//listen in in main isolate event from worker isolate
  isolateBus.listen<String>().listen((event) {
    print('event from isolate: $event');
  });
  print('result: ${await isolateBus.send(10)}');
  print('result: ${await isolateBus.send(11)}');
  await Future.delayed(Duration(seconds: 1));
}
//event from isolate: 10
//result: 10
//event from isolate: 11
//result: 11

///this func run in isolate. And we wait event <int> and send result String
void _initIsolate(EventBus bus) {
  ///all EventBus implement EventBusHandlers
  ///and we set handler for event type <int>
  (bus as EventBusHandlers).setHandler<int>(handler: (dto, lastData) async {
    //send result to main thread
    dto.completer?.complete(dto.data.toString());
    //send event<String>
    bus.send(dto.data.toString());
  });
}
