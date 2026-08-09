#!/usr/bin/env bash
# Pick the Codex account with the most headroom for scanner-fallback sessions.
# Prints "<name> <codex_home>". Config: CODEX_ACCOUNTS="name:/path/to/codex-home ..."
# Codex lanes run always-on, so there is no pace-line requirement here — the only
# gate is not starving the implementation lanes: used < SCANNER_FALLBACK_MAX_USED
# (default 90). Prefers the least-used account.
. "$(dirname "$0")/lib.sh"

max_used="${SCANNER_FALLBACK_MAX_USED:-90}"
best_name="" best_home="" best_pct=""
for entry in ${CODEX_ACCOUNTS:-}; do
  name=${entry%%:*}; home=${entry#*:}
  pct=""
  read -r pct _ < <(CODEX_HOME="$home" bash "$PKG_DIR/bin/usage-codex.sh" 2>/dev/null) || true
  if [ -z "${pct:-}" ]; then
    echo "codex account $name: usage UNAVAILABLE — excluded" >&2
    continue
  fi
  if ! awk -v p="$pct" -v m="$max_used" 'BEGIN { exit !(p < m) }'; then
    echo "codex account $name: used=${pct}% — INELIGIBLE (>= ${max_used}%)" >&2
    continue
  fi
  echo "codex account $name: used=${pct}%" >&2
  if [ -z "$best_home" ] || awk -v p="$pct" -v b="$best_pct" 'BEGIN { exit !(p < b) }'; then
    best_name=$name; best_home=$home; best_pct=$pct
  fi
done

[ -n "$best_home" ] || { echo "no codex account with headroom" >&2; exit 1; }
echo "$best_name $best_home"
