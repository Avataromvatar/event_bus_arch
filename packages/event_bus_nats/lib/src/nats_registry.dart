import 'package:event_bus_arch/event_bus_arch.dart';

///Resolves a serializer or deserializer for a topic.
///
///Resolution order:
///1. the exact topic;
///2. the type token (`int` for `int.sensor.temp`);
///3. when [allowPatterns] is true, the most specific wildcard pattern that
///   matches the topic (more literal tokens win; ties keep insertion order).
///
///A topic that itself contains wildcards is resolved only by the first two
///steps: matching a pattern against a pattern is ambiguous.
class NatsRegistryIndex<T> {
  NatsRegistryIndex(Map<String, T> entries, {required this.allowPatterns}) {
    for (final entry in entries.entries) {
      final topic = Topic.parse(entry.key);
      _byTopic[topic] = entry.value;
      if (topic.paths.isEmpty) {
        _byType[topic.type] = entry.value;
      }
    }
  }

  final Map<Topic, T> _byTopic = {};
  final Map<String, T> _byType = {};
  final bool allowPatterns;

  T? resolve(Topic topic) {
    final exact = _byTopic[topic];
    if (exact != null) return exact;

    final byType = _byType[topic.type];
    if (byType != null) return byType;

    if (!allowPatterns || TopicPattern.isPattern(topic)) return null;

    MapEntry<Topic, T>? best;
    var bestScore = -1;
    for (final entry in _byTopic.entries) {
      final pattern = entry.key;
      if (!TopicPattern.isPattern(pattern)) continue;
      if (!TopicPattern.matches(pattern, topic)) continue;
      final score = TopicPattern.specificity(pattern);
      if (score > bestScore) {
        best = entry;
        bestScore = score;
      }
    }
    return best?.value;
  }
}
