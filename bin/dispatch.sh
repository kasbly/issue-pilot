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
    if kill -0 "${lane_pid[$id]}" 2>/dev/null; then
      # the pacer zeroed this lane (quota back on pace / resources gone), the panel
      # disabled it, or the whole system was paused: stop the batch process group
      # now instead of letting it run on stale concurrency
      c=$(cat "$STATE_DIR/lane-$id.concurrency" 2>/dev/null || echo 0)
      if paused || lane_disabled "$id" || [ "$c" -eq 0 ]; then
        log "lane $id: target dropped to 0 — stopping running batch"
        kill -TERM -- "-${lane_pid[$id]}" 2>/dev/null || kill -TERM "${lane_pid[$id]}" 2>/dev/null || true
      fi
      continue
    fi
    wait "${lane_pid[$id]}" && st=0 || st=$?
    log "lane $id: batch finished status=$st"
    bash "$PKG_DIR/bin/cost-log.sh" lane "$id" "$(cat "$STATE_DIR/lane-$id.batch-started" 2>/dev/null || echo 0)" \
      "$(lane_get "$id" CMD)" "$(lane_get "$id" MODEL)/$(lane_get "$id" EFFORT)" || true
    # Crash-loop tripwire: a batch that fails almost instantly (broken auth, bad
    # CLI) would otherwise be relaunched forever. LANE_CRASH_MAX such failures in
    # a row auto-disable the lane via the same flag the panel toggle uses, with a
    # reason the panel shows; re-enabling from the panel clears the strike count.
    # Signal exits (>=128, e.g. our own TERM on repace) never count as crashes.
    b_start=$(cat "$STATE_DIR/lane-$id.batch-started" 2>/dev/null || echo 0)
    b_dur=$(( $(date +%s) - b_start ))
    if [ "$st" -gt 0 ] && [ "$st" -lt 128 ] && [ "$b_start" -gt 0 ] && [ "$b_dur" -lt "${LANE_CRASH_SECS:-120}" ]; then
      n=$(( $(cat "$STATE_DIR/lane-$id.crashes" 2>/dev/null || echo 0) + 1 ))
      echo "$n" >"$STATE_DIR/lane-$id.crashes"
      if [ "$n" -ge "${LANE_CRASH_MAX:-3}" ]; then
        why="crash loop — $n batches in a row died within ${LANE_CRASH_SECS:-120}s"
        tail -30 "$STATE_DIR/batch-$id.log" 2>/dev/null | grep -q -i -E "refresh token was revoked|401 Unauthorized|log ?out and sign in|invalid_grant|not logged in|token .*expired" \
          && why="authentication broken — re-login needed ($n instant batch failures)"
        touch "$STATE_DIR/lane-$id.disabled"
        printf '%s\n' "auto-disabled $(date '+%F %T'): $why" >"$STATE_DIR/lane-$id.disabled-reason"
        rm -f "$STATE_DIR/lane-$id.crashes"
        log "lane $id: AUTO-DISABLED — $why"
        [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: lane '$id' auto-disabled — $why" bash -c "$NOTIFY_CMD" || true; }
      fi
    else
      rm -f "$STATE_DIR/lane-$id.crashes"
    fi
    [ "$st" -ne 0 ] && log "lane $id: non-zero exit — issues it claimed may need '$CLAIM_LABEL' removed to re-queue"
    unset "lane_pid[$id]"
  done

  if paused; then
    [ "${was_paused:-0}" = 1 ] || log "system PAUSED from the panel — no batches will start"
    was_paused=1
  else
    [ "${was_paused:-0}" = 0 ] || log "system resumed"
    was_paused=0
  fi

  if ! paused && [ -n "$(ready_issues | head -1)" ]; then
    sort_dir=asc; [ "${ISSUE_ORDER:-oldest}" = "newest" ] && sort_dir=desc
    for id in ${LANES:-}; do
      [ -n "${lane_pid[$id]:-}" ] && continue
      lane_disabled "$id" && continue
      c=$(cat "$STATE_DIR/lane-$id.concurrency" 2>/dev/null || echo 0)
      [ "$c" -gt 0 ] || continue
      label=$(lane_get "$id" LABEL "$id")
      log "lane $id: starting batch (concurrency=$c)"
      date +%s >"$STATE_DIR/lane-$id.batch-started"
      CONCURRENCY=$c BATCH_SIZE=$(lane_get "$id" BATCH_SIZE "$BATCH_SIZE") GH_REPO=$GH_REPO \
        BASE_BRANCH="${BASE_BRANCH:-main}" AUTO_MERGE="${AUTO_MERGE:-false}" \
        MERGE_METHOD="${MERGE_METHOD:---merge}" \
        ISSUE_ORDER="${ISSUE_ORDER:-oldest}" SORT_DIR=$sort_dir \
        READY_LABEL=$READY_LABEL CLAIM_LABEL=$CLAIM_LABEL BLOCKED_LABEL="${BLOCKED_LABEL:-status/blocked}" \
        REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" \
        LANE_NAME="$label" LANE_SLUG="pilot-$id" CAMPAIGN_LABEL="${CAMPAIGN_LABEL:-}" \
        setsid bash -c "$(lane_get "$id" CMD 'echo "lane has no CMD configured" >&2; exit 1')" \
        >>"$STATE_DIR/batch-$id.log" 2>&1 &
      lane_pid[$id]=$! # setsid: the batch leads its own process group, so a lane
                       # stop can kill orchestrator AND subagents together
    done
  fi
  sleep "$POLL_SECS"
done
