part of event_arch;

///One event: its typed key (address plus local type), the data, the call
///arguments and an optional correlation id.
///
///The address is user-supplied and stable; the type is local and never reaches
///the wire.
abstract class EventDTO<T> {
  ///The typed key: address plus local type.
  EventKey<T> get key;

  T get data;
  Map<String, String>? get arguments;

  ///An optional id that ties an event and every event caused by it together.
  String? get correlationId;

  ///The stable address string.
  String get address => key.address.value;

  ///A copy with some fields replaced. A null argument keeps the current value,
  ///so a correlation id cannot be cleared with this method.
  EventDTO<T> copyWith({
    T? data,
    EventKey<T>? key,
    Map<String, String>? arguments,
    String? correlationId,
  });

  ///Creates a DTO for a typed key.
  factory EventDTO.withKey(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId}) {
    return EventDTOImpl<T>._keyed(key, data,
        arguments: arguments, correlationId: correlationId);
  }

  ///Event representation for logs and serialization.
  ///Data is returned as is: encoding is up to the caller, so an arbitrary
  ///object in [data] no longer breaks the method.
  Map<String, dynamic> toJson();
}

class EventDTOImpl<T> implements EventDTO<T> {
  ///Creates a keyed DTO.
  EventDTOImpl._keyed(this.key, this.data,
      {this.arguments, this.correlationId});

  @override
  final EventKey<T> key;

  @override
  T data;

  @override
  Map<String, String>? arguments;

  @override
  final String? correlationId;

  @override
  String get address => key.address.value;

  @override
  EventDTO<T> copyWith({
    T? data,
    EventKey<T>? key,
    Map<String, String>? arguments,
    String? correlationId,
  }) {
    return EventDTOImpl<T>._keyed(
      key ?? this.key,
      data ?? this.data,
      arguments: arguments ?? this.arguments,
      correlationId: correlationId ?? this.correlationId,
    );
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
      'address': address,
      'data': data,
      if (correlationId != null) 'correlationId': correlationId,
    };
  }

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json,
      {EventKey<T>? key,
      T Function(String address, dynamic data)? dataConverter}) {
    final address = (json['address'] ?? json['topic']) as String;
    final resolvedKey = key ?? EventKey<T>(address);
    return EventDTOImpl<T>._keyed(
      resolvedKey,
      dataConverter != null
          ? dataConverter.call(resolvedKey.address.value, json['data'])
          : json['data'],
      correlationId: json['correlationId'] as String?,
    );
  }
}
