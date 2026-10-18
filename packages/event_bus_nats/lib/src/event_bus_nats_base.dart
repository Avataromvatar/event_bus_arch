import 'dart:async';
import 'dart:math';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'dart_nats_connection.dart';
import 'event_node_nats.dart';
import 'nats_connection.dart';
import 'nats_reconnect_policy.dart';
import 'nats_registry.dart';
import 'nats_serialization.dart';
import 'nats_subject.dart';

///A bus that mirrors its topics to a NATS server.
///
///A topic is published to the server only when [serializers] has an entry for
///it; it is subscribed to only when [deserializers] has one. `send` to a topic
///outside both registries behaves exactly like a local bus: if no local node
///exists, it returns null.
///
///Node creation is lazy and typed: `listen<T>`, `setHandler<T>` and `send<T>`
///call [createNode], which resolves the serializer and the deserializer for
///the topic and returns an [EventNodeNatsImpl]. There is no way to create a
///typed node from a registry key alone, so a topic becomes active when the
///application uses it.
class EventBusNats extends EventBusImpl {
  ///[connection] replaces the default [DartNatsConnection]; when it is given,
  ///[server], [options], [reconnect] and [pingInterval] are ignored. The
  ///injected connection must use the same origin id as [originId] to filter
  ///the bus's own echo.
  EventBusNats(
    Uri server, {
    Map<String, EventDTOSerialization>? serializers,
    Map<String, EventDTODeserialization>? deserializers,
    NatsConnectionOptions options = const NatsConnectionOptions(),
    NatsReconnectPolicy reconnect = const NatsReconnectPolicy(),
    Duration pingInterval = const Duration(seconds: 5),
    String? subjectPrefix,
    Map<String, String>? typeTags,
    String? originId,
    NatsConnection? connection,
  }) : _serializers = Map<String, EventDTOSerialization>.unmodifiable(
         serializers ?? {},
       ),
       _deserializers = Map<String, EventDTODeserialization>.unmodifiable(
         deserializers ?? {},
       ),
       _originId = originId ?? _newOriginId(),
       super(false) {
    _subjects = NatsSubjectMapper(prefix: subjectPrefix, typeTags: typeTags);
    for (final key in _serializers.keys) {
      _subjects.validatePublishKey(key);
    }
    for (final key in _deserializers.keys) {
      _subjects.validateSubscribeKey(key);
    }
    _serializerIndex = NatsRegistryIndex(_serializers, allowPatterns: false);
    _deserializerIndex = NatsRegistryIndex(_deserializers, allowPatterns: true);

    _connection =
        connection ??
        DartNatsConnection(
          server,
          options: options,
          reconnect: reconnect,
          pingInterval: pingInterval,
          originId: _originId,
        );
    _connectionErrorsSubscription = _connection.errors.listen(
      (error) => _reportError(error),
    );
    unawaited(_connection.start());
  }

  final Map<String, EventDTOSerialization> _serializers;
  final Map<String, EventDTODeserialization> _deserializers;
  final String _originId;

  late final NatsSubjectMapper _subjects;
  late final NatsRegistryIndex<EventDTOSerialization> _serializerIndex;
  late final NatsRegistryIndex<EventDTODeserialization> _deserializerIndex;

  late final NatsConnection _connection;
  StreamSubscription<Object>? _connectionErrorsSubscription;
  final _errorController = StreamController<Object>.broadcast();
  Future<void>? _disposeFuture;

  ///The topic-to-subject mapper used by this bus.
  NatsSubjectMapper get subjects => _subjects;

  ///The low-level connection. Exposed for the node and for tests.
  NatsConnection get connection => _connection;

  ///True while the client has a fully established connection.
  bool get isConnected => _connection.isConnected;

  ///The current connection state.
  NatsConnectionStatus get status => _connection.status;

  ///Connection state changes.
  Stream<NatsConnectionStatus> get connectionStatus => _connection.statusStream;

  ///Asynchronous transport and node errors.
  Stream<Object> get errors => _errorController.stream;

  ///The identity this bus writes into the origin header.
  String get originId => _originId;

  ///Completes when the connection is established. With [timeout], completes
  ///with a [TimeoutException] when that does not happen in time.
  Future<void> waitConnected({Duration? timeout}) {
    if (isConnected) return Future.value();
    final future = _connection.statusStream
        .firstWhere((status) => status == NatsConnectionStatus.connected)
        .then<void>((_) {});
    return timeout == null ? future : future.timeout(timeout);
  }

  ///Creates a node for a topic that is known to either registry.
  @override
  bool shouldCreateNodeOnSend(Topic topic) =>
      _serializerFor(topic) != null || _deserializerFor(topic) != null;

  @override
  EventNode<T> createNode<T>({required Topic topic, T? currentData}) {
    final deserializer = _deserializerFor(topic);
    if (deserializer != null) {
      // The node subscribes when it is created; reject an invalid pattern
      // before a server subscription is attempted.
      _subjects.validateSubscribe(topic);
    }
    return EventNodeNatsImpl<T>(
      connection: _connection,
      subjects: _subjects,
      originId: _originId,
      onError: (error, stackTrace) => _reportError(error, stackTrace),
      topic: topic,
      currentData: currentData,
      serializer: _serializerFor(topic),
      deserializer: deserializer,
    );
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

  static String _newOriginId() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final salt = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return '$time-$salt';
  }
}
