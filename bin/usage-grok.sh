#!/usr/bin/env bash
# usage-grok: read the weekly-limit percentage and reset time that Grok Build's
# /usage panel shows. Grok Build (v1.0.5) has no usage subcommand and no REST
# endpoint for this — the numbers travel over the CLI's internal ACP gateway —
# so drive a throwaway TUI in a private tmux session and scrape the panel.
# Prints "<used_pct> <seconds_until_reset>" (the usage-claude.sh shape).
# Cached for GROK_USAGE_TTL (default 600s): a TUI boot is heavier than a curl.
set -euo pipefail
BIN="${GROK_BIN:-grok}"
CACHE="${TMPDIR:-/tmp}/usage-grok-$(id -u).cache"
ttl="${GROK_USAGE_TTL:-600}"
if [ -f "$CACHE" ] && [ $(( $(date +%s) - $(stat -c %Y "$CACHE") )) -lt "$ttl" ]; then
  cat "$CACHE"; exit 0
fi
S="ip-usage-grok-$$"
unset TMUX
tmux kill-session -t "$S" 2>/dev/null || true
tmux new-session -d -s "$S" -x 160 -y 45 "cd ${TMPDIR:-/tmp} && $BIN"
trap 'tmux kill-session -t "$S" 2>/dev/null || true' EXIT
ok=""
for _ in $(seq 1 30); do
  tmux capture-pane -t "$S" -p 2>/dev/null | grep -q "❯" && { ok=1; break; }; sleep 1
done
[ -n "$ok" ] || { echo "usage-grok: TUI did not start" >&2; exit 1; }
tmux send-keys -t "$S" "/usage"; sleep 1; tmux send-keys -t "$S" Enter
panel=""
for _ in $(seq 1 20); do
  panel=$(tmux capture-pane -t "$S" -p 2>/dev/null | sed -n '/Weekly limit/,/Resets:/p')
  [ -n "$panel" ] && break; sleep 1
done
pct=$(grep -o -E "[0-9]+%" <<<"$panel" | head -1 | tr -d '%' || true)
reset=$(grep -o -E "Resets: [^|]*" <<<"$panel" | head -1 | sed 's/Resets: //; s/[[:space:]]*$//; s/,//' || true)
[ -n "${pct:-}" ] && [ -n "${reset:-}" ] || { echo "usage-grok: usage panel not found" >&2; exit 1; }
# "September 2 13:17" has no year: take this year, else it means next year
now=$(date +%s)
at=$(date -d "$reset" +%s 2>/dev/null || echo 0)
[ "$at" -le "$now" ] && at=$(date -d "$reset next year" +%s 2>/dev/null || echo 0)
[ "$at" -gt "$now" ] || { echo "usage-grok: unparseable reset time '$reset'" >&2; exit 1; }
echo "$pct $(( at - now ))" | tee "$CACHE"
