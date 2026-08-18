# Capacity — measured WebSocket fan-out

Produced by `services/api/loadtest/fanout.ts`. Re-run it rather than trusting
this file; the numbers below are a snapshot, not a guarantee.

## Method

N sessions × M participants, every participant sending 1 `LOC_UPDATE`/sec.
Each sender stamps its own send time into the message's `ts`; receivers match
the resulting `LOCATION_UPDATED` broadcast back to that stamp and record the
delta. **Only cross-participant deliveries count** — a client's own echo is
skipped, so this measures fan-out, not round-trip-to-self.

```bash
npm run dev:api                      # terminal 1
cd services/api
npx tsx loadtest/fanout.ts --sessions 20 --participants 10 --seconds 20
```

`--churn` (default 0.05) drops and reconnects that fraction of clients per
minute, exercising the snapshot/replay path under load. Runs shorter than
60s see no churn events.

Setting `JOIN_RATE_LIMIT_COUNT` high is required for the larger
configurations — the per-IP join limit added in W10 otherwise rejects the
benchmark's own setup at 20 joins/minute, which is the limit working correctly.

## Results

**Hardware:** Apple M2, 8 cores, 8 GB RAM · Node v24.10.0 · macOS 24.5.0
**Date:** 2026-08-17 · **Commit:** post-W4 (session-scoped fan-out + O(1) ring buffer)
**Duration:** 20s per configuration

| Sessions × participants | Clients | Deliveries | Events/s | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|
| 1 × 20 | 20 | 7,220 | 361 | 9.5 ms | 15.9 ms | 23.0 ms | 24.0 ms |
| 5 × 10 | 50 | 8,550 | 427 | 12.1 ms | 19.5 ms | 21.3 ms | 22.8 ms |
| 20 × 10 | 200 | 34,200 | 1,709 | 27.7 ms | 35.4 ms | 37.1 ms | 38.1 ms |

## Reading these honestly

- **Client and server share one host.** These exclude real network latency
  entirely. On a phone over LTE, add the network RTT — expect tens to low
  hundreds of ms on top. This measures *server fan-out cost*, nothing else.
- **The benchmark client is itself single-threaded** and drives all 200
  sockets from one Node process, so part of the measured time at the top row
  is client-side scheduling, not server work. The 200-client number is
  therefore pessimistic as a server measurement.
- `docs/ARCHITECTURE.md` §73 sets the acceptance bar at **20 concurrent users
  in one session at 1 update/sec** — the first row, comfortably met.
- `docs/ENGINEERING_ROADMAP.md` targets **p99 < 250 ms at 20 sessions × 10
  participants**. Measured p99 is **37.1 ms**, roughly 7× under budget, but on
  the same host — see the first caveat before quoting it.

## Why this got measured

`broadcastToSession` used to iterate every connection on the process for every
event, making fan-out O(total connections) rather than O(session size). At
20 sessions × 10 participants that is 200 iterations per event × ~200
events/sec of wasted comparisons. W4 added a `sessionId → connections` index
and replaced the event ring buffer's `Array.shift()` (O(capacity) memmove per
push once full) with a circular buffer.

The table above is post-fix. No pre-fix baseline was captured, so the
improvement is reasoned from the algorithmic change rather than measured —
if you want the delta, revert `handler.ts`'s index and re-run the 20 × 10 row.
