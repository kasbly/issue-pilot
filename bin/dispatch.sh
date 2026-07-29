#!/usr/bin/env bash
# dispatch: long-running loop that runs one batch session at a time.
# The batch session (BATCH_CMD, see examples/goal.md) orchestrates its own subagents,
# CONCURRENCY at a time. pace.sh adjusts state/concurrency between batches.
. "$(dirname "$0")/lib.sh"

cd "$ISSUE_PILOT_HOME" # so BATCH_CMD can reference examples/ by relative path
log "dispatcher up (repo=$GH_REPO, batch_size=$BATCH_SIZE)"

while true; do
  . "$ISSUE_PILOT_CONF" # hot-reload: conf edits apply from the next batch, no restart
  if [ -z "$(ready_issues | head -1)" ]; then
    sleep "$POLL_SECS"
    continue
  fi
  # ponytail: concurrency is read per-batch, not live — a running session keeps the
  # concurrency it started with; the pacer's nudge applies from the next batch on
  concurrency=$(cat "$STATE_DIR/concurrency" 2>/dev/null || echo "$CONCURRENCY")
  sort_dir=asc; [ "${ISSUE_ORDER:-oldest}" = "newest" ] && sort_dir=desc
  log "starting batch session (concurrency=$concurrency)"
  CONCURRENCY=$concurrency BATCH_SIZE=$BATCH_SIZE GH_REPO=$GH_REPO \
    BASE_BRANCH="${BASE_BRANCH:-main}" AUTO_MERGE="${AUTO_MERGE:-false}" \
    ISSUE_ORDER="${ISSUE_ORDER:-oldest}" SORT_DIR=$sort_dir READY_LABEL=$READY_LABEL CLAIM_LABEL=$CLAIM_LABEL \
    REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" \
    bash -c "$BATCH_CMD" >>"$STATE_DIR/batch.log" 2>&1 \
    && log "batch session finished" || log "batch session exited non-zero"
  sleep "$POLL_SECS"
done
