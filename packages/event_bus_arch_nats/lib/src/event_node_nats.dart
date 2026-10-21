import 'package:event_bus_arch_transport/event_bus_arch_transport.dart';

export 'package:event_bus_arch_transport/event_bus_arch_transport.dart'
    show TransportEventNode, TransportNodeErrorHandler;

///The node of a NATS bus. The implementation is shared by all transports.
typedef EventNodeNatsImpl<T> = TransportEventNode<T>;
