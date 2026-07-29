#!/usr/bin/env bash
# Self-check for the pacer math — the only branchy logic in the repo.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ISSUE_PILOT_HOME="$tmp"
export ISSUE_PILOT_CONF="$tmp/issue-pilot.conf"

make_conf() { # $1 = USAGE_CMD output ("pct secs_left"), $2 = starting worker count
  cat >"$ISSUE_PILOT_CONF" <<EOF
GH_REPO=x/y; READY_LABEL=r; CLAIM_LABEL=c
REFILL_THRESHOLD=10; SCANNER_CMD=true
MIN_WORKERS=1; MAX_WORKERS=4; POLL_SECS=1; WORKER_CMD=true
USAGE_CMD="echo $1"; PACE_TOLERANCE=10; NOTIFY_CMD="cat >> $tmp/notified"
EOF
  mkdir -p "$tmp/state" && echo "$2" >"$tmp/state/workers"
}

check() { # $1 = name, $2 = expected worker count
  bash bin/pace.sh >/dev/null
  got=$(cat "$tmp/state/workers")
  [ "$got" = "$2" ] || { echo "FAIL $1: workers=$got expected=$2"; exit 1; }
  echo "ok   $1"
}

# halfway through the week (302400s left → ideal 50%)
make_conf "20 302400" 2; check "behind pace scales up" 3
make_conf "80 302400" 2; check "ahead of pace scales down" 1
make_conf "50 302400" 2; check "on pace holds steady" 2
make_conf "10 302400" 4; check "clamped at MAX_WORKERS" 4
make_conf "95 302400" 1; check "clamped at MIN_WORKERS" 1
make_conf "5 302400" 2; check "big drift still steps by one" 3
[ -f "$tmp/notified" ] || { echo "FAIL: >2x-tolerance drift did not notify"; exit 1; }
echo "ok   big drift notifies"

# no USAGE_CMD → pinned to MIN_WORKERS
make_conf "0 0" 3
sed -i.bak 's/^USAGE_CMD=.*/USAGE_CMD=""/' "$ISSUE_PILOT_CONF"
check "no USAGE_CMD pins to MIN_WORKERS" 1

echo "all checks passed"
