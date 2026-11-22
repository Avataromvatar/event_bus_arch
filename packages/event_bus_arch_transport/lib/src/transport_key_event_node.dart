import 'dart:async';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'event_address_mapper.dart';
import 'event_codec.dart';
import 'transport_connection.dart';
import 'transport_exception.dart';

///A transport node for the E address model.
///
///The node is bound to an exact [EventKey] or an [EventPatternKey]. The address
///is the wire subject; the local type is only a filter. A message received from
///the broker is decoded by the codec for its concrete address and delivered to
///the node's local listeners.
///
///Only the exact key that produced an event publishes it. A supertype key or a
///pattern node delivers locally and never publishes, which prevents duplicate
///broker messages.
class TransportKeyEventNode<T>
    implements
        EventNode<T>,
        KeepAliveNode,
        IncomingEventNode,
        SubscriptionHost<T> {
  TransportKeyEventNode({
    required this.connection,
    required this.addresses,
    required this.codecs,
    required this.selector,
    required this.originId,
    T? currentData,
    this.onError,
  }) : _local = EventNodeImp<T>(currentData: currentData) {
    if (_shouldSubscribe) {
      _subscription = connection.subscribe(
        addresses.toSubject(selector, subscription: true),
        _onMessage,
      );
    }
  }

  final TransportConnection connection;
  final EventAddressMapper addresses;
  final EventCodecRegistry codecs;
  final EventSelector<T> selector;
  final String originId;
  final void Function(Object error, StackTrace? stackTrace)? onError;

  late final EventNodeImp<T> _local;
  TransportSubscription? _subscription;

  bool get _shouldSubscribe {
    final selector = this.selector;
    if (selector is EventPatternKey<T>) {
      return codecs.forPattern(selector.pattern)?.canDecode == true ||
          codecs.hasDecoders;
    }
    return codecs.resolve((selector as EventKey<T>).address)?.canDecode == true;
  }

  EventCodec? get _exactCodec {
    final selector = this.selector;
    return selector is EventKey<T>
        ? codecs.resolve(selector.address)
        : null;
  }

  @override
  T? get currentData => _local.currentData;
  @override
  set currentData(T? value) => _local.currentData = value;

  @override
  bool get isDisposed => _local.isDisposed;

  @override
  bool get keepAlive => true;

  @override
  StreamController<T> get streamControllerValue => _local.streamControllerValue;

  @override
  Iterable<EventSubscription<T>> get subscriptions => _local.subscriptions;

  @override
  void addSubscription(EventSubscription<T> subscription) =>
      _local.addSubscription(subscription);

  @override
  void removeSubscription(EventSubscription<T> subscription) =>
      _local.removeSubscription(subscription);

  @override
  bool get hasSubscriptions => _local.hasSubscriptions;

  @override
  bool get hasListenerSubscriptions => _local.hasListenerSubscriptions;

  @override
  bool deliver(EventDTO dto) {
    final selector = this.selector;
    final codec = _exactCodec;
    final canPublish = selector is EventKey<T> &&
        codec?.encode != null &&
        dto.key == selector;
    final published = canPublish ? _publish(dto, codec!.encode!) : false;
    final local = _local.deliver(dto);
    return published || local;
  }

  ///Delivers an event that came from the broker to local listeners. It is
  ///never published again.
  @override
  void deliverIncoming(EventDTO dto) => _local.deliver(dto);

  void _onMessage(TransportMessage message) {
    final address = addresses.toAddress(message.subject);
    final codec = codecs.resolve(address);
    final decode = codec?.decode;
    if (decode == null) return;

    late EventDTO dto;
    try {
      dto = decode(message.data, address, arguments: message.arguments);
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

    if (dto.data is! T) {
      _report(
        TransportDeserializationException(
          'expected $T, got ${dto.data.runtimeType} on "${message.subject}"',
          subject: message.subject,
        ),
        null,
      );
      return;
    }

    final selector = this.selector;
    if (selector is EventPatternKey<T> &&
        !selector.pattern.matches(address)) {
      return;
    }

    final correlationId = message.correlationId;
    if (correlationId != null && dto.correlationId != correlationId) {
      dto = dto.copyWith(correlationId: correlationId);
    }
    if (dto.key.address.value != address.value) {
      dto = EventDTO<T>.withKey(
        EventKey<T>(address.value),
        dto.data as T,
        arguments: dto.arguments,
        correlationId: dto.correlationId,
      );
    }

    _local.deliver(dto);
  }

  bool _publish(EventDTO dto, EventEncoder encode) {
    if (!connection.isConnected) {
      throw TransportServerUnavailableException(dto.address);
    }
    late final (String?, Uint8List) encoded;
    try {
      encoded = encode(dto);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        TransportSerializationException(
          'encoder failed for "${dto.address}": $error',
          subject: dto.address,
          cause: error,
        ),
        stackTrace,
      );
    }
    final (overrideSubject, bytes) = encoded;
    final subject =
        overrideSubject ?? addresses.toSubject(EventKey<Object?>(dto.address));
    if (overrideSubject != null) {
      addresses.validatePublishSubject(overrideSubject);
    }
    connection.publish(
      subject,
      bytes,
      arguments: dto.arguments,
      correlationId: dto.correlationId,
      originId: originId,
    );
    return true;
  }

  void _report(Object error, StackTrace? stackTrace) {
    onError?.call(error, stackTrace);
  }

  @override
  EventNode<T> copy() => throw UnsupportedError(
      'TransportKeyEventNode cannot be copied between buses');

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
