import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
// import 'package:test/test.dart';

//call from other Isolate
// class TestEventBus extends EventBusImpl {
//   TestEventBus({required super.name}) {
//     addHandler<int>(
//       path: 'fibonacci',
//       handler: (p0, {env, oldData}) async* {
//         yield EventDTO<(int, int)>(data: (p0.data!, fibonacci(p0.data!)));
//       },
//     );
//   }
// }

void main() async {
  EventBusIsolate iebus = EventBusIsolate(onInit: _onInitIsolate);
  await iebus.waitInit;
  var e = iebus as EventBusHandlers;
  var lastFib = 0;

  e.setHandler<String>(
    handler: (dto, lastData) async {
      dto.completer?.complete('you last answer $lastFib and this is Good i satisfied');
    },
  );

  iebus.send<int>(1000, path: 'fibonacci')?.then((value) {
    print('get Answer ${value}');
    lastFib = value;
  });

  await Future.delayed(Duration(seconds: 2));

  // bool end_calculate = false;
  // iebus.getStreamData<(int, int)>().listen((event) {
  //   print('Fibonacci from ${event.$1} = ${event.$2}');
  //   end_calculate = true;
  // });
  // print('Begin calculate');
  // iebus.send(data: 1000, path: 'fibonacci');
  // // await Future.delayed(Duration(seconds: 1));
  // while (!end_calculate) {
  //   await Future.delayed(Duration(seconds: 1));
  // }
  print('goodbay');
}

//call from other Isolate
void _onInitIsolate(EventBus isolateBus) {
  print('Begin Setup Isolate bus');
  var e = isolateBus as EventBusHandlers;
  e.setHandler<int>(
      handler: (dto, lastData) async {
        var ret = fibonacci(dto.data);

        isolateBus
            .send<String>('Fibonacci for ${dto.data} = $ret are you satisfied with the service?')
            ?.then((value) => print('thx for you callback:$value'));
        dto.completer?.complete(ret);
      },
      path: 'fibonacci');
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
