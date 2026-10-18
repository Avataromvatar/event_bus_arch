import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'topic_registry_index.dart';
import 'topic_subject_mapper.dart';
import 'transport_connection.dart';
import 'transport_event_node.dart';
import 'transport_exception.dart';
import 'transport_serialization.dart';

///A bus that mirrors its topics to a broker.
///
///A topic is published to the broker only when [serializers] has an entry for
///it; it is subscribed to only when [deserializers] has one. `fire` to a topic
///outside both registries behaves exactly like a local bus: if no local node
///exists, it returns false.
///
///Node creation is lazy and typed: `listen<T>`, `setHandler<T>` and
///`fire<T>`/`request<T>` call [createNode], which resolves the serializer and
///the deserializer for the topic and returns a [TransportEventNode].
class TransportEventBus extends EventBusImpl {
  TransportEventBus({
    required TransportConnection connection,
    required TopicSubjectMapper subjects,
    Map<String, EventDTOSerialization>? serializers,
    Map<String, EventDTODeserialization>? deserializers,
    required String originId,
  })  : _serializers =
            Map<String, EventDTOSerialization>.unmodifiable(serializers ?? {}),
        _deserializers = Map<String, EventDTODeserialization>.unmodifiable(
            deserializers ?? {}),
        _originId = originId,
        super(false) {
    _subjects = subjects;
    for (final key in _serializers.keys) {
      _subjects.validatePublishKey(key);
    }
    for (final key in _deserializers.keys) {
      _subjects.validateSubscribeKey(key);
    }
    _serializerIndex = TopicRegistryIndex(_serializers, allowPatterns: false);
    _deserializerIndex =
        TopicRegistryIndex(_deserializers, allowPatterns: true);

    _connection = connection;
    _connectionErrorsSubscription =
        _connection.errors.listen((error) => _reportError(error));
    unawaited(_connection.start());
  }

  final Map<String, EventDTOSerialization> _serializers;
  final Map<String, EventDTODeserialization> _deserializers;
  final String _originId;

  late final TopicSubjectMapper _subjects;
  late final TopicRegistryIndex<EventDTOSerialization> _serializerIndex;
  late final TopicRegistryIndex<EventDTODeserialization> _deserializerIndex;

  late final TransportConnection _connection;
  StreamSubscription<Object>? _connectionErrorsSubscription;
  final _errorController = StreamController<Object>.broadcast();
  Future<void>? _disposeFuture;

  ///The topic-to-subject mapper used by this bus.
  TopicSubjectMapper get subjects => _subjects;

  ///The low-level connection. Exposed for the node and for tests.
  TransportConnection get connection => _connection;

  ///True while the client has a fully established connection.
  bool get isConnected => _connection.isConnected;

  ///The current connection state.
  TransportStatus get status => _connection.status;

  ///Connection state changes.
  Stream<TransportStatus> get connectionStatus => _connection.statusStream;

  ///Asynchronous transport and node errors.
  Stream<Object> get errors => _errorController.stream;

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

  ///Creates a node for a topic that is known to either registry.
  @override
  bool shouldCreateNodeOnSend(Topic topic) =>
      _serializerFor(topic) != null || _deserializerFor(topic) != null;

  @override
  EventNode<T> createNode<T>({
    required Topic topic,
    T? currentData,
  }) {
    final deserializer = _deserializerFor(topic);
    if (deserializer != null) {
      // The node subscribes when it is created; reject an invalid pattern
      // before a broker subscription is attempted.
      _subjects.validateSubscribe(topic);
    }
    return TransportEventNode<T>(
      connection: _connection,
      subjects: _subjects,
      originId: _originId,
      onError: (error, stackTrace) => _reportError(error, stackTrace),
      onRequest: _answerRequest,
      topic: topic,
      currentData: currentData,
      serializer: _serializerFor(topic),
      deserializer: deserializer,
    );
  }

