#!/usr/bin/env bash
# claim-janitor: release claims whose worker died. Killed batches and crashed
# subagents leave issues labeled CLAIM_LABEL forever, silently shrinking the queue.
# A claim is stale when the issue has no PR (head ending in "issue-<n>") and its
# latest "claimed by" comment is older than JANITOR_STALE_HOURS (default 6 — no
# healthy worker holds a claim that long without opening a PR).
. "$(dirname "$0")/lib.sh"

cutoff=$(( $(date +%s) - ${JANITOR_STALE_HOURS:-6} * 3600 ))
heads=$(gh pr list -R "$GH_REPO" --state all --author "@me" --limit 100 --json headRefName --jq '.[].headRefName' 2>/dev/null || true)

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
exit 0
