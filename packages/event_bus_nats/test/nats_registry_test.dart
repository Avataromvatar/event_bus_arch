import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_nats/src/nats_registry.dart';
import 'package:test/test.dart';

void main() {
  group('NatsRegistryIndex', () {
    test('an exact match wins over the type and a pattern', () {
      final index = NatsRegistryIndex<String>({
        'int.sensor.temp': 'exact',
        'int': 'type',
        'int.sensor.*': 'pattern',
      }, allowPatterns: true);

      expect(index.resolve(Topic.fromString('int.sensor.temp')), 'exact');
    });

    test('a type match wins over a pattern', () {
      final index = NatsRegistryIndex<String>({
        'int': 'type',
        'int.sensor.*': 'pattern',
      }, allowPatterns: true);

      expect(index.resolve(Topic.fromString('int.sensor.temp')), 'type');
    });

    test('the most specific pattern wins', () {
      final index = NatsRegistryIndex<String>({
        'int.*.*': 'short',
        'int.sensor.*': 'long',
      }, allowPatterns: true);

      expect(index.resolve(Topic.fromString('int.sensor.temp')), 'long');
    });

    test('a tail wildcard matches one or more tokens', () {
      final index = NatsRegistryIndex<String>({
        'int.>': 'tail',
      }, allowPatterns: true);

      expect(index.resolve(Topic.fromString('int.sensor')), 'tail');
      expect(index.resolve(Topic.fromString('int.sensor.temp')), 'tail');
      expect(index.resolve(Topic.fromString('int')), isNull);
    });

    test('patterns are skipped for a wildcard topic', () {
      final index = NatsRegistryIndex<String>({
        'int.>': 'pattern',
      }, allowPatterns: true);

      expect(index.resolve(Topic.fromString('int.sensor.temp')), 'pattern');
      expect(index.resolve(Topic.fromString('int.sensor.*')), isNull);
    });

    test('patterns are disabled for serializers', () {
      final index = NatsRegistryIndex<String>({
        'int.>': 'pattern',
      }, allowPatterns: false);

      expect(index.resolve(Topic.fromString('int.sensor.temp')), isNull);
    });
  });
}
