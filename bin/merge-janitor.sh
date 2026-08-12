#!/usr/bin/env bash
# merge-janitor: land green orphan PRs. A worker opens a PR, CI concludes after
# its batch session is gone, and nothing ever merges it — the adopt rule covers
# red orphans, this covers green ones. Merges exactly what a live worker would:
# all checks green, no conflicts, same AUTO_MERGE gate. Mechanical, no LLM.
. "$(dirname "$0")/lib.sh"

[ "${AUTO_MERGE:-false}" = "true" ] || { log "merge-janitor: AUTO_MERGE is off — nothing to do"; exit 0; }

PR_PREFIX="${PR_DOCTOR_PREFIX:-pilot-}"
merged=0
rows=$(gh pr list -R "$GH_REPO" --state open --limit 100 \
  --json number,headRefName,mergeable,statusCheckRollup \
  --jq '.[] | select(.headRefName | startswith("'"$PR_PREFIX"'"))
        | select(.mergeable == "MERGEABLE")
        | select(([.statusCheckRollup[]? | select(.status != "COMPLETED")] | length) == 0)
        | select(([.statusCheckRollup[]? | select(.conclusion == "FAILURE")] | length) == 0)
        | select(([.statusCheckRollup[]? | select(.conclusion == "SUCCESS")] | length) > 0)
        | .number' 2>/dev/null) || { log "merge-janitor: gh query failed"; exit 0; }
[ -n "$rows" ] || { log "merge-janitor: no green orphan PRs"; exit 0; }

for n in $rows; do
  if gh pr merge "$n" -R "$GH_REPO" --squash --delete-branch >/dev/null 2>&1; then
    log "merge-janitor: merged green orphan PR #$n"
    merged=$((merged + 1))
  else
    log "merge-janitor: PR #$n did not merge (base moved or new required check) — next pass retries"
  fi
done
log "merge-janitor: merged $merged PR(s)"
[ "$merged" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ] && \
  MSG="issue-pilot: merge-janitor landed $merged green orphan PR(s)" bash -c "$NOTIFY_CMD" || true
exit 0
