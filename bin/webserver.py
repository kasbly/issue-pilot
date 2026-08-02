#!/usr/bin/env python3
"""issue-pilot status page server: static files from web/ plus a tiny write API.

Bind it to a private/VPN interface only — the API changes configuration.
Actions (POST /api/action, JSON body {"action": ..., ...}):
  scanner_toggle   {name}   add/remove a scanner in SCANNER_ROTATION (conf edit)
  scanner_run_next {name}   make the next refill run this scanner once
  campaign_set     {goal}   start a new campaign
  campaign_pause / campaign_resume / campaign_done
"""
import json, os, re, subprocess, sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

HOME = os.environ.get("ISSUE_PILOT_HOME", "/opt/issue-pilot")
CONF = os.environ.get("ISSUE_PILOT_CONF", os.path.join(HOME, "issue-pilot.conf"))
PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIND = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9124

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


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


def campaign(*args):
    return subprocess.run(
        ["bash", os.path.join(PKG, "bin", "campaign.sh"), *args],
        capture_output=True, text=True, timeout=30,
    ).returncode == 0


def refresh_status():
    # regenerate status.json right away so the UI reflects the change on its next
    # fetch instead of waiting for the 5-minute timer
    subprocess.Popen(
        ["bash", os.path.join(PKG, "bin", "status.sh")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


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
            if action in ("scanner_toggle", "scanner_run_next"):
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
                refresh_status()
                return self._reply(200, {"ok": True, "next": name})
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
    HTTPServer((BIND, PORT), Handler).serve_forever()
