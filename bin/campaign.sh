#!/usr/bin/env bash
# campaign: the goal loop. You state a goal once; a gap-analysis agent repeatedly
# compares reality against it, files issues for what's missing, and declares the
# goal achieved when nothing meaningful remains.
#   campaign.sh set "<goal text>"   start a new campaign (archives the current one)
#   campaign.sh pause|resume|done   control the current campaign
#   campaign.sh status              print goal + state
#   campaign.sh tick                timer entrypoint: run a gap-analysis round if due
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME"
CDIR="$STATE_DIR/campaign"
mkdir -p "$CDIR"

case "${1:-status}" in
  set)
    [ -n "${2:-}" ] || { echo "usage: campaign set \"<goal>\"" >&2; exit 1; }
    if [ -f "$CDIR/goal.md" ]; then
      echo "$(date +%F) archived: $(head -1 "$CDIR/goal.md")" >>"$CDIR/history.log"
    fi
    printf '%s\n' "$2" >"$CDIR/goal.md"
    echo active >"$CDIR/status"
    rm -f "$CDIR/achieved" "$CDIR/last-assessment.md"
    log "campaign set: $2"
    ;;
  pause)  echo paused >"$CDIR/status"; log "campaign paused" ;;
  resume) echo active >"$CDIR/status"; log "campaign resumed" ;;
  done)
    echo "$(date +%F) done: $(head -1 "$CDIR/goal.md" 2>/dev/null)" >>"$CDIR/history.log"
    echo done >"$CDIR/status"; log "campaign marked done"
    ;;
  status)
    echo "goal:   $(cat "$CDIR/goal.md" 2>/dev/null || echo '(none)')"
    echo "status: $(cat "$CDIR/status" 2>/dev/null || echo '(none)')"
    ;;
  tick)
    exec 9>"$CDIR/tick.lock"
    flock -n 9 || { log "campaign tick already running"; exit 0; }
    [ "$(cat "$CDIR/status" 2>/dev/null)" = "active" ] || { log "campaign not active — tick skipped"; exit 0; }

    # only re-analyze when the lanes have nearly drained the previous batch of
    # campaign issues — that is the "implemented, now validate" moment
    open=$(gh issue list -R "$GH_REPO" --state open --label "${CAMPAIGN_LABEL:-campaign}" --json number --jq length 2>/dev/null || echo 0)
    if [ "$open" -gt "${CAMPAIGN_MIN_OPEN:-3}" ]; then
      log "campaign tick: $open campaign issues still open (> ${CAMPAIGN_MIN_OPEN:-3}) — lanes still working"
      exit 0
    fi

    log "campaign tick: running gap analysis"
    export CAMPAIGN_GOAL="$(cat "$CDIR/goal.md")"
    export GH_REPO READY_LABEL BASE_BRANCH="${BASE_BRANCH:-main}" \
      REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" \
      CAMPAIGN_LABEL="${CAMPAIGN_LABEL:-campaign}" \
      CAMPAIGN_MAX_ISSUES="${CAMPAIGN_MAX_ISSUES:-10}" \
      CAMPAIGN_BROWSER_URL="${CAMPAIGN_BROWSER_URL:-}" \
      CAMPAIGN_STATE_DIR="$CDIR"
    bash -c "$CAMPAIGN_CMD" >>"$CDIR/campaign.log" 2>&1 || log "campaign agent exited non-zero"

    if [ -f "$CDIR/achieved" ]; then
      echo "$(date +%F) ACHIEVED: $(head -1 "$CDIR/goal.md")" >>"$CDIR/history.log"
      echo done >"$CDIR/status"
      log "campaign GOAL ACHIEVED"
      [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: campaign goal ACHIEVED — $(head -1 "$CDIR/goal.md")" bash -c "$NOTIFY_CMD" || true; }
    fi
    ;;
  *) echo "usage: campaign <set|pause|resume|done|status|tick>" >&2; exit 1 ;;
esac
