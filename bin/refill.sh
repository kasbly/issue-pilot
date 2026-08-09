#!/usr/bin/env bash
# refill: when the ready-issue queue runs low, run the scanner to generate more.
. "$(dirname "$0")/lib.sh"

paused && { log "system paused — refill skipped"; exit 0; }

# hourly housekeeping: release claims whose worker died, so issues re-queue
bash "$PKG_DIR/bin/claim-janitor.sh" || true

count=$(ready_issues | wc -l | tr -d ' ')
log "ready issues: $count (threshold: $REFILL_THRESHOLD)"

# panel "Run now": state/refill-force bypasses the queue threshold and the Claude
# pace gate for one run — a human clicked, so the quota hit is deliberate
force=""
[ -f "$STATE_DIR/refill-force" ] && force=1

if [ -z "$force" ] && [ "$count" -ge "$REFILL_THRESHOLD" ]; then
  log "queue healthy, nothing to do"
  echo "$(date +%s) skipped queue=$count" >"$STATE_DIR/refill-last"
  exit 0
fi

# ponytail: flock so an overlapping timer fire never runs two scanners at once
# (a force click during a running scan keeps its flag and applies to the next run)
exec 9>"$STATE_DIR/refill.lock"
flock -n 9 || { log "refill already running, skipping"; exit 0; }
if [ -n "$force" ]; then
  rm -f "$STATE_DIR/refill-force"
  # still route to the least-ahead account, just without the behind-pace requirement
  export ORCH_MAX_DRIFT="${FORCE_MAX_DRIFT:-9999}" ORCH_MAX_USED="${FORCE_MAX_USED:-98}"
  log "manual force-run — bypassing queue threshold and Claude pace gate"
fi

log "queue low — running scanner"
cd "$ISSUE_PILOT_HOME"

# strict round-robin over scanning dimensions: each refill runs the NEXT one in
# SCANNER_ROTATION (= the enabled set, in order). state/next-scanner, written by
# the web panel's "Run next", overrides the rotation once.
if [ -n "${SCANNER_ROTATION:-}" ]; then
  # per-scanner cadence: SCANNER_INTERVAL_<dim> ("3d", "12h", or seconds) is the
  # minimum time between runs of that dimension; rotation skips resting scanners
  interval_secs() {
    case "$1" in
      "") echo 0 ;;
      *d) echo $(( ${1%d} * 86400 )) ;;
      *h) echo $(( ${1%h} * 3600 )) ;;
      *)  echo "$1" ;;
    esac
  }
  scanner_eligible() {
    local key v iv last_ts
    key=$(tr '-' '_' <<<"$1"); v="SCANNER_INTERVAL_$key"
    iv=$(interval_secs "${!v:-}")
    [ "$iv" -eq 0 ] && return 0
    last_ts=$(awk -v d="$1" '$1 == d { print $2 }' "$STATE_DIR/scanner-runs" 2>/dev/null)
    [ -z "$last_ts" ] && return 0
    [ $(( $(date +%s) - last_ts )) -ge "$iv" ]
  }

  if [ -s "$STATE_DIR/next-scanner" ]; then
    next=$(cat "$STATE_DIR/next-scanner")
    rm -f "$STATE_DIR/next-scanner"
    was_override=1
    log "scanner rotation: dimension=$next (one-shot override, interval bypassed)"
  else
    last=$(cat "$STATE_DIR/last-scanner" 2>/dev/null || true)
    ring=""
    if [ -n "$last" ]; then
      seen=0
      for d in $SCANNER_ROTATION; do [ "$seen" = 1 ] && ring="$ring $d"; [ "$d" = "$last" ] && seen=1; done
      for d in $SCANNER_ROTATION; do [ "$d" = "$last" ] && break; ring="$ring $d"; done
      [ "$seen" = 1 ] && ring="$ring $last" || ring="$SCANNER_ROTATION"
    else
      ring="$SCANNER_ROTATION"
    fi
    next=""
    for d in $ring; do scanner_eligible "$d" && { next=$d; break; }; done
    if [ -z "$next" ]; then
      log "scanner: every rotation dimension is resting (per-scanner intervals) — skipping this refill"
      exit 0
    fi
    log "scanner rotation: dimension=$next"
  fi
  export SCANNER_DIMENSION=$next
  # methodology file: working dir overrides the scanned repo's scanners/, which
  # overrides the built-in library
  resolve_prompt_file() {
    for base in "$ISSUE_PILOT_HOME/scanners" "${REPO_DIR:-$ISSUE_PILOT_HOME/repo}/scanners" "$PKG_DIR/scanners"; do
      if [ -f "$base/$1.md" ]; then export SCANNER_PROMPT_FILE="$base/$1.md"; return; fi
    done
  }
  resolve_prompt_file "$next"
  # per-dimension model/effort (hyphens become underscores in the var name):
  # SCANNER_MODEL_security="fable" beats SCANNER_MODEL_DEFAULT
  dim_key=$(tr '-' '_' <<<"$next")
  v="SCANNER_MODEL_$dim_key";  export SCANNER_RUN_MODEL="${!v:-${SCANNER_MODEL_DEFAULT:-sonnet}}"
  v="SCANNER_EFFORT_$dim_key"; export SCANNER_RUN_EFFORT="${!v:-${SCANNER_EFFORT_DEFAULT:-high}}"
  log "scanner model for $next: $SCANNER_RUN_MODEL ($SCANNER_RUN_EFFORT)"
