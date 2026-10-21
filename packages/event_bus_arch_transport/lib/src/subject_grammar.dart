import 'package:event_bus_arch/event_bus_arch.dart';

///The broker's subject grammar.
///
///The local bus always speaks the canonical wildcards [TopicPattern.single]
///(`*`) and [TopicPattern.tail] (`>`). A grammar translates them to the
///broker's symbols and validates the broker-specific rules.
abstract class SubjectGrammar {
  const SubjectGrammar();

  ///The wire separator, for example `.` for NATS or `/` for MQTT.
  String get separator;

  ///The broker symbol for "exactly one token".
  String get singleWildcard;

  ///The broker symbol for "one or more trailing tokens".
  String get tailWildcard;

  ///Translates a canonical local wildcard token to the broker symbol.
  String encodeWildcard(String token) => token == TopicPattern.single
      ? singleWildcard
      : token == TopicPattern.tail
          ? tailWildcard
          : token;

  ///Translates a broker wildcard token back to the canonical local symbol.
  String decodeWildcard(String token) => token == singleWildcard
      ? TopicPattern.single
      : token == tailWildcard
          ? TopicPattern.tail
          : token;

  ///Validates one token of a publish subject.
  void validatePublishToken(String token, {required bool isFirst});

  ///Validates one token of a subscription subject.
  void validateSubscriptionToken(String token,
      {required bool isFirst, required bool isLast});

  ///Validates a full concrete wire subject.
  void validatePublishSubject(String subject) {
    final tokens = subject.split(separator);
    for (var i = 0; i < tokens.length; i++) {
      validatePublishToken(tokens[i], isFirst: i == 0);
    }
  }
}
