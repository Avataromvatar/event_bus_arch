part of event_arch;

///A bounded LRU store of error timestamps per `(kind, address)` key.
///
///The store answers one question: may this error be admitted now? A key keeps
///at most [limit] timestamps inside [window]; older timestamps are pruned on
///access. At most [maxKeys] keys are tracked; the least recently used key is
///evicted when a new key arrives.
class _ErrorWindowStore {
  _ErrorWindowStore({
    this.maxKeys = 256,
    this.window = const Duration(seconds: 1),
    this.limit = 10,
  });

  final int maxKeys;
  final Duration window;
  final int limit;

  final Map<String, List<DateTime>> _windows = <String, List<DateTime>>{};

  ///The number of tracked keys, for diagnostics/tests.
  int get keyCount => _windows.length;

  ///Forgets every key.
  void clear() => _windows.clear();

  ///Whether [key] is currently tracked.
  bool contains(String key) => _windows.containsKey(key);

  ///The number of admitted timestamps recorded for [key].
  int lengthFor(String key) => _windows[key]?.length ?? 0;

  ///Records [at] for [key] and returns false when the per-window limit
  ///suppresses the error.
  bool record(String key, DateTime at) {
    final existing = _windows.remove(key);
    if (existing == null && _windows.length >= maxKeys) {
      _windows.remove(_windows.keys.first);
    }
    final timestamps = existing ?? <DateTime>[];
    _windows[key] = timestamps;
    timestamps.removeWhere((time) => at.difference(time) > window);
    if (timestamps.length >= limit) return false;
    timestamps.add(at);
    return true;
  }
}
