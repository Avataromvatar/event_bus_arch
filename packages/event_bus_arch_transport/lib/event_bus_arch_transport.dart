///Broker-agnostic transport layer for `event_bus_arch`.
///
///It provides the connection seam ([TransportConnection]), the reconnecting
///lifecycle ([ReconnectingTransportConnection]), the address ↔ subject mapping
///([EventAddressMapper] with a broker-specific [SubjectGrammar]), the typed
///codec registry ([EventCodecRegistry]), and the transport bus and node
///([TransportEventBus], [TransportKeyEventNode]). A broker package supplies a
///connection adapter and a grammar.
library;

export 'src/event_address_mapper.dart';
export 'src/event_codec.dart';
export 'src/reconnecting_transport_connection.dart';
export 'src/reconnect_policy.dart';
export 'src/subject_grammar.dart';
export 'src/transport_connection.dart';
export 'src/transport_event_bus.dart';
export 'src/transport_exception.dart';
export 'src/transport_key_event_node.dart';
