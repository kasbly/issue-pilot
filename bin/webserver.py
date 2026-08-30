#!/usr/bin/env python3
"""issue-pilot status page server: static files from web/ plus a tiny write API.

Bind it to a private/VPN interface only — the API changes configuration.
Actions (POST /api/action, JSON body {"action": ..., ...}):
  system_pause / system_resume   stop/start the whole machine (state/paused)
  lane_toggle      {id}     enable/disable one agent lane (state/lane-<id>.disabled)
  scanner_toggle   {name}   add/remove a scanner in SCANNER_ROTATION (conf edit)
  scanner_run_next {name}   make the next refill run this scanner once
  scanner_run_now {name}    launch refill immediately for this scanner, bypassing
                            the queue threshold and the Claude pace gate (one run)
  claude_role_toggle {role}  allow/forbid Claude for: issues | scanner | promote
  announce_preview / announce_now   generate the release note (dry run) / post it
  scanner_model    {name, model}   per-dim scanner model (SCANNER_MODEL_<dim>)
  scanner_effort   {name, effort}  per-dim scanner effort
  setting          {key, value}    guarded conf edit (thresholds, batch, fallback)
  campaign_set     {goal}   start a new campaign
  campaign_pause / campaign_resume / campaign_done
"""
import json, os, re, subprocess, sys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

HOME = os.environ.get("ISSUE_PILOT_HOME", "/opt/issue-pilot")
CONF = os.environ.get("ISSUE_PILOT_CONF", os.path.join(HOME, "issue-pilot.conf"))
PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIND = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9124

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
STATE = os.path.join(HOME, "state")


def state_path(*parts):
    return os.path.join(STATE, *parts)


def set_flag(path, on):
    """Create or remove a state flag file. Returns the resulting state."""
    os.makedirs(STATE, exist_ok=True)
    if on:
        open(path, "w").close()
    elif os.path.exists(path):
        os.remove(path)
    return on


def read_rotation():
    with open(CONF) as f:
        for line in f:
            m = re.match(r'^SCANNER_ROTATION="([^"]*)"', line)
            if m:
                return m.group(1).split()
    return []


def write_rotation(items):
    with open(CONF) as f:
        text = f.read()
    new_line = 'SCANNER_ROTATION="%s"' % " ".join(items)
    if re.search(r"^SCANNER_ROTATION=.*$", text, flags=re.M):
        text = re.sub(r"^SCANNER_ROTATION=.*$", new_line, text, count=1, flags=re.M)
    else:
        text += "\n" + new_line + "\n"
    with open(CONF, "w") as f:
        f.write(text)


MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
# conf keys the panel may edit, with validation: (kind, lo, hi) for ints
SETTINGS = {
    "PROMOTE_AFTER_COMMITS": (1, 500),
    "REFILL_THRESHOLD": (0, 200),
    "BATCH_SIZE": (1, 50),
    "PR_WIP_LIMIT": (1, 200),
}


def conf_set(key, value, quote=False):
    """Set or append one KEY=value line in the conf (same pattern as lane_mode)."""
    with open(CONF) as f:
        text = f.read()
    line = '%s="%s"' % (key, value) if quote else "%s=%s" % (key, value)
    pat = r"^%s=.*$" % re.escape(key)
    if re.search(pat, text, flags=re.M):
        text = re.sub(pat, line, text, count=1, flags=re.M)
    else:
        text += "\n" + line + "\n"
    with open(CONF, "w") as f:
        f.write(text)


def campaign(*args):
    return subprocess.run(
        ["bash", os.path.join(PKG, "bin", "campaign.sh"), *args],
        capture_output=True, text=True, timeout=30,
    ).returncode == 0


def kick(script, logfile=None, args=()):
    # logfile: append the script's output to state/<logfile> so panel-triggered
    # runs stay auditable (timer-triggered runs log to the journal instead)
    out = subprocess.DEVNULL
    if logfile:
        os.makedirs(STATE, exist_ok=True)
        out = open(os.path.join(STATE, logfile), "a")
    subprocess.Popen(
        ["bash", os.path.join(PKG, "bin", script), *args],
        stdout=out, stderr=subprocess.STDOUT if logfile else subprocess.DEVNULL,
    )


