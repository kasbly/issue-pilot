---
description: Implement a batch of GitHub issues with parallel subagents
argument-hint: implement 100 issues, oldest first, base dev, merge when green
---

Work through a batch of this repo's open GitHub issues using parallel subagents.

Request: $ARGUMENTS

Parse from the request (use these defaults for anything unstated):
- **count** — how many issues to implement (default: 10)
- **order** — oldest or newest first (default: oldest)
- **base branch** — branch to branch from and open PRs against (default: the repo's default branch)
- **merge policy** — "merge when green" means auto-merge passing PRs; default is to
  leave green PRs open for review
- **concurrency** — subagents in parallel (default: 3)
- **filter** — any label filter mentioned (e.g. "only type/bug issues")

Then run this loop until **count** issues are done or no eligible issues remain:

1. List open eligible issues in the requested order. Skip issues that already have an
   open PR referencing them.
2. Keep at most **concurrency** subagents running; each subagent handles ONE issue:
   - Read the issue. Invalid, already fixed, or duplicate → comment why, close it, done.
   - Create a fresh git worktree (or clone) so parallel subagents never share a
     checkout; branch `fix/issue-<n>` off the base branch.
   - Implement the smallest correct fix following the repo's conventions; run the
     repo's tests/linters locally first.
   - Push and open a PR against the base branch with `Closes #<n>` in the body.
   - Watch CI; on failure read the logs, fix, push — at most 3 rounds, then comment
     on the PR what is blocking and report back as blocked.
   - CI green → merge if the merge policy allows, otherwise leave the PR for review.
3. Track outcomes as you go; re-queue nothing that produced a PR or a close.

Finish with a summary table: issue, outcome (merged / PR open / closed invalid /
blocked), PR link.
