#!/usr/bin/env bash
# Pick the Claude account with the most quota headroom — the one furthest BEHIND its
# straight-line pace to reset. Prints "<name> <config_dir>". Scanner, campaign, and
# promotion use this so heavyweight orchestration sessions always bill to the account
# that can best afford them right now.
# Config: CLAUDE_ACCOUNTS="name:/path/to/config-dir name2:/path/to/other-dir"
. "$(dirname "$0")/lib.sh"

best_name="" best_dir="" best_drift=""
for entry in ${CLAUDE_ACCOUNTS:-}; do
  name=${entry%%:*}; dir=${entry#*:}
  read -r pct secs _ < <(CLAUDE_CREDENTIALS="$dir/.credentials.json" bash "$PKG_DIR/bin/usage-claude.sh" 2>/dev/null) || continue
  [ -n "${secs:-}" ] || continue
  # drift > 0 = ahead of pace (already burned more than the line); prefer the lowest
  drift=$(awk -v p="$pct" -v s="$secs" 'BEGIN { printf "%.1f", p - 100 * (1 - s / 604800) }')
  echo "account $name: used=${pct}% drift=${drift}%" >&2
  if [ -z "$best_dir" ] || awk -v d="$drift" -v b="$best_drift" 'BEGIN { exit !(d < b) }'; then
    best_name=$name; best_dir=$dir; best_drift=$drift
  fi
done

[ -n "$best_dir" ] || exit 1
echo "$best_name $best_dir"
