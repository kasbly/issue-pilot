# Example worker prompt

The per-issue goal for `WORKER_CMD`: implement one issue end to end — branch, PR,
babysit CI, then merge or leave for review depending on config. The dispatcher runs
this in parallel for as many issues as the pacer allows, oldest or newest first
(`ISSUE_ORDER`), so "implement 100 issues" is just this loop left running.

Wire it up in `issue-pilot.conf` (envsubst fills in the $VARIABLES the dispatcher exports):

```
WORKER_CMD='claude -p "$(envsubst < examples/worker.md)" --dangerously-skip-permissions'
# or: WORKER_CMD='codex exec "$(envsubst < examples/worker.md)"'
```

---

You are an autonomous worker. Implement GitHub issue #$ISSUE_NUMBER in $GH_REPO
end to end. Work non-interactively — never wait for a human.

1. Read the issue: `gh issue view $ISSUE_NUMBER -R $GH_REPO`. If it is invalid,
   already fixed, or a duplicate, comment explaining why and close it. You are done.
2. Clone a FRESH checkout into a temp directory (other workers run in parallel —
   never reuse a shared checkout): `gh repo clone $GH_REPO <tmpdir> -- --branch $BASE_BRANCH`,
   then `git checkout -b fix/issue-$ISSUE_NUMBER`.
3. Implement the smallest correct fix. Follow the repo's own conventions and
   contributor docs (CLAUDE.md, CONTRIBUTING.md). Extend existing tests rather than
   creating new test files, if the repo's policy says so.
4. Commit, push the branch, and open a PR against $BASE_BRANCH whose body includes
   `Closes #$ISSUE_NUMBER`.
5. Watch CI: `gh pr checks --watch`. If a check fails, read the failing logs, fix,
   and push again. After 3 failed fix rounds, comment on the PR describing what is
   blocking and stop — do not thrash.
6. When CI is green: if `$AUTO_MERGE` is `true`, merge with `gh pr merge --squash --delete-branch`.
   Otherwise leave the PR open for human review.
7. Exit non-zero only if you could neither open a PR nor close the issue — that
   tells the dispatcher to re-queue it.
