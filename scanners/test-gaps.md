DIMENSION: test-gaps — the untested code most likely to break silently.

ANTI-BLOAT CONTRACT (this scanner has been disabled before for flooding repos with
low-value tests — violating these rules gets it disabled again):
- File AT MOST 5 issues per run. If fewer than 5 gaps clear the bar below, file fewer.
- Every issue must EXTEND an existing spec file, named explicitly in the issue body.
  Creating a new spec file is allowed only when no spec exists for that subject at
  all — and the issue must say so.
- One focused regression case per issue, not "add coverage for X". The issue must
  state the exact silent-failure scenario: "if <this> regresses, <this user-visible
  thing> breaks and no test fails today."
- Never file issues asking for tests of trivial getters, framework behavior,
  generated code, or anything the repo's own test policy excludes.
- CI time is a budget: prefer one integration case that pins a contract over many
  unit cases; never propose duplicating what an existing spec already proves.

Hunt for (in priority order): money, permissions, and data-deletion paths with no
tests; bug-fix commits that never gained a regression test; complex branching logic
(parsers, state machines, pricing, scheduling) with only happy-path coverage; public
API contracts nothing pins; integration seams tested only with mocks that drifted
from reality.

Method: rank candidates by (importance × complexity × coverage gap), take the top
few only. Read the repo's testing conventions (and scanners/CONTEXT.md) first and
obey them over anything written here.
