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

///A request matched handler subscriptions, but none had a free slot or queue
///room, or all matching handlers were paused.
class BusyException extends EventBusException {
  BusyException(this.topic, [String? reason])
      : super('no handler capacity for "$topic"'
            '${reason == null ? '' : ': $reason'}');

  ///The topic of the request.
  final String topic;
}

///A request did not complete within its timeout.
class RequestTimeoutException extends EventBusException {
  RequestTimeoutException(this.topic, this.timeout)
      : super('request "$topic" timed out after $timeout');

  ///The topic of the request.
  final String topic;

  ///The timeout that expired.
  final Duration timeout;
}

///A request was cancelled by its caller.
class RequestCanceledException extends EventBusException {
  RequestCanceledException(this.topic)
      : super('request "$topic" was cancelled');

  ///The topic of the request.
  final String topic;
}
