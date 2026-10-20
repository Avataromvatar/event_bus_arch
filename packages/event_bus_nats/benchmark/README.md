# NATS load benchmark

Measures the NATS transport end to end: an `EventBusNats` publisher and a
subscriber (and a requester and a responder for `request`) in one process,
connected to a NATS server.

```text
# start a NATS server first
nats-server -p 4222

dart run benchmark/nats_load_benchmark.dart
dart run benchmark/nats_load_benchmark.dart --rates=100,1000,10000
dart run benchmark/nats_load_benchmark.dart --scenario=fire --rates=100000 --seconds=2
dart run benchmark/nats_load_benchmark.dart --url=nats://127.0.0.1:4222
```

Options: `--rates=`, `--seconds=`, `--warmup-ms=`, `--scenario=both|fire|request`,
`--mode=shared|isolated`, `--url=`. The broker can also come from `NATS_URL`.

* `shared` (default) — publisher, subscriber, requester and responder all live
  in the main isolate. This measures an application that both publishes and
  consumes in one isolate.
* `isolated` — publisher/requester run in a worker isolate, subscriber and
  responder in the main isolate. The consumer event loop no longer competes
  with the generator. Fire latency uses a calibrated stopwatch offset between
  the two isolates; request latency is measured inside the worker.

## What is measured

* **nats fire** — `publisher.fire` to a listener on the subscriber bus;
* **nats request** — `requester.request` from the call until the responder's
  handler future arrives back.

Both buses live in the **same isolate**. That is the important caveat: the
generator, the publisher client, the subscriber client and (for requests) the
responder all share one event loop. The benchmark therefore measures the
ceiling of an application that both publishes and consumes in one isolate, not
the broker's own throughput.

Every event carries a sequence number and the publisher's stopwatch timestamp.
The subscriber records latency and a set of sequence numbers, so loss,
duplication and pacing shortfall are distinguishable.

The payload is 16 bytes (two `int64`s); the request codec is 9 bytes. Headers
carry the origin; no `arguments` are used.

## Snapshot: shared mode

Dart 3.12.0 (JIT), Windows, 12 CPUs, NATS 2.15.1 on localhost, 2 s per rate,
500 ms warm-up:

| scenario | target/s | sent | delivered | achieved/s | p50 ms | p90 ms | p99 ms | max ms | mean ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| nats fire | 100 | 200 | 200 | 100 | 0.250 | 0.329 | 0.689 | 0.729 | 0.273 |
| nats fire | 500 | 1000 | 1000 | 500 | 0.225 | 0.290 | 0.397 | 1.913 | 0.241 |
| nats fire | 1000 | 2000 | 2000 | 1000 | 0.193 | 0.248 | 0.316 | 0.495 | 0.203 |
| nats fire | 5000 | 9945 | 9945 | 4972 | 0.136 | 0.176 | 0.609 | 4.761 | 0.162 |
| nats fire | 10000 | 19887 | 19887 | 9943 | 92.717 | 158.769 | 173.349 | 174.548 | 89.509 |
| nats request | 100 | 200 | 200 | 100 | 0.480 | 0.595 | 0.750 | 3.139 | 0.509 |
| nats request | 500 | 1000 | 1000 | 500 | 0.387 | 0.427 | 0.515 | 0.705 | 0.395 |
| nats request | 1000 | 2000 | 2000 | 1000 | 0.366 | 0.440 | 0.538 | 0.754 | 0.379 |
| nats request | 5000 | 9726 | 9726 | 4863 | 412.034 | 570.550 | 581.802 | 597.641 | 373.956 |
| nats request | 10000 | 18768 | 18768 | 9384 | 1308.441 | 1591.180 | 1652.448 | 1662.636 | 1164.053 |

No `lost` or `dup` markers: every sent sequence number was delivered exactly
once, and there were no asynchronous transport errors. `sent` is slightly below
`rate × seconds` where the generator could not hit the exact target; that is
pacing, not loss.

### 100,000 events/s, shared mode

Fire only, 1 s:

