part of event_arch;

///The event address: a type plus an optional path.
///
///An address reads `<type><separator><path...>`, so with the default separator
///`Topic.create<String>(paths: ['a', 'b'])` is `String.a.b`.
///
///Two topics are equal when their [topic] strings are equal — the type and the
///paths are what select a node. Call parameters (`arguments`) are payload and
///live on the [EventDTO], not here.
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
    return TopicImpl(l[0], paths: l.length > 1 ? l.sublist(1) : [], separator: separator);
  }

  ///The topic of an explicitly given [type], for a type known only at runtime.
  factory Topic.fromParametr({Type? type, List<String>? paths, String separator = '.'}) {
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

class TopicImpl implements Topic {
  TopicImpl(this.type, {this.separator = '.', this.paths = const []});

  @override
  final String separator;

  @override
  final List<String> paths;

  @override
  final String type;

  @override
  Topic copy({List<String>? paths, String? separator}) {
    return TopicImpl(type, separator: separator ?? this.separator, paths: paths ?? this.paths);
  }

  @override
  String get topic => paths.isEmpty ? type : '$type$separator${paths.join(separator)}';

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
