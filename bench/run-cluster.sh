#!/usr/bin/env bash
# Two gateway nodes joined by a local NATS server (plan 8.3, Benchmark II). Odd clients connect
# to the second node, so every friend group spans both. Needs `nats-server` on PATH
# (`brew install nats-server`, plan section 14).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v nats-server &>/dev/null || { echo "bench-cluster: install nats-server first (brew install nats-server)"; exit 1; }

export WAYPOINTS_ENV=bench WAYPOINTS_BENCH_SECRET=${WAYPOINTS_BENCH_SECRET:-bench-secret} DATABASE_URL= SUPABASE_URL=
export WAYPOINTS_LOG_LEVEL=warn NATS_URL=nats://127.0.0.1:14222
OUT="bench/results/cluster-$(date -u +%Y%m%d-%H%M%S).jsonl"
DURATION=${DURATION:-20s}

(cd server && go build -o ../.build/gateway ./cmd/gateway && go build -o ../.build/loadgen ./cmd/loadgen)
nats-server -p 14222 & nats=$!
trap 'kill $nats 2>/dev/null || true' EXIT
sleep 0.5

run() { # label, clients, group
  WAYPOINTS_NODE=a WAYPOINTS_ADDR=127.0.0.1:18081 WAYPOINTS_METRICS_ADDR=127.0.0.1:19091 ./.build/gateway -bench & local a=$!
  WAYPOINTS_NODE=b WAYPOINTS_ADDR=127.0.0.1:18082 WAYPOINTS_METRICS_ADDR=127.0.0.1:19092 ./.build/gateway -bench & local b=$!
  sleep 1
  ./.build/loadgen -url http://127.0.0.1:18081 -url2 http://127.0.0.1:18082 -clients "$2" -group "$3" -hz 1 \
    -duration "$DURATION" -scenario "$1" -out "$OUT" || true
  kill "$a" "$b"; wait "$a" "$b" 2>/dev/null || true
}

run "two nodes, 200 drivers, groups of 10" 200 10
run "two nodes, 2,000 drivers, groups of 20" 2000 20

python3 - "$OUT" <<'PY'
import json, sys, datetime
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
table = ["| Scenario | Clients | Deliveries/s | p50 | p99 | p99.9 | Errors |", "|---|---|---|---|---|---|---|"]
for r in rows:
    table.append(f"| {r['scenario']} | {r['clients']} | {r['deliveries_per_sec']:.0f} | {r['p50_ms']:.1f} ms | "
                 f"{r['p99_ms']:.1f} ms | {r['p999_ms']:.1f} ms | {r['errors']} |")
section = f"## Two-node run {datetime.date.today()}\n\nRaw: `{sys.argv[1]}`. Two gateways and NATS on one machine.\n\n" + "\n".join(table) + "\n"
open("docs/BENCHMARKS.md", "a").write("\n" + section)
print("\n".join(table))
PY
