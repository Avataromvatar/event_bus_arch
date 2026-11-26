# ADR-0011: Typed request responses

- Status: Proposed
- Date: 2026-11-24
- Current in: not implemented

## Context

`EventBus.request<T>` returns `Future<dynamic>`. `T` describes the request payload, while the
response type is not part of any key or method contract. Callers must cast the result, and a
handler can return a value of an unexpected type without a compile-time warning. The request
lifecycle (ADR-0003) already carries timeout, cancellation and error behavior; response typing
must not change that lifecycle.

## Options

1. **Add a response type parameter.** `Future<R> request<T, R>(...)` and
   `Handler<T, R> Function(EventDTO<T>, T?) -> FutureOr<R>`. This is the smallest change if Dart
   infers `dynamic` for existing unannotated call sites. A prototype must prove source
   compatibility; otherwise this is a breaking change.
2. **A request key carries both types.** `RequestKey<T, R>` or `EventRpc<T, R>` binds the request
   payload and the response. This is the strongest contract and can also select a request codec,
   but it changes key identity, transport codecs and handler registration.
3. **Keep `dynamic` and add an extension.** A typed helper casts at the call site. It is the least
   invasive option but does not make handlers or transport replies type-safe.

## Proposed decision

Prototype option 1 with a focused inference test matrix. If existing `await bus.request(key,
data)` calls infer `dynamic` and remain source-compatible, adopt it as an additive minor change.
If not, prepare option 2 for 5.0. Do not implement either before the prototype and an accepted
decision record.

## Consequences

- Option 1 puts the response type in the API but not on the wire; a transport still decodes a
  dynamic payload and the caller-side cast remains possible until codecs become response-aware.
- Option 2 gives the strongest static contract but increases the migration surface; it should not
  be mixed into a patch release.
- The request lifecycle from ADR-0003, including cancellation and error envelopes, is unchanged.

## Alternatives considered

- **Cast everywhere.** Rejected as the final design: it moves a protocol error to a runtime cast.
- **Return `RequestResult<R>`.** Possible wrapper, but it changes every call site and complicates
  timeout/cancellation composition.
- **One address = one schema.** Deferred; it does not provide a response type by itself.
