import 'dart:async';
import 'dart:math';

import 'package:event_bus_arch/event_bus_arch.dart';

import 'dart_nats_connection.dart';
import 'event_node_nats.dart';
import 'nats_connection.dart';
import 'nats_reconnect_policy.dart';
import 'nats_serialization.dart';

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
    _connection =
        connection ??
        DartNatsConnection(
          server,
          options: options,
          reconnect: reconnect,
          pingInterval: pingInterval,
          originId: _originId,
        );
    unawaited(_connection.start());
  }

  final Map<String, EventDTOSerialization> _serializers;
  final Map<String, EventDTODeserialization> _deserializers;
  final String _originId;

  late final NatsConnection _connection;
  Future<void>? _disposeFuture;

  ///The low-level connection. Exposed for the node and for tests.
  NatsConnection get connection => _connection;

  ///True while the client has a fully established connection.
  bool get isConnected => _connection.isConnected;

  ///The current connection state.
  NatsConnectionStatus get status => _connection.status;

  ///Connection state changes.
  Stream<NatsConnectionStatus> get connectionStatus => _connection.statusStream;

  ///Asynchronous transport errors.
  Stream<Object> get errors => _connection.errors;

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
  EventNode<T> createNode<T>({
    required Topic topic,
    T? currentData,
    Handler<T>? handler,
  }) {
    return EventNodeNatsImpl<T>(
      topic: topic,
      currentData: currentData,
      handler: handler,
      serializer: _serializerFor(topic),
      deserializer: _deserializerFor(topic),
    );
  }

  ///The serializer for a concrete topic, falling back to its type token.
  EventDTOSerialization? _serializerFor(Topic topic) =>
      _serializers[topic.topic] ?? _serializers[topic.type];

  ///The deserializer for a concrete topic, falling back to its type token.
  EventDTODeserialization? _deserializerFor(Topic topic) =>
      _deserializers[topic.topic] ?? _deserializers[topic.type];

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    await super.dispose();
    await _connection.close();
  }

  static String _newOriginId() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final salt = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return '$time-$salt';
  }
}
