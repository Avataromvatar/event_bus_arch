import 'package:event_bus_arch/event_bus_arch.dart';

import 'subject_grammar.dart';
import 'transport_exception.dart';

///Maps a typed [EventAddress] or [EventPattern] to a broker subject.
///
///The local address grammar is fixed by [EventAddress] (`.` joins tokens); the
///mapper translates it to the broker grammar and adds the optional [prefix].
///No Dart type name is involved: the address is the wire contract.
class EventAddressMapper {
  EventAddressMapper({
    required this.grammar,
    String? prefix,
  }) : prefix = _normalizePrefix(prefix, grammar);

  ///The broker's subject grammar.
  final SubjectGrammar grammar;

  ///Prepended to every subject; null means no namespace.
  final String? prefix;

  ///The wire subject for an exact key or a pattern key.
  ///
  ///Pass [subscription] when the subject is used for `SUB`, so wildcard tokens
  ///are allowed.
  String toSubject(EventSelector selector, {bool subscription = false}) {
    if (selector is EventPatternKey) {
      if (!subscription) {
        throw TransportSubjectException(
            'cannot publish to a pattern address "${selector.pattern.value}"');
      }
      return _join(selector.pattern.tokens,
          subscription: true, pattern: selector.pattern);
    }
    final key = selector as EventKey;
    if (subscription) {
      return _join(key.address.tokens, subscription: true);
    }
    return _join(key.address.tokens, subscription: false);
  }

  ///The exact address for a concrete wire subject.
  EventAddress toAddress(String subject) {
    final local = _stripPrefix(subject);
    grammar.validatePublishSubject(local);
    final tokens = local
        .split(grammar.separator)
        .map(grammar.decodeWildcard)
        .join(EventAddress.separator);
    return EventAddress(tokens);
  }

  ///The pattern for a wire subscription subject.
  EventPattern toPattern(String subject) {
    final local = _stripPrefix(subject);
    final tokens = local.split(grammar.separator);
    for (var i = 0; i < tokens.length; i++) {
      grammar.validateSubscriptionToken(
        tokens[i],
        isFirst: prefix == null && i == 0,
        isLast: i == tokens.length - 1,
      );
    }
    final localPattern = tokens
        .map(grammar.decodeWildcard)
        .join(EventAddress.separator);
    return EventPattern(localPattern);
  }

  ///Validates a full wire subject returned by an encoder.
  void validatePublishSubject(String subject) {
    grammar.validatePublishSubject(subject);
  }

  String _join(List<String> tokens,
      {required bool subscription, EventPattern? pattern}) {
    final parts = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final token = grammar.encodeWildcard(tokens[i]);
      final isFirst = prefix == null && i == 0;
      final isLast = i == tokens.length - 1;
      if (subscription) {
        grammar.validateSubscriptionToken(token,
            isFirst: isFirst, isLast: isLast);
      } else {
        grammar.validatePublishToken(token, isFirst: isFirst);
      }
      parts.add(token);
    }
    final local = parts.join(grammar.separator);
    final namespace = prefix;
    return namespace == null
        ? local
        : '$namespace${grammar.separator}$local';
  }

  String _stripPrefix(String subject) {
    final namespace = prefix;
    if (namespace == null) return subject;
    final head = '$namespace${grammar.separator}';
    if (!subject.startsWith(head)) {
      throw TransportSubjectException(
          'subject "$subject" does not start with prefix "$namespace"');
    }
    return subject.substring(head.length);
  }

  static String? _normalizePrefix(String? prefix, SubjectGrammar grammar) {
    if (prefix == null) return prefix;
    final tokens = prefix.split(grammar.separator);
    for (var i = 0; i < tokens.length; i++) {
      grammar.validatePublishToken(tokens[i], isFirst: i == 0);
    }
    return prefix;
  }
}
