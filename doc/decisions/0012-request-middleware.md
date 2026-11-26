# ADR-0012: Request middleware and pipelines

- Status: Proposed
- Date: 2026-11-24
- Current in: not implemented

## Context

Applications repeat cross-cutting request logic (authentication, tenant propagation, logging,
tracing, retries, fallback) around handlers. The bus has observability, but no place to compose
behavior around a request while preserving one timeout/cancellation owner. A pipeline must not
silently change delivery semantics or cross an isolate/transport boundary without an explicit
decision.

## Options

1. **Bus-level interceptor chain.** `EventBus(middleware: [...])` or `bus.use(interceptor)`, where
   each interceptor receives a request context and `next`. Ordering is construction/registration
   order; an interceptor may short-circuit with a response or an error.
2. **Subscription-level middleware.** Attach middleware to a handler subscription. Scoped and
   local, but each subscription repeats configuration and a request can choose only the selected
   handler's chain.
3. **External wrapper.** A service layer around `request`/`handleIncomingRequest`; no core change,
   but no access to dispatch details and easy to bypass.

## Proposed decision

Design option 1 for local `request` first. Define:

- execution order (outermost first) and short-circuit rules;
- propagation of `timeout`, `CancelToken`, correlation id and arguments;
- error mapping (handler error vs middleware error) and whether errors are reported to
  `bus.errors`;
- metrics timing (pipeline time vs handler time);
- redaction and payload capture boundaries;
- scope: local bus only by default; crossing isolate/transport requires a separate protocol;
- interaction with request phases and queued-request cancellation.

No implementation until the decision record and examples are accepted. Middleware must not turn a
`BusyException`/timeout/cancellation into a different terminal outcome.

## Consequences

- A pipeline gives one place for cross-cutting policy without modifying every handler.
- The bus gains another lifecycle surface; middleware order and error semantics must be tested.
- Local-only middleware will not protect requests answered by a remote isolate or broker unless a
  protocol carries the policy; that limitation must be documented.

## Alternatives considered

- **Retry inside a handler.** Rejected: duplicates timeout/cancellation ownership and hides side
  effects.
- **Transport-only interceptors.** Rejected: local requests would bypass the policy.
- **Global static middleware registry.** Rejected: test pollution and multi-app interference.
