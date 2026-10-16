part of event_arch;



///By default Topic equals by Topic.topic
abstract class Topic /*extends Equatable*/ {
  
  String get type;
  List<String> get paths;
  String get separator;
  // set separator(String v);
  String get topic;

  Topic copy({ List<String>? paths,String? separator});

  static Topic create<T>({List<String>? paths,String separator='.'}) {
    return TopicImpl('${T..runtimeType}',paths: paths??[],separator:separator );
    // return Topic.fromParametr(
    //     type: T..runtimeType, target: target, path: path, fragment: fragment, arguments: arguments);
  }

  factory Topic.parse(String str, {String separator='.'}) {
    var l = str.split(separator);
    if(l.isNotEmpty)
    {
      return TopicImpl('$l[0]',paths: l.length>1? l.sublist(1):[],separator:separator );
    }
    throw Exception('Cant parse topic $str');
  }

  ///Required type or nameType
  factory Topic.fromParametr(
      {Type? type, List<String>? paths,String separator='.'}) {
    return TopicImpl(
        '${type??''}',paths: paths??[],separator:separator);
  }
  factory Topic.fromString(String topic) {
    return Topic.parse(topic);
  }
  
  @override
  String toString() {
    return topic;
  }
}


class TopicImpl implements Topic {

  TopicImpl(this.type,{this.separator = '.',this.paths=const []});
  
  @override
  final String separator;

  @override
  Topic copy({List<String>? paths, String? separator}) {
    return TopicImpl(type,separator: separator??this.separator,paths: paths??this.paths);
  }

  @override 
  final List<String> paths;
  
  
  @override
  String get topic => '$type${paths.reduce((value, element) => '$value$separator$element',)}';

  @override
  final String type;

    @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Topic && other.topic == topic;
  }

  @override
  int get hashCode => Object.hashAll([topic]);
}
// class EventTopicImpl implements Topic {
//   late final Uri _uri;

//   @override
//   String get scheme => _uri.scheme;
//   @override
//   @Deprecated('Use scheme')
//   String get shema => scheme;
//   @override
//   String? get target => _uri.host.split('.').first;
//   @override
//   String get type => _uri.host.split('.').last;

//   ///target.type
//   @override
//   String get host => _uri.host;
//   @override
//   String get path => _uri.path;

//   @override
//   String get fragment => _uri.fragment;
//   @override
//   Map<String, String>? get arguments => _uri.queryParameters;

//   ///This topic used in EventBus for detect handler.
//   ///this string not include: fragment and arguments
//   @override
//   String get topic => _getTopic();

//   @override
//   String get topicWithFragment => _getTopic(needFragment: true);

//   ///this string include: fragment and arguments
//   @override
//   String get fullTopic => '$_uri';

//   EventTopicImpl.parse(String topic) {
//     var tmp = Uri.tryParse(topic);
//     if (tmp != null) {
//       _uri = tmp;
//     } else {
//       throw EventBusException('Cant parse topic $topic');
//     }
//   }

//   ///Must required type or nameType
//   EventTopicImpl.create(
//       {Type? type,
//       String? nameType,
//       String target = _targetDefault,
//       String? path,
//       String? fragment,
//       String scheme = _shema,
//       @Deprecated('Use scheme') String? shema,
//       Map<String, String>? arguments}) {
//     if (type == null && nameType == null) {
//       throw EventBusException('Topic.create required type or nameType !');
//     }
//     var typeName = '${type ?? nameType}'.replaceAll("?", "^");
//     // the topic host is "target.type": a dot inside a part breaks parsing
//     // and makes addresses collide (a.b.int is indistinguishable from a.int)
//     assert(
//         !target.contains('.') && !typeName.contains('.'),
//         'Topic host must be "target.type": "target" and type name must not '
//         'contain a dot (got "$target.$typeName")');
//     _uri = Uri(
//         scheme: shema ?? scheme,
//         host: '$target.$typeName',
//         path: path,
//         fragment: fragment,
//         queryParameters: arguments);
//   }

//   String _getTopic({bool needFragment = false}) {
//     return '${_uri.scheme}://${target ?? _targetDefault}.$type$path${needFragment ? '#$fragment' : ''}';
//   }

//   @override
//   Topic copy({String? target, String? scheme, String? fragment, Map<String, String>? arguments, String? path}) {
//     return EventTopicImpl.create(
//         nameType: type,
//         scheme: scheme ?? this.scheme,
//         target: target ?? this.target!,
//         fragment: fragment ?? (this.fragment.isEmpty ? null : this.fragment),
//         arguments: arguments ?? ((this.arguments?.isEmpty ?? true) ? null : this.arguments),
//         path: path ?? (this.path.isEmpty ? null : this.path));
//   }

//   @override
//   bool operator ==(Object other) {
//     if (identical(this, other)) return true;

//     return other is EventTopicImpl && other.topic == topic;
//   }

//   @override
//   int get hashCode => Object.hashAll([topic]);

//   @override
//   String toString() {
//     return fullTopic;
//   }
// }
