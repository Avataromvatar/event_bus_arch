import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'nats_serialization.dart';

///A node of `EventBusNats`.
///
///Local delivery is delegated to [EventNodeImp], so the value stream,
///`currentData` and handler semantics are exactly those of a local node.
///
///The node always has an internal handler. That is deliberate: the core
///removes a node only when it has no listeners and no handler, and a NATS
///node must survive a cancelled listener so that its subscription, its
///`currentData` and the ability to publish on a later `send` stay alive.
///The internal handler forwards to the user handler when one is set.
class EventNodeNatsImpl<T> implements EventNode<T> {
  EventNodeNatsImpl({
    required this.topic,
    T? currentData,
    Handler<T>? handler,
    this.serializer,
    this.deserializer,
  }) {
    _userHandler = handler;
    _local = EventNodeImp<T>(currentData: currentData, handler: _bridge);
  }

  ///The local topic this node is bound to.
  final Topic topic;

  ///Encodes the payload for the server; null means the node is local-only.
  final EventDTOSerialization? serializer;

  ///Decodes events received from the server; null means no subscription.
  final EventDTODeserialization? deserializer;

  Handler<T>? _userHandler;
  late final EventNodeImp<T> _local;

  ///The handler that pins the node and forwards to the user handler.
  Future<dynamic> _bridge(EventDTO<T> dto, T? lastData) async {
    var handler = _userHandler;
    return handler == null ? null : await handler(dto, lastData);
  }

  @override
  T? get currentData => _local.currentData;
  @override
  set currentData(T? value) => _local.currentData = value;

  @override
  Handler<T>? get handler => _userHandler;
  @override
  set handler(Handler<T>? value) => _userHandler = value;

  @override
  bool get isDisposed => _local.isDisposed;

  ///Always true: the internal bridge handler keeps the node in the bus map.
  @override
  bool get isHaveHandler => true;

  @override
  StreamController<T> get streamControllerValue => _local.streamControllerValue;

  @override
  void send(EventDTO dto) {
    // TODO(phase 4): publish through NATS when [serializer] is set and the
    // connection is up; throw when the server is unavailable.
    _local.send(dto);
  }

  @override
  EventNode<T> copy() => throw UnsupportedError(
    'EventNodeNatsImpl cannot be copied between buses',
  );

  @override
  Future<void> dispose() => _local.dispose();
}
