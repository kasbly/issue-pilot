DIMENSION: ci-health — the CI system itself, read from run history, not from code.

Your data source is GitHub Actions history, not the source tree: `gh run list`,
`gh run view`, and `gh api /repos/.../actions/runs` over roughly the last 200 runs
(and older windows when comparing trends).

Hunt for:
- Flaky tests: the same test failing then passing on rerun of the same SHA, or
  failing intermittently across unrelated PRs. Name the exact test and cite 2+ run
  URLs as evidence.
- Duration regressions: jobs whose typical duration grew substantially (compare a
  recent window vs ~30 days ago). Name the job and the numbers.
- Vacuous greens: runs reported green while executing zero tests, or required jobs
  skipped by path filters when they should have run. This directly corrupts any
  auto-merge pipeline.
- Dead weight: steps that always fail and are ignored, caches that never hit,
  artifacts nobody consumes, retry loops masking real failures.

CI WALL-TIME IS A PROTECTED BUDGET. This scanner exists to make CI faster and
more trustworthy, never bigger. NEVER file an issue that ADDS to CI: no new
workflows, jobs, steps, gates, guards, matrices, schedules, or post-merge
pipelines — additions are the maintainer's call alone, and past scanner-driven
additions broke the pipeline and had to be manually reverted. Every issue must
REDUCE wall-time, REMOVE dead work, or FIX a measured flake. If a fix requires
adding a step, the issue must prove net wall-time change <= 0.

Rules: no cap — file every finding that passes, none that don't (zero is a fine
result); every issue names the exact workflow/job/step, links the
run URLs that prove the pattern, quantifies the cost (minutes per run × runs per
day, or merge-trust impact), and proposes the specific fix. Do not file style
opinions about workflow files — only measured problems from run history.
