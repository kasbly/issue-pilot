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
  read -r claims verdicts < <(gh issue view "$n" -R "$GH_REPO" --json comments \
    --jq '[([.comments[] | select(.body | startswith("claimed by"))] | length),
           ([.comments[] | select(.body | startswith("claimed by") | not)] | length)] | @tsv' 2>/dev/null) || continue
  [ "${claims:-0}" -ge "$park_after" ] || continue
  # claims without a single substantive worker comment are mechanical churn
  # (repace kills, auth outages) — require real engagement, or twice the strikes
  if [ "${verdicts:-0}" -eq 0 ] && [ "${claims:-0}" -lt $((park_after * 2)) ]; then continue; fi
  if gh issue edit "$n" -R "$GH_REPO" --remove-label "$READY_LABEL,$CLAIM_LABEL" --add-label "$blocked" >/dev/null 2>&1; then
    gh issue comment "$n" -R "$GH_REPO" --body "Blocked: parked by issue-pilot — claimed $claims times without a PR, so workers cannot finish it as written. A maintainer decision is needed; re-add \`$READY_LABEL\` (and remove \`$blocked\`) to re-queue." >/dev/null 2>&1 || true
    log "janitor: parked #$n ($claims claims, no PR) -> $blocked"
    parked=$((parked + 1))
  fi
done
if [ "$parked" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ]; then
  MSG="issue-pilot: janitor parked $parked looping issue(s) as $blocked" bash -c "$NOTIFY_CMD" || true
fi

