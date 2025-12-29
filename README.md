# EventBus Arch

EventBus Arch is a Dart package that provides an event-driven architecture for managing communication between different parts of an application. It allows components to communicate with each other through events, promoting loose coupling and better organization of code.
EventBus have a two type is Model and Common. isModelBus autocreate Node if user try send Event what not have Node. Common EventBus not create Node if user send Event what not have Node. 
## Features

- Send and receive events between components
- Support for event handlers with optional return values
- Isolate-safe event bus for multi-threaded applications
- Event scoping with command pattern support
- Type-safe event handling
- Flexible topic-based routing
- two type EventBus: Model and Common. isModelBus autocreate Node if user try send Event what not have Node, Common EventBus dont create Node

## Installation

Add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  event_bus_arch: ^2.1.0
```

Then run:

```bash
flutter pub get
```

## Usage

### Basic Usage

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

void main() async {
  // Create an EventBus
  EventBus bus = EventBus();
  
  // Listen for events
  bus.listen<String>().listen((event) {
    print('Received event: $event');
  });
  
  // Send an event
  await bus.send('Hello, World!');
}
```

### Event Handlers

```dart
// Set up an event handler
(bus as EventBusHandlers).setHandler<String>(handler: (dto, lastData) async {
  print('Handler received: ${dto.data}');
  // Optionally complete the event with a result
  dto.completer?.complete('Processed: ${dto.data}');
});

// Send an event and get the result
var result = await bus.send('Test message');
print('Result: $result'); // Result: Processed: Test message
```

### EventBusIsolate

For multi-threaded applications, EventBusIsolate provides a way to send events between the main isolate and worker isolates:

```dart
///this func run in isolate. And we wait event <int> and send result <String>
void _initIsolate(EventBus bus) {
  (bus as EventBusHandlers).setHandler<int>(handler: (dto, lastData) async {
    // Process event in isolate
    dto.completer?.complete(dto.data);
    // Send event back to main thread
    bus.send(dto.data.toString());
  });
}

void main() async {
  EventBusIsolate isolateBus = EventBusIsolate(onInit: _initIsolate);
  await isolateBus.waitInit;
  
  // Listen for events from isolate
  isolateBus.listen<String>().listen((event) {
    print('Event from isolate: $event');
  });
  
  // Send event to isolate
  var result = await isolateBus.send(10);
  print('Result: $result'); //Result: 10
}
```

### Scoping with Command Pattern

The Scope class provides a way to manage event-based state with command pattern support:

```dart
Scope<String> scope = Scope<String>();

void initScope() {
  scope.initScope(bus, initalData: 'Initial Value', onUpdate: (data) {
    print('Data updated: $data');
  });
}

// Send an event
await scope.call('New Value');

// Undo last event
await scope.undo();
```

## API Reference

### EventBus

The EventBus class provides core functionality for sending and receiving events.

#### Methods

- `send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments})` - Send an event
- `listen<T>({String? path, String? target})` - Listen for events
- `lastData<T>({String? path, String? target})` - Get the last data sent for a topic
- `haveHandler<T>({String? path, String? target})` - Check if a handler exists for a topic
- `haveListener<T>({String? path, String? target})` - Check if a listener exists for a topic

### EventBusHandlers

The EventBusHandlers mixin provides methods for managing event handlers.

#### Methods

- `setHandler<T>({T? initalData, String? path, String? target, required Handler<T> handler})` - Set an event handler
- `removeHandler<T>({String? path, String? target})` - Remove an event handler
- `addAllHandlerFromOtherBus(EventBus fromBus)` - Copy all handlers from another bus
- `removeAllHandlerPresentInOtherBus(EventBus otherBus)` - Remove handlers present in another bus

### Command

The Command class provides command pattern support for event handling.

#### Methods

- `execute(T data, {String? fragment, Map<String, String>? arguments})` - Execute a command
- `undo()` - Undo the last command
- `queueLenght` - Get the queue length
- `lastCall` - Get the last call details

### Scope

The Scope class provides scoping for events with command pattern support.

#### Methods

- `initScope(EventBus bus, {T? initalData, bool initalDataNeedExecute = true, String? path, int maxLenForUndo = 0, void Function(T newData)? onUpdate})` - Initialize the scope
- `call(T newData, {String? fragment, Map<String, String>? arguments})` - Call an event
- `undo()` - Undo the last event
- `disposeScope({bool removeHandler = true})` - Dispose the scope

### Topic

The Topic class represents event topics with various components.

#### Properties

- `shema` - The schema of the topic
- `target` - The target of the topic
- `type` - The type of the topic
- `host` - The host of the topic
- `path` - The path of the topic
- `fragment` - The fragment of the topic
- `arguments` - The arguments of the topic
- `topic` - The topic without fragment and arguments
- `topicWithFragment` - The topic with fragment
- `fullTopic` - The full topic with fragment and arguments

## Version 2 Changes

Version 2 introduced several significant changes:

1. **Reduced code base**: Simplified architecture for easier maintenance
2. **EventBusIsolate**: Added support for isolate-safe event communication
3. **Simplified event handling**: Removed the "call" method, now always return either a result or null
4. **Removed EventBusMaster**: Abandoned the need to give names to EventBus
5. **Improved handler return values**: Handlers can now return results via Completer in EventDTO

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
