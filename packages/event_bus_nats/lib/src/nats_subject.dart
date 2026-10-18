import 'package:event_bus_arch/event_bus_arch.dart';

import 'nats_exception.dart';

///Maps local event topics to NATS subjects and back.
///
///By default the mapping is one-to-one: the local topic `int.sensor.temp` is
///also the wire subject. [prefix] namespaces every subject, and [typeTags]
///replaces the first token (the Dart type token) with a stable wire token.
///
///The mapper validates the NATS grammar:
///
///* publish subjects must not contain `*` or `>`;
///* in subscription subjects `*` is a whole token and `>` may only be the
///  last token;
///* tokens must not contain whitespace or a dot, and none may be empty;
///* a topic with a separator other than `.` is rejected.
class NatsSubjectMapper {
  NatsSubjectMapper({String? prefix, Map<String, String>? typeTags})
    : prefix = _normalizePrefix(prefix),
      _typeTags = Map.unmodifiable(typeTags ?? const {}),
      _reverseTypeTags = Map.unmodifiable({
        for (final entry in (typeTags ?? const <String, String>{}).entries)
          entry.value: entry.key,
      }) {
    final wireTags = <String>{};
    for (final entry in _typeTags.entries) {
      _validateTagToken(entry.key, 'type tag key');
      _validateTagToken(entry.value, 'type tag value');
      if (!wireTags.add(entry.value)) {
        throw NatsSubjectException('duplicate wire type tag "${entry.value}"');
      }
    }
  }

  ///Prepended to every subject; null means no namespace.
  final String? prefix;

  final Map<String, String> _typeTags;
  final Map<String, String> _reverseTypeTags;

  ///The wire subject for [topic]. Pass [subscription] when the subject is
  ///used for `SUB`, so wildcard tokens are allowed.
  String toSubject(Topic topic, {bool subscription = false}) {
    if (subscription) {
      validateSubscribe(topic);
    } else {
      validatePublish(topic);
    }
    final local = _localSubject(topic);
    final namespace = prefix;
    return namespace == null ? local : '$namespace.$local';
  }

  ///Parses a wire subject into a local topic. The subject must be concrete:
  ///messages received from the server always name a concrete subject.
  Topic toTopic(String subject) {
    var local = subject;
    final namespace = prefix;
    if (namespace != null) {
      if (!local.startsWith('$namespace.')) {
        throw NatsSubjectException(
          'subject "$subject" does not start with prefix "$namespace"',
        );
      }
      local = local.substring(namespace.length + 1);
    }

    final parsed = _parseLocal(local);
    validatePublish(parsed);
    final type = _reverseTypeTags[parsed.type] ?? parsed.type;
    if (type == parsed.type) return parsed;
    return TopicImpl(type, paths: parsed.paths, separator: '.');
  }

  ///Validates a topic used to publish to the server.
  void validatePublish(Topic topic) {
    _requireDotSeparator(topic);
    final type = _wireType(topic.type);
    _validateConcreteToken(type, what: 'type token');
    if (prefix == null && type.startsWith(r'$')) {
      throw NatsSubjectException(
        'a subject must not start with "\$" ("${topic.topic}")',
      );
    }
    for (final path in topic.paths) {
      _validateConcreteToken(path, what: 'path token');
    }
  }

  ///Validates a topic used to subscribe on the server.
  void validateSubscribe(Topic topic) {
    _requireDotSeparator(topic);
    final type = _wireType(topic.type);
    _validateSubscriptionToken(
      type,
      isFirst: prefix == null,
      isLast: topic.paths.isEmpty,
    );
    for (var i = 0; i < topic.paths.length; i++) {
      _validateSubscriptionToken(
        topic.paths[i],
        isFirst: false,
        isLast: i == topic.paths.length - 1,
      );
    }
  }

  ///Validates a registry key used for publishing. Keys are local topics and
  ///never include the prefix.
  void validatePublishKey(String key) => validatePublish(_parseLocal(key));

