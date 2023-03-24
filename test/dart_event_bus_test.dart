import 'package:dart_event_bus/dart_event_bus.dart';
import 'package:test/test.dart';

void main() async {
  EventBus bus1 = EventBus(prefix: 'bus1');
  EventBus bus2 = EventBus(prefix: 'bus2');
  EventBus bus3 = EventBus(
    prefix: 'bus3',
    defaultHandler: (event, emit, {bus, needComplete}) async {
      print('Bus3 ${event.topic} uid: ${event.uuid}.');
      if (event.data is int) {
        emit?.call(event.copy(data: event.data + 1));
      } else if (event.data is String) {
        emit?.call(event.copy(data: event.data + '!'));
      } else {
        emit?.call(event);
      }
    },
  );
  var busHandler1 = bus1 as EventBusHandler;
  var busHandler2 = bus2 as EventBusHandler;
  busHandler1.addHandler<String>((event, emit, {bus, needComplete}) async {
    var str = event.data + ' unite!!';
    print('Bus1 ${event.topic} uid: ${event.uuid}. ${event.data} -> $str');
    emit?.call(event.copy(data: str));
    needComplete?.complete(str);
  });
  busHandler2.addHandler<String>((event, emit, {bus, needComplete}) async {
    var str = event.data + ' not War!!';
    print('Bus2 ${event.topic} uid: ${event.uuid}. ${event.data} -> $str');
    emit?.call(event.copy(data: str));
    needComplete?.complete(str);
  });

  group('A group of direct EB tests', () {
    test('send and listen event with Handler. test call', () async {
      var count = 0;
      bus1.listenEvent<String>()!.listen(
        (event) {
          if (count < 2) {
            expect(event == 'Workers unite!!', isTrue);
          }
          count++;
        },
      );
      bus2.listenEvent<String>()!.listen(
        (event) {
          expect(event == 'Make Peace not War!!', isTrue);
          count++;
        },
      );
      bus1.send('Workers');
      bus2.send('Make Peace');
      await Future.delayed(Duration(milliseconds: 10));
      expect(count == 2, isTrue);
      var r = await bus1.call('World Workers');
      expect(r == 'World Workers unite!!', isTrue);
    });
    test('send and listen event without handlers', () async {
      var count = 0;
      bus1.listenEvent<int>()!.listen(
        (event) {
          expect(event == 1, isTrue);
          count++;
        },
      );
      bus2.listenEvent<int>()!.listen(
        (event) {
          expect(event == 2, isTrue);
          count++;
        },
      );
      bus1.send(1);
      bus2.send(2);
      await Future.delayed(Duration(milliseconds: 10));

      expect(count == 2, isTrue);
    });
    test('no listener test', () async {
      expect(bus1.send(0.1), isFalse);
    });
    test('default handler test', () async {
      var count = 0;
      bus3.listenEvent<int>()!.listen(
        (event) {
          expect(event == 2, isTrue);
          count++;
        },
      );
      bus3.send(1, afterTime: Duration(milliseconds: 10));
      var r = await bus3.listenEvent<int>()!.first;
      await Future.delayed(Duration(milliseconds: 20));
      expect(r == 2, isTrue);
      expect(count == 1, isTrue);
    });
  });

  await Future.delayed(Duration(seconds: 1));
}
