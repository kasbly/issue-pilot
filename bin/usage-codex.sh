#!/usr/bin/env bash
# USAGE_CMD wrapper for Codex accounts: prints "<pct_of_weekly_quota_used>
# <secs_until_reset>". Codex exposes no usage API, so this reads the rate_limits
# snapshot Codex writes into its newest session file. If the snapshot is older than
# CODEX_SNAPSHOT_MAX_AGE (default 3h — e.g. the lane has been idle since a reset),
# a one-line codex ping refreshes it for pennies.
. "$(dirname "$0")/lib.sh"

# Multi-account: set CODEX_HOME to the account's config dir (default ~/.codex).
# Sessions, auth, and the refresh ping all follow it.
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SESS="${CODEX_SESSIONS:-$CODEX_HOME/sessions}"
# newest session file WITH a snapshot: a busy lane creates fresh session files
# faster than rate_limits land in them, so the newest file alone is unreliable
newest_snap() {
  local f
  snap=""; snap_file=""
  for f in $(ls -t "$SESS"/*/*/*/*.jsonl 2>/dev/null | head -20 || true); do
    snap=$(grep -o '"rate_limits":{[^}]*}[^}]*}[^}]*}' "$f" 2>/dev/null | tail -1 || true)
    [ -n "$snap" ] && { snap_file=$f; return 0; }
  done
  return 0
}

newest_snap
age=999999
[ -n "$snap_file" ] && age=$(( $(date +%s) - $(stat -c %Y "$snap_file" 2>/dev/null || echo 0) ))
if [ "$age" -gt "${CODEX_SNAPSHOT_MAX_AGE:-10800}" ]; then
  echo "usage-codex: snapshot ${age}s old — pinging codex to refresh" >&2
  (cd /tmp && timeout 120 codex exec "Reply with exactly: OK" >/dev/null 2>&1) || true
  newest_snap
fi
pct=$(grep -o '"used_percent":[0-9.]*' <<<"$snap" | head -1 | cut -d: -f2)
resets=$(grep -o '"resets_at":[0-9]*' <<<"$snap" | head -1 | cut -d: -f2)
[ -n "$pct" ] && [ -n "$resets" ] || { echo "usage-codex: no rate_limits snapshot found" >&2; exit 1; }

secs=$(( resets - $(date +%s) )); [ "$secs" -gt 0 ] || secs=0
echo "$pct $secs"
