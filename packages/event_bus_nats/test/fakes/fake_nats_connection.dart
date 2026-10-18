import 'package:event_bus_transport/testing.dart';

export 'package:event_bus_transport/testing.dart';

///An in-memory NATS connection for tests; the shared transport fake.
typedef FakeNatsConnection = FakeTransportConnection;

///One publish captured by [FakeNatsConnection].
typedef FakePublish = FakeTransportPublish;
