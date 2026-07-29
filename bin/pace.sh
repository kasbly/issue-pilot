#!/usr/bin/env bash
# pace: the thermostat. Compares quota actually used against the ideal straight-line
# burn to the weekly reset, and nudges the batch subagent concurrency up or down.
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME" # so USAGE_CMD can use relative paths like bin/usage-ccusage.sh

WEEK_SECS=604800

if [ -z "${USAGE_CMD:-}" ]; then
  echo "$CONCURRENCY" >"$STATE_DIR/concurrency"
  log "no USAGE_CMD configured — pinned concurrency to CONCURRENCY=$CONCURRENCY"
  exit 0
fi

read -r used secs_left < <(bash -c "$USAGE_CMD")
expected=$(awk -v s="$secs_left" -v w="$WEEK_SECS" 'BEGIN { printf "%.1f", 100 * (w - s) / w }')
behind=$(awk -v e="$expected" -v u="$used" 'BEGIN { printf "%.1f", e - u }')

current=$(cat "$STATE_DIR/concurrency" 2>/dev/null || echo "$CONCURRENCY")
target=$current
# ponytail: one-step nudges, not proportional control — the pacer runs often enough
# that ±1 per tick converges, and it can't overshoot the quota by Tuesday
if awk -v b="$behind" -v t="$PACE_TOLERANCE" 'BEGIN { exit !(b > t) }'; then
  target=$((current + 1))
elif awk -v b="$behind" -v t="$PACE_TOLERANCE" 'BEGIN { exit !(b < -t) }'; then
  target=$((current - 1))
fi
[ "$target" -gt "$MAX_CONCURRENCY" ] && target=$MAX_CONCURRENCY
[ "$target" -lt "$MIN_CONCURRENCY" ] && target=$MIN_CONCURRENCY
echo "$target" >"$STATE_DIR/concurrency"

log "used=${used}% expected=${expected}% drift=${behind}% concurrency: $current -> $target"

if [ -n "${NOTIFY_CMD:-}" ] && awk -v b="$behind" -v t="$PACE_TOLERANCE" 'BEGIN { exit !(b > 2*t || b < -2*t) }'; then
  MSG="issue-pilot: usage ${used}% vs ideal ${expected}% (drift ${behind}%), concurrency=$target" bash -c "$NOTIFY_CMD" || true
fi
