import 'dart:async';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'topic_subject_mapper.dart';
import 'transport_connection.dart';
import 'transport_exception.dart';
import 'transport_serialization.dart';

///Reports an error the node could not return to a caller (a broken incoming
///message, for example).
typedef TransportNodeErrorHandler = void Function(
    Object error, StackTrace? stackTrace);

///Produces the payload for a request received from the broker. Returning null
///sends no response, so the requester times out.
typedef TransportRequestAnswer = Future<Uint8List?> Function(
  EventDTO dto,
  TransportMessage message,
);

///A node of a transport bus.
///
///Local delivery is delegated to [EventNodeImp], so the value stream and
///`currentData` are exactly those of a local node. Request handlers are
///registered on the bus, not here.
///
///When a serializer is configured, [EventBus.fire] publishes to the server
///before delivering locally. When a deserializer is configured, the node
///subscribes as soon as it is created and delivers incoming events locally
///without publishing them again.
///
///The node is a [KeepAliveNode]: the core must not remove it while it owns a
///transport subscription, even after its last listener unsubscribes.
class TransportEventNode<T>
    implements EventNode<T>, KeepAliveNode, IncomingEventNode {
  TransportEventNode({
    required this.connection,
    required this.subjects,
    required this.originId,
    required this.topic,
    T? currentData,
    this.serializer,
    this.deserializer,
    this.onError,
    this.onRequest,
  }) {
    _local = EventNodeImp<T>(currentData: currentData);
    if (deserializer != null) {
      _subscription = connection.subscribe(
        subjects.toSubject(topic, subscription: true),
        _onMessage,
      );
    }
  }

  ///The connection used for publishing and subscriptions.
  final TransportConnection connection;

  ///The local-topic ↔ wire-subject mapper.
  final TopicSubjectMapper subjects;

  ///The identity written into the origin header.
  final String originId;

  ///The local topic this node is bound to.
  final Topic topic;

  ///Encodes the payload for the server; null means the node is local-only.
  final EventDTOSerialization? serializer;

  ///Decodes events received from the server; null means no subscription.
  final EventDTODeserialization? deserializer;

  ///Receives errors that cannot be returned to a sender.
  final TransportNodeErrorHandler? onError;

  ///Answers requests received from the broker; null means requests are not
  ///answered on this node.
  final TransportRequestAnswer? onRequest;

  late final EventNodeImp<T> _local;
  TransportSubscription? _subscription;

  @override
  T? get currentData => _local.currentData;
  @override
  set currentData(T? value) => _local.currentData = value;

  @override
  bool get isDisposed => _local.isDisposed;

  ///The transport owns an incoming subscription, so the core must keep the
  ///node even when its last listener unsubscribes.
  @override
  bool get keepAlive => true;

  @override
  StreamController<T> get streamControllerValue => _local.streamControllerValue;

  @override
  void deliver(EventDTO dto) {
    final serializer = this.serializer;
    if (serializer != null) {
      _publish(dto, serializer);
    }
    _local.deliver(dto);
  }

  ///Delivers an event that came from the broker to local listeners. It is
  ///never published again.
  @override
  void deliverIncoming(EventDTO dto) => _local.deliver(dto);

  void _publish(EventDTO dto, EventDTOSerialization serializer) {
    if (!connection.isConnected) {
      throw TransportServerUnavailableException(dto.topic.topic);
    }

    late final (String?, Uint8List) encoded;
    try {
      encoded = serializer(dto);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        TransportSerializationException(
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

  void _onMessage(TransportMessage message) {
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
        TransportDeserializationException(
          'cannot decode "${message.subject}": $error',
          subject: message.subject,
          cause: error,
        ),
        stackTrace,
      );
      return;
    }

    // Broker wildcards are not always identical to the core ones: MQTT `#`
    // also matches zero levels, while the core `>` requires one. Drop
    // over-delivered messages so every transport keeps the core semantics.
    if (TopicPattern.isPattern(topic) &&
        !TopicPattern.matches(topic, dto.topic)) {
      return;
    }

    if (dto.data is! T) {
      _report(
        TransportDeserializationException(
          'expected $T, got ${dto.data.runtimeType} '
          'on "${message.subject}"',
          subject: message.subject,
        ),
        null,
      );
      return;
    }

    final replyTo = message.replyTo;
    final onRequest = this.onRequest;
    if (replyTo != null && onRequest != null) {
      // The bus dispatches the request to listeners while resolving the
      // handler, so it must not be delivered here as well.
      unawaited(_answer(replyTo, dto, message, onRequest));
      return;
    }

    // Local delivery only: an incoming event must not be published again.
    _local.deliver(dto);
  }

  Future<void> _answer(
    String replyTo,
    EventDTO dto,
    TransportMessage message,
    TransportRequestAnswer onRequest,
  ) async {
    try {
      final bytes = await onRequest(dto, message);
      if (bytes == null) return;
      connection.publish(replyTo, bytes, originId: originId);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  void _report(Object error, StackTrace? stackTrace) {
    onError?.call(error, stackTrace);
  }

  @override
  EventNode<T> copy() => throw UnsupportedError(
      'TransportEventNode cannot be copied between buses');

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
