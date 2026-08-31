#!/usr/bin/env bash
# claim-janitor: release claims whose worker died. Killed batches and crashed
# subagents leave issues labeled CLAIM_LABEL forever, silently shrinking the queue.
# A claim is stale when the issue has no OPEN PR (head ending in "issue-<n>") and
# its latest "claimed by" comment is older than JANITOR_STALE_HOURS (default 6 —
# no healthy worker holds a claim that long without opening a PR). Only open PRs
# count as proof of life: a closed-unmerged PR is a FAILED attempt, and treating
# it as alive once locked a base-breakage issue for 28h while 47 red PRs piled up.
. "$(dirname "$0")/lib.sh"

cutoff=$(( $(date +%s) - ${JANITOR_STALE_HOURS:-6} * 3600 ))
heads=$(gh pr list -R "$GH_REPO" --state open --author "@me" --limit 300 --json headRefName --jq '.[].headRefName' 2>/dev/null || true)

released=0
for n in $(gh issue list -R "$GH_REPO" --state open --label "$CLAIM_LABEL" --limit 50 --json number --jq '.[].number' 2>/dev/null); do
  grep -q "issue-${n}\$" <<<"$heads" && continue
  claimed_at=$(gh issue view "$n" -R "$GH_REPO" --json comments \
    --jq '[.comments[] | select(.body | startswith("claimed by")) | .createdAt] | last // empty' 2>/dev/null)
  [ -n "$claimed_at" ] || claimed_at=$(gh issue view "$n" -R "$GH_REPO" --json updatedAt --jq .updatedAt 2>/dev/null)
  ts=$(date -d "$claimed_at" +%s 2>/dev/null || echo 0)
  if [ "$ts" -gt 0 ] && [ "$ts" -lt "$cutoff" ]; then
    if gh issue edit "$n" -R "$GH_REPO" --remove-label "$CLAIM_LABEL" >/dev/null 2>&1; then
      log "janitor: released stale claim #$n (claimed $(( ($(date +%s) - ts) / 3600 ))h ago, no PR)"
      released=$((released + 1))
    fi
  fi
done
if [ "$released" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ]; then
  MSG="issue-pilot: janitor released $released stale claim(s)" bash -c "$NOTIFY_CMD" || true
fi

# Claim loops: an issue no worker can finish (needs a maintainer decision, hits the
# CI guardrail) gets claimed, refused, un-claimed and re-claimed by the next batch —
# hundreds of comments and zero progress. Park any ready issue with
# PARK_AFTER_CLAIMS or more "claimed by" comments and no open PR: out of the ready
# queue, BLOCKED_LABEL on, one comment. Candidates come from one search call.
park_after="${PARK_AFTER_CLAIMS:-4}"
blocked="${BLOCKED_LABEL:-status/blocked}"
parked=0
for n in $(gh api -X GET search/issues -f q="repo:$GH_REPO is:issue is:open label:\"$READY_LABEL\" comments:>=$park_after" \
           -f per_page=50 --jq '.items[].number' 2>/dev/null); do
  grep -q "issue-${n}\$" <<<"$heads" && continue
  claims=$(gh issue view "$n" -R "$GH_REPO" --json comments \
    --jq '[.comments[] | select(.body | startswith("claimed by"))] | length' 2>/dev/null || echo 0)
  [ "${claims:-0}" -ge "$park_after" ] || continue
  if gh issue edit "$n" -R "$GH_REPO" --remove-label "$READY_LABEL,$CLAIM_LABEL" --add-label "$blocked" >/dev/null 2>&1; then
    gh issue comment "$n" -R "$GH_REPO" --body "Blocked: parked by issue-pilot — claimed $claims times without a PR, so workers cannot finish it as written. A maintainer decision is needed; re-add \`$READY_LABEL\` (and remove \`$blocked\`) to re-queue." >/dev/null 2>&1 || true
    log "janitor: parked #$n ($claims claims, no PR) -> $blocked"
    parked=$((parked + 1))
  fi
