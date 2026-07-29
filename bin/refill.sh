#!/usr/bin/env bash
# refill: when the ready-issue queue runs low, run the scanner to generate more.
. "$(dirname "$0")/lib.sh"

count=$(ready_issues | wc -l | tr -d ' ')
log "ready issues: $count (threshold: $REFILL_THRESHOLD)"

if [ "$count" -ge "$REFILL_THRESHOLD" ]; then
  log "queue healthy, nothing to do"
  exit 0
fi

# ponytail: flock so an overlapping timer fire never runs two scanners at once
exec 9>"$STATE_DIR/refill.lock"
flock -n 9 || { log "refill already running, skipping"; exit 0; }

log "queue low — running scanner"
cd "$ISSUE_PILOT_HOME"
bash -c "$SCANNER_CMD"
log "scanner finished; ready issues now: $(ready_issues | wc -l | tr -d ' ')"
