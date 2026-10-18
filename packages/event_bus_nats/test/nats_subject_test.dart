import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_nats/event_bus_nats.dart';
import 'package:test/test.dart';

void main() {
  group('NatsSubjectMapper', () {
    test('maps a concrete topic one-to-one', () {
      final mapper = NatsSubjectMapper();
      final topic = Topic.create<int>(paths: ['sensor', 'temp']);

      expect(mapper.toSubject(topic), 'int.sensor.temp');
      expect(mapper.toTopic('int.sensor.temp'), topic);
    });

    test('prepends and strips the subject prefix', () {
      final mapper = NatsSubjectMapper(prefix: 'acme.shop');
      final topic = Topic.create<int>(paths: ['sensor']);

      expect(mapper.toSubject(topic), 'acme.shop.int.sensor');
      expect(mapper.toTopic('acme.shop.int.sensor'), topic);
      expect(
        () => mapper.toTopic('int.sensor'),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('applies and reverses type tags', () {
      final mapper = NatsSubjectMapper(typeTags: {'int': 'number'});
      final topic = Topic.create<int>(paths: ['sensor']);

      expect(mapper.toSubject(topic), 'number.sensor');
      expect(mapper.toTopic('number.sensor'), topic);
    });

    test('accepts wildcard tokens in a subscription subject', () {
      final mapper = NatsSubjectMapper();

      expect(
        mapper.toSubject(Topic.fromString('int.sensor.*'), subscription: true),
        'int.sensor.*',
      );
      expect(
        mapper.toSubject(Topic.fromString('int.>'), subscription: true),
        'int.>',
      );
    });

    test('rejects wildcards in a publish subject', () {
      final mapper = NatsSubjectMapper();

      expect(
        () => mapper.toSubject(Topic.fromString('int.sensor.*')),
        throwsA(isA<NatsSubjectException>()),
      );
      expect(
        () => mapper.toSubject(Topic.fromString('int.>')),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('rejects a tail wildcard that is not last', () {
      final mapper = NatsSubjectMapper();

      expect(
        () => mapper.toSubject(
          Topic.fromString('int.>.value'),
          subscription: true,
        ),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('rejects a wildcard mixed with literal characters', () {
      final mapper = NatsSubjectMapper();

      expect(
        () => mapper.toSubject(
          Topic.fromString('int.sen*or'),
          subscription: true,
        ),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('rejects a non-dot separator', () {
      final mapper = NatsSubjectMapper();

      expect(
        () => mapper.toSubject(Topic.fromString('int/a/b', separator: '/')),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('rejects an empty path token', () {
      final mapper = NatsSubjectMapper();

      expect(
        () => mapper.toSubject(Topic.create<int>(paths: [''])),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('validates registry keys', () {
      final mapper = NatsSubjectMapper();

      expect(
        () => mapper.validatePublishKey('int.sensor.temp'),
        returnsNormally,
      );
      expect(
        () => mapper.validateSubscribeKey('int.sensor.*'),
        returnsNormally,
      );
      expect(() => mapper.validateSubscribeKey('int.>'), returnsNormally);
      expect(
        () => mapper.validateSubscribeKey('int.>.value'),
        throwsA(isA<NatsSubjectException>()),
      );
      expect(
        () => mapper.validatePublishKey('int.*'),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('validates a full wire subject returned by a serializer', () {
      final mapper = NatsSubjectMapper(prefix: 'acme');

      expect(
        () => mapper.validatePublishSubject('acme.int.sensor'),
        returnsNormally,
      );
      expect(
        () => mapper.validatePublishSubject('acme.int.*'),
        throwsA(isA<NatsSubjectException>()),
      );
    });

    test('rejects duplicate wire type tags', () {
      expect(
        () => NatsSubjectMapper(typeTags: {'int': 'number', 'num': 'number'}),
        throwsA(isA<NatsSubjectException>()),
      );
    });
  });
}
