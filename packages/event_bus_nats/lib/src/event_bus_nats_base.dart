import 'dart:async';

import 'package:dart_nats/dart_nats.dart' as nats;
import 'package:event_bus_arch/event_bus_arch.dart';

import 'event_node_nats.dart';
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
  EventBusNats(
    Uri server, {
    Map<String, EventDTOSerialization>? serializers,
    Map<String, EventDTODeserialization>? deserializers,
    nats.ConnectOption? connectOption,
    Duration pingInterval = const Duration(seconds: 5),
  }) : _serializers = Map<String, EventDTOSerialization>.unmodifiable(
         serializers ?? {},
       ),
       _deserializers = Map<String, EventDTODeserialization>.unmodifiable(
         deserializers ?? {},
       ),
       super(false) {
    _client = nats.Client();
    _statusSubscription = _client.statusStream.listen(_updateClientStatus);
    // The constructor cannot await. A failed attempt must not escape as an
    // unhandled error: callers observe [isConnected] and `send` reports the
    // unavailable server. The reconnect supervisor is added later.
    unawaited(
      _connect(
        server,
        connectOption: connectOption,
        pingInterval: pingInterval,
      ),
    );
  }

  final Map<String, EventDTOSerialization> _serializers;
  final Map<String, EventDTODeserialization> _deserializers;

  late final nats.Client _client;
  late final StreamSubscription<nats.Status> _statusSubscription;
  Future<void>? _disposeFuture;

  ///True while the client has a fully established connection.
  bool get isConnected => _client.status == nats.Status.connected;

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

  Future<void> _connect(
    Uri server, {
    nats.ConnectOption? connectOption,
    required Duration pingInterval,
  }) async {
    try {
      await _client.connect(
        server,
        connectOption: connectOption,
        pingInterval: pingInterval,
        retry: false,
      );
    } catch (_) {
      // Reported through [isConnected]; send() tells the caller.
    }
  }

  void _updateClientStatus(nats.Status _) {
    // Connection state is read through [isConnected]. Reconnect handling
    // will be added with the connection adapter.
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    await super.dispose();
    await _statusSubscription.cancel();
    await _client.forceClose();
  }
}
