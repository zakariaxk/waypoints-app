# Shared helpers for the benchmark scripts. Source it; it does not run anything.
#
#   start_node NAME PORT METRICS_PORT [gateway flags...]   sets $pid_NAME
#   stop_nodes                                            kills every node started here
#   loadgen [flags...]                                    runs the generator with the bench secret
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

export WAYPOINTS_ENV=bench WAYPOINTS_BENCH_SECRET=${WAYPOINTS_BENCH_SECRET:-bench-secret} DATABASE_URL= SUPABASE_URL=
export WAYPOINTS_LOG_LEVEL=${WAYPOINTS_LOG_LEVEL:-warn}
DURATION=${DURATION:-15s}
LABEL=${LABEL:-loopback}
NODES=()
GATEWAY=${GATEWAY:-./.build/gateway}

build() {
  (cd server && go build -o ../.build/gateway ./cmd/gateway && go build -o ../.build/loadgen ./cmd/loadgen)
}

start_node() { # name port metrics-port [flags...]
  local name=$1 port=$2 mport=$3
  shift 3
  WAYPOINTS_NODE=$name WAYPOINTS_ADDR=127.0.0.1:$port WAYPOINTS_METRICS_ADDR=127.0.0.1:$mport \
    "$GATEWAY" -bench "$@" 2> >(grep -v 'store running in memory' >&2) &
  local p=$!
  NODES+=("$p")
  printf -v "pid_$name" '%s' "$p"
  for _ in $(seq 50); do curl -sf "http://127.0.0.1:$mport/metrics" >/dev/null && return 0; sleep 0.1; done
  echo "node $name did not come up" >&2
  return 1
}

stop_nodes() {
  for p in ${NODES[@]+"${NODES[@]}"}; do kill "$p" 2>/dev/null || true; done
  for p in ${NODES[@]+"${NODES[@]}"}; do wait "$p" 2>/dev/null || true; done
  NODES=()
  sleep 1
}

loadgen() {
  ./.build/loadgen -label "$LABEL" -duration "$DURATION" "$@" || true
}

# Leave this many open files for the rest of the machine (kern.maxfiles is shared).
fd_headroom() {
  echo $(($(sysctl -n kern.maxfiles) - $(sysctl -n kern.num_files)))
}
