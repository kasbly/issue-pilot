# shared bootstrap, sourced by every script
set -euo pipefail

ISSUE_PILOT_HOME="${ISSUE_PILOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ISSUE_PILOT_CONF="${ISSUE_PILOT_CONF:-$ISSUE_PILOT_HOME/issue-pilot.conf}"

[ -f "$ISSUE_PILOT_CONF" ] || { echo "issue-pilot: config not found: $ISSUE_PILOT_CONF (copy issue-pilot.conf.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ISSUE_PILOT_CONF"

STATE_DIR="$ISSUE_PILOT_HOME/state"
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%F %T')] $*"; }

# open issues that are ready and unclaimed, oldest first, one number per line
ready_issues() {
  gh issue list -R "$GH_REPO" --state open --label "$READY_LABEL" \
    --search "sort:created-asc -label:$CLAIM_LABEL" \
    --limit 100 --json number --jq '.[].number'
}
