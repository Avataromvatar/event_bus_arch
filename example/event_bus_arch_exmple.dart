import 'dart:isolate';

import 'package:event_bus_arch/event_bus_arch.dart';

class TestIntData {
  final int value;
  TestIntData(this.value);
}

class TestStrData {
  final String value;
  TestStrData(this.value);
}

Future<void> main() async {
  print('Main Isolate ${Isolate.current.hashCode}');
  var isolateBus = EventBusIsolate(onInit: _initIsolate, initialData: 'Test');
  await isolateBus.waitInit;

  ///When subscribe or listen you can add paths for narrowing the address:
  ///the topic is type + paths, so 'TestStrData.origin' is not 'TestStrData'
  ///listen return Stream<T>
  isolateBus.listen<TestStrData>(paths: ['origin']).listen((e) {
    print(e.value);
  });

  ///subscribe return StreamSubscription<T>
  isolateBus.subscribe<TestStrData>(
    onData: (e) {
      print(e.value);
    },
  );
  isolateBus.fire(TestStrData('Hello from main isolate'));

  ///If you sethandler for event you can call completer
  ///what return result
  ///You can send arguments in dto
  var ret = await isolateBus.request<TestIntData>(TestIntData(1),
      paths: ['calc'], arguments: {'multiplier': 10.toString()});
  print(ret);
  await Future.delayed(Duration(seconds: 1));
  await isolateBus.dispose();
}

void _initIsolate(EventBus bus, Object? initialData) async {
  var name = initialData as String;
  print('Worker Isolate ${Isolate.current.hashCode}');
  bus.subscribe<TestStrData>(
    onData: (e) {
      bus.fire(TestStrData('$name get ${e.value}'));
      bus.fire(TestStrData(e.value), paths: ['origin']);
    },
  );

  ///sethandler what can return result
  ///the handler answers on the address TestIntData.calc
  (bus as EventBusHandlers).setHandler<TestIntData>(
    paths: ['calc'],
    handler: (dto, lastData) async {
      print('Arguments:${dto.arguments}');
      var multStr = dto.arguments?['multiplier'] ?? '';
      dto.completer?.complete(dto.data.value * (int.tryParse(multStr) ?? 1));
    },
  );
}
