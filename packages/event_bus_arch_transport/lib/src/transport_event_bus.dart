import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'event_address_mapper.dart';
import 'event_codec.dart';
import 'transport_connection.dart';
import 'transport_exception.dart';
import 'transport_key_event_node.dart';

///A bus that mirrors its keys to a broker.
///
///A key is published to the broker only when a codec with `encode` resolves
///for its address; it is subscribed to only when a codec with `decode`
///resolves. `fire` to an address outside the registry behaves exactly like a
///local bus: if no local node exists, it returns false.
///
///Node creation is lazy and typed: `listen<T>`, `subscribe<T>(handler:)`
///and `fire<T>`/`request<T>` call [createNodeForKey] or
///[createPatternNodeForKey], which resolve the codec for the address and return
///a [TransportKeyEventNode].
class TransportEventBus extends EventBusImpl {
  ///Creates a transport bus for the E address model.
  ///
  ///The wire subject is the event address; [codecs] resolve an encoder and a
  ///decoder by address. No Dart type name and no `typeTags` are involved.
  TransportEventBus.keys({
    required TransportConnection connection,
    required EventAddressMapper addresses,
    required EventCodecRegistry codecs,
    required String originId,
    ObservabilityConfig? observability,
  })  : _addresses = addresses,
        _codecs = codecs,
        _originId = originId,
        super(false,
            observability: observability ?? ObservabilityConfig.disabled) {
    _connection = connection;
    _connectionErrorsSubscription =
        _connection.errors.listen((error) => _reportError(error));
    unawaited(_connection.start());
  }

  final String _originId;

  late final EventAddressMapper _addresses;
  late final EventCodecRegistry _codecs;

  late final TransportConnection _connection;
  StreamSubscription<Object>? _connectionErrorsSubscription;
  Future<void>? _disposeFuture;

  ///The address-to-subject mapper of this bus.
  EventAddressMapper get addresses => _addresses;

  ///The codec registry of this bus.
  EventCodecRegistry get codecs => _codecs;

  ///The low-level connection. Exposed for the node and for tests.
  TransportConnection get connection => _connection;

  ///True while the client has a fully established connection.
  bool get isConnected => _connection.isConnected;

  ///The current connection state.
  TransportStatus get status => _connection.status;

  ///Connection state changes.
  Stream<TransportStatus> get connectionStatus => _connection.statusStream;

  ///The identity this bus writes into the origin header.
  String get originId => _originId;

  ///Completes when the connection is established. With [timeout], completes
  ///with a [TimeoutException] when that does not happen in time.
  Future<void> waitConnected({Duration? timeout}) {
    if (isConnected) return Future.value();
    final future = _connection.statusStream
        .firstWhere((status) => status == TransportStatus.connected)
        .then<void>((_) {});
    return timeout == null ? future : future.timeout(timeout);
  }

  @override
  bool shouldCreateNodeOnSendKey<T>(EventKey<T> key) =>
      _codecs.resolve(key.address)?.canEncode == true;

  @override
  EventNode<T> createNodeForKey<T>({
    required EventKey<T> key,
    T? currentData,
  }) {
    return TransportKeyEventNode<T>(
      connection: _connection,
      addresses: _addresses,
      codecs: _codecs,
      selector: key,
      originId: _originId,
      currentData: currentData,
      onError: (error, stackTrace) => _reportError(error, stackTrace),
      onRequest: (dto, message, codec) =>
          _answerKeyedRequest(key, dto, message, codec),
    );
  }

  @override
  EventNode<T> createPatternNodeForKey<T>({
    required EventPatternKey<T> key,
    T? currentData,
  }) {
    return TransportKeyEventNode<T>(
      connection: _connection,
      addresses: _addresses,
      codecs: _codecs,
      selector: key,
      originId: _originId,
      currentData: currentData,
      onError: (error, stackTrace) => _reportError(error, stackTrace),
      onRequest: (dto, message, codec) =>
          _answerKeyedRequest(key, dto, message, codec),
    );
  }

