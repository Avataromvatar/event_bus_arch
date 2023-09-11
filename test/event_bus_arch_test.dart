import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

class TestScope {
  String prefix;
  int count = 0;
  TestScope({this.prefix = "TestScope"});
}

void main() async {
  //   test('adds one to input values', () {
//     final calculator = Calculator();
//     expect(calculator.addOne(2), 3);
//     expect(calculator.addOne(-7), -6);
//     expect(calculator.addOne(0), 1);
//   });
//==== Inital section
  var oneBus = EventBus(name: 'one');
  var eventStringOneBus = oneBus.addHandler<String>(
    env: TestScope(prefix: 'OneBusScope'),
    handler: (p0, {env, oldData}) async* {
      env!.count++;
      print('${p0.topic}:${env.prefix}/${env.count}/${p0.data}');
      //send event to oneBus
      yield EventDTO<int>(data: env.count);
    },
  );
  //==== check send in one bus
  test('Check Send Message to One bus', () async {
    int count = 0;
    var l = oneBus.getStreamData<int>().listen(
      (event) {
        count++;
      },
    );
    eventStringOneBus.sendEvent(data: 'Test1');
    eventStringOneBus.sendEvent(data: 'Test2');
    await Future.delayed(Duration(milliseconds: 100));
    expect(count, 2);
    l.cancel();
    await Future.delayed(Duration(milliseconds: 100));
    expect(oneBus.contain(Topic.create<int>()), false, reason: "Topic not deleted after cancel all listener");
  });

//==== check send to ring connection bus
  var ring1Bus = EventBus(name: 'ring1Bus');
  var ring2Bus = EventBus(name: 'ring2Bus');
  var ring3Bus = EventBus(name: 'ring3Bus');
  var conn1 = EventBusConnector(
    source: ring1Bus,
    target: ring2Bus,
    onEvent: (dir, event) {
      print(
          '${event.topic} ${dir == eEventBusConnection.sourceToTarget ? '${ring1Bus.name}->${ring2Bus.name}' : '${ring1Bus.name}<-${ring2Bus.name}'} ');
      return event;
    },
  );
  var conn2 = EventBusConnector(
    source: ring2Bus,
    target: ring3Bus,
    onEvent: (dir, event) {
      print(
          '${event.topic} ${dir == eEventBusConnection.sourceToTarget ? '${ring2Bus.name}->${ring3Bus.name}' : '${ring2Bus.name}<-${ring3Bus.name}'} ');
      return event;
    },
  );
  var conn3 = EventBusConnector(
    source: ring3Bus,
    target: ring1Bus,
    onEvent: (dir, event) {
      print(
          '${event.topic} ${dir == eEventBusConnection.sourceToTarget ? '${ring3Bus.name}->${ring1Bus.name}' : '${ring3Bus.name}<-${ring1Bus.name}'} ');
      return event;
    },
  );

  await Future.delayed(Duration(milliseconds: 200));
  test('check send to ring connection bus', () async {
    int count = 0;
    ring1Bus.getStreamData<String>().listen((event) {
      count++;
      print('ring1Bus $count');
    });
    ring2Bus.getStreamData<String>().listen((event) {
      count++;
      print('ring2Bus $count');
    });
    ring3Bus.getStreamData<String>().listen((event) {
      count++;
      print('ring3Bus $count');
    });
    ring1Bus.send<String>(data: 'Yoy');
    await Future.delayed(Duration(milliseconds: 100));
    expect(count, 3);
    print('--------');
    count = 0;
    var e1 = await ring1Bus.addHandler<String>(
      handler: (p0, {env, oldData}) async* {},
    );
    e1.sendEvent(data: 'Test');
    await Future.delayed(Duration(milliseconds: 100));
    expect(count, 3);
  });
  print('--------');
  await Future.delayed(Duration(milliseconds: 200));
  test('test send generate event to another bus', () async {
    var e1 = await ring3Bus.addHandler<void>(
      handler: (p0, {env, oldData}) async* {
        yield EventDTO<int>(data: 1, target: ring1Bus.name);
        yield EventDTO<int>(data: 2, target: ring2Bus.name);
        yield EventDTO<int>(data: 3);
      },
    );
    int v1 = 0;
    int v2 = 0;
    int v3 = 0;
    ring1Bus.getStreamData<int>().listen((event) {
      v1 = event;
      print('ring1Bus int $event');
    });
    ring2Bus.getStreamData<int>().listen((event) {
      v2 = event;
      print('ring2Bus int $event');
    });
    ring3Bus.getStreamData<int>().listen((event) {
      v3 = event;
      print('ring3Bus int $event');
    });
    e1.sendEvent();
    await Future.delayed(Duration(milliseconds: 100));
    expect(v1, 3);
  });
}
