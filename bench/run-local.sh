#!/usr/bin/env bash
# Single-node benchmark on this machine (plan 8.3, Benchmark I). Starts the gateway in bench
# mode with the in-memory store, runs each scenario with the load generator, and writes
# bench/results/local-<date>.jsonl plus a table in docs/BENCHMARKS.md.
set -euo pipefail
cd "$(dirname "$0")/.."

export WAYPOINTS_ENV=bench WAYPOINTS_BENCH_SECRET=${WAYPOINTS_BENCH_SECRET:-bench-secret} DATABASE_URL= SUPABASE_URL=
export WAYPOINTS_ADDR=127.0.0.1:18080 WAYPOINTS_METRICS_ADDR=127.0.0.1:19090 WAYPOINTS_LOG_LEVEL=warn
OUT="bench/results/local-$(date -u +%Y%m%d-%H%M%S).jsonl"
DURATION=${DURATION:-20s}

(cd server && go build -o ../.build/gateway ./cmd/gateway && go build -o ../.build/loadgen ./cmd/loadgen)

run() { # label, tick, clients, group, hz
  ./.build/gateway -bench -tick "$2" & local pid=$!
  sleep 1
  ./.build/loadgen -url "http://$WAYPOINTS_ADDR" -clients "$3" -group "$4" -hz "$5" -duration "$DURATION" \
    -scenario "$1" -out "$OUT" || true
  kill "$pid"; wait "$pid" 2>/dev/null || true
}

# The old service's last row (200 clients in groups of 10 at 1 Hz), then tick vs immediate, then scale.
run "baseline 20x10, tick 100ms" 100ms 200 10 1
run "baseline 20x10, immediate" 0 200 10 1
run "1,000 drivers, groups of 10" 100ms 1000 10 1
run "2,000 drivers, groups of 20" 100ms 2000 20 1

python3 - "$OUT" <<'PY'
import json, sys, re, datetime
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
table = ["| Scenario | Clients | Deliveries/s | Bytes/delivery | p50 | p99 | p99.9 | Errors |", "|---|---|---|---|---|---|---|---|"]
for r in rows:
    table.append(f"| {r['scenario']} | {r['clients']} | {r['deliveries_per_sec']:.0f} | {r['bytes_per_delivery']:.1f} | "
                 f"{r['p50_ms']:.1f} ms | {r['p99_ms']:.1f} ms | {r['p999_ms']:.1f} ms | {r['errors']} |")
section = f"## Local run {datetime.date.today()}\n\nRaw: `{sys.argv[1]}`. Gateway and load generator on one machine.\n\n" + "\n".join(table) + "\n"
path = "docs/BENCHMARKS.md"
try:
    doc = open(path).read()
except FileNotFoundError:
    doc = "# Benchmarks\n\nProduced by `make bench-local` (plan section 8). Latency is publish to delivery, from the publisher's clock (`origin_ms`).\n\n"
open(path, "w").write(doc + "\n" + section)
print("\n".join(table))
PY
