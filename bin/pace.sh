#!/usr/bin/env bash
# pace: decides each lane's batch concurrency and writes it to state/lane-<id>.concurrency.
#   always → the lane's fixed CONCURRENCY, unconditionally
#   window → pace follower: whenever the account's usage falls behind the straight-line
#            burn toward its weekly reset, run enough workers to catch back up to the
#            line; once on (or ahead of) pace, idle
#   off    → 0
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME"

# paused: leave every lane's concurrency file untouched (dispatch is already
# holding the lanes down) so resuming picks up where it left off, not at zero
paused && { log "system paused — pacing skipped"; exit 0; }

# Server resource budget: how many workers the box can afford right now, shared by
# all lanes (allocated in LANES order). Probe prints "<cores> <load5> <mem_avail_mb>".
probe="${RESOURCE_PROBE_CMD:-echo \"\$(nproc) \$(awk '{print \$2}' /proc/loadavg) \$(awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo)\"}"
read -r cores load5 mem_mb < <(bash -c "$probe")
budget=$(awk -v c="$cores" -v l="$load5" -v m="$mem_mb" \
  -v cpw="${CORES_PER_WORKER:-2}" -v mpw="${MEM_MB_PER_WORKER:-3000}" \
  -v floor="${RESOURCE_MIN_BUDGET:-3}" \
  'BEGIN { cpu = int((c - l) / cpw); mem = int(m / mpw);
           b = (cpu < mem) ? cpu : mem; if (b < floor) b = floor; print b }')
echo "$budget $load5 $cores $mem_mb" >"$STATE_DIR/resource-budget"
log "resource budget: $budget workers (load ${load5}/${cores} cores, ${mem_mb}MB avail)"

