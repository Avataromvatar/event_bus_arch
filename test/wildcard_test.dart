import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

void main() {
  group('TopicPattern', () {
    test('recognises whole-token wildcards', () {
      expect(TopicPattern.isPattern(Topic.fromString('int.sensor.*')), isTrue);
      expect(TopicPattern.isPattern(Topic.fromString('int.>')), isTrue);
      expect(TopicPattern.isPattern(Topic.fromString('int.sen*or')), isTrue);
      expect(
          TopicPattern.isPattern(Topic.fromString('int.sensor.temp')), isFalse);
    });

    test('matches one token with * and one or more with >', () {
      final pattern = Topic.fromString('int.sensor.*');

      expect(TopicPattern.matches(pattern, Topic.fromString('int.sensor.temp')),
          isTrue);
      expect(
          TopicPattern.matches(
              pattern, Topic.fromString('int.sensor.temp.value')),
          isFalse);
      expect(TopicPattern.matches(pattern, Topic.fromString('int.sensor')),
          isFalse);

      final tail = Topic.fromString('int.sensor.>');
      expect(TopicPattern.matches(tail, Topic.fromString('int.sensor.temp')),
          isTrue);
      expect(
          TopicPattern.matches(tail, Topic.fromString('int.sensor.temp.value')),
          isTrue);
      expect(
          TopicPattern.matches(tail, Topic.fromString('int.sensor')), isFalse);
    });

    test('does not match another type or another topic', () {
      final pattern = Topic.fromString('int.sensor.*');

      expect(
          TopicPattern.matches(pattern, Topic.fromString('String.sensor.temp')),
          isFalse);
      expect(TopicPattern.matches(pattern, Topic.fromString('int.other.temp')),
          isFalse);
    });

    test('counts literal tokens for specificity', () {
      expect(TopicPattern.specificity(Topic.fromString('int.sensor.*')), 1);
      expect(TopicPattern.specificity(Topic.fromString('int.>')), 0);
    });

    test('rejects an invalid pattern', () {
      expect(() => TopicPattern.validate(Topic.fromString('int.>.value')),
          throwsA(isA<EventBusException>()));
      expect(() => TopicPattern.validate(Topic.fromString('int.sen*or')),
          throwsA(isA<EventBusException>()));
      expect(() => TopicPattern.validate(Topic.fromString('int.sensor.*')),
          returnsNormally);
    });
  });

  group('EventBus: wildcard listeners', () {
    test('a pattern listener receives matching concrete events', () async {
      final bus = EventBus();
      final received = <int>[];
      final sub = bus.listen<int>(paths: ['sensor', '*']).listen(received.add);

      expect(bus.fire<int>(1, paths: ['sensor', 'temp']), isTrue);
      expect(bus.fire<int>(2, paths: ['sensor', 'humidity']), isTrue);
      expect(bus.fire<int>(3, paths: ['sensor']), isFalse);
      expect(bus.fire<int>(4, paths: ['other', 'temp']), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(received, [1, 2]);
      expect(bus.currentData<int>(paths: ['sensor', '*']), 2);
      expect(bus.currentData<int>(paths: ['sensor', 'temp']), isNull);
      expect(bus.haveListener<int>(paths: ['sensor', 'temp']), isTrue);
      expect(bus.haveListener<int>(paths: ['sensor', '*']), isTrue);

      await sub.cancel();
      await bus.dispose();
    });

    test('fire rejects wildcard paths', () async {
      final bus = EventBus();

      expect(() => bus.fire<int>(1, paths: ['sensor', '*']),
          throwsA(isA<EventBusException>()));
      await bus.dispose();
    });
  });

  group('EventBus: wildcard request handlers', () {
    test('a request is answered by a pattern handler', () async {
      final bus = EventBus();
      String? seenTopic;
      int? seenLast;
      bus.handlers.setHandler<int>(
          paths: ['sensor', '*'],
          handler: (dto, lastData) async {
            seenTopic = dto.topic.topic;
            seenLast = lastData;
            return dto.data * 2;
          });

      // The pattern node's previous value is updated by fire events.
      bus.fire<int>(5, paths: ['sensor', 'temp']);
      await Future<void>.delayed(Duration.zero);

      expect(await bus.request<int>(7, paths: ['sensor', 'temp']), 14);
      expect(seenTopic, 'int.sensor.temp');
      expect(seenLast, 5);
      expect(bus.haveHandler<int>(paths: ['sensor', 'temp']), isTrue);
      await bus.dispose();
    });

    test('an exact handler wins over a pattern handler', () async {
      final bus = EventBus();
      bus.handlers.setHandler<int>(
          paths: ['sensor', '*'], handler: (dto, lastData) async => 'pattern');
      bus.handlers.setHandler<int>(
          paths: ['sensor', 'temp'], handler: (dto, lastData) async => 'exact');

      expect(await bus.request<int>(1, paths: ['sensor', 'temp']), 'exact');
      await bus.dispose();
    });

    test('the most specific pattern handler wins', () async {
      final bus = EventBus();
      bus.handlers.setHandler<int>(
          paths: ['*', '*'], handler: (dto, lastData) async => 'short');
      bus.handlers.setHandler<int>(
          paths: ['sensor', '*'], handler: (dto, lastData) async => 'long');

      expect(await bus.request<int>(1, paths: ['sensor', 'temp']), 'long');
      await bus.dispose();
    });

    test('removeHandler removes a pattern responder', () async {
      final bus = EventBus();
      bus.handlers.setHandler<int>(
          paths: ['sensor', '*'], handler: (dto, lastData) async => 1);
      bus.handlers.removeHandler<int>(paths: ['sensor', '*']);

      expect(bus.haveHandler<int>(paths: ['sensor', '*']), isFalse);
      await expectLater(
        bus.request<int>(1, paths: ['sensor', 'temp']),
        throwsA(isA<NoHandlerException>()),
      );
      await bus.dispose();
    });

    test('addAllHandlerFromOtherBus copies a pattern handler', () async {
      final source = EventBus();
      final target = EventBus();
      source.handlers.setHandler<int>(
          paths: ['sensor', '*'],
          handler: (dto, lastData) async => dto.data * 2);

      target.handlers.addAllHandlerFromOtherBus(source);

      expect(await target.request<int>(3, paths: ['sensor', 'temp']), 6);
      await source.dispose();
      await target.dispose();
    });
  });
}
