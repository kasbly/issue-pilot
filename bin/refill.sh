#!/usr/bin/env bash
# refill: when the ready-issue queue runs low, run the scanner to generate more.
. "$(dirname "$0")/lib.sh"

count=$(ready_issues | wc -l | tr -d ' ')
log "ready issues: $count (threshold: $REFILL_THRESHOLD)"

if [ "$count" -ge "$REFILL_THRESHOLD" ]; then
  log "queue healthy, nothing to do"
  echo "$(date +%s) skipped queue=$count" >"$STATE_DIR/refill-last"
  exit 0
fi

# ponytail: flock so an overlapping timer fire never runs two scanners at once
exec 9>"$STATE_DIR/refill.lock"
flock -n 9 || { log "refill already running, skipping"; exit 0; }

log "queue low — running scanner"
cd "$ISSUE_PILOT_HOME"

# strict round-robin over scanning dimensions: each refill runs the NEXT one in
# SCANNER_ROTATION and exports it as $SCANNER_DIMENSION for the prompt template
if [ -n "${SCANNER_ROTATION:-}" ]; then
  last=$(cat "$STATE_DIR/last-scanner" 2>/dev/null || true)
  next=""; prev=""
  for d in $SCANNER_ROTATION; do
    [ -z "$next" ] && [ "$prev" = "$last" ] && [ -n "$last" ] && next=$d
    prev=$d
  done
  [ -n "$next" ] || next=${SCANNER_ROTATION%% *}
  export SCANNER_DIMENSION=$next
  echo "$next" >"$STATE_DIR/last-scanner"
  log "scanner rotation: dimension=$next"
fi

bash -c "$SCANNER_CMD"
after=$(ready_issues | wc -l | tr -d ' ')
echo "$(date +%s) ran queue=$after" >"$STATE_DIR/refill-last"
log "scanner finished; ready issues now: $after"