# Base-breakage verdict abuse: a worker that cannot make its PR green can write
# "blocked by base breakage" and walk away; the next batch adopts the PR, rebases,
# burns a CI run, and writes it again — twelve rounds on one PR before a human
# noticed. The base-red flag (pr-doctor) is the only evidence that verdict may rest
# on. With no flag and BASE_BLOCK_MAX such verdicts, the failure is the PR's own:
# park it as a draft (lanes skip drafts), park its issue, and tell a human.
if [ ! -f "$STATE_DIR/base-red" ]; then
  bb_max="${BASE_BLOCK_MAX:-2}"
  # only PRs that are red right now: a fix push resets the rollup, and a PR whose
  # checks are queued, running, or green has nothing to park
  for row in $(gh pr list -R "$GH_REPO" --state open --limit 100 --json number,headRefName,isDraft,comments,statusCheckRollup \
      --jq '.[] | select(.isDraft | not) | select(.headRefName | startswith("'"${PR_DOCTOR_PREFIX:-pilot-}"'"))
            | select([.statusCheckRollup[]? | select(.conclusion == "FAILURE")] | length > 0)
            | "\(.number):\(.headRefName):\([.comments[] | select(.body | ascii_downcase | contains("blocked by base breakage"))] | length)"' 2>/dev/null \
      | awk -F: -v m="$bb_max" '$3 >= m {print $1 ":" $2}'); do
    pr=${row%%:*}; head=${row#*:}; issue=${head##*issue-}
    gh pr ready "$pr" -R "$GH_REPO" --undo >/dev/null 2>&1 || continue
    gh pr comment "$pr" -R "$GH_REPO" --body "Blocked: parked by issue-pilot — workers wrote \`blocked by base breakage\` $bb_max+ times while no base-breakage issue is open, so the failure is this PR's own. Converted to draft (lanes skip drafts); a maintainer must fix or close it, then mark it ready for review." >/dev/null 2>&1 || true
    case "$issue" in ""|*[!0-9]*) ;; *) gh issue edit "$issue" -R "$GH_REPO" --remove-label "$READY_LABEL,$CLAIM_LABEL" --add-label "$blocked" >/dev/null 2>&1 || true ;; esac
    log "janitor: parked PR #$pr as draft ($bb_max+ base-breakage verdicts while the base is green)"
    [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: parked PR #$pr as draft — workers blamed the base $bb_max+ times but the base is green; it needs a human" bash -c "$NOTIFY_CMD" || true; }
  done
fi

# Leaked worktrees: prompts tell workers to clean up, but killed batches can't.
# Remove pilot/promote worktrees untouched for JANITOR_WORKTREE_HOURS (default 6 —
# no healthy worker holds one longer; at a few GB each, 48h let ~200 pile up and
# fill a 1.2T disk) with no open files, then prune the clone's worktree registry.
wt_removed=0
for d in ${TMP_SWEEP_GLOBS:-/tmp/pilot-* /tmp/promote-*}; do
  [ -e "$d" ] || continue
  # loose files (install/push logs a worker left beside its worktree) age out too
  if [ -f "$d" ]; then
    [ $(( $(date +%s) - $(stat -c %Y "$d") )) -gt $(( ${JANITOR_WORKTREE_HOURS:-6} * 3600 )) ] && rm -f "$d"
    continue
  fi
  age=$(( $(date +%s) - $(stat -c %Y "$d" 2>/dev/null || date +%s) ))
  [ "$age" -gt $(( ${JANITOR_WORKTREE_HOURS:-6} * 3600 )) ] || continue
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
  for d in ${TMP_SWEEP_GLOBS:-/tmp/pilot-* /tmp/promote-*}; do
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


# --- Claude login expiry ------------------------------------------------------
# Refresh tokens expire ~30 days after login regardless of use; an expired one
# silently idles every window lane on that account. Warn ahead (once per day)
# and shout when an account is already logged out.
for entry in ${CLAUDE_ACCOUNTS:-}; do
  a_name=${entry%%:*}; a_dir=${entry#*:}; creds="$a_dir/.credentials.json"
  [ -f "$creds" ] || continue
  tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null || true)
  exp=$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // 0' "$creds" 2>/dev/null || echo 0); exp=$(( ${exp:-0} / 1000 ))
  stamp="$STATE_DIR/login-warned-$a_name"
  if [ -z "$tok" ]; then
    msg="Claude account '$a_name' is LOGGED OUT — its lanes are idle until you re-login"
  elif [ "$exp" -gt 0 ] && [ $(( exp - $(date +%s) )) -lt $(( ${LOGIN_WARN_DAYS:-3} * 86400 )) ]; then
    msg="Claude account '$a_name' login expires $(date -d @"$exp" '+%b %-d %H:%M') — re-login before then"
  else
    rm -f "$stamp"; continue
  fi
  if [ ! -f "$stamp" ] || [ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -ge 86400 ]; then
    log "janitor: $msg"
    [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: $msg" bash -c "$NOTIFY_CMD" || true; }
    touch "$stamp"
  fi
done

# --- Agent CLI updates --------------------------------------------------------
# Agent CLIs ship weekly and a stale one quietly loses models (Claude Code
# 2.1.258 did not know claude-opus-5-5). Once per CLI_UPDATE_HOURS run each
# CLI_UPDATE_<name> (an idempotent "install latest"), then record what
# CLI_VERSION_<name> reports; a change is logged, notified, and shown on the panel.
# ponytail: no idle gate — npm swaps the package dir and grok swaps a symlink, so
# a CLI that is already running keeps its old inode until it exits.
cli_ver() { bash -c "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true; }
cli_stamp="$STATE_DIR/cli-updated"
if [ -n "${CLIS:-}" ] && { [ ! -f "$cli_stamp" ] || [ $(( $(date +%s) - $(stat -c %Y "$cli_stamp") )) -ge $(( ${CLI_UPDATE_HOURS:-24} * 3600 )) ]; }; then
  touch "$cli_stamp"
  for c in $CLIS; do
    ver_var="CLI_VERSION_$c"; upd_var="CLI_UPDATE_$c"
    ver_cmd="${!ver_var:-$c --version}"; upd_cmd="${!upd_var:-}"
    before=$(cli_ver "$ver_cmd")
    [ -n "$upd_cmd" ] && { bash -c "$upd_cmd" >>"$STATE_DIR/cli-update.log" 2>&1 || log "janitor: $c update command failed (see state/cli-update.log)"; }
    after=$(cli_ver "$ver_cmd")
    echo "${after:-?}" >"$STATE_DIR/cli-version-$c"
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
      log "janitor: updated $c ${before:-?} → $after"
      [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: updated $c ${before:-?} → $after" bash -c "$NOTIFY_CMD" || true; }
    fi
  done
fi

exit 0
