part of event_arch;

const String _targetDefault = 'all';
const String _shema = 'event';

///By default Topic equals by Topic.topic
abstract class Topic /*extends Equatable*/ {
  String get shema;
  String? get target;
  String get type;

  ///target.type
  String get host;
  String get path;

  String? get fragment;
  Map<String, String>? get arguments;

  ///This topic used in EventBus for detect handler.
  ///this string not include: fragment and arguments
  String get topic;

  ///
  String get topicWithFragment;

  ///this string include: fragment and arguments
  String get fullTopic;

  Topic copy({String? target, String? fragment, Map<String, String>? arguments});

  static Topic create<T>({String? target, String? path, String? fragment, Map<String, String>? arguments}) {
    return Topic.fromParametr(
        type: T..runtimeType, target: target, path: path, fragment: fragment, arguments: arguments);
  }

  factory Topic.parse(String fullTopic) {
    return EventTopicImpl.parse(fullTopic);
  }

  ///Required type or nameType
  factory Topic.fromParametr(
      {Type? type, String? nameType, String? target, String? path, String? fragment, Map<String, String>? arguments}) {
    return EventTopicImpl.create(
        type: type,
        nameType: nameType,
        target: target ?? _targetDefault,
        path: path,
        fragment: fragment,
        arguments: arguments);
  }
  @override
  String toString() {
    return fullTopic;
  }
}

class EventTopicImpl implements Topic {
  late final Uri _uri;

  @override
  String get shema => _uri.scheme;
  @override
  String? get target => _uri.host.split('.').first;
  @override
  String get type => _uri.host.split('.').last;

  ///target.type
  @override
  String get host => _uri.host;
  @override
  String get path => _uri.path;

  @override
  String get fragment => _uri.fragment;
  @override
  Map<String, String>? get arguments => _uri.queryParameters;

  ///This topic used in EventBus for detect handler.
  ///this string not include: fragment and arguments
  @override
  String get topic => _getTopic();

  @override
  String get topicWithFragment => _getTopic(needFragment: true);

  ///this string include: fragment and arguments
  @override
  String get fullTopic => '$_uri';

  EventTopicImpl.parse(String topic) {
    var tmp = Uri.tryParse(topic);
    if (tmp != null) {
      _uri = tmp;
    } else {
      throw Exception('Cant parse topic $topic');
    }
  }

  ///Must required type or nameType
  EventTopicImpl.create(
      {Type? type,
      String? nameType,
      String target = _targetDefault,
      String? path,
      String? fragment,
      String shema = _shema,
      Map<String, String>? arguments}) {
    if (type == null && nameType == null) {
      throw Exception('Topic.create required type or nameType !');
    }
    _uri = Uri(
        scheme: shema, host: '$target.${type ?? nameType}', path: path, fragment: fragment, queryParameters: arguments);
  }

  String _getTopic({bool needFragment = false}) {
    return '${_uri.scheme}://${target ?? _targetDefault}.$type/$path${needFragment ? '#$fragment' : ''}';
  }

  @override
  Topic copy({String? target, String? shema, String? fragment, Map<String, String>? arguments, String? path}) {
    return EventTopicImpl.create(
        nameType: type,
        shema: shema ?? this.shema,
        target: target ?? this.target!,
        fragment: fragment ?? this.fragment,
        arguments: arguments ?? this.arguments,
        path: path);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EventTopicImpl && other.topic == topic;
  }

  @override
  int get hashCode => Object.hashAll([topic]);

  @override
  String toString() {
    return fullTopic;
  }
}
