# Load benchmark

Measures how the local bus and the isolate bus behave under an open-loop event
rate from 100 to 10,000 events per second.

```text
dart run benchmark/load_benchmark.dart
dart run benchmark/load_benchmark.dart --seconds=3 --rates=100,1000,10000
dart run benchmark/load_benchmark.dart --warmup-ms=1000
```

## What is measured

* **local fire** — `EventBus.fire` to a listener callback;
* **local request** — `EventBus.request` from the call until the handler future
  completes (the handler returns immediately);
* **isolate fire** — one-way delivery from the main isolate to a listener in
  `EventBusIsolate`'s worker;
* **isolate request** — main-side round trip through `EventBusIsolate.request`.

Each scenario sends at the target rate for `--seconds`, after a warm-up. The
sender is open loop: it does not wait for delivery, and it does not burst to
catch up if the VM stalls. Every event carries a sequence number; the report
shows `sent` and `delivered`, so loss is visible.

Latency is the per-event wall-clock time from the publish call to the listener
or handler completion. Percentiles are computed from all delivered samples of
the measured run.

### Isolate timestamps

A `Stopwatch` cannot be compared across isolates (different start epochs), so
the isolate-fire scenario calibrates the offset between the main and worker
stopwatches with seven request round trips and uses the best round (smallest
RTT, split in half). The estimate is good to roughly half a round trip. A few
samples can come out negative when the offset is off by more than the event
latency; they are clamped to zero and counted as `neg=N` in the report. The
isolate-request scenario needs no calibration: it is measured entirely on the
main side.

## Snapshot

Dart 3.12.0 (JIT), Windows, 12 CPUs, 2 s per rate, 500 ms warm-up:

| scenario | target/s | sent | delivered | achieved/s | p50 ms | p90 ms | p99 ms | max ms | mean ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| local fire | 100 | 200 | 200 | 100 | 0.046 | 0.072 | 0.177 | 0.416 | 0.053 |
| local fire | 500 | 1000 | 1000 | 500 | 0.015 | 0.027 | 0.044 | 0.068 | 0.018 |
| local fire | 1000 | 2000 | 2000 | 1000 | 0.010 | 0.016 | 0.036 | 0.051 | 0.010 |
| local fire | 5000 | 10000 | 10000 | 5000 | 0.002 | 0.007 | 0.014 | 0.100 | 0.003 |
| local fire | 10000 | 20000 | 20000 | 10000 | 0.002 | 0.002 | 0.007 | 0.368 | 0.002 |
| local request | 100 | 200 | 200 | 100 | 0.017 | 0.031 | 0.048 | 0.064 | 0.019 |
| local request | 500 | 1000 | 1000 | 500 | 0.006 | 0.012 | 0.025 | 0.035 | 0.008 |
| local request | 1000 | 2000 | 2000 | 1000 | 0.005 | 0.008 | 0.017 | 0.033 | 0.005 |
| local request | 5000 | 10000 | 10000 | 5000 | 0.002 | 0.003 | 0.009 | 0.073 | 0.002 |
| local request | 10000 | 20000 | 20000 | 10000 | 0.002 | 0.002 | 0.006 | 0.458 | 0.002 |
| isolate fire | 100 | 200 | 200 neg=29 | 100 | 0.013 | 0.034 | 0.074 | 0.099 | 0.016 |
| isolate fire | 500 | 1000 | 1000 | 500 | 0.005 | 0.022 | 0.059 | 0.115 | 0.010 |
| isolate fire | 1000 | 2000 | 2000 | 1000 | 0.005 | 0.017 | 0.056 | 0.106 | 0.008 |
| isolate fire | 5000 | 10000 | 10000 | 5000 | 0.004 | 0.007 | 0.026 | 0.212 | 0.005 |
| isolate fire | 10000 | 20000 | 20000 neg=11243 | 10000 | 0.000 | 0.001 | 0.014 | 0.925 | 0.001 |
| isolate request | 100 | 200 | 200 | 100 | 0.040 | 0.057 | 0.095 | 0.121 | 0.043 |
| isolate request | 500 | 1000 | 1000 | 500 | 0.019 | 0.036 | 0.076 | 0.144 | 0.024 |
| isolate request | 1000 | 2000 | 2000 | 1000 | 0.018 | 0.031 | 0.087 | 0.159 | 0.022 |
| isolate request | 5000 | 10000 | 10000 | 5000 | 0.015 | 0.019 | 0.044 | 0.368 | 0.016 |
| isolate request | 10000 | 19976 | 19976 | 9988 | 0.014 | 0.018 | 0.035 | 1.202 | 0.016 |

## 100,000 events/s: loss check

