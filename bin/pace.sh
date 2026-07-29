#!/usr/bin/env bash
# pace: the thermostat. Compares quota actually used against the ideal straight-line
# burn to the weekly reset, and nudges the dispatcher's worker count up or down.
. "$(dirname "$0")/lib.sh"

WEEK_SECS=604800

if [ -z "${USAGE_CMD:-}" ]; then
  echo "$MIN_WORKERS" >"$STATE_DIR/workers"
  log "no USAGE_CMD configured — pinned workers to MIN_WORKERS=$MIN_WORKERS"
  exit 0
fi

read -r used secs_left < <(bash -c "$USAGE_CMD")
expected=$(awk -v s="$secs_left" -v w="$WEEK_SECS" 'BEGIN { printf "%.1f", 100 * (w - s) / w }')
behind=$(awk -v e="$expected" -v u="$used" 'BEGIN { printf "%.1f", e - u }')

current=$(cat "$STATE_DIR/workers" 2>/dev/null || echo "$MIN_WORKERS")
target=$current
# ponytail: one-step nudges, not proportional control — the pacer runs often enough
# that ±1 per tick converges, and it can't overshoot the quota by Tuesday
if awk -v b="$behind" -v t="$PACE_TOLERANCE" 'BEGIN { exit !(b > t) }'; then
  target=$((current + 1))
elif awk -v b="$behind" -v t="$PACE_TOLERANCE" 'BEGIN { exit !(b < -t) }'; then
  target=$((current - 1))
fi
[ "$target" -gt "$MAX_WORKERS" ] && target=$MAX_WORKERS
[ "$target" -lt "$MIN_WORKERS" ] && target=$MIN_WORKERS
echo "$target" >"$STATE_DIR/workers"

log "used=${used}% expected=${expected}% drift=${behind}% workers: $current -> $target"

if [ -n "${NOTIFY_CMD:-}" ] && awk -v b="$behind" -v t="$PACE_TOLERANCE" 'BEGIN { exit !(b > 2*t || b < -2*t) }'; then
  MSG="issue-pilot: usage ${used}% vs ideal ${expected}% (drift ${behind}%), workers=$target" bash -c "$NOTIFY_CMD" || true
fi
