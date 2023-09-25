import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

//call from other Isolate
class TestEventBus extends EventBusImpl {
  TestEventBus({required super.name}) {
    addHandler<int>(
      path: 'fibonacci',
      handler: (p0, {env, oldData}) async* {
        yield EventDTO<(int, int)>(data: (p0.data!, fibonacci(p0.data!)));
      },
    );
  }
}

void main() async {
  EventBusIsolate iebus = EventBusIsolate(name: 'test', onInit: _onInitIsolate);
  await iebus.waitInit;
  bool end_calculate = false;
  iebus.getStreamData<(int, int)>().listen((event) {
    print('Fibonacci from ${event.$1} = ${event.$2}');
    end_calculate = true;
  });
  print('Begin calculate');
  iebus.send(data: 1000, path: 'fibonacci');
  // await Future.delayed(Duration(seconds: 1));
  while (!end_calculate) {
    await Future.delayed(Duration(seconds: 1));
  }
  print('goodbay');
}

//call from other Isolate
EventBus _onInitIsolate() {
  return TestEventBus(name: 'testF');
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
