// ignore_for_file: deprecated_member_use
import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///The names of public parameters are part of the API. This file calls the
///members with named arguments on purpose: renaming one breaks the build here
///instead of surprising a caller later.

void _worker(EventBus bus, Object? initialData) {
  bus.subscribe(EventKey<String>('String'), handler: (dto, lastData) async {
    return '$initialData: ${dto.data}';
  });
}

void main() {
  group('Parameter names: EventBusIsolate', () {
    test('onInit and initialData', () async {
      final iso = EventBusIsolate(onInit: _worker, initialData: 'prefix');
      await iso.waitInit;

      expect(await iso.request(EventKey<String>('String'), 'x'), 'prefix: x');
      await iso.dispose();
    });
  });

  group('Parameter names: EventBus', () {
    test('send takes paths, separator and arguments', () async {
      final bus = EventBus(isModelBus: true);
      Map<String, String>? seen;
      bus.subscribe(EventKey<int>('int.a.b'), handler: (dto, lastData) async {
        seen = dto.arguments;
        return dto.data;
      });

      final result =
          await bus.request(EventKey<int>('int.a.b'), 1, arguments: {'k': 'v'});

      expect(result, 1);
      expect(seen, {'k': 'v'});
      await bus.dispose();
    });

    test('the reading methods take paths and separator', () async {
      final bus = EventBus(isModelBus: true);
      final handler = bus.subscribe(EventKey<int>('int.c'),
          handler: (dto, lastData) async {});

      expect(bus.haveHandler(EventKey<int>('int.c')), true);
      expect(bus.haveListener(EventKey<int>('int.c')), false);
      expect(bus.currentData(EventKey<int>('int.c')), null);

      final sub = bus
          .listen(EventKey<int>('int.c'))
          .listen((_) {}, onError: (_) {}, onDone: () {}, cancelOnError: true);
      expect(bus.haveListener(EventKey<int>('int.c')), true);
      await sub.cancel();

      final stream = bus.listen(EventKey<int>('int.c'));
      expect(stream, isA<Stream<int>>());

      await handler.cancel();
      expect(bus.haveHandler(EventKey<int>('int.c')), false);
      await bus.dispose();
    });

    test('subscribe takes initialData', () async {
      final bus = EventBus(isModelBus: true);
      bus.subscribe(EventKey<int>('int'),
          initialData: 3, handler: (dto, lastData) async {});

      expect(bus.currentData(EventKey<int>('int')), 3);
      await bus.dispose();
    });
  });

  group('Parameter names: EventAddress and EventDTO', () {
    test('EventKey takes an address and EventDTO takes a key', () {
      final key = EventKey<int>('orders.placed');

      expect(key.address.value, 'orders.placed');
      expect(key.address.tokens, ['orders', 'placed']);

      final dto = EventDTO.withKey(key, 1, arguments: {'a': '1'});
      expect(dto.key, key);

      final restored = EventDTOImpl.fromJson<int>(
          {'address': 'orders.placed', 'data': 1},
          dataConverter: (address, data) => data as int);
      expect(restored.data, 1);
    });
  });

  group('Parameter names: Layers and logger', () {
    test('createLayers takes LayerSpec, currentIsModelBus and timeout',
        () async {
      final layer = await Layers.createLayers(
        [LayerSpec(init: _initNameLayer, isModelBus: true)],
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
