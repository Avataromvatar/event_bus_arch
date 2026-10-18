import 'package:event_bus_transport/event_bus_transport.dart';

export 'package:event_bus_transport/event_bus_transport.dart'
    show SubjectGrammar, TopicSubjectMapper, TransportSubjectException;

///The NATS subject grammar.
///
///Publish tokens are concrete single tokens: no whitespace, no dot and no
///wildcard. In subscription subjects `*` matches exactly one token and `>` may
///only be the last token. A subject must not start with `$` (the server
///reserves that prefix) unless a subject prefix moves the first token.
class NatsGrammar extends SubjectGrammar {
  const NatsGrammar();

  @override
  String get separator => '.';

  @override
  String get singleWildcard => '*';

  @override
  String get tailWildcard => '>';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {
    if (token.isEmpty) {
      throw TransportSubjectException('subject token is empty');
    }
    if (RegExp(r'\s').hasMatch(token)) {
      throw TransportSubjectException(
        'subject token contains whitespace: "$token"',
      );
    }
    if (token.contains('.')) {
      throw TransportSubjectException('subject token contains a dot: "$token"');
    }
    if (token.contains('*') || token.contains('>')) {
      throw TransportSubjectException(
        'subject token must not contain a wildcard: "$token"',
      );
    }
    if (isFirst && token.startsWith(r'$')) {
      throw TransportSubjectException(
        'a subject must not start with "\$" ("$token")',
      );
    }
  }

  @override
  void validateSubscriptionToken(
    String token, {
    required bool isFirst,
    required bool isLast,
  }) {
    if (token.isEmpty) {
      throw TransportSubjectException('subscription token is empty');
    }
    if (RegExp(r'\s').hasMatch(token)) {
      throw TransportSubjectException(
        'subscription token contains whitespace: "$token"',
      );
    }
    if (token.contains('.')) {
      throw TransportSubjectException(
        'subscription token contains a dot: "$token"',
      );
    }
    if (token == tailWildcard) {
      if (!isLast) {
        throw TransportSubjectException(
          'the ">" wildcard must be the last token',
        );
      }
      return;
    }
    if (token == singleWildcard) return;
    if (token.contains('*') || token.contains('>')) {
      throw TransportSubjectException(
        'a wildcard must be a whole token: "$token"',
      );
    }
    if (isFirst && token.startsWith(r'$')) {
      throw TransportSubjectException(
        'a subject must not start with "\$" ("$token")',
      );
    }
  }
}

///Maps local event topics to NATS subjects and back.
///
///By default the mapping is one-to-one: the local topic `int.sensor.temp` is
///also the wire subject. [prefix] namespaces every subject, and [typeTags]
///replaces the first token (the Dart type token) with a stable wire token.
class NatsSubjectMapper extends TopicSubjectMapper {
  NatsSubjectMapper({super.prefix, super.typeTags})
    : super(grammar: const NatsGrammar());
}
