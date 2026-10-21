import 'package:event_bus_arch_transport/testing.dart';

export 'package:event_bus_arch_transport/testing.dart';

///An in-memory MQTT connection for tests; the shared transport fake.
typedef FakeMqttConnection = FakeTransportConnection;

///One publish captured by [FakeMqttConnection].
typedef FakePublish = FakeTransportPublish;
