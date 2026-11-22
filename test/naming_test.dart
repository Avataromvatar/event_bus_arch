import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///The names of public parameters are part of the API. This file calls the
///members with named arguments on purpose: renaming one breaks the build here
///instead of surprising a caller later.

void _worker(EventBus bus, Object? initialData) {
  bus.subscribeEvents<String>(handler: (dto, lastData) async {
    return '$initialData: ${dto.data}';
  });
}

void main() {
  group('Parameter names: EventBusIsolate', () {
    test('onInit and initialData', () async {
      final iso = EventBusIsolate(onInit: _worker, initialData: 'prefix');
      await iso.waitInit;

      expect(await iso.request<String>('x'), 'prefix: x');
      await iso.dispose();
    });
  });

  group('Parameter names: EventBus', () {
    test('send takes paths, separator and arguments', () async {
      final bus = EventBus(isModelBus: true);
      Map<String, String>? seen;
      bus.subscribeEvents<int>(
        paths: ['a', 'b'],
        separator: '/',
        handler: (dto, lastData) async {
          seen = dto.arguments;
          return dto.data;
        },
      );

      final result = await bus.request<int>(1,
          paths: ['a', 'b'], separator: '/', arguments: {'k': 'v'});

      expect(result, 1);
      expect(seen, {'k': 'v'});
      await bus.dispose();
    });

    test('the reading methods take paths and separator', () async {
      final bus = EventBus(isModelBus: true);
      final handler = bus.subscribeEvents<int>(
          paths: ['c'], handler: (dto, lastData) async {});

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

      await handler.cancel();
      expect(bus.haveHandler<int>(paths: ['c']), false);
      await bus.dispose();
    });

    test('subscribeEvents takes initialData', () async {
      final bus = EventBus(isModelBus: true);
      bus.subscribeEvents<int>(
          initialData: 3, handler: (dto, lastData) async {});

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
          topic: topic.copy(),
          paths: ['p'],
          separator: '/',
          arguments: {'a': '1'});
      expect(dto.topic, isA<Topic>());

      final created = EventDTO.create<int>(1,
          paths: ['p'], separator: '/', arguments: {'a': '1'});
      expect(created.topic.topic, 'int/p');

      final restored = EventDTOImpl.fromJson<int>({'topic': 'int', 'data': 1},
          dataConverter: (t, d) => d as int);
      expect(restored.data, 1);
    });
  });

  group('Parameter names: Layers and logger', () {
    test('createLayers takes init tuples, currentIsModelBus and timeout',
        () async {
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

Future<void> _initNameLayer(Layer layer, Object? initialData) async {}

class _NameLog with EventBusLogger {}
