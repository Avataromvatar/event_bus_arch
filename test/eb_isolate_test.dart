import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() async {
  EventBusIsolate isolateBus = EventBusIsolate(onInit: _initIsolate);
  await isolateBus.waitInit;
  EventBus bus = EventBus();
  EventBus bus1 = EventBus();
  (bus as EventBusHandlers).setHandler<int>(handler: mainThreadHandler);
  (bus1 as EventBusHandlers).setHandler<int>(handler: mainThreadHandler);
  isolateBus.listen<String>().listen((event) {
    print(event);
  });
  // fibonacci(10000);
  //--- get speed calc in main thread
  // var start = DateTime.now();
  // print('From bus: ${await bus.send(10000)}');
  // print('From bus: ${await bus1.send(10000)}');
  // var end = DateTime.now();
  // print('Main thread calc: ${(end.microsecondsSinceEpoch - start.microsecondsSinceEpoch)}');
  //--- get speed calc in worker thread
  // var start = DateTime.now();
  // print('From isolate bus: ${await isolateBus.send(10000)}');
  // print('From isolate bus: ${await isolateBus.send(10000)}');
  // var end = DateTime.now();
  // print('Worker thread calc: ${(end.microsecondsSinceEpoch - start.microsecondsSinceEpoch)}');
  //--- get speed calc in main thread + worker thread
  var start = DateTime.now();
  var ret = await Future.wait<dynamic>([bus.send(10000)!, isolateBus.send(10000)!]);
  print('From bus: ${ret[0]}');
  print('From isolate bus: ${ret[1]}');
  var end = DateTime.now();
  print('Main + Worker thread calc: ${(end.microsecondsSinceEpoch - start.microsecondsSinceEpoch)}');
}

Future<void> mainThreadHandler(EventDTO<int> dto, int? lastData) async {
  int ret;

  ret = fibonacci(dto.data);

  dto.completer?.complete(ret);
}

EventBus? _isolateBus;
void _initIsolate(EventBus bus) {
  _isolateBus = bus;
  (bus as EventBusHandlers).setHandler<int>(handler: workerThreadHandler);
}

Future<void> workerThreadHandler(EventDTO<int> dto, int? lastData) async {
  int ret;

  ret = fibonacci(dto.data);
  _isolateBus?.send('from worker to main $ret');
  dto.completer?.complete(ret);
}

//call from other Isolate
int fibonacci(int n) {
  int a = 0, b = 1, c, i;
  if (n == 0) return a;
  for (i = 2; i <= n; i++) {
    c = a + b;
    a = b;
    b = c;
  }
  return b;
}
