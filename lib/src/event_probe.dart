part of event_arch;

///A side-effect-free snapshot of what a [EventBus.fire] call would reach.
///
///The counts are local to this bus plus the cached remote interest of an
///isolate bridge. A transport cannot know its broker subscribers, so
///[transportPublishes] only says that a codec can encode the key.
class FireProbe {
  const FireProbe({
    required this.localListeners,
    required this.hasRawListener,
    required this.modelStores,
    required this.transportPublishes,
    required this.remoteListenerInterest,
  });

  ///Managed listener subscriptions that would receive the event.
  final int localListeners;

  ///Whether a raw `listen(...).listen(...)` exists; exact count is not tracked.
  final bool hasRawListener;

  ///Whether a model bus would store the value.
  final bool modelStores;

  ///Whether a transport codec can encode the key.
  final bool transportPublishes;

  ///Number of typed remote listener/model interest entries on the other side.
  final int remoteListenerInterest;

  ///Whether [EventBus.fire] would report the event as accepted.
  bool get accepted =>
      localListeners > 0 ||
      hasRawListener ||
      modelStores ||
      transportPublishes ||
      remoteListenerInterest > 0;

  @override
  String toString() => 'FireProbe(listeners: $localListeners, '
      'raw: $hasRawListener, model: $modelStores, '
      'publishes: $transportPublishes, remote: $remoteListenerInterest)';
}

///A side-effect-free snapshot of what an [EventBus.request] call would reach.
class RequestProbe {
  const RequestProbe({
    required this.localHandlers,
    required this.localAvailableHandlers,
    required this.localListeners,
    required this.hasRawListener,
    required this.remoteHandlerInterest,
    this.transportRequests = false,
  });

  ///Handlers in the resolved tier that accept the data.
  final int localHandlers;

  ///Those handlers that have a free slot or queue room right now.
  final int localAvailableHandlers;

  ///Managed listener subscriptions that the request would also notify.
  final int localListeners;

  ///Whether a raw `listen(...).listen(...)` exists.
  final bool hasRawListener;

  ///Whether the other side of an isolate bridge has a typed handler interest.
  final bool remoteHandlerInterest;

  ///Whether a transport codec can route this key as a request.
  ///
  ///A transport request needs both an encoder and a decoder. Like
  ///[FireProbe.transportPublishes], this reports codec capability, not a live
  ///connection or a broker subscriber.
  final bool transportRequests;

  ///Whether a local or remote handler is known.
  bool get hasHandler => localHandlers > 0 || remoteHandlerInterest;

  ///Whether the request has a route: a local/remote handler or a transport.
  bool get canRequest => hasHandler || transportRequests;

  ///A local handler exists but none has capacity now.
  bool get isBusy => localHandlers > 0 && localAvailableHandlers == 0;

  @override
  String toString() => 'RequestProbe(handlers: $localHandlers, '
      'available: $localAvailableHandlers, listeners: $localListeners, '
      'remote: $remoteHandlerInterest, transport: $transportRequests)';
}
