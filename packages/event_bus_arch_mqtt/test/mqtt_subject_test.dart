import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_mqtt/event_bus_arch_mqtt.dart';
import 'package:test/test.dart';

void main() {
  group('MqttSubjectMapper', () {
    test('maps a concrete topic one-to-one with "/"', () {
      final mapper = MqttSubjectMapper();
      final topic = Topic.create<int>(paths: ['sensor', 'temp']);

      expect(mapper.toSubject(topic), 'int/sensor/temp');
      expect(mapper.toTopic('int/sensor/temp'), topic);
    });

    test('prepends and strips the subject prefix', () {
      final mapper = MqttSubjectMapper(prefix: 'acme/shop');
      final topic = Topic.create<int>(paths: ['sensor']);

      expect(mapper.toSubject(topic), 'acme/shop/int/sensor');
      expect(mapper.toTopic('acme/shop/int/sensor'), topic);
      expect(
        () => mapper.toTopic('int/sensor'),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('applies and reverses type tags', () {
      final mapper = MqttSubjectMapper(typeTags: {'int': 'number'});
      final topic = Topic.create<int>(paths: ['sensor']);

      expect(mapper.toSubject(topic), 'number/sensor');
      expect(mapper.toTopic('number/sensor'), topic);
    });

    test('translates core wildcards to MQTT symbols', () {
      final mapper = MqttSubjectMapper();

      expect(
        mapper.toSubject(Topic.fromString('int.sensor.*'), subscription: true),
        'int/sensor/+',
      );
      expect(
        mapper.toSubject(Topic.fromString('int.>'), subscription: true),
        'int/#',
      );
    });

    test('rejects wildcards in a publish subject', () {
      final mapper = MqttSubjectMapper();

      expect(
        () => mapper.toSubject(Topic.fromString('int.sensor.*')),
        throwsA(isA<MqttSubjectException>()),
      );
      expect(
        () => mapper.toSubject(Topic.fromString('int.>')),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('rejects a tail wildcard that is not last', () {
      final mapper = MqttSubjectMapper();

      expect(
        () => mapper.toSubject(
          Topic.fromString('int.>.value'),
          subscription: true,
        ),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('rejects a wildcard mixed with literal characters', () {
      final mapper = MqttSubjectMapper();

      expect(
        () => mapper.toSubject(
          Topic.fromString('int.sen*or'),
          subscription: true,
        ),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('rejects a non-dot local separator', () {
      final mapper = MqttSubjectMapper();

      expect(
        () => mapper.toSubject(Topic.fromString('int/a/b', separator: '/')),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('rejects an empty path token', () {
      final mapper = MqttSubjectMapper();

      expect(
        () => mapper.toSubject(Topic.create<int>(paths: [''])),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('validates registry keys', () {
      final mapper = MqttSubjectMapper();

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
        throwsA(isA<MqttSubjectException>()),
      );
      expect(
        () => mapper.validatePublishKey('int.*'),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('validates a full wire subject returned by a serializer', () {
      final mapper = MqttSubjectMapper(prefix: 'acme');

      expect(
        () => mapper.validatePublishSubject('acme/int/sensor'),
        returnsNormally,
      );
      expect(
        () => mapper.validatePublishSubject('acme/int/+'),
        throwsA(isA<MqttSubjectException>()),
      );
    });

    test('rejects duplicate wire type tags', () {
      expect(
        () => MqttSubjectMapper(typeTags: {'int': 'number', 'num': 'number'}),
        throwsA(isA<MqttSubjectException>()),
      );
    });
  });
}
