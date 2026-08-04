#!/usr/bin/env bash
# USAGE_CMD wrapper for Codex accounts: prints "<pct_of_weekly_quota_used>
# <secs_until_reset>". Codex exposes no usage API, so this reads the rate_limits
# snapshot Codex writes into its newest session file. If the snapshot is older than
# CODEX_SNAPSHOT_MAX_AGE (default 3h — e.g. the lane has been idle since a reset),
# a one-line codex ping refreshes it for pennies.
. "$(dirname "$0")/lib.sh"

SESS="${CODEX_SESSIONS:-$HOME/.codex/sessions}"
newest() { ls -t "$SESS"/*/*/*/*.jsonl 2>/dev/null | head -1 || true; }

f=$(newest)
age=999999
[ -n "$f" ] && age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
if [ "$age" -gt "${CODEX_SNAPSHOT_MAX_AGE:-10800}" ]; then
  echo "usage-codex: snapshot ${age}s old — pinging codex to refresh" >&2
  (cd /tmp && timeout 120 codex exec "Reply with exactly: OK" >/dev/null 2>&1) || true
  f=$(newest)
fi

snap=""
[ -n "$f" ] && snap=$(grep -o '"rate_limits":{[^}]*}[^}]*}[^}]*}' "$f" 2>/dev/null | tail -1 || true)
pct=$(grep -o '"used_percent":[0-9.]*' <<<"$snap" | head -1 | cut -d: -f2)
resets=$(grep -o '"resets_at":[0-9]*' <<<"$snap" | head -1 | cut -d: -f2)
[ -n "$pct" ] && [ -n "$resets" ] || { echo "usage-codex: no rate_limits snapshot found" >&2; exit 1; }

secs=$(( resets - $(date +%s) )); [ "$secs" -gt 0 ] || secs=0
echo "$pct $secs"
