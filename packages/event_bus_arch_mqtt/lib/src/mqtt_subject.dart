import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

import 'mqtt_exception.dart';

///The MQTT topic grammar.
///
///Levels are separated by `/`. In subscriptions `+` matches exactly one level
///and `#` may only be the last level. MQTT `#` matches zero or more levels,
///while the core `>` requires at least one; the shared node drops the extra
///matches, so the bus keeps the core semantics.
class MqttGrammar extends SubjectGrammar {
  const MqttGrammar();

  @override
  String get separator => '/';

  @override
  String get singleWildcard => '+';

  @override
  String get tailWildcard => '#';

  @override
  void validatePublishToken(String token, {required bool isFirst}) {
    if (token.isEmpty) {
      throw MqttSubjectException('topic level is empty');
    }
    if (token.contains('\u0000')) {
      throw MqttSubjectException('topic level contains a null character');
    }
    if (token.contains('/')) {
      throw MqttSubjectException('topic level contains "/": "$token"');
    }
    if (token.contains('+') || token.contains('#')) {
      throw MqttSubjectException(
        'topic level must not contain a wildcard: "$token"',
      );
    }
    if (isFirst && token.startsWith(r'$')) {
      throw MqttSubjectException('a topic must not start with "\$" ("$token")');
    }
  }

  @override
  void validateSubscriptionToken(
    String token, {
    required bool isFirst,
    required bool isLast,
  }) {
    if (token.isEmpty) {
      throw MqttSubjectException('subscription level is empty');
    }
    if (token.contains('\u0000')) {
      throw MqttSubjectException(
        'subscription level contains a null character',
      );
    }
    if (token.contains('/')) {
      throw MqttSubjectException('subscription level contains "/": "$token"');
    }
    if (token == tailWildcard) {
      if (!isLast) {
        throw MqttSubjectException('the "#" wildcard must be the last level');
      }
      return;
    }
    if (token == singleWildcard) return;
    if (token.contains('+') || token.contains('#')) {
      throw MqttSubjectException('a wildcard must be a whole level: "$token"');
    }
    if (isFirst && token.startsWith(r'$')) {
      throw MqttSubjectException('a topic must not start with "\$" ("$token")');
    }
  }
}

///Maps local event topics to MQTT topics and back.
///
///By default the mapping is one-to-one but for the separator: the local topic
///`int.sensor.temp` becomes `int/sensor/temp`. [prefix] namespaces every
///topic, and [typeTags] replaces the first token (the Dart type token) with a
///stable wire token.
class MqttSubjectMapper extends TopicSubjectMapper {
  MqttSubjectMapper({super.prefix, super.typeTags})
    : super(grammar: const MqttGrammar());
}
