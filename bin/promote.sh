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
# an announcement deferred for lack of an account (or a failed post) is retried here
if [ "${ANNOUNCE_ENABLED:-false}" = "true" ] && [ -f "$STATE_DIR/announce-pending" ]; then
  bash "$PKG_DIR/bin/announce.sh" || true
fi
if [ "$force" -eq 0 ]; then
  paused && { log "system paused — promotion skipped"; exit 0; }
  [ "${PROMOTE_ENABLED:-false}" = "true" ] || { log "promotion disabled (PROMOTE_ENABLED=false)"; exit 0; }
  [ "${AUTO_MERGE:-false}" = "true" ] || { log "promotion requires AUTO_MERGE=true"; exit 0; }
fi

# panel role switch: "Claude promotes" off while PROMOTE_CMD runs the claude CLI
if [ "${PROMOTE_USES_CLAUDE:-true}" = "true" ] && [ -f "$STATE_DIR/claude-role-promote.disabled" ]; then
  log "promotion runs on Claude but Claude is switched off for promotion (panel) — skipping"
  exit 0
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
prod_before=$(gh api "repos/$GH_REPO/commits/$prod" --jq .sha 2>/dev/null || true)

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

# A mid-flight release outranks pace purity: deferring rounds lets the frozen
# candidate rot while dev advances. Promotion may bill a somewhat-ahead account
# (ORCH_MAX_USED still protects nearly-spent ones).
export ORCH_MAX_DRIFT="${PROMOTE_MAX_DRIFT:-50}"

# Between rounds, wait for a STATE CHANGE, not a fixed nap: relaunching an
# opus/max session while CI is still running burns most of it on re-orienting
# just to conclude "still waiting", and napping after CI already concluded
# wastes wall-clock. Poll cheaply until every open promotion PR's checks have
# concluded (or the promotion completed), capped at PROMOTE_ROUND_WAIT_MAX.
promo_ci_pending() {
  gh pr list -R "$GH_REPO" --state open --json headRefName,statusCheckRollup --jq \
    "[.[] | select((.headRefName | startswith(\"promotion/\")) or (.headRefName | startswith(\"promote/\"))
       or .headRefName == \"${BASE_BRANCH:-main}\" or .headRefName == \"$staging\")
      | .statusCheckRollup[]? | select(.status != \"COMPLETED\")] | length" 2>/dev/null || echo 0
}
wait_for_round() {
  local waited=0 cap="${PROMOTE_ROUND_WAIT_MAX:-2700}" step=120 p
  while [ "$waited" -lt "$cap" ]; do
    sleep "$step"; waited=$((waited + step))
    promotion_done && return 0
    p=$(promo_ci_pending)
    [ "${p:-0}" -eq 0 ] && { log "round wait: promotion CI concluded after ${waited}s — relaunching"; return 0; }
  done
  log "round wait: cap reached (${cap}s) with CI still pending — relaunching anyway"
}

outcome="FAILED"
rounds="${PROMOTE_MAX_ROUNDS:-8}"
for round in $(seq 1 "$rounds"); do
  log "promotion round $round/$rounds"
  # PROMOTE_USES_CLAUDE=false when PROMOTE_CMD bills another provider (grok, codex)
  if [ "${PROMOTE_USES_CLAUDE:-true}" = "true" ] && ! pick_claude_account; then
    log "round $round deferred — waiting for an account to fall behind its line"
    sleep "${PROMOTE_ROUND_WAIT:-600}"
    continue
  fi
  round_start=$(date +%s)
  PROMOTE_MODEL="${PROMOTE_MODEL:-}" PROMOTE_EFFORT="${PROMOTE_EFFORT:-}" \
  GH_REPO=$GH_REPO BASE_BRANCH="${BASE_BRANCH:-main}" \
    STAGING_BRANCH="$staging" PROD_BRANCH="$prod" \
    REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" \
    bash -c "$PROMOTE_CMD" >>"$STATE_DIR/promotion.log" 2>&1 \
    || log "round $round: agent exited non-zero"
  bash "$PKG_DIR/bin/cost-log.sh" promotion "round $round" "$round_start" "$PROMOTE_CMD" || true
  if promotion_done; then outcome="succeeded"; break; fi
  log "round $round: promotion not verified complete — waiting for promotion CI to conclude (cap $(( ${PROMOTE_ROUND_WAIT_MAX:-2700} / 60 ))m)"
  wait_for_round
  if promotion_done; then outcome="succeeded"; break; fi
done

# optional deterministic runtime check (endpoint probes etc.) after a verified merge
if [ "$outcome" = "succeeded" ] && [ -n "${PROMOTE_VERIFY_CMD:-}" ]; then
  if ! bash -c "$PROMOTE_VERIFY_CMD" >>"$STATE_DIR/promotion.log" 2>&1; then
    outcome="merged, runtime verification FAILED"
  fi
fi

echo "$(date +%s) $outcome" >"$STATE_DIR/promotion-last"
# release note for non-technical users — only after a fully verified release
if [ "$outcome" = "succeeded" ] && [ "${ANNOUNCE_ENABLED:-false}" = "true" ]; then
  ANNOUNCE_FROM="$prod_before" bash "$PKG_DIR/bin/announce.sh" || log "announce failed (details: state/announce.log)"
fi
log "promotion $outcome after $(( ($(date +%s) - start) / 60 ))m (details: state/promotion.log)"
[ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: promotion $outcome" bash -c "$NOTIFY_CMD" || true; }
