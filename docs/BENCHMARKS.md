# Benchmarks

Produced by `make bench-local`, `make bench-cluster`, `make bench-matrix`, and `make bench-delta` (plan section 8). Latency is publish to delivery, from the publisher's clock (`origin_ms`).


## Local run 2026-11-10

Raw: `bench/results/local-20261110-061708.jsonl`. Gateway and load generator on one machine.

| Scenario | Clients | Deliveries/s | Bytes/delivery | p50 | p99 | p99.9 | Errors |
|---|---|---|---|---|---|---|---|
| baseline 20x10, tick 100ms | 200 | 1800 | 27.3 | 28.0 ms | 103.0 ms | 104.0 ms | 0 |
| baseline 20x10, immediate | 200 | 1800 | 33.0 | 11.0 ms | 27.0 ms | 28.0 ms | 0 |
| 1,000 drivers, groups of 10 | 1000 | 9000 | 28.3 | 48.0 ms | 109.0 ms | 111.0 ms | 0 |
| 2,000 drivers, groups of 20 | 2000 | 37777 | 28.1 | 48.0 ms | 101.0 ms | 882.0 ms | 0 |

Against the old TypeScript service's last row (200 clients in groups of 10, 1 Hz: 1,709 deliveries/s, p50 27.7 ms, p99 37.1 ms, Apple M2): with `-tick 0` the gateway delivers the same load at p50 11 ms and p99 27 ms. With the default 100 ms tick, latency is bounded by the tick (p99 about 100 ms) in exchange for one batched frame per tick per connection. The 2,000-driver run shows a p99.9 tail near 0.9 s with the load generator on the same machine; not yet profiled. These are 10 s runs on a MacBook Air; the targets in plan 8.1 are judged on the reference VMs (Benchmark III).

## Benchmarks II and III, loopback, 2026-11-14

Produced by `make bench-matrix` (Benchmark III, the plan 8.1 target matrix), `make bench-cluster` (Benchmark II, two nodes over NATS) and `make bench-delta` (one node against two, alternated). Everything ran on one machine, an Apple M2 MacBook Air (8 cores, 8 GB, macOS 15.5, Go 1.27.2), with the gateway, the load generator, and NATS sharing its cores. Every row is labelled loopback: these are not the reference-VM numbers plan 8.1 asks for, because no host exists yet (PRD 9.1 step 7). Windows are 15 s (30 s for storms). Latency is the publisher's scheduled send to the subscriber's receive; the first snapshot delivery to each connection is left out and counted in the raw files.

Raw results: `bench/results/20261115/matrix.jsonl`, `bench/results/20261115/cluster.jsonl`, `bench/results/20261114/delta.jsonl`. The runs made before the stalled-reader fix below are kept as `bench/results/20261114/matrix-before-ping.jsonl` and `cluster-before-ping.jsonl`, next to the profiles (`*.pprof`, `*-goroutine.txt`) and probes taken while explaining the misses.

### Against the targets

| Target (plan 8.1) | Result on loopback | Verdict |
|---|---|---|
| 50,000 idle connections under 2.5 GB | 8,657 held (macOS allows one process 10,240 open files without root). 489 MB footprint. | Not reached: the machine's descriptor limit, not the gateway, set the count. |
| Under 50 KB per connection | 54.9 KB idle at 8,657; 49.8 KB in a second probe at 8,000. It was 35.9 KB before the ping below. | Miss by about 10%. At this rate 50,000 connections would need about 2.7 GB. |
| 5,000 publishers, fan-out 20 (100,000 deliveries/s) | 99,962 deliveries/s sustained, 183% of one core. | Met. |
| Tick 100 ms: p50 ≤ 60, p99 ≤ 150, p99.9 ≤ 250 ms | 52 / 109 / 196 ms at 5,000x20. An earlier run the same hour read 52 / 161 / 226 ms. | Met in one run, p99 over by 11 ms in the other. The tail is the shared machine (timer lag up to 61 ms in the generator). |
| Immediate: p50 ≤ 5, p99 ≤ 40 ms | 1.0 / 14 ms at 2,000x20. At 5,000x20 it collapses: p50 458 ms, p99 5.1 s, 24,590 deliveries/s. | Met at 2,000x20. Missed at 5,000x20 on one machine. |
| 5% stalled: healthy p99 moves under 10%, stalled closed within 6 s | Healthy p99 100 ms against 100 ms unstalled. All 100 stalled connections closed by 4.3 s (one node and two). | Met, after the fix below. Before it: 0 closed. |
| Two nodes over NATS add under 10 ms to p99 | Tick: 100 ms on one node, 100 ms on two. Immediate: 14 ms on one, 7.4 ms on two. Three alternated pairs in `delta.jsonl` agree: two nodes were never slower. | Met. The difference is inside the noise of a shared machine. |
| 10,000 drop and return within 10 s, all live within 15 s | 9,000 over two nodes (the descriptor limit again): 9,000 of 9,000 back, all live 10.3 s after the drop, no restart. 4,820 on one node: all live at 10.0 s. | Met at 9,000. |
| Under 30 bytes per delivered update | 29.9 to 30.3 with the 100 ms tick, 34.9 immediate, measured with `-bench`, which adds `origin_ms` (a 7-byte field) to every update for timing. Without it: about 23 and 28. | Met in production framing; the measured figure includes the benchmark's own field. |

