#!/usr/bin/env bash
# Self-check for the lane pacer — the only branchy logic in the repo.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ISSUE_PILOT_HOME="$tmp"
export ISSUE_PILOT_CONF="$tmp/issue-pilot.conf"

make_conf() { # $1 = lane MODE, $2 = extra conf lines, $3 = seed concurrency (optional)
  cat >"$ISSUE_PILOT_CONF" <<EOF
GH_REPO=x/y; READY_LABEL=r; CLAIM_LABEL=c
REFILL_THRESHOLD=10; SCANNER_CMD=true; POLL_SECS=1; BATCH_SIZE=25
LANES="t"
LANE_t_LABEL="T"; LANE_t_MODE="$1"; LANE_t_CMD=true
WINDOW_DAYS=3; WINDOW_MAX_PCT=50; MIN_CONCURRENCY=1; MAX_CONCURRENCY=6
BURN_PCT_PER_WORKER_HOUR=2
DEFAULT_CONCURRENCY=3; CORES_PER_WORKER=2; MEM_MB_PER_WORKER=3000; RESOURCE_MIN_BUDGET=1
RESOURCE_PROBE_CMD='echo "32 0 64000"'
NOTIFY_CMD="cat >> $tmp/notified"
$2
EOF
  mkdir -p "$tmp/state"
  [ -n "${3:-}" ] && echo "$3" >"$tmp/state/lane-t.concurrency" || rm -f "$tmp/state/lane-t.concurrency"
}

check() { # $1 = name, $2 = expected concurrency
  bash bin/pace.sh >/dev/null
  got=$(cat "$tmp/state/lane-t.concurrency")
  [ "$got" = "$2" ] || { echo "FAIL $1: concurrency=$got expected=$2"; exit 1; }
  echo "ok   $1"
}

make_conf always 'LANE_t_CONCURRENCY=4'
check "always mode uses fixed concurrency" 4

make_conf off ''
check "off mode writes 0" 0

make_conf window 'LANE_t_USAGE_CMD="echo 40 432000"'          # resets in 5d — outside window
check "outside window stays 0" 0

make_conf window 'LANE_t_USAGE_CMD="echo 60 129600"'          # 60% used — over threshold
check "over usage threshold stays 0" 0

make_conf window 'LANE_t_USAGE_CMD="echo 40 129600"'          # 36h left: 60%/(36h*2) → 1
check "eligible: light leftover gets 1 worker" 1

make_conf window 'LANE_t_USAGE_CMD="echo 10 86400"'           # 24h left: 90%/(24h*2) → 2
check "eligible: heavy leftover scales up" 2

make_conf window 'LANE_t_USAGE_CMD="echo 0 21600" BURN_PCT_PER_WORKER_HOUR=1'  # 6h left: 100/6 → clamp
check "clamped at MAX_CONCURRENCY" 6

make_conf window 'LANE_t_USAGE_CMD="echo 45 255600" LANE_t_MIN_CONCURRENCY=2'  # 71h left, tiny need
check "clamped at per-lane MIN_CONCURRENCY" 2

make_conf window 'LANE_t_USAGE_CMD="false"' 5
check "usage unavailable keeps previous" 5

make_conf window 'LANE_t_USAGE_CMD="echo 10 86400 95 1200" FIVE_HOUR_THROTTLE_PCT=85'
check "hot 5h window throttles to cap" 1

make_conf window 'LANE_t_USAGE_CMD="echo 10 86400 50 1200" FIVE_HOUR_THROTTLE_PCT=85'
check "cool 5h window leaves target alone" 2

make_conf always ''
check "always mode defaults to DEFAULT_CONCURRENCY" 3

make_conf always 'LANE_t_CONCURRENCY=4 RESOURCE_PROBE_CMD="echo 8 6 64000"'   # (8-6)/2 → 1 slot
check "cpu load caps concurrency" 1

make_conf always 'LANE_t_CONCURRENCY=4 RESOURCE_PROBE_CMD="echo 32 0 4000"'   # 4000/3000 → 1 slot
check "low memory caps concurrency" 1

make_conf always 'LANE_t_CONCURRENCY=4 RESOURCE_PROBE_CMD="echo 8 20 64000" RESOURCE_MIN_BUDGET=3'  # overloaded box
check "RESOURCE_MIN_BUDGET floors the budget" 3

# shared budget: (16-8)/2 = 4 slots for two lanes wanting 3 each → 3 then 1
cat >"$ISSUE_PILOT_CONF" <<EOF
GH_REPO=x/y; READY_LABEL=r; CLAIM_LABEL=c
REFILL_THRESHOLD=10; SCANNER_CMD=true; POLL_SECS=1; BATCH_SIZE=25
LANES="a b"
LANE_a_LABEL=A; LANE_a_MODE=always; LANE_a_CONCURRENCY=3; LANE_a_CMD=true
LANE_b_LABEL=B; LANE_b_MODE=always; LANE_b_CONCURRENCY=3; LANE_b_CMD=true
CORES_PER_WORKER=2; MEM_MB_PER_WORKER=3000
RESOURCE_PROBE_CMD='echo "16 8 64000"'
EOF
bash bin/pace.sh >/dev/null
got_a=$(cat "$tmp/state/lane-a.concurrency"); got_b=$(cat "$tmp/state/lane-b.concurrency")
[ "$got_a" = 3 ] && [ "$got_b" = 1 ] || { echo "FAIL shared budget: a=$got_a b=$got_b expected 3/1"; exit 1; }
echo "ok   shared budget allocated in lane order"

# tight budget (3 slots, two lanes wanting 3): nobody starves — 2 / 1, not 3 / 0
sed -i.bak "s/echo \"16 8 64000\"/echo \"16 10 64000\"/" "$ISSUE_PILOT_CONF"
bash bin/pace.sh >/dev/null
got_a=$(cat "$tmp/state/lane-a.concurrency"); got_b=$(cat "$tmp/state/lane-b.concurrency")
[ "$got_a" = 2 ] && [ "$got_b" = 1 ] || { echo "FAIL no-starve: a=$got_a b=$got_b expected 2/1"; exit 1; }
echo "ok   tight budget never starves an active lane"

[ -f "$tmp/notified" ] || { echo "FAIL: concurrency changes did not notify"; exit 1; }
echo "ok   changes notify"

echo "all checks passed"
