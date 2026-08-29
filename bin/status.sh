#!/usr/bin/env bash
# Collects subscription usage + active work into web/status.json for the status page.
# Linux-only (GNU date, /proc). Run from issue-pilot-status.timer every few minutes.
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME"
mkdir -p web
now=$(date +%s)

join_json() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -s '.'; fi; }

acc_rows=()
declare -A DIR2NAME=()
CODEX_NAME="Codex"

IFS=';' read -ra ACCTS <<<"${STATUS_ACCOUNTS:-}"
for a in "${ACCTS[@]}"; do
  IFS='|' read -r name kind path <<<"$a"
  used="" resets=0 stale=0 h5=""
  if [ "$kind" = "grok" ]; then
    # Grok Build has no public usage API; usage-grok.sh scrapes the TUI's /usage
    # panel (weekly limit % + reset). Fall back to a plain connected marker.
    auth=false; [ -s "$path" ] && auth=true
    g_used=""; g_resets=0
    if read -r g_pct g_secs < <(bash "$PKG_DIR/bin/usage-grok.sh" 2>/dev/null) && [ -n "${g_secs:-}" ]; then
      g_used=$g_pct; g_resets=$(( now + g_secs ))
    fi
    acc_rows+=("$(jq -n --arg name "$name" --argjson auth "$auth" --arg used "$g_used" --argjson resets "$g_resets" \
      '{name:$name, kind:"grok",
        used_pct:(if $used=="" then null else ($used|tonumber) end),
        resets_at:(if $resets==0 then null else $resets end),
        five_hour_pct:null, stale_secs:0,
        no_usage_api:(if $used=="" then true else false end), connected:$auth}')")
    continue
  fi
  if [ "$kind" = "claude" ]; then
    DIR2NAME[$(dirname "$path")]=$name
    # usage-claude.sh self-heals stale tokens (idle accounts stop refreshing them),
    # so the card never shows "no data" for a merely-idle account
    if read -r u_pct u_secs u_h5 _ < <(CLAUDE_CREDENTIALS="$path" bash "$PKG_DIR/bin/usage-claude.sh" 2>/dev/null) && [ -n "${u_secs:-}" ]; then
      used=$u_pct
      resets=$(( $(date +%s) + u_secs ))
      h5=${u_h5:-}
    fi
  else
    CODEX_NAME=$name # fallback attribution for codex procs without LANE_NAME
    # newest codex session file WITH a rate_limits snapshot — a busy lane creates
    # fresh session files faster than snapshots land in them, so the newest file
    # is often still empty; an unguarded grep here once killed status.sh for an
    # hour under set -e. || true everywhere: SIGPIPE + no-match are both benign.
    snap=""
    for f in $(ls -t "$path"/*/*/*/*.jsonl 2>/dev/null | head -20 || true); do
      snap=$(grep -o '"rate_limits":{[^}]*}[^}]*}[^}]*}' "$f" 2>/dev/null | tail -1 || true)
      [ -n "$snap" ] && break
    done
    if [ -n "$snap" ]; then
      used=$(grep -o '"used_percent":[0-9.]*' <<<"$snap" | head -1 | cut -d: -f2 || true)
      resets=$(grep -o '"resets_at":[0-9]*' <<<"$snap" | head -1 | cut -d: -f2 || true)
      stale=$((now - $(stat -c %Y "$f")))
    fi
  fi
  acc_rows+=("$(jq -n --arg name "$name" --arg kind "$kind" --arg used "${used:-}" \
    --argjson resets "${resets:-0}" --argjson stale "${stale:-0}" --arg h5 "${h5:-}" \
    '{name:$name, kind:$kind,
      used_pct:(if $used=="" then null else ($used|tonumber) end),
      resets_at:(if $resets==0 then null else $resets end),
      five_hour_pct:(if $h5=="" then null else ($h5|tonumber) end),
      stale_secs:$stale}')")
done

proc_rows=()
declare -A LIVE=()
while read -r pid etimes rest; do
  [ -n "$pid" ] || continue
  acct="" env_lane=""
  env_lane=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^LANE_NAME=//p')
  case "$rest" in
    *"codex exec"*) acct=${env_lane:-$CODEX_NAME} ;;
    *"claude -p"*)
      cfg=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p')
      acct=${env_lane:-${DIR2NAME[${cfg:-$HOME/.claude}]:-Claude}} ;;
  esac
  [ -n "$acct" ] || continue
  # role from the session's own prompt text — an orchestration session billed to an
  # account is NOT that account's lane worker
  role="agent"
  case "$rest" in
    *"batch orchestrator"*) role="lane batch" ;;
    *"issue scanner"*)      role="scanner" ;;
    *"campaign analyst"*)   role="campaign" ;;
    *"release engineer"*)   role="promotion" ;;
  esac
  [ "$role" = "lane batch" ] && LIVE[$acct]=$(( ${LIVE[$acct]:-0} + 1 ))
  proc_rows+=("$(jq -n --arg a "$acct" --arg role "$role" --argjson pid "$pid" --argjson up "$etimes" \
    '{account:$a, role:$role, pid:$pid, uptime_secs:$up}')")
done < <(ps -u "$(id -un)" -o pid=,etimes=,args= | grep -E 'claude -p|codex exec' | grep -v -e 'bash -c' -e grep)

dispatch=$(systemctl is-active issue-pilot-dispatch.service 2>/dev/null || true)
claimed=$(gh issue list -R "$GH_REPO" --state open --label "$CLAIM_LABEL" --json number,title,url 2>/dev/null || echo '[]')
all_prs=$(gh pr list -R "$GH_REPO" --author "@me" --state all --limit 100 --json number,title,url,createdAt,headRefName 2>/dev/null || echo '[]')

# queue + refill
ready_count=$(ready_issues | wc -l | tr -d ' ')
open_total=$(gh api "search/issues?q=repo:$GH_REPO+is:issue+is:open&per_page=1" --jq '.total_count' 2>/dev/null || echo 0)
# parked by workers/janitor: a human decision is needed before they can re-queue
blocked_total=$(gh api -X GET search/issues -f q="repo:$GH_REPO is:issue is:open label:\"${BLOCKED_LABEL:-status/blocked}\"" -f per_page=1 --jq '.total_count' 2>/dev/null || echo 0)
next_refill=0
nr=$(systemctl show issue-pilot-refill.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
[ -n "$nr" ] && [ "$nr" != "n/a" ] && next_refill=$(date -d "$nr" +%s 2>/dev/null || echo 0)
read -r rl_ts rl_action rl_detail 2>/dev/null <"$STATE_DIR/refill-last" || { rl_ts=0; rl_action=""; rl_detail=""; }
b_red=false; [ -f "$STATE_DIR/base-red" ] && b_red=true
# the "needs you" pane lists a few parked issues by title (count comes from blocked_total)
blocked_list=$(gh api -X GET search/issues -f q="repo:$GH_REPO is:issue is:open label:\"${BLOCKED_LABEL:-status/blocked}\"" \
  -f per_page=6 --jq '[.items[] | {number, title}]' 2>/dev/null || echo '[]')
refill=$(jq -n --argjson ready "$ready_count" --argjson threshold "${REFILL_THRESHOLD:-0}" \
  --argjson open "$open_total" --argjson blocked "$blocked_total" --argjson blocked_list "$blocked_list" \
  --argjson base_red "$b_red" --argjson batch "${BATCH_SIZE:-25}" --argjson next "$next_refill" \
  --arg model "${SCANNER_MODEL:-}" --arg effort "${SCANNER_EFFORT:-}" \
  --arg fb "$([ -n "${SCANNER_FALLBACK_CMD:-}" ] && echo "${SCANNER_FALLBACK_MODEL:-}${SCANNER_FALLBACK_EFFORT:+ (${SCANNER_FALLBACK_EFFORT})}")" \
  --argjson last_ts "${rl_ts:-0}" --arg last_action "${rl_action:-}" --arg last_detail "${rl_detail:-}" \
  '{ready:$ready, threshold:$threshold, open_issues:$open, blocked_issues:$blocked, blocked_list:$blocked_list,
    base_red:$base_red, batch_size:$batch, next_run:(if $next==0 then null else $next end),
    scanner_model:(if $model=="" then null else $model end), scanner_effort:(if $effort=="" then null else $effort end),
    scanner_fallback:(if $fb=="" then null else $fb end),
    last:(if $last_ts==0 then null else {ts:$last_ts, action:$last_action, detail:$last_detail} end)}')

# merged-PR throughput (server-local calendar days; mergedAt is UTC — close enough for a scoreboard)
merged=$(gh pr list -R "$GH_REPO" --author "@me" --state merged --limit 500 --json mergedAt 2>/dev/null || echo '[]')
throughput=$(jq -n --argjson m "$merged" --arg today "$(date +%F)" --arg yday "$(date -d yesterday +%F)" \
  '{merged_today:([$m[] | select(.mergedAt|startswith($today))] | length),
    merged_yesterday:([$m[] | select(.mergedAt|startswith($yday))] | length)}')

# per-lane batch progress: PRs are attributed by their pilot-<lane>/ branch prefix
lane_rows=()
# show lanes in the pace allocator's priority order (most pace headroom first),
# appending any lane the allocator hasn't scored yet
lane_order=""
for id in $(cat "$STATE_DIR/alloc-order" 2>/dev/null) ${LANES:-}; do
  case " ${LANES:-} " in *" $id "*) case " $lane_order " in *" $id "*) ;; *) lane_order="$lane_order $id" ;; esac ;; esac
done
for id in $lane_order; do
  conc=$(cat "$STATE_DIR/lane-$id.concurrency" 2>/dev/null || echo 0)
  started=$(cat "$STATE_DIR/lane-$id.batch-started" 2>/dev/null || echo 0)
  l_label=$(lane_get "$id" LABEL "$id")
  lane_rows+=("$(jq -n --arg id "$id" --arg label "$l_label" \
    --arg mode "$(lane_get "$id" MODE off)" --argjson conc "$conc" \
    --argjson disabled "$(lane_disabled "$id" && echo true || echo false)" \
    --argjson live "${LIVE[$l_label]:-0}" \
    --arg model "$(lane_get "$id" MODEL)" --arg effort "$(lane_get "$id" EFFORT)" \
    --argjson started "$started" --argjson target "${BATCH_SIZE:-0}" \
    --argjson prs "$all_prs" '
    {id:$id, label:$label, mode:$mode, concurrency:$conc, disabled:$disabled, workers_live:$live, model:$model, effort:$effort,
     batch_started:(if $started==0 then null else $started end),
     batch_target:$target,
     batch_done:([$prs[] | select((.headRefName|startswith("pilot-"+$id+"/"))
                                  and (.createdAt|fromdateiso8601) >= $started)] | length),
     total_done:([$prs[] | select(.headRefName|startswith("pilot-"+$id+"/"))] | length)}')")
done

# promotion state (live commit count; last-run details written by promote.sh)
pw_count=$(gh api "repos/$GH_REPO/compare/${STAGING_BRANCH:-staging}...${BASE_BRANCH:-main}" --jq .total_commits 2>/dev/null || echo 0)
read -r pl_ts pl_outcome 2>/dev/null <"$STATE_DIR/promotion-last" || { pl_ts=0; pl_outcome=""; }
p_active=false; [ -f "$STATE_DIR/promotion-active" ] && p_active=true
promotion=$(jq -n --arg enabled "${PROMOTE_ENABLED:-false}" --argjson waiting "${pw_count:-0}" \
  --argjson threshold "${PROMOTE_AFTER_COMMITS:-100}" --argjson active "$p_active" \
  --argjson last_ts "${pl_ts:-0}" --arg last_outcome "${pl_outcome:-}" \
  '{enabled:($enabled=="true"), waiting:$waiting, threshold:$threshold, active:$active,
    last:(if $last_ts==0 then null else {ts:$last_ts, outcome:$last_outcome} end)}')

# release announcements (announce.sh): last post, pending retry, latest preview text
read -r al_ts al_outcome al_n 2>/dev/null <"$STATE_DIR/announce-last" || { al_ts=0; al_outcome=""; al_n=0; }
a_pending=false; [ -f "$STATE_DIR/announce-pending" ] && a_pending=true
a_prev=""; a_prev_ts=0
if [ -f "$STATE_DIR/announce-preview.txt" ]; then
  a_prev=$(head -c 3000 "$STATE_DIR/announce-preview.txt"); a_prev_ts=$(stat -c %Y "$STATE_DIR/announce-preview.txt")
fi
announce=$(jq -n --arg enabled "${ANNOUNCE_ENABLED:-false}" --argjson pending "$a_pending" \
  --argjson last_ts "${al_ts:-0}" --arg last_outcome "${al_outcome:-}" --argjson last_n "${al_n:-0}" \
  --argjson prev_ts "$a_prev_ts" --arg prev "$a_prev" \
  '{enabled:($enabled=="true"), pending:$pending,
    last:(if $last_ts==0 then null else {ts:$last_ts, outcome:$last_outcome, commits:$last_n} end),
    preview:(if $prev_ts==0 then null else {ts:$prev_ts, text:$prev} end)}')

# scanners: union of rotation entries, working-dir overrides, the SCANNED REPO's own
# scanners/ directory, and the built-in library; enabled = in rotation
scan_rows=()
rot=" ${SCANNER_ROTATION:-} "
peek_next=$(cat "$STATE_DIR/next-scanner" 2>/dev/null || true)
rdir="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}"
ref="origin/${BASE_BRANCH:-main}"
repo_dims=""
if [ -d "$rdir/.git" ]; then
  git -C "$rdir" fetch -q origin "${BASE_BRANCH:-main}" 2>/dev/null || true
  repo_dims=$(git -C "$rdir" ls-tree --name-only "$ref" scanners/ 2>/dev/null \
    | sed -n 's|^scanners/\(.*\)\.md$|\1|p' | grep -vE '^(CONTEXT|README)$' || true)
fi
all_dims=$( { for d in ${SCANNER_ROTATION:-}; do echo "$d"; done
              printf '%s\n' "$repo_dims"
              for base in "$ISSUE_PILOT_HOME/scanners" "$PKG_DIR/scanners"; do
                [ -d "$base" ] && for f in "$base"/*.md; do
                  [ -e "$f" ] || continue
                  n=$(basename "$f" .md)
                  if [ "$n" != "CONTEXT" ] && [ "$n" != "README" ]; then echo "$n"; fi
                done
              done; } | sed '/^$/d' | sort -u )
for d in $all_dims; do
  enabled=false; case "$rot" in *" $d "*) enabled=true ;; esac
  desc=""; src=""
  if [ -f "$ISSUE_PILOT_HOME/scanners/$d.md" ]; then
    desc=$(head -1 "$ISSUE_PILOT_HOME/scanners/$d.md")
    # when working dir == package dir (git-clone install), tracked files are the
    # shipped library, not user overrides
    if [ "$ISSUE_PILOT_HOME" = "$PKG_DIR" ] && git -C "$PKG_DIR" ls-files --error-unmatch "scanners/$d.md" >/dev/null 2>&1; then
      src="built-in"
    else
      src="custom"
    fi
  elif grep -qx "$d" <<<"$repo_dims"; then
    desc=$(git -C "$rdir" show "$ref:scanners/$d.md" 2>/dev/null | head -1)
    src="repo"
  elif [ -f "$PKG_DIR/scanners/$d.md" ]; then
    desc=$(head -1 "$PKG_DIR/scanners/$d.md")
    src="built-in"
  fi
  desc=$(sed 's/^DIMENSION: *[^—-]*[—-] *//; s/^# *//' <<<"$desc")
  dim_key=$(tr '-' '_' <<<"$d")
  mv_var="SCANNER_MODEL_$dim_key"; ev_var="SCANNER_EFFORT_$dim_key"
  d_model="${!mv_var:-${SCANNER_MODEL_DEFAULT:-${SCANNER_MODEL:-}}}"
  d_effort="${!ev_var:-${SCANNER_EFFORT_DEFAULT:-${SCANNER_EFFORT:-}}}"
  d_last=$(awk -v d="$d" '$1 == d { print $2 }' "$STATE_DIR/scanner-runs" 2>/dev/null || true)
  d_filed=$(awk -v d="$d" '$1 == d && NF >= 3 { print $3 }' "$STATE_DIR/scanner-runs" 2>/dev/null || true)
  d_focus=$(awk -v d="$d" '$1 == d && NF >= 4 { out=""; for (i=4; i<=NF; i++) out = out (i>4?" ":"") $i; print out }' "$STATE_DIR/scanner-runs" 2>/dev/null || true)
  iv_var="SCANNER_INTERVAL_$dim_key"; d_interval="${!iv_var:-}"
  scan_rows+=("$(jq -n --arg name "$d" --argjson enabled "$enabled" --arg desc "$desc" --arg src "$src" \
    --arg model "$d_model" --arg effort "$d_effort" --argjson last "${d_last:-0}" \
    --arg filed "${d_filed:-}" --arg interval "$d_interval" --arg focus "${d_focus:-}" \
    --argjson next "$([ "$d" = "$peek_next" ] && echo true || echo false)" \
    '{name:$name, enabled:$enabled, desc:$desc, source:(if $src=="" then "rotation-only" else $src end),
      model:(if $model=="" then null else $model end), effort:(if $effort=="" then null else $effort end),
      last_run:(if $last==0 then null else $last end),
      last_filed:(if $filed=="" then null else ($filed | tonumber) end),
      interval:(if $interval=="" then null else $interval end),
      last_focus:(if $focus=="" then null else $focus end), queued_next:$next}')")
done

# campaign state
CDIR="$STATE_DIR/campaign"
c_goal=$(cat "$CDIR/goal.md" 2>/dev/null || true)
c_status=$(cat "$CDIR/status" 2>/dev/null || true)
c_assess=$(cat "$CDIR/last-assessment.md" 2>/dev/null || true)
c_open=0; c_closed=0
if [ -n "$c_goal" ]; then
  c_open=$(gh issue list -R "$GH_REPO" --state open --label "${CAMPAIGN_LABEL:-campaign}" --json number --jq length 2>/dev/null || echo 0)
  # done counts only THIS campaign's issues: filed after its start timestamp
  c_started=$(cat "$CDIR/started" 2>/dev/null || echo 0)
  if [ "${c_started:-0}" -gt 0 ]; then
    c_since=$(date -u -d "@$c_started" +%Y-%m-%dT%H:%M:%SZ)
    c_closed=$(gh issue list -R "$GH_REPO" --state closed --limit 200 \
      --search "label:${CAMPAIGN_LABEL:-campaign} created:>=$c_since" \
      --json number --jq length 2>/dev/null || echo 0)
  else
    c_closed=$(gh issue list -R "$GH_REPO" --state closed --label "${CAMPAIGN_LABEL:-campaign}" --limit 200 --json number --jq length 2>/dev/null || echo 0)
  fi
fi
campaign=$(jq -n --arg goal "$c_goal" --arg status "$c_status" --arg assess "$c_assess" \
  --argjson open "${c_open:-0}" --argjson closed "${c_closed:-0}" \
  --arg history "$(tail -3 "$CDIR/history.log" 2>/dev/null || true)" \
  '{goal:(if $goal=="" then null else $goal end), status:(if $status=="" then null else $status end),
    assessment:(if $assess=="" then null else $assess end), open:$open, closed:$closed,
    history:(if $history=="" then null else $history end)}')

read -r rb_budget rb_load rb_cores rb_mem 2>/dev/null <"$STATE_DIR/resource-budget" || { rb_budget=0; rb_load=0; rb_cores=0; rb_mem=0; }
disk_free_mb=$(df -Pm "$ISSUE_PILOT_HOME" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
resources=$(jq -n --argjson budget "${rb_budget:-0}" --arg load "${rb_load:-0}" \
  --argjson cores "${rb_cores:-0}" --argjson mem_mb "${rb_mem:-0}" \
  --argjson disk "${disk_free_mb:-0}" \
  '{budget:$budget, load5:$load, cores:$cores, mem_mb:$mem_mb, disk_free_mb:$disk}')

sys_paused=false; paused && sys_paused=true

# panel role switches: which loops may bill the Claude accounts
cr_i=true; [ -f "$STATE_DIR/claude-role-issues.disabled" ] && cr_i=false
cr_s=true; [ -f "$STATE_DIR/claude-role-scanner.disabled" ] && cr_s=false
cr_p=true; [ -f "$STATE_DIR/claude-role-promote.disabled" ] && cr_p=false
claude_roles=$(jq -n --argjson i "$cr_i" --argjson s "$cr_s" --argjson p "$cr_p" \
  '{issues:$i, scanner:$s, promote:$p}')

join_json "${acc_rows[@]}" | jq \
  --argjson gen "$now" --arg dispatch "$dispatch" --argjson paused "$sys_paused" \
  --argjson resources "$resources" \
  --argjson workers "$(join_json "${proc_rows[@]}")" \
  --argjson lanes "$(join_json "${lane_rows[@]}")" \
  --argjson claimed "$claimed" \
  --argjson refill "$refill" --argjson throughput "$throughput" --argjson promotion "$promotion" \
  --argjson announce "$announce" --argjson claude_roles "$claude_roles" \
  --argjson scanners "$(join_json "${scan_rows[@]}")" --argjson campaign "$campaign" \
  --argjson prs "$(jq '[.[:8][] | {number,title,url,createdAt}]' <<<"$all_prs")" \
  '{generated_at:$gen, dispatch:$dispatch, paused:$paused, accounts:., lanes:$lanes, workers:$workers,
    resources:$resources, refill:$refill, throughput:$throughput, promotion:$promotion,
    announce:$announce, claude_roles:$claude_roles, scanners:$scanners, campaign:$campaign, claimed:$claimed, recent_prs:$prs}' \
  >web/status.json.tmp && mv web/status.json.tmp web/status.json