### Benchmark III matrix

| Scenario | Conns | Deliveries/s | B/delivery | p50 | p99 | p99.9 | Gateway memory | KB/conn | Gateway CPU | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| idle, 8657 connections, ping 25 s | 8657 | 0 | - | - | - | - | 489 MB | 54.9 | 67% |  |
| 5,000 publishers, fan-out 20, tick 100 ms | 5000 | 99,962 | 29.9 | 52 ms | 109 ms | 196 ms | 443 MB | 81.7 | 183% | timer lag max 61 ms |
| 5,000 publishers, fan-out 20, immediate | 5000 | 24,590 | 37.8 | 458 ms | 5120 ms | 6717 ms | 343 MB | 61.6 | 90% | timer lag max 81 ms |
| 2,000x20, tick 100 ms (reference) | 2000 | 37,999 | 30.1 | 52 ms | 100 ms | 122 ms | 191 MB | 81.9 | 71% | timer lag max 39 ms |
| one node, 2,000x20, immediate | 2000 | 38,000 | 34.9 | 1.0 ms | 14 ms | 78 ms | 192 MB | 82.4 | 100% | timer lag max 24 ms |
| two nodes, 2,000x20, tick 100 ms | 2000 | 38,000 | 30.1 | 52 ms | 100 ms | 125 ms | 296 MB | 120.8 | 111% | cross-node p50/p99 52 ms/100 ms; timer lag max 37 ms |
| two nodes, 2,000x20, immediate | 2000 | 38,001 | 34.9 | 1.1 ms | 7.4 ms | 54 ms | 297 MB | 121.3 | 141% | cross-node p50/p99 1.2 ms/8.1 ms |
| reconnect storm, 4820 connections | 4820 | 5,160 | 47.7 | 50 ms | 100 ms | 101 ms | 321 MB | 61.0 | 54% | storm: 4820/4820 back, all live 10.0 s after the drop (p50 5.1 s); timer lag max 46 ms |
| 2,000x20, 5% stalled | 2000 | 34,710 | 30.2 | 52 ms | 100 ms | 121 ms | 188 MB | 80.9 | 70% | 100 stalled, healthy p99 100 ms, 100 closed by 4.3 s; timer lag max 32 ms |

### Benchmark II, two nodes

| Scenario | Conns | Deliveries/s | B/delivery | p50 | p99 | p99.9 | Gateway memory | KB/conn | Gateway CPU | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| two nodes, 200 drivers, groups of 10 | 200 | 1,800 | 31.5 | 57 ms | 101 ms | 120 ms | 67 MB | 158.7 | 14% | cross-node p50/p99 57 ms/101 ms; timer lag max 25 ms |
| two nodes, 2,000 drivers, groups of 20 | 2000 | 38,000 | 30.1 | 50 ms | 101 ms | 162 ms | 296 MB | 120.8 | 108% | cross-node p50/p99 50 ms/101 ms; timer lag max 36 ms |
| two nodes, 2,000 drivers, groups of 20, immediate | 2000 | 38,000 | 34.9 | 1.1 ms | 7.4 ms | 79 ms | 298 MB | 122.4 | 140% | cross-node p50/p99 1.2 ms/8.0 ms; timer lag max 22 ms |
| two nodes, 2,000x20, 5% stalled | 2000 | 34,705 | 30.2 | 54 ms | 100 ms | 146 ms | 293 MB | 119.3 | 106% | 100 stalled, healthy p99 100 ms, 100 closed by 4.3 s; cross-node p50/p99 54 ms/100 ms; timer lag max 23 ms |
| two nodes, reconnect storm, 9000 connections | 9000 | 9,451 | 46.5 | 51 ms | 103 ms | 168 ms | 948 MB | 98.3 | 161% | storm: 9000/9000 back, all live 10.3 s after the drop (p50 5.1 s); cross-node p50/p99 52 ms/113 ms; timer lag max 84 ms |

