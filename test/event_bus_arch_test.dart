import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() async {
  EventBus bus = EventBus(
    'bus',
    onCall: (p0, p1) async {
      print('bus call: $p0 return $p1');
    },
    onEvent: (p0) async {
      print('bus send: $p0 ');
    },
  );
  var busHandler = bus as EventBusHandler;
  var sumCommand = busHandler.addHandler<String>(_stringSumHandler);
  var parseCommand = busHandler.addHandler<String>(_stringParserHandler, path: 'parse');
  var lenCommand = busHandler.addHandler<int>(_intLenHandler, path: 'len');
  var numCommand = busHandler.addHandler<int>(_intLenHandler, path: 'num');
  bus.listen<int>(path: 'num')!.listen((event) {
    print('listen num:$event');
  });
  bus.groupListen([
    bus.listen<int>(path: 'num')!,
    bus.listen<int>(path: 'len')!,
  ]).listen((event) {
    print('group listen num:$event');
  });
  sumCommand.execute(newData: 'Test1');
  sumCommand.execute(newData: 'Test2');
  await Future.delayed(Duration(seconds: 1));
  bus.sendEvent(event: sumCommand);
  await Future.delayed(Duration(seconds: 1));
  print('---- undo 1 canUndo:${sumCommand.canUndo}');
  await sumCommand.undo();
  print('---- undo 2 canUndo:${sumCommand.canUndo}');
  await sumCommand.undo();
  print('---- undo 3 canUndo:${sumCommand.canUndo}');
  await sumCommand.undo();
  // EventBus bus1 = EventBus(prefix: 'bus1');
  // EventBus bus2 = EventBus(prefix: 'bus2');
  // EventBus bus3 = EventBus(
  //   prefix: 'bus3',
  //   defaultHandler: (event, emit, {bus, needComplete}) async {
  //     print('Bus3 ${event.topic} uid: ${event.uuid}.');
  //     if (event.data is int) {
  //       emit?.call(event.copy(data: event.data + 1));
  //     } else if (event.data is String) {
  //       emit?.call(event.copy(data: event.data + '!'));
  //     } else {
  //       emit?.call(event);
  //     }
  //   },
  // );
  // var busHandler1 = bus1 as EventBusHandler;
  // var busHandler2 = bus2 as EventBusHandler;
  // busHandler1.addHandler<String>((event, emit, {bus, needComplete}) async {
  //   var str = event.data + ' unite!!';
  //   print('Bus1 ${event.topic} uid: ${event.uuid}. ${event.data} -> $str');
  //   emit?.call(event.copy(data: str));
  //   needComplete?.complete(str);
  // });
  // busHandler2.addHandler<String>((event, emit, {bus, needComplete}) async {
  //   var str = event.data + ' not War!!';
  //   print('Bus2 ${event.topic} uid: ${event.uuid}. ${event.data} -> $str');
  //   emit?.call(event.copy(data: str));
  //   needComplete?.complete(str);
  // });

  // group('A group of direct EB tests', () {
  //   test('send and listen event with Handler. test call', () async {
  //     var count = 0;
  //     bus1.listenEvent<String>()!.listen(
  //       (event) {
  //         if (count < 2) {
  //           expect(event == 'Workers unite!!', isTrue);
  //         }
  //         count++;
  //       },
  //     );
  //     bus2.listenEvent<String>()!.listen(
  //       (event) {
  //         expect(event == 'Make Peace not War!!', isTrue);
  //         count++;
  //       },
  //     );
  //     bus1.send('Workers');
  //     bus2.send('Make Peace');
  //     await Future.delayed(Duration(milliseconds: 10));
  //     expect(count == 2, isTrue);
  //     var r = await bus1.call('World Workers');
  //     expect(r == 'World Workers unite!!', isTrue);
  //   });
  //   test('send and listen event without handlers', () async {
  //     var count = 0;
  //     bus1.listenEvent<int>()!.listen(
  //       (event) {
  //         expect(event == 1, isTrue);
  //         count++;
  //       },
  //     );
  //     bus2.listenEvent<int>()!.listen(
  //       (event) {
  //         expect(event == 2, isTrue);
  //         count++;
  //       },
  //     );
  //     bus1.send(1);
  //     bus2.send(2);
  //     await Future.delayed(Duration(milliseconds: 10));

  //     expect(count == 2, isTrue);
  //   });
  //   test('no listener test', () async {
  //     expect(bus1.send(0.1), isFalse);
  //   });
  //   test('default handler test', () async {
  //     var count = 0;
  //     bus3.listenEvent<int>()!.listen(
  //       (event) {
  //         expect(event == 2, isTrue);
  //         count++;
  //       },
  //     );
  //     bus3.send(1, afterTime: Duration(milliseconds: 10));
  //     var r = await bus3.listenEvent<int>()!.first;
  //     await Future.delayed(Duration(milliseconds: 20));
  //     expect(r == 2, isTrue);
  //     expect(count == 1, isTrue);
  //   });
  // });

  await Future.delayed(Duration(seconds: 1));
}

Future<dynamic> _stringSumHandler(Topic topic, {String? data, String? oldData}) async {
  return ChainEventDTO(Topic.create<String>(path: 'parse'), (oldData ?? '') + (data ?? ''));
}

Future<dynamic> _stringParserHandler(Topic topic, {String? data, String? oldData}) async {
  return [
    ChainEventDTO(Topic.create<int>(path: 'len'), data?.length ?? 0),
    ChainEventDTO(
        Topic.create<int>(path: 'num'), data?.isNotEmpty ?? false ? RegExp(r'[0-9]').allMatches(data!).length : 0),
  ];
}

Future<dynamic> _intLenHandler(Topic topic, {int? data, int? oldData}) async {
  print('Len str: $data');
}

Future<dynamic> _intNumNumberHandler(Topic topic, {int? data, int? oldData}) async {
  print('Number count: $data');
}

Future<dynamic> _boolHandler(Topic topic, {bool? data, bool? oldData}) async {}