fi

export GH_REPO READY_LABEL BASE_BRANCH="${BASE_BRANCH:-main}" REPO_DIR="${REPO_DIR:-$ISSUE_PILOT_HOME/repo}"
export ERROR_LOG_CMD="${ERROR_LOG_CMD:-}" CAMPAIGN_LOGIN_EMAIL="${CAMPAIGN_LOGIN_EMAIL:-}" CAMPAIGN_LOGIN_PASSWORD="${CAMPAIGN_LOGIN_PASSWORD:-}"
RUN_CMD="$SCANNER_CMD"
if ! pick_claude_account; then
  # Codex fallback: while every Claude account rests at its pace line, dims listed
  # in SCANNER_FALLBACK_DIMS may scan on a Codex account instead. Keep this list to
  # evidence-gated scanners (ci-health, deps, prod-errors, ui-quality) — a wrong
  # issue from a judgment-heavy scanner costs a lane hours downstream.
  # If the dim whose turn it is isn't fallback-listed, walk the rest of the ring —
  # a Claude-rest hour shouldn't idle while an evidence-gated dim is due. The
  # deferred dim keeps its turn: the pointer advances to whichever dim runs.
  fbdim=""
  if [ -n "${SCANNER_FALLBACK_CMD:-}" ] && [ -n "${SCANNER_DIMENSION:-}" ]; then
    for d in $SCANNER_DIMENSION ${ring:-}; do
      case " ${SCANNER_FALLBACK_DIMS:-} " in *" $d "*) ;; *) continue ;; esac
      scanner_eligible "$d" || continue
      fbdim=$d; break
    done
  fi
  if [ -n "$fbdim" ] && read -r fb_name fb_home < <(bash "$PKG_DIR/bin/pick-codex-account.sh" 2>/dev/null) && [ -n "${fb_home:-}" ]; then
    if [ "$fbdim" != "$SCANNER_DIMENSION" ]; then
      export SCANNER_DIMENSION=$fbdim
      resolve_prompt_file "$fbdim"
    fi
    export CODEX_HOME="$fb_home"
    export SCANNER_RUN_MODEL="${SCANNER_FALLBACK_MODEL:-$SCANNER_RUN_MODEL}"
    export SCANNER_RUN_EFFORT="${SCANNER_FALLBACK_EFFORT:-$SCANNER_RUN_EFFORT}"
    RUN_CMD="$SCANNER_FALLBACK_CMD"
    log "scanner fallback: running $SCANNER_DIMENSION on Codex account '$fb_name' ($SCANNER_RUN_MODEL/$SCANNER_RUN_EFFORT)"
  else
    # a deferred run must not eat a "Run next" click — restore the override
    [ -n "${was_override:-}" ] && echo "$SCANNER_DIMENSION" >"$STATE_DIR/next-scanner"
    log "scanner deferred — next hourly check retries"
    echo "$(date +%s) deferred queue=$count" >"$STATE_DIR/refill-last"
    exit 0
  fi
fi
# advance the rotation pointer only when a scan actually launches — a deferred
# hour must not burn every dimension's turn
[ -n "${SCANNER_DIMENSION:-}" ] && echo "$SCANNER_DIMENSION" >"$STATE_DIR/last-scanner"
scan_start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bash -c "$RUN_CMD"
# record when this dimension last ran and how many issues that run filed
if [ -n "${SCANNER_DIMENSION:-}" ]; then
  filed=$(gh issue list -R "$GH_REPO" --state all --limit 100 \
    --search "author:@me created:>=$scan_start_iso" --json number --jq length 2>/dev/null || echo 0)
  log "scanner run ($SCANNER_DIMENSION) filed $filed issue(s)"
  { grep -v "^$SCANNER_DIMENSION " "$STATE_DIR/scanner-runs" 2>/dev/null || true; \
    echo "$SCANNER_DIMENSION $(date +%s) $filed"; } > "$STATE_DIR/scanner-runs.tmp"
  mv "$STATE_DIR/scanner-runs.tmp" "$STATE_DIR/scanner-runs"
fi
bash "$PKG_DIR/bin/label-guard.sh" || true
after=$(ready_issues | wc -l | tr -d ' ')
echo "$(date +%s) ran queue=$after" >"$STATE_DIR/refill-last"
log "scanner finished; ready issues now: $after"
