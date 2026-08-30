#!/usr/bin/env bash
# cost-log: attribute the AI tokens one finished run consumed and append a row to
# state/costs.jsonl. The engines' own session stores are the source of truth:
#   claude  $CLAUDE_CONFIG_DIR/projects/**.jsonl   per-message usage records
#   codex   $CODEX_HOME/sessions/**/*.jsonl        cumulative total_token_usage
#   grok    ~/.grok/logs/unified.jsonl             per-request inference_done lines
# Usage: cost-log.sh <kind> <detail> <start_epoch> <cmd-or-engine> [model_hint]
# The engine (and its home dir, when the command string embeds one) is sniffed from
# the 4th arg. Attribution is by time window per engine store: rows are per-run
# attributions, not billing records — two overlapping runs of the SAME engine
# split imprecisely. "tok" = uncached input + cache writes + output.
. "$(dirname "$0")/lib.sh"

kind="${1:?}" detail="${2:-}" start="${3:?}" cmd="${4:-}" model="${5:-}"
end=$(date +%s)
[ "$start" -gt 0 ] 2>/dev/null && [ "$end" -ge "$start" ] || exit 0

engine="" home=""
case "$cmd" in
  *grok*)  engine=grok;  home="$HOME/.grok" ;;
  *codex*) engine=codex; home="${CODEX_HOME:-$HOME/.codex}"
           h=$(grep -o "CODEX_HOME=[^ ]*" <<<"$cmd" | head -1 | cut -d= -f2); [ -n "$h" ] && home="$h" ;;
  *claude*) engine=claude; home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
           h=$(grep -o "CLAUDE_CONFIG_DIR=[^ ]*" <<<"$cmd" | head -1 | cut -d= -f2); [ -n "$h" ] && home="$h" ;;
  *) exit 0 ;;
esac

python3 - "$engine" "$home" "$start" "$end" "$kind" "$detail" "$model" "$STATE_DIR/costs.jsonl" <<'PY' || true
import glob, json, os, sys, time
eng, home, start, end, kind, detail, model, out = sys.argv[1:9]
start, end = int(start), int(end)
i = cached = o = 0
def newer(paths):
    return [p for p in paths if start <= os.path.getmtime(p) + 1]
try:
    if eng == "claude":
        for p in newer(glob.glob(home + "/projects/*/*.jsonl")):
            for line in open(p, errors="ignore"):
                if '"usage"' not in line: continue
                try: d = json.loads(line)
                except ValueError: continue
                u = (d.get("message") or {}).get("usage") or d.get("usage") or {}
                if not u: continue
                i += u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                cached += u.get("cache_read_input_tokens", 0)
                o += u.get("output_tokens", 0)
                model = model or (d.get("message") or {}).get("model", "")
    elif eng == "codex":
        for p in newer(glob.glob(home + "/sessions/*/*/*/*.jsonl")):
            last = None
            for line in open(p, errors="ignore"):
                if '"total_token_usage"' not in line: continue
                try: last = json.loads(line)
                except ValueError: continue
            if last:
                def dig(d):
                    if isinstance(d, dict):
                        if "total_token_usage" in d: return d["total_token_usage"]
                        for v in d.values():
                            r = dig(v)
                            if r: return r
                u = dig(last) or {}
                i += u.get("input_tokens", 0) - u.get("cached_input_tokens", 0) + u.get("cache_write_input_tokens", 0)
                cached += u.get("cached_input_tokens", 0)
                o += u.get("output_tokens", 0)
    else:  # grok
        for line in open(home + "/logs/unified.jsonl", errors="ignore"):
            if '"shell.turn.inference_done"' not in line: continue
            try: d = json.loads(line)
            except ValueError: continue
            ts = d.get("ts", "")
            try: t = time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
            except ValueError: continue
            if not start <= t <= end + 60: continue
            c = d.get("ctx") or {}
            i += max(0, c.get("prompt_tokens", 0) - c.get("cached_prompt_tokens", 0))
            cached += c.get("cached_prompt_tokens", 0)
            o += c.get("completion_tokens", 0)
    tok = i + o
    if tok <= 0: sys.exit(0)
    row = {"ts": end, "secs": end - start, "kind": kind, "detail": detail,
           "engine": eng, "model": model, "in": i, "cached": cached, "out": o, "tok": tok}
    with open(out, "a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")
    # keep the ledger bounded
    lines = open(out).readlines()
    if len(lines) > 4000:
        open(out, "w").writelines(lines[-3000:])
except FileNotFoundError:
    pass
PY
