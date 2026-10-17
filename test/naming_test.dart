import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///The names of public parameters are part of the API. This file calls the
///members with named arguments on purpose: renaming one breaks the build here
///instead of surprising a caller later.

enum NameState { a, b }

class NameEvent {}

void _worker(EventBus bus, Object? initialData) {
  bus.handlers.setHandler<String>(handler: (dto, lastData) async {
    dto.completer?.complete('$initialData: ${dto.data}');
  });
}

void main() {
  group('Parameter names: EventBusIsolate', () {
    test('onInit and initialData', () async {
      final iso = EventBusIsolate(onInit: _worker, initialData: 'prefix');
      await iso.waitInit;

      expect(await iso.send<String>('x'), 'prefix: x');
      await iso.dispose();
    });
  });

  group('Parameter names: EventBus', () {
    test('send takes paths, separator and arguments', () async {
      final bus = EventBus(isModelBus: true);
      Map<String, String>? seen;
      bus.handlers.setHandler<int>(
        paths: ['a', 'b'],
        separator: '/',
        handler: (dto, lastData) async {
          seen = dto.arguments;
          dto.completer?.complete(dto.data);
        },
      );

      final result =
          await bus.send<int>(1, paths: ['a', 'b'], separator: '/', arguments: {'k': 'v'});

      expect(result, 1);
      expect(seen, {'k': 'v'});
      await bus.dispose();
    });

    test('the reading methods take paths and separator', () async {
      final bus = EventBus(isModelBus: true);
      bus.handlers.setHandler<int>(paths: ['c'], handler: (dto, lastData) async {});

      expect(bus.haveHandler<int>(paths: ['c'], separator: '.'), true);
      expect(bus.haveListener<int>(paths: ['c'], separator: '.'), false);
      expect(bus.currentData<int>(paths: ['c'], separator: '.'), null);

      final sub = bus.subscribe<int>(
          paths: ['c'],
          separator: '.',
          onData: (_) {},
          onError: (_) {},
          onDone: () {},
          cancelOnError: true);
      expect(bus.haveListener<int>(paths: ['c'], separator: '.'), true);
      await sub.cancel();

      final stream = bus.listen<int>(paths: ['c'], separator: '.');
      expect(stream, isA<Stream<int>>());

      bus.handlers.removeHandler<int>(paths: ['c'], separator: '.');
      expect(bus.haveHandler<int>(paths: ['c']), false);
      await bus.dispose();
    });

    test('setHandler takes initialData', () async {
      final bus = EventBus(isModelBus: true);
      bus.handlers.setHandler<int>(initialData: 3, handler: (dto, lastData) async {});

      expect(bus.currentData<int>(), 3);
      await bus.dispose();
    });
  });

  group('Parameter names: Topic and EventDTO', () {
    test('Topic takes paths and separator', () {
      var topic = Topic.create<String>(paths: ['a'], separator: '/');

      expect(topic.copy(paths: ['b']).topic, 'String/b');
      expect(Topic.parse('String/a', separator: '/').paths, ['a']);

      final dto = EventDTO<int>(1,
          topic: topic.copy(), paths: ['p'], separator: '/', arguments: {'a': '1'}, completer: null);
      expect(dto.topic, isA<Topic>());

      final created = EventDTO.create<int>(1,
          paths: ['p'], separator: '/', arguments: {'a': '1'}, completer: null);
      expect(created.topic.topic, 'int/p');

      final restored =
          EventDTOImpl.fromJson<int>({'topic': 'int', 'data': 1}, dataConverter: (t, d) => d as int);
      expect(restored.data, 1);
    });
  });

  group('Parameter names: Command and Scope', () {
    test('Command takes paths and maxLen, execute takes arguments', () async {
      final bus = EventBus(isModelBus: true);
      final command = Command<int>(bus, paths: ['counter'], maxLen: 3);

      await command.execute(1, arguments: {'a': '1'});

      expect(command.paths, ['counter']);
      expect(command.queueLength, 1);
      await bus.dispose();
    });

    test('initScope takes initialData, initialDataNeedExecute, paths, maxLenForUndo and onUpdate',
        () async {
      final bus = EventBus(isModelBus: true);
      final scope = Scope<int>();

      await scope.initScope(bus,
          initialData: 7,
          initialDataNeedExecute: false,
          paths: ['counter'],
          maxLenForUndo: 4,
          onUpdate: (_) {});

      expect(scope.lastData, 7);
      scope.disposeScope(removeHandler: true);
      await bus.dispose();
    });
  });

  group('Parameter names: FSM, Layers and logger', () {
    test('addFSMTransition takes eventPaths, handler and filter', () async {
      final bus = EventBus();
      final machine = _NameMachine(bus);

      // the transition is registered for NameEvent.go: another path is another topic
      await bus.send<NameEvent>(NameEvent(), paths: ['other']);
      await pumpEventQueue();
      expect(machine.state, NameState.a);

      await bus.send<NameEvent>(NameEvent(), paths: ['go']);
      await pumpEventQueue();

      expect(machine.state, NameState.b);
      await bus.dispose();
    });

    test('createLayers takes init tuples, currentIsModelBus and timeout', () async {
      final layer = await Layers.createLayers(
        [(_initNameLayer, null, true)],
        currentIsModelBus: true,
        timeout: const Duration(seconds: 10),
      );

      expect(layer.top, isNull);
      expect(layer.current, isNotNull);
      expect(layer.bottom, isNotNull);
      await layer.close();
    });

    test('the logger takes a handler', () async {
      final bus = EventBus();
      final log = _NameLog();

      expect(log.add(bus, handler: (dto, delivered) {}), true);
      expect(log.remove(bus), true);
      await bus.dispose();
    });
  });
}

class _NameMachine with FSM<NameState> {
  _NameMachine(EventBus bus) {
    initFSM(bus, NameState.a, lastState: null);
    addFSMTransition<NameEvent>(NameState.a, NameState.b,
        eventPaths: ['go'],
        filter: (current, last, event) => true,
        handler: (current, last, event, ignored) async => null);
  }
}

Future<void> _initNameLayer(Layer layer, Object? initialData) async {}

class _NameLog with EventBusLogger {}
