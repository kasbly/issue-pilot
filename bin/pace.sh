#!/usr/bin/env bash
# pace: decides each lane's batch concurrency and writes it to state/lane-<id>.concurrency.
#   always → the lane's fixed CONCURRENCY, unconditionally
#   window → 0 until the account is close to its quota reset AND still underused,
#            then enough concurrency to drain the leftover quota by the reset
#   off    → 0
. "$(dirname "$0")/lib.sh"
cd "$ISSUE_PILOT_HOME"

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
remaining=$budget

for id in ${LANES:-}; do
  label=$(lane_get "$id" LABEL "$id")
  mode=$(lane_get "$id" MODE off)
  out="$STATE_DIR/lane-$id.concurrency"
  prev=$(cat "$out" 2>/dev/null || echo 0)
  target=0

  case "$mode" in
    always)
      target=$(lane_get "$id" CONCURRENCY "${DEFAULT_CONCURRENCY:-3}")
      log "[$label] always-on concurrency=$target"
      ;;
    window)
      ucmd=$(lane_get "$id" USAGE_CMD)
      [ -n "$ucmd" ] || ucmd="CLAUDE_CREDENTIALS='$(lane_get "$id" CREDENTIALS)' bash bin/usage-claude.sh"
      if read -r pct secs < <(bash -c "$ucmd" 2>/dev/null) && [ -n "${secs:-}" ]; then
        wdays=$(lane_get "$id" WINDOW_DAYS "${WINDOW_DAYS:-3}")
        wmax=$(lane_get "$id" WINDOW_MAX_PCT "${WINDOW_MAX_PCT:-50}")
        if awk -v s="$secs" -v w="$wdays" -v p="$pct" -v m="$wmax" 'BEGIN { exit !(s <= w*86400 && p < m) }'; then
          burn=$(lane_get "$id" BURN_PCT_PER_WORKER_HOUR "${BURN_PCT_PER_WORKER_HOUR:-2}")
          hi=$(lane_get "$id" MAX_CONCURRENCY "${MAX_CONCURRENCY:-6}")
          lo=$(lane_get "$id" MIN_CONCURRENCY "${MIN_CONCURRENCY:-1}")
          # workers needed to burn the remaining % by the reset; re-computed from real
          # usage every tick, so a wrong BURN constant self-corrects
          target=$(awk -v p="$pct" -v s="$secs" -v b="$burn" -v hi="$hi" -v lo="$lo" \
            'BEGIN { h = s/3600; if (h < 1) h = 1;
                     t = int((100 - p) / (h * b) + 0.999);
                     if (t < lo) t = lo; if (t > hi) t = hi; print t }')
        fi
        state=idle; [ "$target" -gt 0 ] && state=ACTIVE
        log "[$label] used=${pct}% resets_in=$((secs / 3600))h window=$state concurrency=$target"
      else
        target=$prev
        log "[$label] usage unavailable — keeping concurrency=$prev"
      fi
      ;;
    off)
      log "[$label] lane off"
      ;;
  esac

  # cap by what's left of the shared server resource budget
  if [ "$target" -gt "$remaining" ]; then
    log "[$label] capped by resource budget: $target -> $remaining"
    target=$remaining
  fi
  remaining=$((remaining - target))

  echo "$target" >"$out"
  if [ "$target" != "$prev" ] && [ -n "${NOTIFY_CMD:-}" ]; then
    MSG="issue-pilot: lane '$label' concurrency $prev -> $target" bash -c "$NOTIFY_CMD" || true
  fi
done
