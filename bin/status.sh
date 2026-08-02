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
  if [ "$kind" = "claude" ]; then
    DIR2NAME[$(dirname "$path")]=$name
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$path" 2>/dev/null)
    if [ -n "$tok" ]; then
      resp=$(curl -sf --max-time 20 https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" || true)
      used=$(jq -r '.seven_day.utilization // empty' <<<"$resp")
      iso=$(jq -r '.seven_day.resets_at // empty' <<<"$resp")
      [ -n "$iso" ] && resets=$(date -d "$iso" +%s)
      h5=$(jq -r '.five_hour.utilization // empty' <<<"$resp")
    fi
  else
    CODEX_NAME=$name
    # newest codex session file's last rate_limits snapshot (stale between runs)
    # || true: with many session files, head's early exit SIGPIPEs ls under pipefail
    f=$(ls -t "$path"/*/*/*/*.jsonl 2>/dev/null | head -1 || true)
    if [ -n "$f" ]; then
      snap=$(grep -o '"rate_limits":{[^}]*}[^}]*}[^}]*}' "$f" | tail -1)
      used=$(grep -o '"used_percent":[0-9.]*' <<<"$snap" | head -1 | cut -d: -f2)
      resets=$(grep -o '"resets_at":[0-9]*' <<<"$snap" | head -1 | cut -d: -f2)
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
  proc_rows+=("$(jq -n --arg a "$acct" --argjson pid "$pid" --argjson up "$etimes" \
    '{account:$a, pid:$pid, uptime_secs:$up}')")
done < <(ps -u "$(id -un)" -o pid=,etimes=,args= | grep -E 'claude -p|codex exec' | grep -v -e 'bash -c' -e grep)

dispatch=$(systemctl is-active issue-pilot-dispatch.service 2>/dev/null || true)
claimed=$(gh issue list -R "$GH_REPO" --state open --label "$CLAIM_LABEL" --json number,title,url 2>/dev/null || echo '[]')
all_prs=$(gh pr list -R "$GH_REPO" --author "@me" --state all --limit 100 --json number,title,url,createdAt,headRefName 2>/dev/null || echo '[]')

# queue + refill
ready_count=$(ready_issues | wc -l | tr -d ' ')
open_total=$(gh api "search/issues?q=repo:$GH_REPO+is:issue+is:open&per_page=1" --jq '.total_count' 2>/dev/null || echo 0)
next_refill=0
nr=$(systemctl show issue-pilot-refill.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
[ -n "$nr" ] && [ "$nr" != "n/a" ] && next_refill=$(date -d "$nr" +%s 2>/dev/null || echo 0)
read -r rl_ts rl_action rl_detail 2>/dev/null <"$STATE_DIR/refill-last" || { rl_ts=0; rl_action=""; rl_detail=""; }
refill=$(jq -n --argjson ready "$ready_count" --argjson threshold "${REFILL_THRESHOLD:-0}" \
  --argjson open "$open_total" --argjson next "$next_refill" \
  --arg model "${SCANNER_MODEL:-}" --arg effort "${SCANNER_EFFORT:-}" \
  --argjson last_ts "${rl_ts:-0}" --arg last_action "${rl_action:-}" --arg last_detail "${rl_detail:-}" \
  '{ready:$ready, threshold:$threshold, open_issues:$open, next_run:(if $next==0 then null else $next end),
    scanner_model:(if $model=="" then null else $model end), scanner_effort:(if $effort=="" then null else $effort end),
    last:(if $last_ts==0 then null else {ts:$last_ts, action:$last_action, detail:$last_detail} end)}')

# merged-PR throughput (server-local calendar days; mergedAt is UTC — close enough for a scoreboard)
merged=$(gh pr list -R "$GH_REPO" --author "@me" --state merged --limit 500 --json mergedAt 2>/dev/null || echo '[]')
throughput=$(jq -n --argjson m "$merged" --arg today "$(date +%F)" --arg yday "$(date -d yesterday +%F)" \
  '{merged_today:([$m[] | select(.mergedAt|startswith($today))] | length),
    merged_yesterday:([$m[] | select(.mergedAt|startswith($yday))] | length)}')

# per-lane batch progress: PRs are attributed by their pilot-<lane>/ branch prefix
lane_rows=()
for id in ${LANES:-}; do
  conc=$(cat "$STATE_DIR/lane-$id.concurrency" 2>/dev/null || echo 0)
  started=$(cat "$STATE_DIR/lane-$id.batch-started" 2>/dev/null || echo 0)
  lane_rows+=("$(jq -n --arg id "$id" --arg label "$(lane_get "$id" LABEL "$id")" \
    --arg mode "$(lane_get "$id" MODE off)" --argjson conc "$conc" \
    --arg model "$(lane_get "$id" MODEL)" --arg effort "$(lane_get "$id" EFFORT)" \
    --argjson started "$started" --argjson target "${BATCH_SIZE:-0}" \
    --argjson prs "$all_prs" '
    {id:$id, label:$label, mode:$mode, concurrency:$conc, model:$model, effort:$effort,
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

# scanners: union of rotation entries, working-dir overrides, the SCANNED REPO's own
# scanners/ directory, and the built-in library; enabled = in rotation
scan_rows=()
rot=" ${SCANNER_ROTATION:-} "
peek_next=$(cat "$STATE_DIR/next-scanner" 2>/dev/null || true)
rdir="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}"
scan_bases="$ISSUE_PILOT_HOME/scanners $rdir/scanners $PKG_DIR/scanners"
all_dims=$( { for d in ${SCANNER_ROTATION:-}; do echo "$d"; done
              for base in $scan_bases; do
                [ -d "$base" ] && for f in "$base"/*.md; do
                  [ -e "$f" ] || continue
                  n=$(basename "$f" .md)
                  if [ "$n" != "CONTEXT" ] && [ "$n" != "README" ]; then echo "$n"; fi
                done
              done; } | sort -u )
for d in $all_dims; do
  enabled=false; case "$rot" in *" $d "*) enabled=true ;; esac
  desc=""; src=""
  for base in $scan_bases; do
    if [ -f "$base/$d.md" ]; then
      desc=$(head -1 "$base/$d.md" | sed 's/^DIMENSION: *[^—-]*[—-] *//; s/^# *//')
      case "$base" in
        "$PKG_DIR/scanners") src="built-in" ;;
        "$rdir/scanners")    src="repo" ;;
        *)                   src="custom" ;;
      esac
      break
    fi
  done
  scan_rows+=("$(jq -n --arg name "$d" --argjson enabled "$enabled" --arg desc "$desc" --arg src "$src" \
    --argjson next "$([ "$d" = "$peek_next" ] && echo true || echo false)" \
    '{name:$name, enabled:$enabled, desc:$desc, source:(if $src=="" then "rotation-only" else $src end), queued_next:$next}')")
