import 'package:event_bus_arch/event_bus_arch.dart';

import 'subject_grammar.dart';
import 'transport_exception.dart';

///Maps local event topics to broker subjects and back.
///
///By default the mapping is one-to-one inside the grammar: the local topic
///`int.sensor.temp` becomes the wire subject built by [grammar]. [prefix]
///namespaces every subject, and [typeTags] replaces the first token (the Dart
///type token) with a stable wire token.
class TopicSubjectMapper {
  TopicSubjectMapper({
    required this.grammar,
    String? prefix,
    Map<String, String>? typeTags,
  })  : prefix = _normalizePrefix(prefix, grammar),
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
        throw TransportSubjectException(
            'duplicate wire type tag "${entry.value}"');
      }
    }
  }

  final SubjectGrammar grammar;

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
    return namespace == null ? local : '$namespace${grammar.separator}$local';
  }

  ///Parses a wire subject into a local topic. The subject must be concrete:
  ///messages received from the server always name a concrete subject.
  Topic toTopic(String subject) {
    var local = subject;
    final namespace = prefix;
    if (namespace != null) {
      final head = '$namespace${grammar.separator}';
      if (!local.startsWith(head)) {
        throw TransportSubjectException(
            'subject "$subject" does not start with prefix "$namespace"');
      }
      local = local.substring(head.length);
    }

    grammar.validatePublishSubject(local);
    final tokens = local.split(grammar.separator);
    final wireType = tokens.first;
    final paths =
        tokens.sublist(1).map(grammar.decodeWildcard).toList(growable: false);
    final type = _reverseTypeTags[wireType] ?? wireType;
    return TopicImpl(type, paths: paths, separator: '.');
  }

  ///Validates a topic used to publish to the server.
  void validatePublish(Topic topic) {
    _requireLocalDotSeparator(topic);
    if (TopicPattern.isPattern(topic)) {
      throw TransportSubjectException(
          'cannot publish to a wildcard topic "${topic.topic}"');
    }
    final type = _wireType(topic.type);
    grammar.validatePublishToken(type, isFirst: prefix == null);
    for (final path in topic.paths) {
      grammar.validatePublishToken(grammar.encodeWildcard(path),
          isFirst: false);
    }
  }

  ///Validates a topic used to subscribe on the server.
  void validateSubscribe(Topic topic) {
    _requireLocalDotSeparator(topic);
    try {
      TopicPattern.validate(topic);
    } on EventBusException catch (error) {
      throw TransportSubjectException(
          'invalid subscription topic "${topic.topic}": ${error.message}',
          subject: topic.topic);
    }
    final type = _wireType(topic.type);
    grammar.validateSubscriptionToken(type,
        isFirst: prefix == null, isLast: topic.paths.isEmpty);
    for (var i = 0; i < topic.paths.length; i++) {
      grammar.validateSubscriptionToken(grammar.encodeWildcard(topic.paths[i]),
          isFirst: false, isLast: i == topic.paths.length - 1);
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
    grammar.validatePublishSubject(subject);
  }

  String _localSubject(Topic topic) {
    final type = _wireType(topic.type);
    final parts = <String>[type];
    for (final path in topic.paths) {
      parts.add(grammar.encodeWildcard(path));
    }
    return parts.join(grammar.separator);
  }

  String _wireType(String type) => _typeTags[type] ?? type;

  Topic _parseLocal(String subject) {
    try {
      return Topic.parse(subject);
    } on EventBusException catch (error) {
      throw TransportSubjectException(
          'invalid subject "$subject": ${error.message}');
    }
  }

  static void _requireLocalDotSeparator(Topic topic) {
    if (topic.separator != '.') {
      throw TransportSubjectException(
          'transport topics must use the "." separator (topic "${topic.topic}" '
          'uses "${topic.separator}")');
    }
  }

  static String? _normalizePrefix(String? prefix, SubjectGrammar grammar) {
    if (prefix == null) return null;
    final tokens = prefix.split(grammar.separator);
    for (var i = 0; i < tokens.length; i++) {
      grammar.validatePublishToken(tokens[i], isFirst: i == 0);
    }
    return prefix;
  }

  void _validateTagToken(String token, String what) {
    try {
      grammar.validatePublishToken(token, isFirst: true);
    } on TransportSubjectException catch (error) {
      throw TransportSubjectException('$what: ${error.message}');
    }
  }
}
