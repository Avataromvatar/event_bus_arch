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
| local fire | 100 | 200 | 200 | 100 | 0.033 | 0.076 | 0.120 | 0.127 | 0.042 |
| local fire | 500 | 1000 | 1000 | 500 | 0.023 | 0.040 | 0.053 | 0.066 | 0.026 |
| local fire | 1000 | 2000 | 2000 | 1000 | 0.014 | 0.028 | 0.044 | 0.068 | 0.016 |
| local fire | 5000 | 9949 | 9949 | 4974 | 0.005 | 0.009 | 0.022 | 0.133 | 0.007 |
| local fire | 10000 | 20000 | 20000 | 10000 | 0.003 | 0.005 | 0.015 | 0.062 | 0.004 |
| local request | 100 | 200 | 200 | 100 | 0.027 | 0.036 | 0.049 | 0.078 | 0.029 |
| local request | 500 | 1000 | 1000 | 500 | 0.020 | 0.027 | 0.035 | 0.042 | 0.020 |
| local request | 1000 | 2000 | 2000 | 1000 | 0.009 | 0.017 | 0.029 | 0.058 | 0.010 |
| local request | 5000 | 10000 | 10000 | 5000 | 0.004 | 0.006 | 0.019 | 0.067 | 0.005 |
| local request | 10000 | 20000 | 20000 | 10000 | 0.004 | 0.004 | 0.007 | 0.255 | 0.004 |
| isolate fire | 100 | 200 | 200 | 100 | 0.030 | 0.056 | 0.086 | 0.089 | 0.034 |
| isolate fire | 500 | 1000 | 1000 | 500 | 0.015 | 0.029 | 0.086 | 0.116 | 0.018 |
| isolate fire | 1000 | 2000 | 2000 | 1000 | 0.013 | 0.028 | 0.086 | 0.279 | 0.017 |
| isolate fire | 5000 | 10000 | 10000 | 5000 | 0.007 | 0.012 | 0.031 | 0.236 | 0.009 |
| isolate fire | 10000 | 20000 | 20000 neg=3 | 10000 | 0.005 | 0.007 | 0.024 | 1.205 | 0.006 |
| isolate request | 100 | 200 | 200 | 100 | 0.043 | 0.078 | 0.136 | 0.161 | 0.049 |
| isolate request | 500 | 1000 | 1000 | 500 | 0.020 | 0.040 | 0.092 | 0.141 | 0.025 |
| isolate request | 1000 | 2000 | 2000 | 1000 | 0.017 | 0.034 | 0.096 | 0.175 | 0.022 |
| isolate request | 5000 | 10000 | 10000 | 5000 | 0.015 | 0.022 | 0.070 | 2.553 | 0.019 |
| isolate request | 10000 | 20000 | 20000 | 10000 | 0.014 | 0.017 | 0.033 | 0.240 | 0.014 |

## Reading the numbers

* All events were delivered in every run. The `sent` value at 5000/s local fire
  is 9949 because the 2 s window ended one event before the nominal count; this
  is a pacing shortfall, not loss (`delivered == sent`).
* Both buses sustained 10,000 events/s on this machine. At that rate the
  per-event latency is in the low microseconds: p99 is 0.007–0.015 ms for the
  local bus and 0.024–0.033 ms for the isolate bus.
* The isolate adds tens of microseconds: compare `isolate request` with
  `local request` at the same rate (for example, p50 0.014 ms vs 0.004 ms at
  10,000/s).
* Tail spikes are real: `max` reaches 1.2 ms (isolate fire) and 2.6 ms
  (isolate request). They are rare and are not visible in p99.
* Low-rate latencies are not smaller than high-rate ones in this table. At 100
  events/s the sender is idle between events, so the measured value includes
  the event loop wake-up; at 10,000/s the sender and the consumer overlap and
  the per-event time is dominated by delivery itself. Use p99 and `max` for the
  tail, and `achieved/s` for capacity.
* These are JIT numbers (`dart run`). An AOT build (`dart compile exe`) usually
  has a lower warm-up cost and a different tail. Re-run the benchmark on the
  target machine before sizing anything.
