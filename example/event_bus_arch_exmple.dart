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

///Addresses are explicit: the same string is the local identity and the wire
///subject. A key carries the address and the static type together.
final originKey = EventKey<TestStrData>('origin');
final inboxKey = EventKey<TestStrData>('inbox');
final calcKey = EventKey<TestIntData>('calc');

Future<void> main() async {
  print('Main Isolate ${Isolate.current.hashCode}');
  var isolateBus = EventBusIsolate(onInit: _initIsolate, initialData: 'Test');
  await isolateBus.waitInit;

  ///`listen` returns Stream<T>; the selector owns the address and the type.
  isolateBus.listen(originKey).listen((e) {
    print(e.value);
  });

  ///`subscribe` returns StreamSubscription<T>.
  isolateBus.subscribe(inboxKey, onData: (e) {
    print(e.value);
  });
  isolateBus.fire(inboxKey, TestStrData('Hello from main isolate'));

  ///A handler answers a request and may read `dto.arguments`.
  var ret = await isolateBus.request(calcKey, TestIntData(1),
      arguments: {'multiplier': 10.toString()});
  print(ret);
  await Future.delayed(Duration(seconds: 1));
  await isolateBus.dispose();
}

void _initIsolate(EventBus bus, Object? initialData) async {
  var name = initialData as String;
  print('Worker Isolate ${Isolate.current.hashCode}');
  bus.subscribe(inboxKey, onData: (e) {
    bus.fire(inboxKey, TestStrData('$name get ${e.value}'));
    bus.fire(originKey, TestStrData(e.value));
  });

  ///The handler answers on the address `calc`.
  bus.subscribeEvents(calcKey, handler: (dto, lastData) async {
    print('Arguments:${dto.arguments}');
    var multStr = dto.arguments?['multiplier'] ?? '';
    return dto.data.value * (int.tryParse(multStr) ?? 1);
  });
}
