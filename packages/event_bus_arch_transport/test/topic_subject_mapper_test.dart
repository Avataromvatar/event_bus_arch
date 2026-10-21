import 'package:event_bus_arch/event_bus_arch.dart';
import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';
import 'package:test/test.dart';

///A grammar shaped like MQTT, to prove that the mapper only needs the
///separator and the wildcard symbols from a broker.
class _SlashGrammar extends SubjectGrammar {
  const _SlashGrammar();

  @override
  String get separator => '/';
  @override
  String get singleWildcard => '+';
  @override
  String get tailWildcard => '#';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {
    if (token.isEmpty ||
        token.contains('/') ||
        token.contains('+') ||
        token.contains('#')) {
      throw TransportSubjectException('invalid token "$token"');
    }
  }

  @override
  void validateSubscriptionToken(
    String token, {
    required bool isFirst,
    required bool isLast,
  }) {
    if (token.isEmpty) throw TransportSubjectException('empty token');
    if (token == '#') {
      if (!isLast) {
        throw TransportSubjectException('"#" must be the last token');
      }
      return;
    }
    if (token == '+') return;
    validatePublishToken(token, isFirst: isFirst);
  }
}

void main() {
  group('TopicSubjectMapper with the default grammar', () {
    final mapper = TopicSubjectMapper(grammar: const _SlashGrammar());

    test('maps a concrete topic', () {
      final topic = Topic.create<int>(paths: ['sensor', 'temp']);

      expect(mapper.toSubject(topic), 'int/sensor/temp');
      expect(mapper.toTopic('int/sensor/temp'), topic);
    });

    test('maps wildcards to the broker symbols', () {
      expect(
        mapper.toSubject(Topic.fromString('int.sensor.*'), subscription: true),
        'int/sensor/+',
      );
      expect(
        mapper.toSubject(Topic.fromString('int.>'), subscription: true),
        'int/#',
      );
      // Incoming messages always name a concrete subject.
      expect(
        () => mapper.toTopic('int/sensor/+'),
        throwsA(isA<TransportSubjectException>()),
      );
    });

    test('applies the prefix and type tags', () {
      final mapped = TopicSubjectMapper(
        grammar: const _SlashGrammar(),
        prefix: 'acme/shop',
        typeTags: {'int': 'number'},
      );
      final topic = Topic.create<int>(paths: ['sensor']);

      expect(mapped.toSubject(topic), 'acme/shop/number/sensor');
      expect(mapped.toTopic('acme/shop/number/sensor'), topic);
    });

    test('rejects a local topic with a foreign separator', () {
      expect(
        () => mapper.toSubject(Topic.fromString('int/sensor', separator: '/')),
        throwsA(isA<TransportSubjectException>()),
      );
    });

    test('rejects a subscription pattern that cannot be a subject', () {
      expect(
        () => mapper.toSubject(
          Topic.fromString('int.>.value'),
          subscription: true,
        ),
        throwsA(isA<TransportSubjectException>()),
      );
    });
  });
}