# want_<id>/grant_<id> via eval instead of associative arrays: macOS bash 3.2
# (where test.sh runs) has no declare -A
for id in ${LANES:-}; do
  label=$(lane_get "$id" LABEL "$id")
  mode=$(lane_get "$id" MODE off)
  prev=$(cat "$STATE_DIR/lane-$id.concurrency" 2>/dev/null || echo 0)
  target=0

  if lane_disabled "$id"; then
    log "[$label] disabled from the panel"
    eval "want_$id=0"
    continue
  fi

  case "$mode" in
    always)
      target=$(lane_get "$id" CONCURRENCY "${DEFAULT_CONCURRENCY:-3}")
      # hard stop: even an always-lane must not grind a spent account against
      # rate limits — resume happens automatically after the reset
      ucmd=$(lane_get "$id" USAGE_CMD)
      creds=$(lane_get "$id" CREDENTIALS)
      [ -z "$ucmd" ] && [ -n "$creds" ] && ucmd="CLAUDE_CREDENTIALS='$creds' bash bin/usage-claude.sh"
      if [ -n "$ucmd" ] && read -r a_pct _ < <(bash -c "$ucmd" 2>/dev/null) && [ -n "${a_pct:-}" ]; then
        if awk -v p="$a_pct" -v h="${HARD_STOP_PCT:-98}" 'BEGIN { exit !(p >= h) }'; then
          log "[$label] account at ${a_pct}% — hard stop until reset"
          target=0
        fi
      fi
      log "[$label] always-on concurrency=$target"
      ;;
    window)
      ucmd=$(lane_get "$id" USAGE_CMD)
      [ -n "$ucmd" ] || ucmd="CLAUDE_CREDENTIALS='$(lane_get "$id" CREDENTIALS)' bash bin/usage-claude.sh"
      if read -r pct secs h5pct h5secs < <(bash -c "$ucmd" 2>/dev/null) && [ -n "${secs:-}" ]; then
        rm -f "$STATE_DIR/lane-$id.window-open" # obsolete pre-pace-follower state
        tol=$(lane_get "$id" PACE_TOLERANCE_PCT "${PACE_TOLERANCE_PCT:-5}")
        catchup=$(lane_get "$id" CATCHUP_HOURS "${CATCHUP_HOURS:-4}")
        burn=$(lane_get "$id" BURN_PCT_PER_WORKER_HOUR "${BURN_PCT_PER_WORKER_HOUR:-2}")
        hi=$(lane_get "$id" MAX_CONCURRENCY "${MAX_CONCURRENCY:-6}")
        lo=$(lane_get "$id" MIN_CONCURRENCY "${MIN_CONCURRENCY:-1}")
        # Pace follower: the ideal line runs 0% right after a reset to 100% at the
        # next one. Behind the line by more than the tolerance → enough workers to
        # close the gap within CATCHUP_HOURS; on or ahead of it → idle. Near the
        # reset the gap IS the leftover quota, so this subsumes the old drain mode.
        expected=$(awk -v s="$secs" 'BEGIN { printf "%.1f", 100 * (1 - s / 604800) }')
        behind=$(awk -v e="$expected" -v p="$pct" 'BEGIN { printf "%.1f", e - p }')
        if awk -v b="$behind" -v t="$tol" 'BEGIN { exit !(b > t) }'; then
          target=$(awk -v b="$behind" -v c="$catchup" -v r="$burn" -v hi="$hi" -v lo="$lo" \
            'BEGIN { t = int(b / (c * r) + 0.999);
                     if (t < lo) t = lo; if (t > hi) t = hi; print t }')
        fi
        # the weekly window is the goal, but the 5-hour session window is the wall:
        # when it's nearly spent, back off instead of slamming into rate limits
        h5cap=$(lane_get "$id" FIVE_HOUR_THROTTLE_CAP "${FIVE_HOUR_THROTTLE_CAP:-1}")
        h5max=$(lane_get "$id" FIVE_HOUR_THROTTLE_PCT "${FIVE_HOUR_THROTTLE_PCT:-85}")
        if [ -n "${h5pct:-}" ] && [ "$target" -gt "$h5cap" ] && \
           awk -v p="$h5pct" -v m="$h5max" 'BEGIN { exit !(p >= m) }'; then
          log "[$label] 5h window at ${h5pct}% (resets in $(( ${h5secs:-0} / 60 ))m) — throttling $target -> $h5cap"
          target=$h5cap
        fi
        state=on-pace; [ "$target" -gt 0 ] && state=BEHIND
        log "[$label] used=${pct}% pace=${expected}% behind=${behind}% resets_in=$((secs / 3600))h $state concurrency=$target"
      else
        target=$prev
        log "[$label] usage unavailable — keeping concurrency=$prev"
      fi
      ;;
    off)
      log "[$label] lane off"
      ;;
  esac

  eval "want_$id=\$target"
done

# Allocate the budget in two passes so no active lane is ever starved to zero:
# pass 1 guarantees every lane that wants workers one slot (in LANES order);
# pass 2 hands out the remainder in LANES order (put deadline lanes first).
remaining=$budget
for id in ${LANES:-}; do
  eval "w=\$want_$id"
  g=0
  if [ "$w" -gt 0 ] && [ "$remaining" -gt 0 ]; then
    g=1
    remaining=$((remaining - 1))
  fi
  eval "grant_$id=\$g"
done
for id in ${LANES:-}; do
  eval "w=\$want_$id; g=\$grant_$id"
  extra=$((w - g))
  [ "$extra" -gt "$remaining" ] && extra=$remaining
  if [ "$extra" -gt 0 ]; then
    eval "grant_$id=\$((g + extra))"
    remaining=$((remaining - extra))
  fi
done

for id in ${LANES:-}; do
  label=$(lane_get "$id" LABEL "$id")
  out="$STATE_DIR/lane-$id.concurrency"
  prev=$(cat "$out" 2>/dev/null || echo 0)
  eval "target=\$grant_$id; wanted=\$want_$id"
  [ "$target" -lt "$wanted" ] && log "[$label] capped by resource budget: $wanted -> $target"
  echo "$target" >"$out"
  if [ "$target" != "$prev" ] && [ -n "${NOTIFY_CMD:-}" ]; then
    MSG="issue-pilot: lane '$label' concurrency $prev -> $target" bash -c "$NOTIFY_CMD" || true
  fi
done
