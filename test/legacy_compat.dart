// Test-only compatibility facade for the 3.x paths/separator API.
//
// The production library no longer exposes these methods. Existing behaviour
// tests still exercise them through this file, which reproduces the old
// type-prefixed topic string as an EventAddress; the keyed tests in
// `test/event_key_bus_test.dart` cover the public E API directly.
//
// Do not use this file in application code or examples.

import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';

String _legacyTopic<T>(List<String>? paths, String? separator) {
  final path = (paths ?? const <String>[]).join(separator ?? '.');
  final type = T.toString();
  return path.isEmpty ? type : '$type${separator ?? '.'}$path';
}

EventKey<T> _legacyKey<T>(List<String>? paths, String? separator) =>
    EventKey<T>(_legacyTopic<T>(paths, separator));

EventSelector<T> _legacySelector<T>(List<String>? paths, String? separator) {
  final topic = _legacyTopic<T>(paths, separator);
  final hasWildcard =
      (paths ?? const <String>[]).any((p) => p.contains('*') || p.contains('>'));
  return hasWildcard
      ? EventPatternKey<T>(topic)
      : EventKey<T>(topic);
}

extension LegacyBusTestApi on EventBus {
  bool fireLegacy<T>(T data,
          {List<String>? paths,
          String? separator,
          Map<String, String>? arguments,
          String? correlationId}) =>
      fire(_legacyKey<T>(paths, separator), data,
          arguments: arguments, correlationId: correlationId);

  Future<dynamic> requestLegacy<T>(T data,
          {List<String>? paths,
          String? separator,
          Map<String, String>? arguments,
          Duration? timeout,
          CancelToken? cancelToken,
          String? correlationId}) =>
      request(_legacyKey<T>(paths, separator), data,
          arguments: arguments,
          timeout: timeout,
          cancelToken: cancelToken,
          correlationId: correlationId);

  Stream<T> listenLegacy<T>({List<String>? paths, String? separator}) =>
      listen<T>(_legacySelector<T>(paths, separator));

  StreamSubscription<T> subscribeLegacy<T>(
          {List<String>? paths,
          String? separator,
          void Function(T e)? onData,
          Function? onError,
          void Function()? onDone,
          bool? cancelOnError}) =>
      listen<T>(_legacySelector<T>(paths, separator)).listen(onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError);

  EventSubscription<T> subscribeEventsLegacy<T>(
          {List<String>? paths,
          String? separator,
          EventCallback<T>? onEvent,
          Handler<T>? handler,
          T? initialData,
          int handlerConcurrency = 1,
          int? requestQueueCapacity,
          int? bufferCapacity,
          BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
          DeliveryMode deliveryMode = DeliveryMode.async,
          void Function(Object error, StackTrace? stackTrace)? onError,
          void Function()? onDone,
          bool cancelOnError = false}) =>
      subscribe<T>(_legacySelector<T>(paths, separator),
          onEvent: onEvent,
          handler: handler,
          initialData: initialData,
          handlerConcurrency: handlerConcurrency,
          requestQueueCapacity: requestQueueCapacity,
          bufferCapacity: bufferCapacity,
          bufferOverflow: bufferOverflow,
          deliveryMode: deliveryMode,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError);

  T? currentDataLegacy<T>({List<String>? paths, String? separator}) {
    final selector = _legacySelector<T>(paths, separator);
    return currentData<T>(selector);
  }

  bool haveListenerLegacy<T>({List<String>? paths, String? separator}) =>
      haveListener<T>(_legacySelector<T>(paths, separator));

  bool haveHandlerLegacy<T>({List<String>? paths, String? separator}) =>
      haveHandler<T>(_legacySelector<T>(paths, separator));

  bool haveAvailableHandlerLegacy<T>(
          {List<String>? paths, String? separator}) =>
      haveAvailableHandler<T>(_legacySelector<T>(paths, separator));

  bool removeTopicLegacy<T>({List<String>? paths, String? separator}) =>
      remove<T>(_legacySelector<T>(paths, separator));
}

extension LegacyPoolTestApi on WorkerPool {
  bool fireLegacy<T>(T data,
          {List<String>? paths,
          String? separator,
          Map<String, String>? arguments,
          String? correlationId}) =>
      fire(_legacyKey<T>(paths, separator), data,
          arguments: arguments, correlationId: correlationId);

  Future<dynamic> requestLegacy<T>(T data,
          {List<String>? paths,
          String? separator,
          Map<String, String>? arguments,
          Duration? timeout,
          CancelToken? cancelToken,
          String? correlationId}) =>
      request(_legacyKey<T>(paths, separator), data,
          arguments: arguments,
          timeout: timeout,
          cancelToken: cancelToken,
          correlationId: correlationId);
}
