#!/usr/bin/env bash
# tools/loop/loop.sh — the Waypoints loop orchestrator.
#
# Takes items off tools/loop/queue.md, hands each to a headless `devin -p`
# session (the "free agents"), and keeps going until the queue is empty or
# tools/loop/STOP exists. Agents build, commit, and push to main themselves;
# the orchestrator only schedules, watches for a landed commit, and stashes
# any debris a failed agent leaves behind.
#
# One-time setup:  devin auth login          (interactive, once)
#                  (optional) install coreutils for `gtimeout`
#
# Usage:           tools/loop/loop.sh [--dry-run] [--once]
# Env:             MODEL=swe         model for worker sessions
#                  PERMISSION_MODE=dangerous   needs git/build without prompts
#                  ITEM_TIMEOUT=45m  per-item cap (needs gtimeout; else none)
#                  MAX_ITEMS=0       0 = run until queue is empty
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
QUEUE=tools/loop/queue.md
PROMPT=tools/loop/prompt.md
LOGDIR=.build/loop
STOP=tools/loop/STOP

MODEL=${MODEL:-swe}
PERMISSION_MODE=${PERMISSION_MODE:-dangerous}
ITEM_TIMEOUT=${ITEM_TIMEOUT:-45m}
MAX_ITEMS=${MAX_ITEMS:-0}
DRY=0; ONCE=0
for a in "$@"; do case "$a" in --dry-run) DRY=1;; --once) ONCE=1;; esac; done

mkdir -p "$LOGDIR"
TIMEOUT_CMD=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_CMD="gtimeout $ITEM_TIMEOUT"

mark() { # mark <id> <char>
  # First `- [ ]` (or `[~]`) line containing "| <id> |" gets its checkbox set.
  python3 - "$QUEUE" "$1" "$2" <<'PY'
import re, sys
path, ident, ch = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(keepends=True)
for i, l in enumerate(lines):
    m = re.match(r'^- \[( |~|!)\] (L\d+) \|', l)
    if m and m.group(2) == ident:
        lines[i] = l.replace(m.group(0), f'- [{ch}] {ident} |', 1)
        break
open(path, 'w').writelines(lines)
PY
}

next_item() { grep -E '^- \[ \] L[0-9]+' "$QUEUE" | head -1; }

count=0
while :; do
  [ -f "$STOP" ] && { echo "loop: STOP file present; halting."; break; }
  item=$(next_item)
  [ -z "$item" ] && { echo "loop: queue empty."; break; }
  id=$(echo "$item" | sed -E 's/^- \[ \] (L[0-9]+).*/\1/')
  task=$(echo "$item" | sed -E 's/^- \[ \] [^ ]+ \| //')
  echo "loop: $id -> $task"
  mark "$id" '~'
  [ $DRY -eq 1 ] && { echo "loop: dry run, skipped"; break; }

  head_before=$(git rev-parse HEAD)
  log="$LOGDIR/$id.log"
  rendered=$(mktemp)
  python3 - "$PROMPT" "$rendered" "$task" <<'PY'
import sys
src, dst, item = sys.argv[1], sys.argv[2], sys.argv[3]
open(dst, 'w').write(open(src).read().replace('%ITEM%', item))
PY

  # shellcheck disable=SC2086
  $TIMEOUT_CMD devin -p --model "$MODEL" --permission-mode "$PERMISSION_MODE" \
      --respect-workspace-trust false --prompt-file "$rendered" >"$log" 2>&1
  rc=$?
  rm -f "$rendered"

  git pull --rebase -q 2>/dev/null
  if [ "$(git rev-parse HEAD)" != "$head_before" ] && [ -z "$(git status --porcelain)" ]; then
    mark "$id" 'x'; echo "loop: $id done (rc=$rc)"
  elif [ -z "$(git status --porcelain)" ] && [ -n "$(echo "$task" | cut -d'|' -f1 | tr -d ' ')" ] \
      && git log -1 --format=%s | grep -qi "$(echo "$task" | cut -d'|' -f1 | tr -d ' ')"; then
    mark "$id" 'x'; echo "loop: $id done (commit matched task)"
  else
    mark "$id" '!'
    echo "loop: $id failed or left the tree dirty (rc=$rc); see $log"
    [ -n "$(git status --porcelain)" ] && git stash push -u -m "loop:$id-incomplete" -q 2>/dev/null \
      && echo "loop: stashed leftovers as 'loop:$id-incomplete'"
  fi
  git push origin main -q 2>/dev/null   # safety net; the agent pushes itself

  count=$((count+1))
  [ $ONCE -eq 1 ] && break
  [ "$MAX_ITEMS" -gt 0 ] && [ $count -ge "$MAX_ITEMS" ] && break
done
echo "loop: finished $count item(s)."
