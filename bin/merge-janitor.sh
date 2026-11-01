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
  # protected paths (customer-facing AI behaviour) land only for evidence-backed
  # issues — same rule the lanes and label-guard apply, enforced at the last gate
  if [ -n "${PROTECTED_PATHS:-}" ]; then
    files=$(gh pr view "$n" -R "$GH_REPO" --json files --jq '[.files[].path]|join(" ")' 2>/dev/null || true)
    if protected_hit "$files"; then
      iss=$(gh pr view "$n" -R "$GH_REPO" --json headRefName --jq .headRefName 2>/dev/null | sed -n 's/.*issue-\([0-9][0-9]*\)$/\1/p')
      ok=1
      if [ -n "$iss" ]; then
        b=$(gh issue view "$iss" -R "$GH_REPO" --json body --jq .body 2>/dev/null || true)
        l=$(gh issue view "$iss" -R "$GH_REPO" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || true)
        has_evidence "$b" "$l" && ok=0
      fi
      if [ "$ok" -ne 0 ]; then
        gh pr close "$n" -R "$GH_REPO" --delete-branch --comment "Closed by issue-pilot: this PR changes a protected path (customer-facing AI behaviour) for an issue that carries no tenant evidence. Owners change these paths on their own evidence; the pilot does not." >/dev/null 2>&1 || true
        [ -n "$iss" ] && gh issue edit "$iss" -R "$GH_REPO" --remove-label "$READY_LABEL,$CLAIM_LABEL" --add-label owner-managed >/dev/null 2>&1 && gh issue close "$iss" -R "$GH_REPO" --reason "not planned" >/dev/null 2>&1 || true
        log "merge-janitor: closed PR #$n — protected path without evidence (issue #${iss:-?})"
        continue
      fi
    fi
  fi
  if gh pr merge "$n" -R "$GH_REPO" ${MERGE_METHOD:---merge} --delete-branch >/dev/null 2>&1; then
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
