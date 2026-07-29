# issue-pilot

Keep AI coding agents fed with GitHub issues, and pace the whole thing so your
subscription quota is spent by the weekly reset — not before, not after.

Three small loops, plain bash + `gh` + systemd. No daemon framework, no database:
GitHub Issues **is** the queue, labels **are** the state machine.

```
┌─────────┐  queue low   ┌──────────┐  ready issues  ┌──────────┐   ┌─ subagent ─► PR ─► CI ─► merge?
│ refill  │ ───────────► │  GitHub  │ ◄────────────  │ dispatch │──►│─ subagent ─► …
│ (timer) │  run scanner │  Issues  │  claim labels  │ (daemon) │   └─ subagent ─► …
└─────────┘              └──────────┘                └──────────┘   one batch session,
                                                          ▲         CONCURRENCY at a time
                                     state/concurrency    │
                                                     ┌─────────┐
                                     quota vs ideal  │  pace   │
                                     burn line       │ (timer) │
                                                     └─────────┘
```

## The three loops

| Loop | Unit | What it does |
|---|---|---|
| **refill** | `issue-pilot-refill.timer` (hourly) | Counts open issues with `READY_LABEL`. Below `REFILL_THRESHOLD`? Runs your `SCANNER_CMD` to generate more. |
| **dispatch** | `issue-pilot-dispatch.service` (always on) | Runs one batch session at a time (`BATCH_CMD`): an agent that works through up to `BATCH_SIZE` ready issues, spawning subagents `CONCURRENCY` at a time. Issues are claimed with `CLAIM_LABEL`, un-claimed on failure so they re-queue. When a batch ends and ready issues remain, the next batch starts. |
| **pace** | `issue-pilot-pace.timer` (every 2 h) | Asks `USAGE_CMD` how much quota is spent and how long until reset, compares against the straight-line ideal, nudges `CONCURRENCY` up or down by one within `[MIN_CONCURRENCY, MAX_CONCURRENCY]`. Applies from the next batch. |

## Install

```bash
git clone https://github.com/kasbly/issue-pilot /opt/issue-pilot
cd /opt/issue-pilot
cp issue-pilot.conf.example issue-pilot.conf
$EDITOR issue-pilot.conf            # set repo, labels, scanner/batch/usage commands
cp systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now issue-pilot-refill.timer issue-pilot-pace.timer issue-pilot-dispatch.service
```

Cloned somewhere other than `/opt/issue-pilot`? Update the paths in the unit files.
Needs: `bash`, `gh` (authenticated), `awk`, `flock`, `envsubst`. Run `./test.sh` to
verify the pacer math.

## The three commands you plug in

Everything agent-specific lives in your config as shell commands. The example files
under `examples/` are pure prompts — no headers or commentary — because headless
agents treat anything that reads like documentation as an invitation to discuss
instead of act. Keep them that way when you adapt them.

- **`SCANNER_CMD`** — generates issues. Start from [examples/scanner.md](examples/scanner.md):
  `claude -p "$(cat examples/scanner.md)"`. Wave-size tip: many smaller waves beat one
  giant dump — quality stays high and usage spreads across the week, which is exactly
  what the pacer wants.
- **`BATCH_CMD`** — one orchestrator session per batch. Start from
  [examples/goal.md](examples/goal.md): it claims ready issues (`ISSUE_ORDER` picks
  oldest- or newest-first), fans out subagents `CONCURRENCY` at a time, and each
  subagent implements one issue end to end — fresh checkout, branch off `BASE_BRANCH`,
  PR, watch CI and fix failures (max 3 rounds), then merge if `AUTO_MERGE=true` or
  leave for review. Session output lands in `state/batch.log`.
- **`USAGE_CMD`** — prints `<percent_of_weekly_quota_used> <seconds_until_reset>`.
  Wrap whatever your provider exposes (`ccusage`, a status API, a scraped dashboard).
  Leave empty to disable pacing; batches then run at a constant `CONCURRENCY`.

## /goal — the same thing, interactively

[commands/goal.md](commands/goal.md) is the batch goal as a Claude Code slash command.
Copy it into your repo's `.claude/commands/` (or `~/.claude/commands/`) and run:

```
/goal implement 100 issues, oldest first, base dev, merge when green
```

Count, order, base branch, merge policy, concurrency, and label filters are all
parsed from the request; anything unstated falls back to sane defaults (10 issues,
oldest first, repo default branch, no auto-merge, 3 subagents).

## Pacing behavior

The pacer is deliberately dumb: ±1 concurrency per tick, clamped to
`[MIN_CONCURRENCY, MAX_CONCURRENCY]`, only when actual usage drifts more than
`PACE_TOLERANCE` percent from the ideal line. A running batch keeps the concurrency
it started with; nudges apply from the next batch. Drift beyond 2× tolerance fires
`NOTIFY_CMD` (point it at ntfy/Telegram/Slack) so you hear about it instead of
discovering it at reset time.

Start with `NOTIFY_CMD` only and a fixed concurrency; turn on auto-scaling once you
trust your `USAGE_CMD` numbers — provider quota reporting is usually approximate.

## Notes

- One dispatcher per repo. The claim label is the mutex; a single orchestrator
  session claiming before delegating means no races.
- Killing the dispatcher mid-batch orphans claimed-but-unfinished issues: remove
  `CLAIM_LABEL` by hand (`gh issue edit N --remove-label in-pilot`) or let the batch
  finish first.
- Keep `BATCH_SIZE` modest (≤25): smaller batches survive session/context limits,
  and a crashed session costs at most one batch, not the whole backlog.
