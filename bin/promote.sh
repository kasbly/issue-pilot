#!/usr/bin/env bash
# promote: the release loop. When enough commits pile up on BASE_BRANCH, run one
# strong agent session (PROMOTE_CMD) that promotes BASE→STAGING→PROD through PRs,
# fixing CI along the way. Timer-driven; `issue-pilot promote --now` forces a run
# past the enabled/threshold gates (still singleton-locked).
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME"

exec 9>"$STATE_DIR/promote.lock"
flock -n 9 || { log "promotion already running — skipping"; exit 0; }

force=0; [ "${1:-}" = "--now" ] && force=1
if [ "$force" -eq 0 ]; then
  [ "${PROMOTE_ENABLED:-false}" = "true" ] || { log "promotion disabled (PROMOTE_ENABLED=false)"; exit 0; }
  [ "${AUTO_MERGE:-false}" = "true" ] || { log "promotion requires AUTO_MERGE=true"; exit 0; }
fi

staging="${STAGING_BRANCH:-staging}"
waiting=$(gh api "repos/$GH_REPO/compare/$staging...${BASE_BRANCH:-main}" --jq .total_commits 2>/dev/null || echo 0)
echo "$waiting $(date +%s)" >"$STATE_DIR/promotion-waiting"
if [ "$force" -eq 0 ] && [ "$waiting" -lt "${PROMOTE_AFTER_COMMITS:-100}" ]; then
  log "promotion: $waiting commits waiting (< ${PROMOTE_AFTER_COMMITS:-100}) — not yet"
  exit 0
fi

log "promotion starting ($waiting commits ${BASE_BRANCH:-main} -> $staging)"
touch "$STATE_DIR/promotion-active"
trap 'rm -f "$STATE_DIR/promotion-active"' EXIT
[ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: PROMOTION started ($waiting commits waiting)" bash -c "$NOTIFY_CMD" || true; }

start=$(date +%s)
if GH_REPO=$GH_REPO BASE_BRANCH="${BASE_BRANCH:-main}" \
   STAGING_BRANCH="$staging" PROD_BRANCH="${PROD_BRANCH:-main}" \
   REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" \
   bash -c "$PROMOTE_CMD" >>"$STATE_DIR/promotion.log" 2>&1; then
  outcome="succeeded"
else
  outcome="FAILED"
fi
echo "$(date +%s) $outcome" >"$STATE_DIR/promotion-last"
log "promotion $outcome after $(( ($(date +%s) - start) / 60 ))m (details: state/promotion.log)"
[ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: promotion $outcome" bash -c "$NOTIFY_CMD" || true; }