| sent | delivered | lost | dup | achieved/s | p50 ms | p99 ms | max ms |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 86940 | 86940 | 0 | 0 | 86938 | 4380 | 8799 | 8889 |

The broker and the client accepted ~87k messages/s, every one was delivered,
but the subscriber could not process the backlog: the last event waited ~9 s.
This is the single-isolate ceiling, not the NATS server.

## Snapshot: isolated mode

Publisher/requester in a worker isolate, subscriber/responder in the main
isolate, 2 s per rate, 500 ms warm-up:

| scenario | target/s | sent | delivered | achieved/s | p50 ms | p90 ms | p99 ms | max ms | mean ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| nats fire (isolated) | 100 | 200 | 200 | 100 | 0.292 | 0.378 | 0.557 | 0.581 | 0.308 |
| nats fire (isolated) | 500 | 1000 | 1000 | 500 | 0.227 | 0.287 | 3.844 | 15.802 | 0.341 |
| nats fire (isolated) | 1000 | 2000 | 2000 | 1000 | 0.191 | 0.220 | 0.283 | 0.697 | 0.191 |
| nats fire (isolated) | 5000 | 10000 | 10000 | 5000 | 0.114 | 0.164 | 0.207 | 0.419 | 0.123 |
| nats fire (isolated) | 10000 | 19986 | 19986 | 9993 | 0.099 | 0.149 | 0.655 | 5.348 | 0.130 |
| nats request (isolated) | 100 | 200 | 200 | 100 | 0.558 | 0.802 | 0.969 | 0.989 | 0.601 |
| nats request (isolated) | 500 | 1000 | 1000 | 500 | 0.384 | 0.472 | 0.831 | 3.600 | 0.413 |
| nats request (isolated) | 1000 | 2000 | 2000 | 1000 | 0.332 | 0.396 | 0.460 | 0.602 | 0.342 |
| nats request (isolated) | 5000 | 10000 | 10000 | 5000 | 6.553 | 18.658 | 27.580 | 38.795 | 7.920 |
| nats request (isolated) | 10000 | 19626 | 19626 | 9813 | 16.885 | 26.043 | 36.165 | 43.623 | 17.480 |

No lost or duplicated sequence numbers, no async errors.

Isolated fire at 100,000/s (1 s): `sent=89798`, `delivered=89798`, `lost=0`,
`dup=0`, p50 3357 ms, p99 6500 ms. The worker could not hand more than ~90k
messages/s to the NATS client; the timestamp queue in front of the socket grew.
At this rate the sender side, not the subscriber, is the bottleneck.

## Shared vs isolated

| scenario | shared p50 at 10k/s | isolated p50 at 10k/s |
|---|---:|---:|
| nats fire | 92.7 ms | 0.099 ms |
| nats request | 1308 ms | 16.9 ms |

Separating the peers removes the event-loop competition: fire drops by almost
three orders of magnitude. Requests improve by ~77x but remain in the tens of
milliseconds because the worker's generator, requester client and per-request
inbox subscriptions share the worker event loop. Above ~5k request/s the
requester becomes the bottleneck; the broker and the responder are not.

## Reading the numbers

* Up to 5,000 fire/s and 1,000 request/s the transport is comfortably
  sub-millisecond (p50 0.14–0.48 ms).
* At 10,000/s the shared event loop saturates: the fire p50 jumps to ~93 ms and
  request p50 to ~1.3 s. All messages still arrive; latency is queueing, not
  loss.
* Requests are more expensive than fire at high rates: every `request` opens
  its own NATS inbox subscription in the shared
  `ReconnectingTransportConnection.request`, so 5,000–10,000 concurrent
  requests also churn thousands of subscriptions.
* Use `--mode=isolated` to measure the transport without the generator sharing
  the subscriber's event loop. Even then, the worker's own client and generator
  can cap the sender around 90k fire/s and the requester around 5k request/s.
* These are JIT numbers (`dart run`) against a local broker. Re-run on the
  target machine and broker before sizing anything.
