part of event_arch;

///The event address: a type plus an optional path.
///
///An address reads `<type><separator><path...>`, so with the default separator
///`Topic.create<String>(paths: ['a', 'b'])` is `String.a.b`.
///
///Two topics are equal when their [topic] strings are equal — the type and the
///paths are what select a node. Call parameters (`arguments`) are payload and
///live on the [EventDTO], not here.
///
///The type token is derived from `$T`, so it is normalised to a token that is
///safe in a broker subject: `<` becomes `(`, `>` becomes `)`, and commas and
///whitespace become `_`. Without this a generic type such as `List<int>` would
///produce `List<int>`, and `>` is a wildcard in NATS.
abstract class Topic /*extends Equatable*/ {
  ///The event type — the first token of the address, usually `T` of the call.
  String get type;

  ///The path tokens after the type. Empty when the address is the type alone.
  List<String> get paths;

  ///The string that joins [type] and [paths] into [topic].
  String get separator;

  ///The routing key. This is the string the bus looks a node up by.
  String get topic;

  ///A copy with [paths] and/or [separator] replaced. The type is kept.
  Topic copy({List<String>? paths, String? separator});

  ///The topic of the static type [T] with the given [paths].
  static Topic create<T>({List<String>? paths, String separator = '.'}) {
    return TopicImpl('$T', paths: paths ?? [], separator: separator);
  }

  ///Parses an address built as `<type><separator><path...>`.
  ///
  ///An empty type is rejected: a topic that no `create` can produce would never
  ///match a node.
  factory Topic.parse(String str, {String separator = '.'}) {
    var l = str.split(separator);
    if (l.isEmpty || l.first.isEmpty) {
      throw EventBusException('Cant parse topic $str');
    }
    return TopicImpl(l[0],
        paths: l.length > 1 ? l.sublist(1) : [], separator: separator);
  }

  ///The topic of an explicitly given [type], for a type known only at runtime.
  factory Topic.fromParametr(
      {Type? type, List<String>? paths, String separator = '.'}) {
    if (type == null) {
      throw EventBusException('Topic.fromParametr required type !');
    }
    return TopicImpl('$type', paths: paths ?? [], separator: separator);
  }

  factory Topic.fromString(String topic, {String separator = '.'}) {
    return Topic.parse(topic, separator: separator);
  }

  @override
  String toString() {
    return topic;
  }
}

///Replaces characters that cannot appear in a broker subject token.
String _normalizeTypeToken(String raw) {
  return raw
      .replaceAll('<', '(')
      .replaceAll('>', ')')
      .replaceAll(',', '_')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
}

class TopicImpl implements Topic {
  TopicImpl(String type, {this.separator = '.', this.paths = const []})
      : type = _normalizeTypeToken(type);

  @override
  final String separator;

  @override
  final List<String> paths;

  @override
  final String type;

  @override
  Topic copy({List<String>? paths, String? separator}) {
    return TopicImpl(type,
        separator: separator ?? this.separator, paths: paths ?? this.paths);
  }

  @override
  String get topic =>
      paths.isEmpty ? type : '$type$separator${paths.join(separator)}';

  ///The routing key: implementations use `implements`, so the body in [Topic]
  ///is not inherited and has to be repeated here.
  @override
  String toString() => topic;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Topic && other.topic == topic;
  }

  @override
  int get hashCode => Object.hashAll([topic]);
}

///Canonical wildcard rules for local topics.
///
///`*` matches exactly one path token. `>` matches one or more trailing path
///tokens and must be the last token. Wildcards are only allowed as whole path
///tokens; the type token is always concrete.
abstract final class TopicPattern {
  static const String single = '*';
  static const String tail = '>';

  ///Whether [topic] contains wildcard characters in its paths.
  static bool isPattern(Topic topic) =>
      topic.paths.any((path) => path.contains(single) || path.contains(tail));

  ///Validates a pattern topic; a mixed token such as `a*` is rejected.
  static void validate(Topic topic) {
    for (var i = 0; i < topic.paths.length; i++) {
      final token = topic.paths[i];
      if (token == tail) {
        if (i != topic.paths.length - 1) {
          throw EventBusException(
              'the ">" wildcard must be the last path token');
        }
        continue;
      }
      if (token == single) continue;
      if (token.contains(single) || token.contains(tail)) {
        throw EventBusException(
            'a wildcard must be a whole path token: "$token"');
      }
    }
  }

  ///Whether [pattern] matches the concrete [topic].
  static bool matches(Topic pattern, Topic topic) {
    if (pattern.type != topic.type) return false;
    if (isPattern(topic)) return false;

    final patternPaths = pattern.paths;
    final topicPaths = topic.paths;
    var index = 0;
    for (; index < patternPaths.length; index++) {
      final token = patternPaths[index];
      if (token == tail) {
        return index == patternPaths.length - 1 && index < topicPaths.length;
      }
      if (index >= topicPaths.length) return false;
      if (token == single) continue;
      if (token != topicPaths[index]) return false;
    }
    return index == topicPaths.length;
  }

  ///The number of literal tokens in [pattern]; more specific patterns win.
  static int specificity(Topic pattern) =>
      pattern.paths.where((token) => token != single && token != tail).length;
}
