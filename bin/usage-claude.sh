#!/usr/bin/env bash
# USAGE_CMD wrapper: prints "<pct_of_weekly_quota_used> <seconds_until_reset>" from
# Claude Code's own OAuth usage endpoint — the exact numbers the /usage screen shows,
# no calibration needed. Reads the access token of whatever account's credentials
# file is given (default: this user's). The token is refreshed whenever Claude Code
# runs, which batch sessions do constantly; on a stale token this exits non-zero and
# the pacer simply skips a tick.
. "$(dirname "$0")/lib.sh"

CREDS="${CLAUDE_CREDENTIALS:-$HOME/.claude/.credentials.json}"
tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
[ -n "$tok" ] || { echo "usage-claude: no access token in $CREDS" >&2; exit 1; }

resp=$(curl -sf --max-time 30 https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20")
pct=$(jq -r '.seven_day.utilization // empty' <<<"$resp")
resets=$(jq -r '.seven_day.resets_at // empty' <<<"$resp")
[ -n "$pct" ] && [ -n "$resets" ] || { echo "usage-claude: unexpected response shape" >&2; exit 1; }

secs=$(( $(date -d "$resets" +%s) - $(date +%s) ))
[ "$secs" -gt 0 ] || secs=0

# optional trailing pair: the 5-hour session window (pace.sh throttles on it)
h5pct=$(jq -r '.five_hour.utilization // empty' <<<"$resp")
h5resets=$(jq -r '.five_hour.resets_at // empty' <<<"$resp")
if [ -n "$h5pct" ] && [ -n "$h5resets" ]; then
  h5secs=$(( $(date -d "$h5resets" +%s) - $(date +%s) ))
  [ "$h5secs" -gt 0 ] || h5secs=0
  echo "$pct $secs $h5pct $h5secs"
else
  echo "$pct $secs"
fi
