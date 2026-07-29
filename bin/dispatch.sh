#!/usr/bin/env bash
# dispatch: long-running loop that keeps N workers busy on ready issues.
# N is written by pace.sh into state/workers (defaults to MIN_WORKERS).
. "$(dirname "$0")/lib.sh"

declare -A worker_pid_issue=()

reap() {
  local pid
  for pid in "${!worker_pid_issue[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" && status=0 || status=$?
      local issue="${worker_pid_issue[$pid]}"
      log "worker pid=$pid issue=#$issue exited status=$status"
      # ponytail: unclaim on failure so the issue goes back in the queue; on success
      # the worker's PR closing the issue is the terminal state, label stays as audit trail
      if [ "$status" -ne 0 ]; then
        gh issue edit "$issue" -R "$GH_REPO" --remove-label "$CLAIM_LABEL" || true
      fi
      unset "worker_pid_issue[$pid]"
    fi
  done
}

log "dispatcher up (repo=$GH_REPO, min=$MIN_WORKERS, max=$MAX_WORKERS)"
while true; do
  reap
  target=$(cat "$STATE_DIR/workers" 2>/dev/null || echo "$MIN_WORKERS")
  [ "$target" -gt "$MAX_WORKERS" ] && target=$MAX_WORKERS
  [ "$target" -lt 0 ] && target=0
  running=${#worker_pid_issue[@]}

  if [ "$running" -lt "$target" ]; then
    issue=$(ready_issues | head -1)
    if [ -n "${issue:-}" ]; then
      gh issue edit "$issue" -R "$GH_REPO" --add-label "$CLAIM_LABEL"
      ISSUE_NUMBER=$issue GH_REPO=$GH_REPO bash -c "$WORKER_CMD" \
        >>"$STATE_DIR/worker-$issue.log" 2>&1 &
      worker_pid_issue[$!]=$issue
      log "started worker pid=$! issue=#$issue ($((running + 1))/$target)"
      continue # fill remaining slots without waiting a full poll
    fi
  fi
  sleep "$POLL_SECS"
done
