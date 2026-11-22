part of event_arch;

///The stable address of an event.
///
///An address is a user-supplied string; it is the routing key and the wire
///contract. It carries no Dart type name. The grammar is fixed: [separator]
///joins path tokens, [singleWildcard] matches one token and [tailWildcard]
///matches one or more trailing tokens. A concrete address may not contain
///wildcards; use [EventPattern] for a wildcard selector.
///
///Equality is by [value]: two addresses with the same string are the same
///address, regardless of how they were built.
final class EventAddress {
  EventAddress(String value) : value = _validateExact(value);

  ///Parses an exact address. Equivalent to the constructor.
  factory EventAddress.parse(String value) => EventAddress(value);

  ///The grammar separator; this is a rule, not a configuration.
  static const String separator = '.';

  ///Matches exactly one path token.
  static const String singleWildcard = '*';

  ///Matches one or more trailing path tokens; it must be the last token.
  static const String tailWildcard = '>';

  ///The address string; the identity of this address.
  final String value;

  ///The path tokens derived from [value]. Not a constructor input.
  List<String> get tokens => List<String>.unmodifiable(value.split(separator));

  static String _validateExact(String value) {
    if (value.isEmpty) {
      throw EventBusException('event address must not be empty');
    }
    final tokens = value.split(separator);
    for (final token in tokens) {
      if (token.isEmpty) {
        throw EventBusException('event address "$value" has an empty token');
      }
      if (token.contains(singleWildcard) || token.contains(tailWildcard)) {
        throw EventBusException(
            'exact event address "$value" must not contain wildcards');
      }
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is EventAddress && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

///A wildcard address used to select a set of [EventAddress] values.
///
///The grammar is the same as [EventAddress]: [EventAddress.separator] joins
///tokens, `*` matches one token, `>` matches one or more trailing tokens.
///A pattern never compares Dart types; type filtering happens at delivery.
final class EventPattern {
  EventPattern(String value) : value = _validatePattern(value);

  ///Parses a pattern. Equivalent to the constructor.
  factory EventPattern.parse(String value) => EventPattern(value);

  ///The pattern string.
  final String value;

  ///The path tokens derived from [value].
  List<String> get tokens =>
      List<String>.unmodifiable(value.split(EventAddress.separator));

  ///Whether this pattern contains at least one wildcard token.
  bool get hasWildcard =>
      tokens.any((token) =>
          token == EventAddress.singleWildcard ||
          token == EventAddress.tailWildcard);

  ///The number of literal tokens; more specific patterns win.
  int get specificity => tokens
      .where((token) =>
          token != EventAddress.singleWildcard &&
          token != EventAddress.tailWildcard)
      .length;

  static String _validatePattern(String value) {
    if (value.isEmpty) {
      throw EventBusException('event pattern must not be empty');
    }
    final tokens = value.split(EventAddress.separator);
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (token.isEmpty) {
        throw EventBusException('event pattern "$value" has an empty token');
      }
      if (token == EventAddress.tailWildcard) {
        if (i != tokens.length - 1) {
          throw EventBusException(
              'the ">" wildcard must be the last path token');
        }
        continue;
      }
      if (token == EventAddress.singleWildcard) continue;
      if (token.contains(EventAddress.singleWildcard) ||
          token.contains(EventAddress.tailWildcard)) {
        throw EventBusException(
            'a wildcard must be a whole path token: "$token"');
      }
    }
    return value;
  }

  ///Whether this pattern matches the concrete [address].
  bool matches(EventAddress address) {
    final patternTokens = tokens;
    final addressTokens = address.tokens;
    var index = 0;
    for (; index < patternTokens.length; index++) {
      final token = patternTokens[index];
      if (token == EventAddress.tailWildcard) {
        return index == patternTokens.length - 1 &&
            index < addressTokens.length;
      }
      if (index >= addressTokens.length) return false;
      if (token == EventAddress.singleWildcard) continue;
      if (token != addressTokens[index]) return false;
    }
    return index == addressTokens.length;
  }

  @override
  bool operator ==(Object other) =>
      other is EventPattern && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

///The local type of an event, captured without its name.
///
///The type is **not** part of the address and never reaches the wire. It is
///used for local identity and for `data is T` filtering. `Type` equality
///survives minification and obfuscation; `Type.toString()` does not.
Type _typeOf<T>() => T;

///A selector of events: an exact [EventKey] or an [EventPatternKey].
///
///The type parameter is the local payload type. [accepts] is the only type
///check delivery needs; it is `data is T`.
sealed class EventSelector<T> {
  const EventSelector();

  ///The local type captured when the key was created.
  Type get type;

  ///Whether [data] has the selector's local type.
  bool accepts(Object? data) => data is T;
}

///A typed exact address: the unit passed to `fire`, `request`, `currentData`
///and the other exact operations.
///
///Equality is by address and [type]; a class rename changes neither the address
///nor the type identity, and neither reaches the wire.
final class EventKey<T> extends EventSelector<T> {
  EventKey(String address) : this.fromAddress(EventAddress(address));

  EventKey.fromAddress(this.address) : type = _typeOf<T>();

  ///The exact address; the stable wire contract.
  final EventAddress address;

  @override
  final Type type;

  @override
  bool operator ==(Object other) =>
      other is EventKey && other.address == address && other.type == type;

  @override
  int get hashCode => Object.hash(address, type);

  @override
  String toString() => address.value;
}

///A typed wildcard selector: the unit passed to `listen`/`subscribe`.
///
///The pattern matches addresses only; delivery filters by [type]. `fire` and
///`request` require an exact [EventKey].
final class EventPatternKey<T> extends EventSelector<T> {
  EventPatternKey(String pattern)
      : this.fromPattern(EventPattern(pattern));

  EventPatternKey.fromPattern(this.pattern) : type = _typeOf<T>();

  ///The wildcard pattern.
  final EventPattern pattern;

  @override
  final Type type;

  ///Whether the pattern matches the concrete [address].
  bool matches(EventAddress address) => pattern.matches(address);

  @override
  bool operator ==(Object other) =>
      other is EventPatternKey &&
      other.pattern == pattern &&
      other.type == type;

  @override
  int get hashCode => Object.hash(pattern, type);

  @override
  String toString() => pattern.value;
}
