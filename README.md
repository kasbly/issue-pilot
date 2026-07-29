# issue-pilot

Keep AI coding agents fed with GitHub issues, and pace the whole thing so your
subscription quota is spent by the weekly reset — not before, not after.

Three small loops, plain bash + `gh` + systemd. No daemon framework, no database:
GitHub Issues **is** the queue, labels **are** the state machine.

```
┌─────────┐  queue low   ┌──────────┐   ready issues   ┌──────────┐
│ refill  │ ───────────► │  GitHub  │ ◄──────────────  │ dispatch │──► worker (codex / claude / …)
│ (timer) │  run scanner │  Issues  │   claim + spawn  │ (daemon) │──► worker
└─────────┘              └──────────┘                  └──────────┘
                                                            ▲
                                          state/workers = N │
                                                       ┌─────────┐
                                       quota vs ideal  │  pace   │
                                       burn line       │ (timer) │
                                                       └─────────┘
```

## The three loops

| Loop | Unit | What it does |
|---|---|---|
| **refill** | `issue-pilot-refill.timer` (hourly) | Counts open issues with `READY_LABEL`. Below `REFILL_THRESHOLD`? Runs your `SCANNER_CMD` to generate more. |
| **dispatch** | `issue-pilot-dispatch.service` (always on) | Keeps N workers busy. Claims the oldest ready issue by adding `CLAIM_LABEL`, spawns `WORKER_CMD` with `ISSUE_NUMBER` set, unclaims on worker failure so the issue re-queues. |
| **pace** | `issue-pilot-pace.timer` (every 2 h) | Asks `USAGE_CMD` how much quota is spent and how long until reset, compares against the straight-line ideal, nudges N up or down by one. Writes N to `state/workers`. |

## Install

```bash
git clone https://github.com/kasbly/issue-pilot /opt/issue-pilot
cd /opt/issue-pilot
cp issue-pilot.conf.example issue-pilot.conf
$EDITOR issue-pilot.conf            # set repo, labels, scanner/worker/usage commands
cp systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now issue-pilot-refill.timer issue-pilot-pace.timer issue-pilot-dispatch.service
```

Cloned somewhere other than `/opt/issue-pilot`? Update the paths in the unit files.
Needs: `bash`, `gh` (authenticated), `awk`, `flock`. Run `./test.sh` to verify the pacer math.

## The three commands you plug in

Everything agent-specific lives in your config as shell commands:

- **`SCANNER_CMD`** — generates issues. E.g. a headless agent run:
  `claude -p "Scan the repo, file up to 75 high-quality issues labeled status/approved"`.
  Wave-size tip: many smaller waves beat one giant dump — quality stays high and the
  usage spreads across the week, which is exactly what the pacer wants.
- **`WORKER_CMD`** — implements one issue. Gets `ISSUE_NUMBER` and `GH_REPO` in its env:
  `codex exec "Implement issue #$ISSUE_NUMBER in $GH_REPO and open a PR"`.
  Per-issue logs land in `state/worker-<n>.log`.
- **`USAGE_CMD`** — prints `<percent_of_weekly_quota_used> <seconds_until_reset>`.
  Wrap whatever your provider exposes (`ccusage`, a status API, a scraped dashboard).
  Leave empty to disable pacing; the dispatcher then runs a constant `MIN_WORKERS`.

## Pacing behavior

The pacer is deliberately dumb: ±1 worker per tick, clamped to `[MIN_WORKERS, MAX_WORKERS]`,
only when actual usage drifts more than `PACE_TOLERANCE` percent from the ideal line.
Running every 2 hours, that converges without ever burning the whole quota by Tuesday.
Drift beyond 2× tolerance fires `NOTIFY_CMD` (point it at ntfy/Telegram/Slack) so you
hear about it instead of discovering it at reset time.

Start with `NOTIFY_CMD` only and a fixed worker count; turn on auto-scaling once you
trust your `USAGE_CMD` numbers — provider quota reporting is usually approximate.

## Notes

- One dispatcher per repo. The claim label is the mutex; a single dispatcher means no races.
- Killing the dispatcher orphans claimed-but-unfinished issues: remove `CLAIM_LABEL`
  by hand (`gh issue edit N --remove-label in-pilot`) or let workers finish first.
- Scale expectations for `MAX_WORKERS` to what your subscription actually sustains;
  more parallel workers just moves you along the same quota curve faster.
