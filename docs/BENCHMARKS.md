# Benchmarks

Produced by `make bench-local` (plan section 8). Latency is publish to delivery, from the publisher's clock (`origin_ms`).


## Local run 2026-11-10

Raw: `bench/results/local-20261110-061708.jsonl`. Gateway and load generator on one machine.

| Scenario | Clients | Deliveries/s | Bytes/delivery | p50 | p99 | p99.9 | Errors |
|---|---|---|---|---|---|---|---|
| baseline 20x10, tick 100ms | 200 | 1800 | 27.3 | 28.0 ms | 103.0 ms | 104.0 ms | 0 |
| baseline 20x10, immediate | 200 | 1800 | 33.0 | 11.0 ms | 27.0 ms | 28.0 ms | 0 |
| 1,000 drivers, groups of 10 | 1000 | 9000 | 28.3 | 48.0 ms | 109.0 ms | 111.0 ms | 0 |
| 2,000 drivers, groups of 20 | 2000 | 37777 | 28.1 | 48.0 ms | 101.0 ms | 882.0 ms | 0 |

Against the old TypeScript service's last row (200 clients in groups of 10, 1 Hz: 1,709 deliveries/s, p50 27.7 ms, p99 37.1 ms, Apple M2): with `-tick 0` the gateway delivers the same load at p50 11 ms and p99 27 ms. With the default 100 ms tick, latency is bounded by the tick (p99 about 100 ms) in exchange for one batched frame per tick per connection. The 2,000-driver run shows a p99.9 tail near 0.9 s with the load generator on the same machine; not yet profiled. These are 10 s runs on a MacBook Air; the targets in plan 8.1 are judged on the reference VMs (Benchmark III).
