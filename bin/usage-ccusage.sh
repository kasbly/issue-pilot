#!/usr/bin/env bash
# USAGE_CMD wrapper: prints "<pct_of_weekly_budget_used> <seconds_until_reset>".
# No API exposes subscription weekly limits, so this estimates: ccusage cost-equivalent
# spent since the last weekly reset vs WEEKLY_COST_BUDGET. Calibrate the budget by
# running `ccusage weekly` after a week you fully used and taking that week's totalCost.
# Linux/GNU date only. ccusage sees ALL Claude usage by this OS user on this machine.
. "$(dirname "$0")/lib.sh"

: "${WEEKLY_COST_BUDGET:?set WEEKLY_COST_BUDGET in issue-pilot.conf}"
: "${WEEKLY_RESET_DAY:=Mon}"
: "${WEEKLY_RESET_HOUR:=0}"

now=$(date +%s)
next=$(date -d "$WEEKLY_RESET_DAY ${WEEKLY_RESET_HOUR}:00" +%s)
[ "$next" -le "$now" ] && next=$((next + 604800))
last=$((next - 604800))

# ponytail: --since has day granularity — a few hours of slop at the reset boundary
spent=$(ccusage daily --json --since "$(date -d "@$last" +%Y%m%d)" 2>/dev/null | jq -r '.totals.totalCost // 0')
pct=$(awk -v s="$spent" -v b="$WEEKLY_COST_BUDGET" 'BEGIN { p = 100 * s / b; if (p > 100) p = 100; printf "%.1f", p }')
echo "$pct $((next - now))"
