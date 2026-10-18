import 'dart:async';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'nats_connection.dart';
import 'nats_exception.dart';
import 'nats_serialization.dart';
import 'nats_subject.dart';

///Reports an error the node could not return to a caller (a broken incoming
///message, for example).
typedef NatsNodeErrorHandler =
    void Function(Object error, StackTrace? stackTrace);

///A node of `EventBusNats`.
///
///Local delivery is delegated to [EventNodeImp], so the value stream,
///`currentData` and handler semantics are exactly those of a local node.
///
///When a serializer is configured, [send] publishes to the server before
///delivering locally. When a deserializer is configured, the node subscribes
///as soon as it is created and delivers incoming events locally without
///publishing them again.
///
///The node always has an internal handler. That is deliberate: the core
///removes a node only when it has no listeners and no handler, and a NATS
///node must survive a cancelled listener so that its subscription, its
///`currentData` and the ability to publish on a later `send` stay alive.
///The internal handler forwards to the user handler when one is set.
class EventNodeNatsImpl<T> implements EventNode<T> {
  EventNodeNatsImpl({
    required this.connection,
    required this.subjects,
    required this.originId,
    required this.topic,
    T? currentData,
    Handler<T>? handler,
    this.serializer,
    this.deserializer,
    this.onError,
  }) {
    _userHandler = handler;
    _local = EventNodeImp<T>(currentData: currentData, handler: _bridge);
    if (deserializer != null) {
      _subscription = connection.subscribe(
        subjects.toSubject(topic, subscription: true),
        _onMessage,
      );
    }
  }

  ///The connection used for publishing and subscriptions.
  final NatsConnection connection;

  ///The local-topic ↔ wire-subject mapper.
  final NatsSubjectMapper subjects;

  ///The identity written into the origin header.
  final String originId;

  ///The local topic this node is bound to.
  final Topic topic;

  ///Encodes the payload for the server; null means the node is local-only.
  final EventDTOSerialization? serializer;

  ///Decodes events received from the server; null means no subscription.
  final EventDTODeserialization? deserializer;

  ///Receives errors that cannot be returned to a sender.
  final NatsNodeErrorHandler? onError;

  Handler<T>? _userHandler;
  late final EventNodeImp<T> _local;
  NatsSubscription? _subscription;

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
    final serializer = this.serializer;
    if (serializer != null) {
      _publish(dto, serializer);
    }
    _local.send(dto);
  }

  void _publish(EventDTO dto, EventDTOSerialization serializer) {
    if (!connection.isConnected) {
      throw NatsServerUnavailableException(dto.topic.topic);
    }

    late final (String?, Uint8List) encoded;
    try {
      encoded = serializer(dto);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NatsSerializationException(
          'serializer failed for "${dto.topic.topic}": $error',
          subject: dto.topic.topic,
          cause: error,
        ),
        stackTrace,
      );
    }

    final (overrideSubject, bytes) = encoded;
    final subject = overrideSubject ?? subjects.toSubject(dto.topic);
    if (overrideSubject != null) {
      subjects.validatePublishSubject(overrideSubject);
    }

    connection.publish(
      subject,
      bytes,
      arguments: dto.arguments,
      originId: originId,
    );
  }

  void _onMessage(NatsMessage message) {
    final deserializer = this.deserializer;
    if (deserializer == null) return;

    late final EventDTO dto;
    late final String localTopic;
    try {
      localTopic = subjects.toTopic(message.subject).topic;
      dto = deserializer(
        message.data,
        localTopic,
        arguments: message.arguments,
      );
    } catch (error, stackTrace) {
      _report(
        NatsDeserializationException(
          'cannot decode "${message.subject}": $error',
          subject: message.subject,
          cause: error,
        ),
        stackTrace,
      );
      return;
    }

    if (dto.data is! T) {
      _report(
        NatsDeserializationException(
          'expected $T, got ${dto.data.runtimeType} '
          'on "${message.subject}"',
          subject: message.subject,
        ),
        null,
      );
      return;
    }

    // Local delivery only: an incoming event must not be published again.
    _local.send(dto);
  }

  void _report(Object error, StackTrace? stackTrace) {
    onError?.call(error, stackTrace);
  }

  @override
  EventNode<T> copy() => throw UnsupportedError(
    'EventNodeNatsImpl cannot be copied between buses',
  );

  @override
  Future<void> dispose() async {
    if (_local.isDisposed) return;
    try {
      await _subscription?.cancel();
    } finally {
      _subscription = null;
      await _local.dispose();
    }
  }
}
