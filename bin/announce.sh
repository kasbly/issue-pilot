#!/usr/bin/env bash
# announce: after a verified promotion, turn the commits that just reached
# PROD_BRANCH into a short release note for NON-technical users (ANNOUNCE_CMD —
# any model command that prints the note; the prompt is yours, see
# examples/announce.md) and post it (ANNOUNCE_POST_CMD, note in $MSG). The range
# is "since the last announcement" (state/announce-last-sha), so a deferred or
# failed run never loses a release — it catches up on the next one.
#   issue-pilot announce            post the pending range (no-op when empty)
#   issue-pilot announce --dry-run  write the note to state/announce-preview.txt, post nothing
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME"

dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
# conf vars are plain assignments; the model/post commands run in child shells
for v in "${!ANNOUNCE_@}"; do export "$v"; done
prod="${PROD_BRANCH:-main}"
exec 9>"$STATE_DIR/announce.lock"
flock -n 9 || { log "announce already running — skipping"; exit 0; }
refresh() { bash "$PKG_DIR/bin/status.sh" >/dev/null 2>&1 || true; }

head=$(gh api "repos/$GH_REPO/commits/$prod" --jq .sha)
from=$(cat "$STATE_DIR/announce-last-sha" 2>/dev/null || echo "${ANNOUNCE_FROM:-}")
if [ -z "$from" ]; then
  echo "$head" >"$STATE_DIR/announce-last-sha"
  log "announce: no starting point — seeded at $prod $head; the next release will be announced"; exit 0
fi
[ "$from" = "$head" ] && { log "announce: nothing new on $prod since the last announcement"; exit 0; }

# non-merge commit subjects that can carry a user-visible change; the model does
# the real filtering (tests, CI, refactors never reach users)
commits=$(gh api --paginate "repos/$GH_REPO/compare/$from...$head" \
  --jq '.commits[] | select(.parents | length == 1) | .commit.message | split("\n")[0]' \
  | grep -E "${ANNOUNCE_COMMIT_FILTER:-^(feat|fix|perf)(\(|:|!)}" | head -400 || true)
n=$(printf '%s' "$commits" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  [ "$dry" -eq 1 ] || echo "$head" >"$STATE_DIR/announce-last-sha"
  log "announce: no matching commits in ${from:0:9}..${head:0:9} — nothing to announce"; exit 0
fi
changelog=""
if [ -n "${ANNOUNCE_CHANGELOG_FILE:-}" ]; then
  cl() { gh api -H "Accept: application/vnd.github.raw" "repos/$GH_REPO/contents/$ANNOUNCE_CHANGELOG_FILE?ref=$1" 2>/dev/null || true; }
  changelog=$(diff <(cl "$from") <(cl "$head") | sed -n 's/^> //p' | head -c 12000 || true)
fi
# release version = newest ANNOUNCE_TAG_PREFIX* tag reachable from the prod head (tags
# are usually cut on the staging merge, so they sit behind head, not on it)
ver=""
for t in $(gh api --paginate "repos/$GH_REPO/git/matching-refs/tags/${ANNOUNCE_TAG_PREFIX:-v}" \
             --jq '.[].ref | ltrimstr("refs/tags/")' 2>/dev/null | sort -rV | head -20); do
  case "$(gh api "repos/$GH_REPO/compare/$t...$head" --jq .status 2>/dev/null)" in
    identical|ahead) ver="${t#"${ANNOUNCE_TAG_PREFIX:-v}"}"; break ;;
  esac
done
export ANNOUNCE_RANGE="${from:0:9}..${head:0:9}" ANNOUNCE_COUNT="$n" ANNOUNCE_VERSION="$ver" \
  ANNOUNCE_COMMITS="$commits" ANNOUNCE_CHANGELOG="${changelog:-<none>}"

# model: a paced Claude account, else the Codex fallback, else defer — promote.sh
# retries a pending announcement on its hourly tick
run="${ANNOUNCE_CMD:?ANNOUNCE_CMD is not set}"
if ! pick_claude_account; then
  if [ -n "${ANNOUNCE_FALLBACK_CMD:-}" ] \
     && read -r fb_name fb_home < <(bash "$PKG_DIR/bin/pick-codex-account.sh" 2>/dev/null) && [ -n "${fb_home:-}" ]; then
    export CODEX_HOME="$fb_home"; run="$ANNOUNCE_FALLBACK_CMD"
    log "announce: using Codex account '$fb_name'"
  else
    touch "$STATE_DIR/announce-pending"; log "announce: deferred — no account available"; refresh; exit 0
  fi
fi
# the command prints the note on stdout, or writes it to $ANNOUNCE_OUT (for tools
# whose stdout is noisy)
export ANNOUNCE_OUT="$STATE_DIR/announce-out.txt"; : >"$ANNOUNCE_OUT"
log "announce: summarizing $n commits ($ANNOUNCE_RANGE)$([ "$dry" -eq 1 ] && echo ', dry run')"
out=$(bash -c "$run" </dev/null 2>>"$STATE_DIR/announce.log" || true)  # no stdin: codex exec would wait on it
[ -s "$ANNOUNCE_OUT" ] && out=$(cat "$ANNOUNCE_OUT")
msg=$(printf '%s\n' "$out" | sed 's/[[:space:]]*$//' \
  | awk 'NF{p=1} p{l[++c]=$0} END{while(c && l[c]=="") c--; for(i=1;i<=c;i++) print l[i]}')
if [ -z "$msg" ]; then
  touch "$STATE_DIR/announce-pending"; log "announce: model returned nothing (see state/announce.log)"; refresh; exit 1
fi
printf '%s\n' "$msg" >"$STATE_DIR/announce-preview.txt"

if [ "$dry" -eq 1 ]; then log "announce: dry run — note written to state/announce-preview.txt"; refresh; exit 0; fi
if [ "$msg" = "SKIP" ]; then
  echo "$head" >"$STATE_DIR/announce-last-sha"; rm -f "$STATE_DIR/announce-pending"
  echo "$(date +%s) skipped $n" >"$STATE_DIR/announce-last"
  log "announce: nothing user-visible in this release — skipped"; refresh; exit 0
fi
if MSG="$msg" bash -c "${ANNOUNCE_POST_CMD:?ANNOUNCE_POST_CMD is not set}" >>"$STATE_DIR/announce.log" 2>&1; then
  echo "$head" >"$STATE_DIR/announce-last-sha"; rm -f "$STATE_DIR/announce-pending"
  echo "$(date +%s) posted $n" >"$STATE_DIR/announce-last"
  log "announce: posted ($n commits${ver:+, version $ver})"; refresh
else
  touch "$STATE_DIR/announce-pending"; log "announce: post FAILED (see state/announce.log) — will retry"; refresh; exit 1
fi
