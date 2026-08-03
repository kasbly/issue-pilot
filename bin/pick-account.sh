#!/usr/bin/env bash
# Pick the Claude account with the most quota headroom — the one furthest BEHIND its
# straight-line pace to reset. Prints "<name> <config_dir>". Scanner, campaign, and
# promotion use this so heavyweight orchestration sessions always bill to the account
# that can best afford them right now.
# Config: CLAUDE_ACCOUNTS="name:/path/to/config-dir name2:/path/to/other-dir"
. "$(dirname "$0")/lib.sh"

# Eligibility: an account must be BEHIND its pace line (drift < ORCH_MAX_DRIFT,
# default 0) and not nearly exhausted (used < ORCH_MAX_USED, default 95). An account
# at or past its line is never used — using it would exhaust the quota before the
# reset instead of exactly at it.
max_drift="${ORCH_MAX_DRIFT:-0}"
max_used="${ORCH_MAX_USED:-95}"

best_name="" best_dir="" best_drift=""
for entry in ${CLAUDE_ACCOUNTS:-}; do
  name=${entry%%:*}; dir=${entry#*:}
  pct=""; secs=""
  read -r pct secs _ < <(CLAUDE_CREDENTIALS="$dir/.credentials.json" bash "$PKG_DIR/bin/usage-claude.sh" 2>/dev/null) || true
  if [ -z "${secs:-}" ]; then
    # stale access token (idle accounts stop refreshing): a minimal session on that
    # account refreshes it through the official path, then retry the read once
    echo "account $name: usage read failed — pinging to refresh token" >&2
    CLAUDE_CONFIG_DIR="$dir" timeout 90 claude -p "Reply with exactly: OK" --effort low >/dev/null 2>&1 || true
    read -r pct secs _ < <(CLAUDE_CREDENTIALS="$dir/.credentials.json" bash "$PKG_DIR/bin/usage-claude.sh" 2>/dev/null) || true
  fi
  if [ -z "${secs:-}" ]; then
    echo "account $name: usage UNAVAILABLE even after refresh — excluded (check credentials)" >&2
    continue
  fi
  # drift > 0 = ahead of pace (already burned more than the line); prefer the lowest
  drift=$(awk -v p="$pct" -v s="$secs" 'BEGIN { printf "%.1f", p - 100 * (1 - s / 604800) }')
  if ! awk -v d="$drift" -v md="$max_drift" -v p="$pct" -v mu="$max_used" \
       'BEGIN { exit !(d < md && p < mu) }'; then
    echo "account $name: used=${pct}% drift=${drift}% — INELIGIBLE (at/ahead of pace or nearly spent)" >&2
    continue
  fi
  echo "account $name: used=${pct}% drift=${drift}%" >&2
  if [ -z "$best_dir" ] || awk -v d="$drift" -v b="$best_drift" 'BEGIN { exit !(d < b) }'; then
    best_name=$name; best_dir=$dir; best_drift=$drift
  fi
done

[ -n "$best_dir" ] || { echo "no eligible account — all at/ahead of pace" >&2; exit 1; }
echo "$best_name $best_dir"
