#!/usr/bin/env bash
# PERF-5: one node against two nodes over NATS at the same load, alternated REPEAT times
# (default 3) so drift on a shared machine hits both sides alike. Immediate mode, so the
# 100 ms tick does not hide the bus. Writes bench/results/<date>/delta.jsonl.
source "$(dirname "$0")/lib.sh"
command -v nats-server &>/dev/null || { echo "bench-delta: install nats-server first (brew install nats-server)"; exit 1; }

DIR="bench/results/$(date -u +%Y%m%d)"
mkdir -p "$DIR"
OUT="$DIR/delta.jsonl"
REPEAT=${REPEAT:-3}
build

nats-server -a 127.0.0.1 -p 14222 2>/dev/null & nats=$!
trap 'stop_nodes; kill $nats 2>/dev/null || true' EXIT
sleep 0.5

for i in $(seq "$REPEAT"); do
  start_node a 18080 19090 -tick 0
  loadgen -url http://127.0.0.1:18080 -metrics http://127.0.0.1:19090/metrics -pid "$pid_a" -out "$OUT" \
    -scenario "delta $i: one node, 2,000x20, immediate" -clients 2000 -group 20
  stop_nodes
  NATS_URL=nats://127.0.0.1:14222 start_node a 18081 19091 -tick 0
  NATS_URL=nats://127.0.0.1:14222 start_node b 18082 19092 -tick 0
  loadgen -url http://127.0.0.1:18081,http://127.0.0.1:18082 -out "$OUT" \
    -metrics http://127.0.0.1:19091/metrics,http://127.0.0.1:19092/metrics -pid "$pid_a,$pid_b" \
    -scenario "delta $i: two nodes, 2,000x20, immediate" -clients 2000 -group 20
  stop_nodes
done

python3 bench/table.py "$OUT"
