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
start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prod="${PROD_BRANCH:-main}"

# An agent session may exit early ("waiting for CI" is not a thing a one-shot
# session can do). So: run in rounds, and only VERIFIED state counts as done —
# never the agent's exit code. Done means: staging is contained in prod, no
# promotion PR is still open, and at least one promotion PR merged after we
# started (guards against declaring victory without having done anything).
promotion_done() {
  local contained open merged
  contained=$(gh api "repos/$GH_REPO/compare/$prod...$staging" --jq .status 2>/dev/null || echo unknown)
  case "$contained" in identical|behind) ;; *) return 1 ;; esac
  open=$(gh pr list -R "$GH_REPO" --state open --json baseRefName,headRefName --jq \
    "[.[] | select((.baseRefName == \"$staging\" or .baseRefName == \"$prod\")
      and ((.headRefName | startswith(\"promotion/\")) or (.headRefName | startswith(\"promote/\"))
           or .headRefName == \"${BASE_BRANCH:-main}\" or .headRefName == \"$staging\"))] | length")
  [ "${open:-1}" -eq 0 ] || return 1
  merged=$(gh pr list -R "$GH_REPO" --state merged --limit 40 --json baseRefName,mergedAt --jq \
    "[.[] | select((.baseRefName == \"$staging\" or .baseRefName == \"$prod\") and .mergedAt >= \"$start_iso\")] | length")
  [ "${merged:-0}" -ge 1 ]
}

outcome="FAILED"
rounds="${PROMOTE_MAX_ROUNDS:-8}"
for round in $(seq 1 "$rounds"); do
  log "promotion round $round/$rounds"
  if ! pick_claude_account; then
    log "round $round deferred — waiting for an account to fall behind its line"
    sleep "${PROMOTE_ROUND_WAIT:-600}"
    continue
  fi
  GH_REPO=$GH_REPO BASE_BRANCH="${BASE_BRANCH:-main}" \
    STAGING_BRANCH="$staging" PROD_BRANCH="$prod" \
    REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" \
    bash -c "$PROMOTE_CMD" >>"$STATE_DIR/promotion.log" 2>&1 \
    || log "round $round: agent exited non-zero"
  if promotion_done; then outcome="succeeded"; break; fi
  log "round $round: promotion not verified complete — waiting $(( ${PROMOTE_ROUND_WAIT:-600} / 60 ))m for CI, then relaunching"
  sleep "${PROMOTE_ROUND_WAIT:-600}"
done

# optional deterministic runtime check (endpoint probes etc.) after a verified merge
if [ "$outcome" = "succeeded" ] && [ -n "${PROMOTE_VERIFY_CMD:-}" ]; then
  if ! bash -c "$PROMOTE_VERIFY_CMD" >>"$STATE_DIR/promotion.log" 2>&1; then
    outcome="merged, runtime verification FAILED"
  fi
fi

echo "$(date +%s) $outcome" >"$STATE_DIR/promotion-last"
log "promotion $outcome after $(( ($(date +%s) - start) / 60 ))m (details: state/promotion.log)"
[ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: promotion $outcome" bash -c "$NOTIFY_CMD" || true; }