  ///Validates a registry key used for subscriptions. The key may contain
  ///wildcard tokens.
  void validateSubscribeKey(String key) => validateSubscribe(_parseLocal(key));

  ///Validates a full wire subject returned by a serializer. The subject
  ///already includes the prefix and the type tags, so neither is applied here.
  void validatePublishSubject(String subject) {
    final parsed = _parseLocal(subject);
    _requireDotSeparator(parsed);
    _validateConcreteToken(parsed.type, what: 'type token');
    if (parsed.type.startsWith(r'$')) {
      throw NatsSubjectException(
        'a subject must not start with "\$" ("$subject")',
      );
    }
    for (final path in parsed.paths) {
      _validateConcreteToken(path, what: 'path token');
    }
  }

  String _localSubject(Topic topic) {
    final type = _wireType(topic.type);
    return topic.paths.isEmpty ? type : '$type.${topic.paths.join('.')}';
  }

  String _wireType(String type) => _typeTags[type] ?? type;

  Topic _parseLocal(String subject) {
    try {
      return Topic.parse(subject);
    } on EventBusException catch (error) {
      throw NatsSubjectException(
        'invalid subject "$subject": ${error.message}',
      );
    }
  }

  static void _requireDotSeparator(Topic topic) {
    if (topic.separator != '.') {
      throw NatsSubjectException(
        'NATS requires the "." separator (topic "${topic.topic}" uses '
        '"${topic.separator}")',
      );
    }
  }

  static void _validateConcreteToken(String token, {required String what}) {
    if (token.isEmpty) {
      throw NatsSubjectException('$what is empty');
    }
    if (RegExp(r'\s').hasMatch(token)) {
      throw NatsSubjectException('$what contains whitespace: "$token"');
    }
    if (token.contains('.')) {
      throw NatsSubjectException('$what contains a dot: "$token"');
    }
    if (token.contains('*') || token.contains('>')) {
      throw NatsSubjectException('$what must not contain a wildcard: "$token"');
    }
  }

  static void _validateSubscriptionToken(
    String token, {
    required bool isFirst,
    required bool isLast,
  }) {
    if (token.isEmpty) {
      throw NatsSubjectException('subscription token is empty');
    }
    if (RegExp(r'\s').hasMatch(token)) {
      throw NatsSubjectException(
        'subscription token contains whitespace: "$token"',
      );
    }
    if (token.contains('.')) {
      throw NatsSubjectException('subscription token contains a dot: "$token"');
    }
    if (token == '>') {
      if (!isLast) {
        throw NatsSubjectException('the ">" wildcard must be the last token');
      }
      return;
    }
    if (token == '*') return;
    if (token.contains('*') || token.contains('>')) {
      throw NatsSubjectException('a wildcard must be a whole token: "$token"');
    }
    if (isFirst && token.startsWith(r'$')) {
      throw NatsSubjectException(
        'a subject must not start with "\$" ("$token")',
      );
    }
  }

  static void _validateTagToken(String token, String what) {
    if (token.isEmpty) {
      throw NatsSubjectException('$what is empty');
    }
    if (RegExp(r'\s').hasMatch(token)) {
      throw NatsSubjectException('$what contains whitespace: "$token"');
    }
    if (token.contains('.') || token.contains('*') || token.contains('>')) {
      throw NatsSubjectException(
        '$what must be a single concrete token: "$token"',
      );
    }
    if (token.startsWith(r'$')) {
      throw NatsSubjectException('$what must not start with "\$": "$token"');
    }
  }

  static String? _normalizePrefix(String? prefix) {
    if (prefix == null) return null;
    if (prefix.isEmpty) {
      throw NatsSubjectException('subject prefix is empty');
    }
    final tokens = prefix.split('.');
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      _validateConcreteToken(token, what: 'subject prefix token');
      if (i == 0 && token.startsWith(r'$')) {
        throw NatsSubjectException(
          'a subject prefix must not start with "\$": "$token"',
        );
      }
    }
    return prefix;
  }
}
