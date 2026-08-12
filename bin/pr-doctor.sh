#!/usr/bin/env bash
# pr-doctor: detect base-branch breakage from the pattern no single worker can see —
# many open pilot PRs failing the SAME check. Workers each hit the wall alone, burn
# their fix rounds on an unrelated failure, and walk away; this turns the pattern
# into ONE high-priority issue so a lane fixes the base instead of 18 PRs.
# Mechanical and cheap (no LLM): run hourly from refill, like label-guard.
. "$(dirname "$0")/lib.sh"

PR_PREFIX="${PR_DOCTOR_PREFIX:-pilot-}"          # lane branches look like pilot-<lane>/issue-N
MIN_SAME="${PR_DOCTOR_MIN_SAME:-4}"              # same check red on >= this many PRs => base suspect
ISSUE_TITLE_PREFIX="[CI] Base breakage suspected"

# maintain the base-red flag first: while a suspect issue is open, pace throttles
# every lane to 1 worker (see pace.sh) so the flood of born-red PRs stops.
# (plain list + startswith, NOT --search: the search index lags closes by minutes)
existing=$(gh issue list -R "$GH_REPO" --state open --limit 100 --json title \
  --jq '[.[] | select(.title | startswith("'"$ISSUE_TITLE_PREFIX"'"))] | length' 2>/dev/null || echo 0)
if [ "${existing:-0}" -gt 0 ]; then
  touch "$STATE_DIR/base-red"
else
  rm -f "$STATE_DIR/base-red"
fi

rows=$(gh pr list -R "$GH_REPO" --state open --limit 100 \
  --json number,headRefName,statusCheckRollup \
  --jq '.[] | select(.headRefName | startswith("'"$PR_PREFIX"'"))
        | .number as $n | (.statusCheckRollup[]? | select(.conclusion=="FAILURE") | .name) as $c
        | "\($c)\t\($n)"' 2>/dev/null) || { log "pr-doctor: gh query failed"; exit 0; }
[ -n "$rows" ] || { log "pr-doctor: no red pilot PRs"; exit 0; }

# group by failing check name; report the biggest cluster
top=$(sort <<<"$rows" | awk -F'\t' '{ c[$1] = c[$1] " #" $2; n[$1]++ }
  END { best=""; for (k in n) if (n[k] > n[best]) best=k; print n[best] "\t" best "\t" c[best] }')
cnt=${top%%$'\t'*}; rest=${top#*$'\t'}; check=${rest%%$'\t'*}; prs=${rest#*$'\t'}
log "pr-doctor: $(wc -l <<<"$rows" | tr -d ' ') red pilot PR check(s); biggest cluster: '$check' on $cnt PR(s)"

[ "$cnt" -ge "$MIN_SAME" ] || exit 0

# stale reds are not evidence of a broken base: after a base fix merges, dozens
# of pre-fix PR heads stay red until rebased. If recent completed runs on pilot
# branches include greens, the base is healthy — do not file (and do not flag).
if ! recent=$(gh run list -R "$GH_REPO" --limit 30 --json conclusion,status,headBranch \
  --jq '[.[] | select(.status == "completed" and (.headBranch | startswith("'"$PR_PREFIX"'")))] | .[0:6] | map(.conclusion) | join(" ")' 2>/dev/null); then
  # fail closed: filing needs positive evidence the base is broken. An unreadable
  # probe (API rate limit hit this exact path once) must never produce an alarm.
  log "pr-doctor: cannot read recent run conclusions (API error/rate limit) — not filing without evidence"
  exit 0
fi
case " $recent " in
  *" success "*)
    log "pr-doctor: base looks healthy (recent pilot runs: $recent) — red PRs are stale heads, not filing"
    exit 0
  ;;
esac

# one issue per breakage: skip if an open suspect issue already exists
[ "${existing:-0}" -gt 0 ] && { log "pr-doctor: suspect issue already open — not filing another"; exit 0; }

body="$cnt open pilot PRs are failing the same check (\`$check\`):$prs

Unrelated changes failing one identical check means the breakage is almost
certainly on \`${BASE_BRANCH:-dev}\` itself, inherited by every PR branched from it.

Fix procedure:
1. Reproduce the failing check on a fresh \`origin/${BASE_BRANCH:-dev}\` checkout to confirm.
2. Fix the root cause ON THE BASE BRANCH (via a normal PR) — do NOT patch the
   failing test inside any of the listed PRs.
3. After the fix merges, the listed PRs get adopted by their lanes' next batches
   (rebase + re-run checks) — no manual action needed on them."

gh issue create -R "$GH_REPO" \
  --title "$ISSUE_TITLE_PREFIX: '$check' red on $cnt open pilot PRs" \
  --label "${PR_DOCTOR_LABELS:-agent-created,status/approved,type/bug,priority/high}" \
  ${PR_DOCTOR_ASSIGNEE:+--assignee "$PR_DOCTOR_ASSIGNEE"} \
  --body "$body" >/dev/null \
  && { log "pr-doctor: filed base-breakage issue for '$check' ($cnt PRs)"; touch "$STATE_DIR/base-red"; } \
  || log "pr-doctor: issue creation failed"