done
if [ "$parked" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ]; then
  MSG="issue-pilot: janitor parked $parked looping issue(s) as $blocked" bash -c "$NOTIFY_CMD" || true
fi

# Leaked worktrees: prompts tell workers to clean up, but killed batches can't.
# Remove pilot/promote worktrees untouched for JANITOR_WORKTREE_HOURS (default 48)
# with no open files, then prune the clone's worktree registry.
wt_removed=0
for d in /tmp/pilot-* /tmp/promote-*; do
  [ -d "$d" ] || continue
  age=$(( $(date +%s) - $(stat -c %Y "$d" 2>/dev/null || date +%s) ))
  [ "$age" -gt $(( ${JANITOR_WORKTREE_HOURS:-48} * 3600 )) ] || continue
  lsof -t +d "$d" >/dev/null 2>&1 && continue
  rm -rf "$d" && { log "janitor: removed stale worktree $d ($(( age / 3600 ))h old)"; wt_removed=$((wt_removed + 1)); }
done
[ -d "${REPO_DIR:-$ISSUE_PILOT_HOME/repo}/.git" ] && git -C "${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" worktree prune 2>/dev/null || true
[ "$wt_removed" -gt 0 ] && log "janitor: removed $wt_removed stale worktree(s)"

# workers are told not to install into the scheduler home; sweep it anyway
for d in "$ISSUE_PILOT_HOME/node_modules" "$ISSUE_PILOT_HOME"/.pnpm-store* "$ISSUE_PILOT_HOME/pnpm-store" "$ISSUE_PILOT_HOME/pnpm-lock.yaml"; do
  [ -e "$d" ] || continue
  rm -rf "$d" && log "janitor: removed stray $d from the scheduler home"
done
exit 0

# --- Disk floor --------------------------------------------------------------
# When any watched filesystem drops under DISK_FLOOR_GB free, sweep the safe
# debris — stale batch worktrees in /tmp (lsof-guarded), plus the site-specific
# DISK_FLOOR_SWEEP_CMD — and raise state/disk-low for the panel. The flag clears
# itself once space recovers, so the banner is always current.
floor_gb="${DISK_FLOOR_GB:-30}"
low=""
for pth in ${DISK_FLOOR_PATHS:-/ /tmp}; do
  avail_kb=$(df -Pk "$pth" 2>/dev/null | awk 'NR==2 {print $4}') || true
  [ -n "${avail_kb:-}" ] || continue
  avail_gb=$(( avail_kb / 1048576 ))
  [ "$avail_gb" -lt "$floor_gb" ] && low="${low}${pth} ${avail_gb}G free · "
done
if [ -n "$low" ]; then
  swept=0
  for d in /tmp/pilot-* /tmp/promote-*; do
    [ -d "$d" ] || continue
    [ $(( ($(date +%s) - $(stat -c %Y "$d")) / 3600 )) -ge "${DISK_FLOOR_TMP_HOURS:-6}" ] || continue
    lsof +D "$d" >/dev/null 2>&1 && continue
    rm -rf "$d" 2>/dev/null && swept=$((swept + 1))
  done
  git -C "${REPO_DIR:-$ISSUE_PILOT_HOME/repo}" worktree prune 2>/dev/null || true
  [ -n "${DISK_FLOOR_SWEEP_CMD:-}" ] && bash -c "$DISK_FLOOR_SWEEP_CMD" >/dev/null 2>&1 || true
  echo "$(date '+%F %T') ${low%· } — swept $swept stale worktree(s)" >"$STATE_DIR/disk-low"
  log "janitor: DISK LOW — ${low%· }— swept $swept stale worktree(s) + site sweep"
  [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: disk low — ${low%· }" bash -c "$NOTIFY_CMD" || true; }
else
  rm -f "$STATE_DIR/disk-low"
fi