done

# campaign state
CDIR="$STATE_DIR/campaign"
c_goal=$(cat "$CDIR/goal.md" 2>/dev/null || true)
c_status=$(cat "$CDIR/status" 2>/dev/null || true)
c_assess=$(cat "$CDIR/last-assessment.md" 2>/dev/null || true)
c_open=0; c_closed=0
if [ -n "$c_goal" ]; then
  c_open=$(gh issue list -R "$GH_REPO" --state open --label "${CAMPAIGN_LABEL:-campaign}" --json number --jq length 2>/dev/null || echo 0)
  c_closed=$(gh issue list -R "$GH_REPO" --state closed --label "${CAMPAIGN_LABEL:-campaign}" --limit 200 --json number --jq length 2>/dev/null || echo 0)
fi
campaign=$(jq -n --arg goal "$c_goal" --arg status "$c_status" --arg assess "$c_assess" \
  --argjson open "${c_open:-0}" --argjson closed "${c_closed:-0}" \
  --arg history "$(tail -3 "$CDIR/history.log" 2>/dev/null || true)" \
  '{goal:(if $goal=="" then null else $goal end), status:(if $status=="" then null else $status end),
    assessment:(if $assess=="" then null else $assess end), open:$open, closed:$closed,
    history:(if $history=="" then null else $history end)}')

read -r rb_budget rb_load rb_cores rb_mem 2>/dev/null <"$STATE_DIR/resource-budget" || { rb_budget=0; rb_load=0; rb_cores=0; rb_mem=0; }
resources=$(jq -n --argjson budget "${rb_budget:-0}" --arg load "${rb_load:-0}" \
  --argjson cores "${rb_cores:-0}" --argjson mem_mb "${rb_mem:-0}" \
  '{budget:$budget, load5:$load, cores:$cores, mem_mb:$mem_mb}')

join_json "${acc_rows[@]}" | jq \
  --argjson gen "$now" --arg dispatch "$dispatch" --argjson resources "$resources" \
  --argjson workers "$(join_json "${proc_rows[@]}")" \
  --argjson lanes "$(join_json "${lane_rows[@]}")" \
  --argjson claimed "$claimed" \
  --argjson refill "$refill" --argjson throughput "$throughput" --argjson promotion "$promotion" \
  --argjson scanners "$(join_json "${scan_rows[@]}")" --argjson campaign "$campaign" \
  --argjson prs "$(jq '[.[:8][] | {number,title,url,createdAt}]' <<<"$all_prs")" \
  '{generated_at:$gen, dispatch:$dispatch, accounts:., lanes:$lanes, workers:$workers,
    resources:$resources, refill:$refill, throughput:$throughput, promotion:$promotion,
    scanners:$scanners, campaign:$campaign, claimed:$claimed, recent_prs:$prs}' \
  >web/status.json.tmp && mv web/status.json.tmp web/status.json
