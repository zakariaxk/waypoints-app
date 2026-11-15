#!/usr/bin/env bash
# Benchmark II (plan 8.3): two gateway nodes joined by a local NATS server. Client i connects to
# node i mod 2, so every friend group spans both nodes. Scenarios: plain fan-out, 5% stalled
# subscribers, and a reconnect storm. Needs `nats-server` on PATH (`brew install nats-server`).
#
# Writes bench/results/<date>/cluster.jsonl and prints a table. DURATION (default 15s) sets each
# measurement window; STORM_CLIENTS (default 9000) sizes the storm.
source "$(dirname "$0")/lib.sh"
command -v nats-server &>/dev/null || { echo "bench-cluster: install nats-server first (brew install nats-server)"; exit 1; }

DIR="bench/results/$(date -u +%Y%m%d)"
mkdir -p "$DIR"
OUT="$DIR/cluster.jsonl"
STORM_CLIENTS=${STORM_CLIENTS:-9000} # split over two nodes; see run-matrix.sh on descriptors
build

nats-server -a 127.0.0.1 -p 14222 & nats=$!
trap 'stop_nodes; kill $nats 2>/dev/null || true' EXIT
sleep 0.5
export NATS_URL=nats://127.0.0.1:14222

two() { # tick, then loadgen flags
  local tick=$1
  shift
  start_node a 18081 19091 -tick "$tick"
  start_node b 18082 19092 -tick "$tick"
  loadgen -url http://127.0.0.1:18081,http://127.0.0.1:18082 \
    -metrics http://127.0.0.1:19091/metrics,http://127.0.0.1:19092/metrics -pid "$pid_a,$pid_b" -out "$OUT" "$@"
  stop_nodes
}

two 100ms -scenario "two nodes, 200 drivers, groups of 10" -clients 200 -group 10
two 100ms -scenario "two nodes, 2,000 drivers, groups of 20" -clients 2000 -group 20
two 0 -scenario "two nodes, 2,000 drivers, groups of 20, immediate" -clients 2000 -group 20
two 100ms -scenario "two nodes, 2,000x20, 5% stalled" -clients 2000 -group 20 -stall 0.05 -stall-rcvbuf 4096
if (($(fd_headroom) > STORM_CLIENTS * 2 + 3000)); then
  two 100ms -scenario "two nodes, reconnect storm, $STORM_CLIENTS connections" -clients "$STORM_CLIENTS" -group 10 -hz 0.2 \
    -storm -storm-spread 10s -duration 30s -ports 20000-48000
else
  echo "bench-cluster: skipping the storm, only $(fd_headroom) open files left on this machine" >&2
fi

python3 bench/table.py "$OUT"
