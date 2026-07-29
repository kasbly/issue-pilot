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
  used="" resets=0 stale=0
  if [ "$kind" = "claude" ]; then
    DIR2NAME[$(dirname "$path")]=$name
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$path" 2>/dev/null)
    if [ -n "$tok" ]; then
      resp=$(curl -sf --max-time 20 https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" || true)
      used=$(jq -r '.seven_day.utilization // empty' <<<"$resp")
      iso=$(jq -r '.seven_day.resets_at // empty' <<<"$resp")
      [ -n "$iso" ] && resets=$(date -d "$iso" +%s)
    fi
  else
    CODEX_NAME=$name
    # newest codex session file's last rate_limits snapshot (stale between runs)
    f=$(ls -t "$path"/*/*/*/*.jsonl 2>/dev/null | head -1)
    if [ -n "$f" ]; then
      snap=$(grep -o '"rate_limits":{[^}]*}[^}]*}[^}]*}' "$f" | tail -1)
      used=$(grep -o '"used_percent":[0-9.]*' <<<"$snap" | head -1 | cut -d: -f2)
      resets=$(grep -o '"resets_at":[0-9]*' <<<"$snap" | head -1 | cut -d: -f2)
      stale=$((now - $(stat -c %Y "$f")))
    fi
  fi
  acc_rows+=("$(jq -n --arg name "$name" --arg kind "$kind" --arg used "${used:-}" \
    --argjson resets "${resets:-0}" --argjson stale "${stale:-0}" \
    '{name:$name, kind:$kind,
      used_pct:(if $used=="" then null else ($used|tonumber) end),
      resets_at:(if $resets==0 then null else $resets end),
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

# per-lane batch progress: PRs are attributed by their pilot-<lane>/ branch prefix
lane_rows=()
for id in ${LANES:-}; do
  conc=$(cat "$STATE_DIR/lane-$id.concurrency" 2>/dev/null || echo 0)
  started=$(cat "$STATE_DIR/lane-$id.batch-started" 2>/dev/null || echo 0)
  lane_rows+=("$(jq -n --arg id "$id" --arg label "$(lane_get "$id" LABEL "$id")" \
    --arg mode "$(lane_get "$id" MODE off)" --argjson conc "$conc" \
    --argjson started "$started" --argjson target "${BATCH_SIZE:-0}" \
    --argjson prs "$all_prs" '
    {id:$id, label:$label, mode:$mode, concurrency:$conc,
     batch_started:(if $started==0 then null else $started end),
     batch_target:$target,
     batch_done:([$prs[] | select((.headRefName|startswith("pilot-"+$id+"/"))
                                  and (.createdAt|fromdateiso8601) >= $started)] | length),
     total_done:([$prs[] | select(.headRefName|startswith("pilot-"+$id+"/"))] | length)}')")
done

join_json "${acc_rows[@]}" | jq \
  --argjson gen "$now" --arg dispatch "$dispatch" \
  --argjson workers "$(join_json "${proc_rows[@]}")" \
  --argjson lanes "$(join_json "${lane_rows[@]}")" \
  --argjson claimed "$claimed" \
  --argjson prs "$(jq '[.[:8][] | {number,title,url,createdAt}]' <<<"$all_prs")" \
  '{generated_at:$gen, dispatch:$dispatch, accounts:., lanes:$lanes, workers:$workers,
    claimed:$claimed, recent_prs:$prs}' \
  >web/status.json.tmp && mv web/status.json.tmp web/status.json
