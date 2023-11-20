part of event_arch;

typedef LoggerHandler = void Function(EventDTO dto, bool hasListeners);

mixin class EventBusLogger {
  Map<EventBus, StreamSubscription> _loggerBusesSubscription = {};
  bool add(EventBus bus, {LoggerHandler handler = defaultLoggerHandler}) {
    if (!_loggerBusesSubscription.containsKey(bus)) {
      StreamSubscription<(EventDTO<dynamic>, bool)> sub;
      sub = bus.allEventStream.listen(
        (event) {
          handler.call(event.$1, event.$2);
        },
        onDone: () {
          remove(bus);
        },
      );
      _loggerBusesSubscription[bus] = sub;
      return true;
    }
    return false;
  }

  bool remove(EventBus bus) {
    var s = _loggerBusesSubscription[bus];
    if (s != null) {
      s.cancel();
      _loggerBusesSubscription.remove(bus);
      return true;
    }
    return false;
  }

  static void defaultLoggerHandler(EventDTO dto, bool hasListeners) {
    print('Event:${dto.topic} hasListeners $hasListeners');
  }
}
