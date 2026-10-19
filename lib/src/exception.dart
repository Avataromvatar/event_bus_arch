part of event_arch;

///The exception type of the package: an invalid topic, an uninitialized
///Scope/Command, an isolate exchange failure.
class EventBusException implements Exception {
  final dynamic message;
  EventBusException([this.message]);
  @override
  String toString() {
    Object? message = this.message;
    if (message == null) return "EventBusException";
    return "EventBusException: $message";
  }
}

///A [EventBus.request] had no handler to answer it.
class NoHandlerException extends EventBusException {
  NoHandlerException(this.topic) : super('no request handler for "$topic"');

  ///The topic of the request.
  final String topic;
}
