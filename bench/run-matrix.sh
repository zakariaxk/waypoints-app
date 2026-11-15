#!/usr/bin/env bash
# Benchmark III (plan 8.1 and 8.3): the full target matrix. On the reference VMs the generator
# runs on a second VM; here it runs on the same machine and every row is labelled LABEL
# (default loopback). Each window is short (DURATION, default 15s) so the machine stays usable.
#
#   idle connections and memory per connection   IDLE_CLIENTS (default: as many as the open-file
#                                                limits allow, up to 50,000)
#   5,000 publishers x fan-out 20, tick 100 ms and immediate
#   slow-consumer isolation (2,000 x 20, 5% stalled, against the same run unstalled)
#   one node against two nodes over NATS at the same load (tick 100 ms and immediate)
#   reconnect storm: STORM_CLIENTS drop and return within 10 s (default: what one process's
#                    descriptors allow; see the note below)
#
# Writes bench/results/<date>/matrix.jsonl and prints a table.
source "$(dirname "$0")/lib.sh"

DIR="bench/results/$(date -u +%Y%m%d)"
mkdir -p "$DIR"
OUT="$DIR/matrix.jsonl"
build

one() { # tick, then loadgen flags
  local tick=$1
  shift
  start_node a 18080 19090 -tick "$tick"
  loadgen -url http://127.0.0.1:18080 -metrics http://127.0.0.1:19090/metrics -pid "$pid_a" -out "$OUT" "$@"
  stop_nodes
}

# Idle: one process may hold kern.maxfilesperproc descriptors (10,240 on macOS without sudo),
# and the gateway and the generator share kern.maxfiles with everything else on the machine.
perproc=$(sysctl -n kern.maxfilesperproc)
headroom=$(( ($(fd_headroom) - 6000) / 2 ))
idle=${IDLE_CLIENTS:-$(( perproc - 300 < headroom ? perproc - 300 : headroom ))}
idle=$(( idle > 50000 ? 50000 : idle ))
# The storm needs room for every old socket plus every new one while they overlap; and as of
# 2026-11-14 the gateway keeps each closed connection's socket open (CLOSE_WAIT, see
# docs/BENCHMARKS.md), so a storm of N needs 2N descriptors in one process.
storm=${STORM_CLIENTS:-$(( perproc / 2 - 300 < idle ? perproc / 2 - 300 : idle ))}

one 100ms -scenario "idle, $idle connections, ping 25 s" -clients "$idle" -group 1 -hz 0 -ports 20000-48000
one 100ms -scenario "5,000 publishers, fan-out 20, tick 100 ms" -clients 5000 -group 21
one 0 -scenario "5,000 publishers, fan-out 20, immediate" -clients 5000 -group 21
one 100ms -scenario "2,000x20, tick 100 ms (reference)" -clients 2000 -group 20
one 100ms -scenario "2,000x20, 5% stalled" -clients 2000 -group 20 -stall 0.05 -stall-rcvbuf 4096
one 0 -scenario "one node, 2,000x20, immediate" -clients 2000 -group 20

if command -v nats-server &>/dev/null; then
  nats-server -a 127.0.0.1 -p 14222 & nats=$!
  trap 'stop_nodes; kill $nats 2>/dev/null || true' EXIT
  sleep 0.5
  two() {
    local tick=$1
    shift
    NATS_URL=nats://127.0.0.1:14222 start_node a 18081 19091 -tick "$tick"
    NATS_URL=nats://127.0.0.1:14222 start_node b 18082 19092 -tick "$tick"
    loadgen -url http://127.0.0.1:18081,http://127.0.0.1:18082 \
      -metrics http://127.0.0.1:19091/metrics,http://127.0.0.1:19092/metrics -pid "$pid_a,$pid_b" -out "$OUT" "$@"
    stop_nodes
  }
  two 100ms -scenario "two nodes, 2,000x20, tick 100 ms" -clients 2000 -group 20
  two 0 -scenario "two nodes, 2,000x20, immediate" -clients 2000 -group 20
else
  echo "bench-matrix: nats-server not found, skipping the two-node rows" >&2
fi

one 100ms -scenario "reconnect storm, $storm connections" -clients "$storm" -group 10 -hz 0.2 \
  -storm -storm-spread 10s -duration 30s -ports 20000-48000

python3 bench/table.py "$OUT"
