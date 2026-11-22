import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///The names of public parameters are part of the API. This file calls the
///members with named arguments on purpose: renaming one breaks the build here
///instead of surprising a caller later.

void _worker(EventBus bus, Object? initialData) {
  bus.subscribeEventsLegacy<String>(handler: (dto, lastData) async {
    return '$initialData: ${dto.data}';
  });
}

void main() {
  group('Parameter names: EventBusIsolate', () {
    test('onInit and initialData', () async {
      final iso = EventBusIsolate(onInit: _worker, initialData: 'prefix');
      await iso.waitInit;

      expect(await iso.requestLegacy<String>('x'), 'prefix: x');
      await iso.dispose();
    });
  });

  group('Parameter names: EventBus', () {
    test('send takes paths, separator and arguments', () async {
      final bus = EventBus(isModelBus: true);
      Map<String, String>? seen;
      bus.subscribeEventsLegacy<int>(
        paths: ['a', 'b'],
        separator: '/',
        handler: (dto, lastData) async {
          seen = dto.arguments;
          return dto.data;
        },
      );

      final result = await bus.requestLegacy<int>(1,
          paths: ['a', 'b'], separator: '/', arguments: {'k': 'v'});

      expect(result, 1);
      expect(seen, {'k': 'v'});
      await bus.dispose();
    });

    test('the reading methods take paths and separator', () async {
      final bus = EventBus(isModelBus: true);
      final handler = bus.subscribeEventsLegacy<int>(
          paths: ['c'], handler: (dto, lastData) async {});

      expect(bus.haveHandlerLegacy<int>(paths: ['c'], separator: '.'), true);
      expect(bus.haveListenerLegacy<int>(paths: ['c'], separator: '.'), false);
      expect(bus.currentDataLegacy<int>(paths: ['c'], separator: '.'), null);

      final sub = bus.subscribeLegacy<int>(
          paths: ['c'],
          separator: '.',
          onData: (_) {},
          onError: (_) {},
          onDone: () {},
          cancelOnError: true);
      expect(bus.haveListenerLegacy<int>(paths: ['c'], separator: '.'), true);
      await sub.cancel();

      final stream = bus.listenLegacy<int>(paths: ['c'], separator: '.');
      expect(stream, isA<Stream<int>>());

      await handler.cancel();
      expect(bus.haveHandlerLegacy<int>(paths: ['c']), false);
      await bus.dispose();
    });

    test('subscribeEvents takes initialData', () async {
      final bus = EventBus(isModelBus: true);
      bus.subscribeEventsLegacy<int>(
          initialData: 3, handler: (dto, lastData) async {});

      expect(bus.currentDataLegacy<int>(), 3);
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
