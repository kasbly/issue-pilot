#!/usr/bin/env bash
# dispatch: long-running loop, one batch session per active lane. A lane is active
# when pace.sh wrote concurrency > 0 to state/lane-<id>.concurrency. Each batch
# orchestrates its own subagents (see examples/goal.md); when it ends and ready
# issues remain, the next one starts.
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME" # so lane CMDs can reference examples/ by relative path

declare -A lane_pid=()
log "dispatcher up (repo=$GH_REPO, lanes: ${LANES:-none})"

while true; do
  . "$ISSUE_PILOT_CONF" # hot-reload: conf edits apply from the next batch, no restart

  for id in "${!lane_pid[@]}"; do
    kill -0 "${lane_pid[$id]}" 2>/dev/null && continue
    wait "${lane_pid[$id]}" && st=0 || st=$?
    log "lane $id: batch finished status=$st"
    unset "lane_pid[$id]"
  done

  if [ -n "$(ready_issues | head -1)" ]; then
    sort_dir=asc; [ "${ISSUE_ORDER:-oldest}" = "newest" ] && sort_dir=desc
    for id in ${LANES:-}; do
      [ -n "${lane_pid[$id]:-}" ] && continue
      c=$(cat "$STATE_DIR/lane-$id.concurrency" 2>/dev/null || echo 0)
      [ "$c" -gt 0 ] || continue
      label=$(lane_get "$id" LABEL "$id")
      log "lane $id: starting batch (concurrency=$c)"
      date +%s >"$STATE_DIR/lane-$id.batch-started"
      CONCURRENCY=$c BATCH_SIZE=$BATCH_SIZE GH_REPO=$GH_REPO \
        BASE_BRANCH="${BASE_BRANCH:-main}" AUTO_MERGE="${AUTO_MERGE:-false}" \
        ISSUE_ORDER="${ISSUE_ORDER:-oldest}" SORT_DIR=$sort_dir \
        READY_LABEL=$READY_LABEL CLAIM_LABEL=$CLAIM_LABEL \
        REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" \
        LANE_NAME="$label" LANE_SLUG="pilot-$id" \
        bash -c "$(lane_get "$id" CMD 'echo "lane has no CMD configured" >&2; exit 1')" \
        >>"$STATE_DIR/batch-$id.log" 2>&1 &
      lane_pid[$id]=$!
    done
  fi
  sleep "$POLL_SECS"
done
