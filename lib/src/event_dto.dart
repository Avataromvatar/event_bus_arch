part of event_arch;

///One event: its typed key (address plus local type), the data, the call
///arguments and an optional correlation id.
///
///The key is the E identity: the address is user-supplied and stable, while the
///type is local and never reaches the wire. [topic] is a compatibility view for
///the old topic-shaped API; new code uses [key] and [address].
abstract class EventDTO<T> {
  ///The typed key: address plus local type.
  EventKey<T> get key;

  T get data;
  Map<String, String>? get arguments;

  ///An optional id that ties an event and every event caused by it together.
  String? get correlationId;

  ///The stable address string.
  String get address => key.address.value;

  ///A compatibility view of the address as the old `Topic`.
  ///
  ///New code should use [key] and [address]. For DTOs built from the legacy
  ///`paths`/`separator` API this preserves the original separator.
  Topic get topic => Topic.parse(address);

  ///A copy with some fields replaced. A null argument keeps the current value,
  ///so a correlation id cannot be cleared with this method.
  EventDTO<T> copyWith(
      {T? data,
      EventKey<T>? key,
      Topic? topic,
      List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      String? correlationId});

  static EventDTO<T> create<T>(T data,
      {Topic? topic,
      List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      String? correlationId}) {
    return EventDTO<T>(data,
        topic: topic,
        paths: paths,
        separator: separator,
        arguments: arguments,
        correlationId: correlationId);
  }

  ///Creates a DTO for a typed E key.
  factory EventDTO.withKey(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId}) {
    return EventDTOImpl<T>._keyed(key, data,
        arguments: arguments, correlationId: correlationId);
  }

  ///The legacy constructor: builds a key from a [Topic] or from `paths`.
  factory EventDTO(T data,
      {Topic? topic,
      List<String>? paths,
      Map<String, String>? arguments,
      String? separator,
      String? correlationId}) {
    final resolved = topic ??
        Topic.create<T>(paths: paths, separator: separator ?? '.');
    return EventDTOImpl<T>(resolved, data,
        arguments: arguments, correlationId: correlationId);
  }

  ///Event representation for logs and serialization.
  ///Data is returned as is: encoding is up to the caller, so an arbitrary
  ///object in [data] no longer breaks the method.
  Map<String, dynamic> toJson();
}

class EventDTOImpl<T> implements EventDTO<T> {
  ///Creates a keyed DTO; the preferred constructor for the E model.
  EventDTOImpl._keyed(this.key, this.data,
      {this.arguments, this.correlationId})
      : _topicOverride = null;

  ///Creates a DTO from the legacy topic-shaped API.
  EventDTOImpl(Topic topic, this.data,
      {this.arguments, this.correlationId})
      : key = EventKey<T>(topic.topic),
        _topicOverride = topic;

  @override
  final EventKey<T> key;

  @override
  T data;

  @override
  Map<String, String>? arguments;

  @override
  final String? correlationId;

  final Topic? _topicOverride;

  @override
  String get address => key.address.value;

  @override
  Topic get topic => _topicOverride ?? Topic.parse(address);

  @override
  EventDTO<T> copyWith(
      {T? data,
      EventKey<T>? key,
      Topic? topic,
      List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      String? correlationId}) {
    final nextData = data ?? this.data;
    final nextArguments = arguments ?? this.arguments;
    final nextCorrelation = correlationId ?? this.correlationId;
    if (key != null) {
      return EventDTOImpl<T>._keyed(key, nextData,
          arguments: nextArguments, correlationId: nextCorrelation);
    }
    final builtTopic = topic ??
        (paths != null || separator != null
            ? Topic.create<T>(
                paths: paths, separator: separator ?? '.')
            : null);
    if (builtTopic != null) {
      return EventDTOImpl<T>(builtTopic, nextData,
          arguments: nextArguments, correlationId: nextCorrelation);
    }
    final override = _topicOverride;
    if (override != null) {
      return EventDTOImpl<T>(override, nextData,
          arguments: nextArguments, correlationId: nextCorrelation);
    }
    return EventDTOImpl<T>._keyed(this.key, nextData,
        arguments: nextArguments, correlationId: nextCorrelation);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EventDTOImpl<T> &&
        other.address == address &&
        other.data == data;
  }

  @override
  int get hashCode => Object.hash(address, data);

  @override
  String toString() => 'EventDTO($address, data: $data)';

  @override
  Map<String, dynamic> toJson() {
    return {
      // Kept as `topic` for the legacy JSON shape; the value is the stable
      // address. ADR-0009 renames the field in the final migration.
      'topic': address,
      'data': data,
      if (correlationId != null) 'correlationId': correlationId,
    };
  }

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json,
      {EventKey<T>? key,
      Topic? topic,
      T Function(String topic, dynamic data)? dataConverter}) {
    final resolvedTopic = topic ??
        (key == null
            ? Topic.parse((json['address'] ?? json['topic']) as String)
            : null);
    final resolvedKey = key ?? EventKey<T>(resolvedTopic!.topic);
    return EventDTOImpl<T>._keyed(
      resolvedKey,
      dataConverter != null
          ? dataConverter.call(resolvedKey.address.value, json['data'])
          : json['data'],
      correlationId: json['correlationId'] as String?,
    );
  }
}
