import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///An object that jsonEncode cannot encode.
class NotEncodable {
  final int value = 42;
}

void main() {
  group('Topic', () {
    test('copy preserves path, fragment and arguments', () {
      var topic = Topic.create<String>(path: '/p', fragment: 'f', arguments: {'a': '1'});

      var copy = topic.copy();

      expect(copy.path, '/p');
      expect(copy.fragment, 'f');
      expect(copy.arguments, {'a': '1'});
      expect(copy.topic, topic.topic);
      expect(copy.fullTopic, topic.fullTopic);
    });

    test('copy replaces only the specified parts', () {
      var topic = Topic.create<String>(target: 'x', path: '/p');

      var copy = topic.copy(target: 'y');

      expect(copy.target, 'y');
      expect(copy.path, '/p');
      expect(topic.target, 'x');
    });

    test('copy with an explicit path overrides the original one', () {
      var topic = Topic.create<String>(path: '/p');

      expect(topic.copy(path: '/other').path, '/other');
    });

    test('scheme is available under the new name', () {
      var topic = Topic.create<String>();

      expect(topic.scheme, 'event');
      // ignore: deprecated_member_use_from_same_package
      expect(topic.shema, 'event');
    });

    test('a target with a dot cannot be created (in debug)', () {
      expect(() => Topic.create<String>(target: 'a.b'), throwsA(isA<AssertionError>()));
    });

    test('equality does not depend on fragment and arguments', () {
      var a = Topic.create<int>(path: '/p', fragment: 'f', arguments: {'x': '1'});
      var b = Topic.create<int>(path: '/p');

      expect(a, b);
      expect(a.topic, b.topic);
      expect(a.fullTopic, isNot(b.fullTopic));
    });
  });

  group('EventDTO', () {
    test('toJson returns the data as is', () {
      final data = NotEncodable();
      final dto = EventDTO<NotEncodable>(data, path: '/p');

      final json = dto.toJson();

      expect(json['topic'], dto.topic.fullTopic);
      expect(json['data'], same(data));
    });

    test('toString does not fail on non-JSON data', () {
      final dto = EventDTO<NotEncodable>(NotEncodable());

      expect(dto.toString(), contains('EventDTO'));
    });

    test('fromJson reconstructs the event', () {
      final dto = EventDTO<int>(5, path: '/p');

      final restored = EventDTOImpl.fromJson<int>(dto.toJson());

      expect(restored.data, 5);
      expect(restored.topic.topic, dto.topic.topic);
    });

    test('fromJson can convert the data', () {
      final restored = EventDTOImpl.fromJson<int>(
        {'topic': 'event://all.int/p', 'data': '7'},
        dataConverter: (topic, data) => int.parse(data as String),
      );

      expect(restored.data, 7);
    });

    test('completer is not part of event equality', () {
      final a = EventDTO<int>(1, completer: Completer());
      final b = EventDTO<int>(1);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