Every event carries a sequence number. The report's `sent`, `delivered` and
`unique` columns make it possible to distinguish loss from duplication:
`lost = sent - unique`, `dup = delivered - unique`. Run:

```text
dart run benchmark/load_benchmark.dart --rates=100000 --seconds=2
```

Result on the same machine (2 s per scenario, about 200,000 messages each):

| scenario | sent | delivered | lost | dup | achieved/s | p50 ms | p99 ms | max ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| local fire | 198838 | 198838 | 0 | 0 | 99418 | 0.001 | 0.005 | 2.508 |
| local request | 197351 | 197351 | 0 | 0 | 98675 | 0.002 | 0.004 | 5.552 |
| isolate fire | 199225 | 199225 | 0 | 0 | 99612 | 0.000* | 0.005* | 5.322 |
| isolate request | 195869 | 195869 | 0 | 0 | 97934 | 0.017 | 0.432 | 64.239 |

`*` — the isolate-fire one-way latency is smaller than the clock calibration
error at this rate: 195,215 samples were negative and clamped to zero. That is
a measurement limit, not loss. The isolate-request row is measured entirely on
the main side and is the reliable isolate latency.

No sequence number was lost or duplicated in these runs. `sent` is below
`rate × seconds` because the open-loop sender does not burst to catch up after
a stall; `achieved/s` shows what was actually offered.

## Why events can appear lost

The in-process bus does not drop events: `fire` adds to a broadcast stream that
has an active listener, and `EventBusIsolate` sends every message through a
`SendPort`. If events seem to disappear, the usual causes are:

1. **No subscriber at publish time.** A broadcast stream does not replay. A
   subscriber created after `fire` sees nothing; `currentData` may still hold
   the last value on a model bus. `fire` returns `false` when a common bus has
   no node for the topic.
2. **Subscription or bus closed.** Cancelling the last listener removes a node
   on a common bus (unless a handler or a transport pin keeps it). Events
   published after `dispose` throw, and the node's stream is closed.
3. **Consumer slower than producer.** There is no backpressure in the local or
   isolate bus. The isolate port queue and the pending-request map grow, so
   latency grows and memory grows; the process does not drop messages, but it
   can run out of memory or be killed, which looks like loss from outside.
4. **Isolate or application lifecycle.** A dead worker, a closed `ReceivePort`
   or an application exit completes pending requests with an error and stops
   delivery.
5. **Measurement bias.** Counting completions before the queue is drained
   underestimates `delivered`; counting without sequence numbers cannot
   distinguish a lost event from a duplicated one. For isolate fire, a clock
   calibration error can produce negative one-way latencies (shown as
   `neg=...`); those are not lost messages.
6. **Real transports.** NATS core is at-most-once, MQTT defaults to QoS 0,
   brokers have buffer and payload limits, and a reconnect can drop the window
   between the disconnect and the resubscribe. Those losses happen outside the
   in-process bus.

If a sustained rate is above what the consumer can process, add bounded
concurrency, a request timeout, batching/coalescing, or a transport with flow
control. The bus itself will not apply backpressure for you.

## Reading the numbers

* All events were delivered and no sequence number was lost or duplicated in
  every run. `sent` is slightly below `rate × seconds` where the open-loop
  sender could not hit the exact target; this is a pacing shortfall, not loss
  (`delivered == sent`, `unique == sent`). For example, at 10,000/s the isolate
  request scenario sent 19,976 events in 2 s.
* Both buses sustained 10,000 events/s on this machine. At that rate the
  per-event latency is in the low microseconds: p99 is about 0.006–0.007 ms for
  the local bus and 0.035 ms for isolate request.
* The isolate adds tens of microseconds: compare `isolate request` with
  `local request` at the same rate (for example, p50 0.014 ms vs 0.002 ms at
  10,000/s).
* `isolate fire` p50/p99 can be biased low when the one-way latency is smaller
  than the clock calibration error; `neg=N` counts the clamped samples. Use
  `isolate request` when you need a reliable isolate latency.
* Tail spikes are real: at 10,000/s `max` reaches about 1 ms; in the 100,000/s
  run `isolate request` had a 64 ms stall. They are rare and are not visible in
  p99.
* Low-rate latencies are not smaller than high-rate ones in this table. At 100
  events/s the sender is idle between events, so the measured value includes
  the event loop wake-up; at 10,000/s the sender and the consumer overlap and
  the per-event time is dominated by delivery itself. Use p99 and `max` for the
  tail, and `achieved/s` for capacity.
* These are JIT numbers (`dart run`). An AOT build (`dart compile exe`) usually
  has a lower warm-up cost and a different tail. Re-run the benchmark on the
  target machine before sizing anything.