  ///Requests without a local handler are sent to the broker, and the first
  ///response is decoded with the deserializer registered for the topic.
  ///
  ///A local handler always wins: when one exists, the request never leaves the
  ///process. Without a local handler both a serializer and a deserializer are
  ///required; otherwise [NoHandlerException] is thrown.
  @override
  Future<dynamic> request<T>(
    T data, {
    List<String>? paths,
    String? separator,
    Map<String, String>? arguments,
    Duration? timeout,
  }) {
    if (isDisposed) {
      throw StateError('EventBus is disposed: $this');
    }
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    if (TopicPattern.isPattern(topic)) {
      throw EventBusException(
          'request does not support wildcard paths ("${topic.topic}")');
    }
    if (haveHandler<T>(paths: paths, separator: separator)) {
      return super.request<T>(
        data,
        paths: paths,
        separator: separator,
        arguments: arguments,
        timeout: timeout,
      );
    }
    return _requestTransport<T>(topic, data, arguments, timeout);
  }

  Future<dynamic> _requestTransport<T>(
    Topic topic,
    T data,
    Map<String, String>? arguments,
    Duration? timeout,
  ) async {
    final serializer = _serializerFor(topic);
    final deserializer = _deserializerFor(topic);
    if (serializer == null || deserializer == null) {
      throw NoHandlerException(topic.topic);
    }

    _subjects.validatePublish(topic);
    final dto = EventDTO<T>(data, topic: topic, arguments: arguments);

    late final (String?, Uint8List) encoded;
    try {
      encoded = serializer(dto);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        TransportSerializationException(
          'serializer failed for "${topic.topic}": $error',
          subject: topic.topic,
          cause: error,
        ),
        stackTrace,
      );
    }

    final (overrideSubject, bytes) = encoded;
    final subject = overrideSubject ?? _subjects.toSubject(topic);
    if (overrideSubject != null) {
      _subjects.validatePublishSubject(overrideSubject);
    }

    final reply = await _connection.request(
      subject,
      bytes,
      arguments: arguments,
      originId: _originId,
      timeout: timeout,
    );

    try {
      final response = deserializer(
        reply.data,
        topic.topic,
        arguments: reply.arguments,
      );
      return response.data;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        TransportDeserializationException(
          'cannot decode the response for "${topic.topic}": $error',
          subject: topic.topic,
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  ///Invokes the local handler for an incoming request and encodes its result.
  ///The response always goes to the request's reply subject: a subject
  ///returned by the serializer is ignored.
  Future<Uint8List?> _answerRequest(
    EventDTO dto,
    TransportMessage message,
  ) async {
    final result = await handleIncomingRequest(dto);
    final serializer = _serializerFor(dto.topic);
    if (serializer == null) {
      throw TransportSerializationException(
        'no serializer to answer a request on "${dto.topic.topic}"',
        subject: dto.topic.topic,
      );
    }

    final response = EventDTO<dynamic>(
      result,
      topic: dto.topic,
      arguments: dto.arguments,
    );
    try {
      final (_, bytes) = serializer(response);
      return bytes;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        TransportSerializationException(
          'serializer failed to answer "${dto.topic.topic}": $error',
          subject: dto.topic.topic,
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  ///The serializer for a concrete topic, falling back to its type token.
  EventDTOSerialization? _serializerFor(Topic topic) =>
      _serializerIndex.resolve(topic);

  ///The deserializer for a concrete topic, falling back to its type token and
  ///then to the most specific wildcard pattern.
  EventDTODeserialization? _deserializerFor(Topic topic) =>
      _deserializerIndex.resolve(topic);

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    await super.dispose();
    await _connectionErrorsSubscription?.cancel();
    _connectionErrorsSubscription = null;
    try {
      await _connection.close();
    } finally {
      await _errorController.close();
    }
  }

  void _reportError(Object error, [StackTrace? stackTrace]) {
    if (!_errorController.isClosed) {
      _errorController.add(error);
    }
  }
}

///A random identity for the origin header.
String newTransportOriginId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final salt = Random.secure().nextInt(0x7fffffff).toRadixString(16);
  return '$time-$salt';
}
