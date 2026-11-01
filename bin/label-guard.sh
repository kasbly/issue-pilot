#!/usr/bin/env bash
# label-guard: enforce the repo's issue-label contract mechanically. Scanner agents
# are INSTRUCTED to apply full labels, but instructions drift — this guard runs after
# every scan and repairs any ready issue missing its type label, extra labels, or
# assignee. Enabled by SCANNER_GUARD=true.
# Config:
#   SCANNER_GUARD_LABELS   labels every scanned issue must carry (comma list)
#   SCANNER_GUARD_ASSIGNEE assignee every scanned issue must have
#   SCANNER_GUARD_PRIORITY priority label added only when no priority/* is present
#   SCANNER_TYPE_MAP       "[Prefix]=label" overrides, e.g. "Perf=performance UI/UX=ui-ux"
#   (default type mapping: lowercase of the [Prefix] in the title, as type/<prefix>)
. "$(dirname "$0")/lib.sh"

[ "${SCANNER_GUARD:-false}" = "true" ] || exit 0

fixed=0
# Pass 0: a scanner issue that arrived with NO status/* label at all is invisible
# to the queue, the lanes AND this guard's main pass (which queries by the ready
# label). Give it the ready label so it enters the pipeline. Issues a human moved
# to another status/* (blocked, needs-review) are deliberate states — untouched.
created_label="${SCANNER_GUARD_LABELS%%,*}"
if [ -n "$created_label" ]; then
  for iss in $(gh issue list -R "$GH_REPO" --state open --label "$created_label" --limit 100 \
    --json number,labels --jq '.[] | select(([.labels[].name | startswith("status/")] | any) | not) | .number' 2>/dev/null); do
    if gh issue edit "$iss" -R "$GH_REPO" --add-label "$READY_LABEL" >/dev/null 2>&1; then
      log "label-guard: #$iss had no status/* label — added $READY_LABEL"
      fixed=$((fixed + 1))
    fi
  done
fi
for iss in $(gh issue list -R "$GH_REPO" --state open --label "$READY_LABEL" --limit 50 \
  --json number,labels --jq '.[] | select(([.labels[].name] | map(startswith("type/")) | any) | not) | .number'); do
  title=$(gh issue view "$iss" -R "$GH_REPO" --json title --jq .title)
  prefix=$(sed -n 's/^\[\([^]]*\)\].*/\1/p' <<<"$title")
  type=""
  if [ -n "$prefix" ]; then
    for m in ${SCANNER_TYPE_MAP:-}; do
      [ "${m%%=*}" = "$prefix" ] && type="type/${m#*=}" && break
    done
    [ -n "$type" ] || type="type/$(tr '[:upper:]' '[:lower:]' <<<"$prefix" | tr -cd 'a-z0-9-')"
  fi
  [ -n "$type" ] || type="${SCANNER_GUARD_DEFAULT_TYPE:-type/bug}"

  labels="$type"
  [ -n "${SCANNER_GUARD_LABELS:-}" ] && labels="$labels,$SCANNER_GUARD_LABELS"
  has_priority=$(gh issue view "$iss" -R "$GH_REPO" --json labels --jq '[.labels[].name | select(startswith("priority/"))] | length')
  [ "${has_priority:-0}" -eq 0 ] && [ -n "${SCANNER_GUARD_PRIORITY:-}" ] && labels="$labels,$SCANNER_GUARD_PRIORITY"

  args=(--add-label "$labels")
  [ -n "${SCANNER_GUARD_ASSIGNEE:-}" ] && args+=(--add-assignee "$SCANNER_GUARD_ASSIGNEE")
  if gh issue edit "$iss" -R "$GH_REPO" "${args[@]}" >/dev/null 2>&1; then
    log "label-guard: repaired #$iss (+$labels)"
    fixed=$((fixed + 1))
  else
    log "label-guard: FAILED to repair #$iss (check that '$type' exists as a label)"
  fi
done
[ "$fixed" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: label-guard repaired $fixed scanned issue(s)" bash -c "$NOTIFY_CMD" || true; }

# Pass 2: customer-facing AI behaviour is owner-managed. A ready scanner issue that
# cites a PROTECTED_PATHS file and carries no evidence (has_evidence) is closed, not
# queued: a prose promise is not a requirement for how the AI replies (#34690 printed
# a fee range because a settings hint said so) and a principle is not a production
# signal (#29695 gated order creation on a confirmation no receipt flow ever asks).
# The scanner prompt tells it to file the prose fix instead; dedup against closed
# issues stops the refile. Runs right after every scan, before a lane can claim.
if [ -n "${PROTECTED_PATHS:-}" ]; then
  gh label create owner-managed -R "$GH_REPO" -c 5319e7 \
    -d "customer-facing AI behaviour: the pilot changes it only on tenant evidence" >/dev/null 2>&1 || true
  closed=0
  while read -r iss; do
    [ -n "$iss" ] || continue
    body=$(gh issue view "$iss" -R "$GH_REPO" --json body --jq '.body' 2>/dev/null) || continue
    labels=$(gh issue view "$iss" -R "$GH_REPO" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null) || continue
    protected_hit "$body" || continue
    has_evidence "$body" "$labels" && continue
    gh issue edit "$iss" -R "$GH_REPO" --remove-label "$READY_LABEL" --add-label owner-managed >/dev/null 2>&1 || continue
    gh issue close "$iss" -R "$GH_REPO" --reason "not planned" --comment "Closed by issue-pilot: this asks for a change under a protected path (customer-facing AI behaviour) without tenant evidence — no KB entry, pack config, approved reply, quality issue, failing scenario or production error is cited. A UI hint, README or docs sentence is not a requirement for how the AI replies; when prose and behaviour disagree there, the prose is what gets fixed. Owners change these paths on their own evidence." >/dev/null 2>&1 || true
    log "label-guard: closed #$iss — protected path cited, no evidence"
    closed=$((closed + 1))
  done < <(gh issue list -R "$GH_REPO" --state open --label "$READY_LABEL" --limit 100 \
    --search "-label:$CLAIM_LABEL" --json number --jq '.[].number' 2>/dev/null)
  [ "$closed" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ] && { MSG="issue-pilot: label-guard closed $closed scanner issue(s) that would change AI behaviour without evidence" bash -c "$NOTIFY_CMD" || true; }
fi
exit 0