def refresh_status():
    # regenerate status.json right away so the UI reflects the change on its next
    # fetch instead of waiting for the 5-minute timer
    kick("status.sh")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=os.path.join(HOME, "web"), **kw)

    def log_message(self, *a):
        pass

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/api/action":
            return self._reply(404, {"error": "unknown endpoint"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            action = req.get("action", "")
            if action in ("system_pause", "system_resume"):
                on = set_flag(state_path("paused"), action == "system_pause")
                # resuming re-paces immediately, so lanes don't idle until the 2h timer
                if not on:
                    kick("pace.sh")
                refresh_status()
                return self._reply(200, {"ok": True, "paused": on})
            if action == "lane_toggle":
                lane = req.get("id", "")
                if not NAME_RE.match(lane):
                    return self._reply(400, {"error": "bad lane id"})
                flag = state_path("lane-%s.disabled" % lane)
                off = set_flag(flag, not os.path.exists(flag))
                if not off:  # re-enabling clears an auto-disable's reason + strikes
                    for f in ("lane-%s.disabled-reason" % lane, "lane-%s.crashes" % lane):
                        p = state_path(f)
                        os.path.exists(p) and os.remove(p)
                if not off:
                    kick("pace.sh")
                refresh_status()
                return self._reply(200, {"ok": True, "disabled": off})
            if action == "lane_mode":
                lane = req.get("id", "")
                mode = req.get("mode", "")
                # mode is the lane's pacing personality; on/off is the toggle's job
                if not NAME_RE.match(lane) or mode not in ("always", "window"):
                    return self._reply(400, {"error": "bad lane id or mode"})
                with open(CONF) as f:
                    text = f.read()
                line = 'LANE_%s_MODE="%s"' % (lane, mode)
                pat = r"^LANE_%s_MODE=.*$" % re.escape(lane)
                if re.search(pat, text, flags=re.M):
                    text = re.sub(pat, line, text, count=1, flags=re.M)
                else:
                    text += "\n" + line + "\n"
                with open(CONF, "w") as f:
                    f.write(text)
                kick("pace.sh")  # apply the new mode now, not at the next hourly tick
                refresh_status()
                return self._reply(200, {"ok": True, "mode": mode})
            if action in ("scanner_toggle", "scanner_run_next", "scanner_run_now"):
                name = req.get("name", "")
                if not NAME_RE.match(name):
                    return self._reply(400, {"error": "bad scanner name"})
                if action == "scanner_toggle":
                    rot = read_rotation()
                    rot = [d for d in rot if d != name] if name in rot else rot + [name]
                    write_rotation(rot)
                    refresh_status()
                    return self._reply(200, {"ok": True, "rotation": rot})
                os.makedirs(os.path.join(HOME, "state"), exist_ok=True)
                with open(os.path.join(HOME, "state", "next-scanner"), "w") as f:
                    f.write(name + "\n")
                if action == "scanner_run_now":
                    # force flag: refill bypasses the queue threshold and the Claude
                    # pace gate for this one run, then launch refill immediately
                    with open(os.path.join(HOME, "state", "refill-force"), "w") as f:
                        f.write("1\n")
                    kick("refill.sh", logfile="refill.log")
                refresh_status()
                return self._reply(200, {"ok": True, "next": name})
            if action in ("scanner_model", "scanner_effort"):
                name = req.get("name", "")
                if not NAME_RE.match(name):
                    return self._reply(400, {"error": "bad scanner name"})
                dim_key = re.sub(r"[^A-Za-z0-9]", "_", name)
                if action == "scanner_model":
                    model = req.get("model", "")
                    if not MODEL_RE.match(model):
                        return self._reply(400, {"error": "bad model id"})
                    conf_set("SCANNER_MODEL_%s" % dim_key, model, quote=True)
                else:
                    effort = req.get("effort", "")
                    if effort not in EFFORTS:
                        return self._reply(400, {"error": "bad effort"})
                    conf_set("SCANNER_EFFORT_%s" % dim_key, effort, quote=True)
                refresh_status()
                return self._reply(200, {"ok": True})
            if action == "setting":
                key, value = req.get("key", ""), str(req.get("value", ""))
                if key in SETTINGS:
                    lo, hi = SETTINGS[key]
                    if not value.isdigit() or not lo <= int(value) <= hi:
                        return self._reply(400, {"error": "value out of range %d-%d" % (lo, hi)})
                    conf_set(key, int(value))
                elif key == "SCANNER_FALLBACK_MODEL" and MODEL_RE.match(value):
                    conf_set(key, value, quote=True)
                elif key == "SCANNER_FALLBACK_EFFORT" and value in EFFORTS:
                    conf_set(key, value, quote=True)
                else:
                    return self._reply(400, {"error": "unknown or invalid setting"})
                refresh_status()
                return self._reply(200, {"ok": True})
            if action == "promote_now":
                # manual production promotion: bypasses the commit threshold and
                # the enabled gate (promote.sh --now); its flock makes a click
                # during a running promotion a safe no-op
                kick("promote.sh", logfile="promote-manual.log", args=("--now",))
                refresh_status()
                return self._reply(200, {"ok": True})
            if action == "claude_role_toggle":
                # which loops may bill the Claude accounts: issues (lanes running
                # the claude CLI), scanner (claude-model dims), promote (when
                # PROMOTE_CMD runs claude). Flag present = role OFF.
                role = req.get("role", "")
                if role not in ("issues", "scanner", "promote"):
                    return self._reply(400, {"error": "bad role"})
                flag = state_path("claude-role-%s.disabled" % role)
                off = set_flag(flag, not os.path.exists(flag))
                kick("pace.sh")  # lanes react now, not at the next hourly tick
                refresh_status()
                return self._reply(200, {"ok": True, "role": role, "enabled": not off})
            if action in ("announce_preview", "announce_now"):
                # release note for non-technical users: preview generates without
                # posting; now posts the pending range (announce.sh is flock-guarded)
                args = ("--dry-run",) if action == "announce_preview" else ()
                kick("announce.sh", logfile="announce-manual.log", args=args)
                return self._reply(200, {"ok": True})
            if action == "campaign_set":
                goal = req.get("goal", "").strip()
                if not 10 <= len(goal) <= 2000:
                    return self._reply(400, {"error": "goal must be 10-2000 chars"})
                ok = campaign("set", goal)
                refresh_status()
                return self._reply(200, {"ok": ok})
            if action in ("campaign_pause", "campaign_resume", "campaign_done"):
                ok = campaign(action.split("_", 1)[1])
                refresh_status()
                return self._reply(200, {"ok": ok})
            return self._reply(400, {"error": "unknown action"})
        except Exception as e:  # noqa: BLE001 — surface the message, never a traceback page
            return self._reply(500, {"error": str(e)})


if __name__ == "__main__":
    # threading: a slow action (campaign_set + status regen) must not block page loads
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
