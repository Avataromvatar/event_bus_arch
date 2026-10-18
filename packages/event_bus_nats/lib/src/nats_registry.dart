import 'package:event_bus_arch/event_bus_arch.dart';

///Resolves a serializer or deserializer for a topic.
///
///Resolution order:
///1. the exact topic string;
///2. the type token (`int` for `int.sensor.temp`);
///3. when [allowPatterns] is true, the most specific wildcard pattern that
///   matches the topic (more literal tokens win; ties keep insertion order).
///
///A topic that itself contains wildcards is resolved only by the first two
///steps: matching a pattern against a pattern is ambiguous.
class NatsRegistryIndex<T> {
  NatsRegistryIndex(Map<String, T> entries, {required this.allowPatterns})
    : _entries = Map.unmodifiable(entries);

  final Map<String, T> _entries;
  final bool allowPatterns;

  ///The entry for [topic], or null when none applies.
  T? resolve(Topic topic) {
    final exact = _entries[topic.topic];
    if (exact != null) return exact;

    final byType = _entries[topic.type];
    if (byType != null) return byType;

    if (!allowPatterns || _hasWildcard(topic.topic)) return null;

    MapEntry<String, T>? best;
    var bestScore = -1;
    for (final entry in _entries.entries) {
      if (!_patternMatches(entry.key, topic.topic)) continue;
      final score = _literalTokens(entry.key);
      if (score > bestScore) {
        best = entry;
        bestScore = score;
      }
    }
    return best?.value;
  }

  static bool _hasWildcard(String topic) =>
      topic.split('.').any((token) => token == '*' || token == '>');

  static int _literalTokens(String pattern) =>
      pattern.split('.').where((token) => token != '*' && token != '>').length;

  static bool _patternMatches(String pattern, String topic) {
    final patternTokens = pattern.split('.');
    final topicTokens = topic.split('.');
    var index = 0;
    for (; index < patternTokens.length; index++) {
      final token = patternTokens[index];
      if (token == '>') {
        return index == patternTokens.length - 1 && index < topicTokens.length;
      }
      if (index >= topicTokens.length) return false;
      if (token == '*') continue;
      if (token != topicTokens[index]) return false;
    }
    return index == topicTokens.length;
  }
}