### One node against two, alternated

| Scenario | Conns | Deliveries/s | B/delivery | p50 | p99 | p99.9 | Gateway memory | KB/conn | Gateway CPU | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| delta 1: one node, 2,000x20, immediate | 2000 | 38,000 | 34.9 | 1.1 ms | 11 ms | 68 ms | 189 MB | 80.9 | 98% |  |
| delta 1: two nodes, 2,000x20, immediate | 2000 | 38,001 | 34.9 | 1.2 ms | 7.4 ms | 16 ms | 292 MB | 118.3 | 131% | cross-node p50/p99 1.3 ms/8.5 ms |
| delta 2: one node, 2,000x20, immediate | 2000 | 38,003 | 34.9 | 1.1 ms | 62 ms | 119 ms | 188 MB | 80.4 | 99% | timer lag max 53 ms |
| delta 2: two nodes, 2,000x20, immediate | 2000 | 38,000 | 34.9 | 1.1 ms | 6.8 ms | 18 ms | 294 MB | 119.8 | 135% | cross-node p50/p99 1.2 ms/7.7 ms |
| delta 3: one node, 2,000x20, immediate | 2000 | 38,003 | 34.9 | 1.0 ms | 76 ms | 139 ms | 189 MB | 80.9 | 98% | timer lag max 32 ms |
| delta 3: two nodes, 2,000x20, immediate | 2000 | 38,000 | 34.9 | 1.1 ms | 35 ms | 145 ms | 292 MB | 118.8 | 129% | cross-node p50/p99 1.2 ms/53 ms; timer lag max 44 ms |

### What limited it

- **Open files.** macOS caps a process at 10,240 descriptors without root, so neither the 50,000-connection row nor the 10,000-connection storm could be run at size. Both need the Linux host.
- **Immediate mode at 5,000x20.** With no tick every update is its own WebSocket frame: 100,000 small writes a second, each a syscall on both ends. The backlog is on the publisher-to-gateway leg (`inbound_leg_p99_ms` is 5.1 s of the 5.1 s), the kernel was the busiest process on the machine during the run (`immediate-5000-top-lo0.txt`), and splitting the generator in two changed nothing (`immediate-split.jsonl`). The gateway's CPU profile is `immediate-5000-gateway-cpu.pprof`. Immediate mode is not the default; the 100 ms tick exists to batch exactly this.
- **Tail latency.** p99.9 moves between 115 and 230 ms from run to run at the same load (`tail-2000.jsonl`, three runs). The generator's own 5 ms timer was late by 20 to 80 ms in the same seconds, so the tail is scheduling on a machine running both sides, not the garbage collector: total collector pause over a 15 s run was 1 to 8 ms.
- **Memory per connection.** Idle cost is two 4 KB buffers from `net/http`, the outbox, and goroutine stacks. The stalled-reader ping below added about 15 to 19 KB per connection, mostly stack growth in the read goroutine. Under load it is about 80 KB on one node and 120 KB on two.

### Found and fixed while running these

- **Stalled readers were never closed.** The conflated lane holds one entry per publisher, so a client that stops reading costs the gateway almost nothing and its socket buffer takes minutes to fill; the 5 s write timeout never fired (`stall-close.jsonl`: 0 of 20 closed in 150 s). The gateway now sends a WebSocket ping every 2 s and closes a connection with code 4008 when a pong is 3 s late, so a stalled reader is gone within 5 s. Cost: the memory above. The slow-consumer counter also read 20 after the 9,000-connection storm; whether those were dropped sockets whose ping failed before the read loop noticed, or live connections closed while the machine was saturated, was not separated.
- **Closed connections leaked their sockets.** A client that dropped without a close frame left its descriptor open in the gateway (`CLOSE_WAIT`), so a storm of N needed 2N descriptors and the first 9,000-connection storm brought back only 7,592. The handler now closes the socket on every exit path.
