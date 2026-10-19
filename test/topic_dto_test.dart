import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:test/test.dart';

///An object that jsonEncode cannot encode.
class NotEncodable {
  final int value = 42;
}

void main() {
  group('Topic: address', () {
    test('a topic without paths is the type alone', () {
      var topic = Topic.create<String>();

      expect(topic.type, 'String');
      expect(topic.paths, isEmpty);
      expect(topic.topic, 'String');
    });

    test('paths are joined to the type by the separator', () {
      var topic = Topic.create<String>(paths: ['a', 'b']);

      expect(topic.type, 'String');
      expect(topic.paths, ['a', 'b']);
      expect(topic.separator, '.');
      expect(topic.topic, 'String.a.b');
    });

    test('a custom separator changes the address', () {
      var topic = Topic.create<String>(paths: ['a', 'b'], separator: '/');

      expect(topic.topic, 'String/a/b');
      expect(topic.separator, '/');
    });

    test('the type is the static type parameter, not the runtime type', () {
      expect(Topic.create<num>(paths: ['p']).topic, 'num.p');
      expect(Topic.create<int>(paths: ['p']).topic, 'int.p');
      expect(Topic.create<String?>(paths: ['p']).topic, 'String?.p');
      // Generic type tokens are normalised to broker-safe characters.
      expect(Topic.create<List<int>>(paths: ['p']).topic, 'List(int).p');
      expect(Topic.create<Map<String, int>>(paths: ['p']).topic,
          'Map(String_int).p');
    });

    test('a normalised generic topic parses back to the same key', () {
      var created = Topic.create<List<int>>(paths: ['p']);

      expect(Topic.parse(created.topic), created);
    });

    test('toString returns the routing key', () {
      var topic = Topic.create<String>(paths: ['a', 'b']);

      expect(topic.toString(), 'String.a.b');
      expect('$topic', topic.topic);
    });
  });

  group('Topic: copy', () {
    test('copy without arguments keeps the type, paths and separator', () {
      var topic = Topic.create<String>(paths: ['a', 'b']);
      var copy = topic.copy();

      expect(copy.type, 'String');
      expect(copy.paths, ['a', 'b']);
      expect(copy.separator, '.');
      expect(copy.topic, topic.topic);
    });

    test('copy replaces only what is passed', () {
      var topic = Topic.create<String>(paths: ['a']);

      expect(topic.copy(paths: ['b']).topic, 'String.b');
      expect(topic.copy(paths: ['b']).type, 'String');
      expect(topic.copy(separator: '/').topic, 'String/a');
      expect(topic.copy(paths: [], separator: '/').topic, 'String');
      // the original is untouched
      expect(topic.topic, 'String.a');
    });
  });

  group('Topic: parse', () {
    test('parse splits the type from the paths', () {
      var topic = Topic.parse('String.a.b');

      expect(topic.type, 'String');
      expect(topic.paths, ['a', 'b']);
      expect(topic.separator, '.');
    });

    test('parse of a bare type gives no paths', () {
      var topic = Topic.parse('String');

      expect(topic.type, 'String');
      expect(topic.paths, isEmpty);
      expect(topic.topic, 'String');
    });

    test('parse honours a custom separator', () {
      var topic = Topic.parse('String/a/b', separator: '/');

      expect(topic.type, 'String');
      expect(topic.paths, ['a', 'b']);
      expect(topic.topic, 'String/a/b');
    });

    test('an address survives a round trip through topic and parse', () {
      var topic = Topic.create<String>(paths: ['a', 'b']);

      var restored = Topic.parse(topic.topic);

      expect(restored, topic);
      expect(restored.topic, topic.topic);
    });

    test('an empty type is rejected', () {
      expect(() => Topic.parse(''), throwsA(isA<EventBusException>()));
      expect(() => Topic.parse('.a'), throwsA(isA<EventBusException>()));
    });

    test('fromString is parse', () {
      expect(Topic.fromString('String.a.b'), Topic.parse('String.a.b'));
    });

    test('fromParametr takes a Type and rejects a missing one', () {
      expect(Topic.fromParametr(type: String, paths: ['a']).topic, 'String.a');
      expect(() => Topic.fromParametr(), throwsA(isA<EventBusException>()));
    });
  });

  group('Topic: equality', () {
    test('equality is by the routing key', () {
      var a = Topic.create<int>(paths: ['p']);
      var b = Topic.create<int>(paths: ['p']);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(Topic.create<int>(paths: ['other'])));
      expect(a, isNot(Topic.create<num>(paths: ['p'])));
    });

    test('a parsed topic equals the created one', () {
      var created = Topic.create<int>(paths: ['p']);

      expect(Topic.parse('int.p'), created);
      expect(Topic.parse('int.p').hashCode, created.hashCode);
    });

    test('topics of a different separator are equal when the key matches', () {
      var a = Topic.create<String>(paths: ['a.b']);
      var b = Topic.create<String>(paths: ['a', 'b']);

      // this is why a path token must not contain the separator: the address
      // cannot tell the two apart, so they are the same node
      expect(a.topic, b.topic);
      expect(a, b);
    });
  });

  group('EventDTO', () {
    test('arguments are carried by the dto, not by the topic', () {
      final dto = EventDTO<int>(5, arguments: {'a': '1'});

      expect(dto.arguments, {'a': '1'});
      expect(dto.topic.topic, 'int');
    });

    test('arguments default to null', () {
      expect(EventDTO<int>(5).arguments, null);
    });

    test('a dto can be built from paths and a separator', () {
      final dto = EventDTO<int>(5, paths: ['a', 'b']);

      expect(dto.topic.topic, 'int.a.b');
    });

    test('toJson returns the data as is', () {
      final data = NotEncodable();
      final dto = EventDTO<NotEncodable>(data, paths: ['p']);

      final json = dto.toJson();

      expect(json['topic'], dto.topic.topic);
      expect(json['data'], same(data));
    });

    test('toString does not fail on non-JSON data', () {
      final dto = EventDTO<NotEncodable>(NotEncodable());

      expect(dto.toString(), contains('EventDTO'));
    });

    test('fromJson reconstructs the event', () {
      final dto = EventDTO<int>(5, paths: ['p']);

      final restored = EventDTOImpl.fromJson<int>(dto.toJson());

      expect(restored.data, 5);
      expect(restored.topic.topic, dto.topic.topic);
    });

    test('fromJson can convert the data', () {
      final restored = EventDTOImpl.fromJson<int>(
        {'topic': 'int.p', 'data': '7'},
        dataConverter: (topic, data) => int.parse(data as String),
      );

      expect(restored.data, 7);
    });
  });
}