  ///A request on a keyed transport bus: a local handler wins, otherwise the
  ///codec publishes the request and decodes the first response.
  @override
  Future<dynamic> request<T>(
    EventKey<T> key,
    T data, {
    Map<String, String>? arguments,
    Duration? timeout,
    CancelToken? cancelToken,
    String? correlationId,
  }) {
    if (isDisposed) {
      throw StateError('EventBus is disposed: $this');
    }
    if (cancelToken?.isCancelled ?? false) {
      throw RequestCanceledException(key.address.value);
    }
    if (haveHandler<T>(key)) {
      return super.request<T>(key, data,
          arguments: arguments,
          timeout: timeout,
          cancelToken: cancelToken,
          correlationId: correlationId);
    }
    final codec = _codecs.resolve(key.address);
    if (codec == null) {
      throw NoHandlerException(key.address.value);
    }
    if (codec.encode == null || codec.decode == null) {
      throw EventBusTransportException(
        'a keyed remote request on "${key.address.value}" needs both an '
        'encoder and a decoder',
      );
    }
    return _requestKeyTransport<T>(
        key, codec, data, arguments, timeout, correlationId);
  }

  Future<dynamic> _requestKeyTransport<T>(
    EventKey<T> key,
    EventCodec codec,
    T data,
    Map<String, String>? arguments,
    Duration? timeout,
    String? correlationId,
  ) async {
    final observing = isObservable && observabilityConfig.metrics;
    final started = observing ? DateTime.now().microsecondsSinceEpoch : 0;
    if (observing) metrics.recordRequestStarted(key.address.value);
    try {
      final dto = EventDTO<T>.withKey(key, data,
          arguments: arguments, correlationId: correlationId);
      final (override, bytes) = codec.encode!(dto);
      final subject = override ?? _addresses.toSubject(key);
      if (override != null) {
        _addresses.validatePublishSubject(override);
      }
      final reply = await _connection.request(
        subject,
        bytes,
        arguments: arguments,
        correlationId: correlationId,
        originId: _originId,
        timeout: timeout,
      );
      final response = codec.decode!(
        reply.data,
        key.address,
        arguments: reply.arguments,
      );
      if (observing) {
        metrics.recordRequestOutcome(key.address.value, RequestOutcome.completed,
            DateTime.now().microsecondsSinceEpoch - started);
      }
      return response.data;
    } catch (error) {
      if (observing) {
        metrics.recordRequestOutcome(
            key.address.value,
            error is TimeoutException
                ? RequestOutcome.timeout
                : RequestOutcome.errored,
            DateTime.now().microsecondsSinceEpoch - started);
      }
      rethrow;
    }
  }

  ///Invokes the local handler for an incoming request and encodes its result.
  ///The response always goes to the request's reply subject: a subject
  ///returned by the encoder is ignored.
  ///
  ///A request can reach several overlapping subscriptions (an exact listener
  ///node and a pattern handler node, for example). Only the node that owns the
  ///handler's registration address answers; the others stay silent.
  Future<Uint8List?> _answerKeyedRequest(
    EventSelector selector,
    EventDTO dto,
    TransportMessage message,
    EventCodec codec,
  ) async {
    final nodeAddress = selector is EventPatternKey
        ? selector.pattern.value
        : (selector as EventKey).address.value;
    if (handlerAddressFor(dto.address) != nodeAddress) return null;

    final result = await handleIncomingRequest(dto);
    final encode = codec.encode;
    if (encode == null) {
      throw TransportSerializationException(
        'no encoder to answer a request on "${dto.address}"',
        subject: dto.address,
      );
    }
    final response = EventDTO<dynamic>.withKey(
      EventKey<dynamic>(dto.address),
      result,
      arguments: dto.arguments,
      correlationId: dto.correlationId,
    );
    try {
      final (_, bytes) = encode(response);
      return bytes;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        TransportSerializationException(
          'encoder failed to answer "${dto.address}": $error',
          subject: dto.address,
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    await super.dispose();
    await _connectionErrorsSubscription?.cancel();
    _connectionErrorsSubscription = null;
    await _connection.close();
  }

  void _reportError(Object error, [StackTrace? stackTrace]) {
    reportError(EventBusError(
      kind: EventBusErrorKind.transport,
      source: EventBusErrorSource.transport,
      error: error,
      stackTrace: stackTrace,
    ));
  }
}

///A random identity for the origin header.
String newTransportOriginId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final salt = Random.secure().nextInt(0x7fffffff).toRadixString(16);
  return '$time-$salt';
}
