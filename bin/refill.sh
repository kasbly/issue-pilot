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
# SCANNER_ROTATION (= the enabled set, in order). state/next-scanner, written by
# the web panel's "Run next", overrides the rotation once.
if [ -n "${SCANNER_ROTATION:-}" ]; then
  if [ -s "$STATE_DIR/next-scanner" ]; then
    next=$(cat "$STATE_DIR/next-scanner")
    rm -f "$STATE_DIR/next-scanner"
    log "scanner rotation: dimension=$next (one-shot override)"
  else
    last=$(cat "$STATE_DIR/last-scanner" 2>/dev/null || true)
    next=""; prev=""
    for d in $SCANNER_ROTATION; do
      [ -z "$next" ] && [ "$prev" = "$last" ] && [ -n "$last" ] && next=$d
      prev=$d
    done
    [ -n "$next" ] || next=${SCANNER_ROTATION%% *}
    log "scanner rotation: dimension=$next"
  fi
  export SCANNER_DIMENSION=$next
  echo "$next" >"$STATE_DIR/last-scanner"
  # methodology file: working dir overrides the scanned repo's scanners/, which
  # overrides the built-in library
  for base in "$ISSUE_PILOT_HOME/scanners" "${REPO_DIR:-$ISSUE_PILOT_HOME/repo}/scanners" "$PKG_DIR/scanners"; do
    if [ -f "$base/$next.md" ]; then export SCANNER_PROMPT_FILE="$base/$next.md"; break; fi
  done
fi

export GH_REPO READY_LABEL BASE_BRANCH="${BASE_BRANCH:-main}" REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}"
pick_claude_account || { log "scanner deferred — next hourly check retries"; exit 0; }
bash -c "$SCANNER_CMD"
bash "$PKG_DIR/bin/label-guard.sh" || true
after=$(ready_issues | wc -l | tr -d ' ')
echo "$(date +%s) ran queue=$after" >"$STATE_DIR/refill-last"
log "scanner finished; ready issues now: $after"
