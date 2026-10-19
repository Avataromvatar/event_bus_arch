///Broker-agnostic transport layer for `event_bus_arch`.
///
///It provides the connection seam ([TransportConnection]), the reconnecting
///lifecycle ([ReconnectingTransportConnection]), the topic ↔ subject mapping
///([TopicSubjectMapper] with a broker-specific [SubjectGrammar]), the registry
///index, and the transport bus and node ([TransportEventBus],
///[TransportEventNode]). A broker package supplies a connection adapter, a
///grammar and, when its client API needs it, a subject mapper subclass.
library;

export 'src/reconnecting_transport_connection.dart';
export 'src/reconnect_policy.dart';
export 'src/subject_grammar.dart';
export 'src/topic_registry_index.dart';
export 'src/topic_subject_mapper.dart';
export 'src/transport_connection.dart';
export 'src/transport_event_bus.dart';
export 'src/transport_event_node.dart';
export 'src/transport_exception.dart';
export 'src/transport_serialization.dart';
