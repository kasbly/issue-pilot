DIMENSION: test-gaps — the untested code most likely to break silently.

Hunt for: money, permissions, and data-deletion paths without tests; complex branching
logic (parsers, state machines, pricing, scheduling) with only happy-path coverage;
bug-fix commits that never gained a regression test; public API contracts nothing pins;
integration seams (webhooks, queues, third-party calls) tested only with mocks that
drifted from reality.

Method: rank code by (importance × complexity × current coverage gap) — do not file
issues asking for tests of trivial getters or framework behavior. One well-aimed test
issue beats ten "increase coverage" ones. Respect the repo's own testing conventions
and file layout; extending an existing spec beats creating a new file.

Every issue: what breaks silently today if this regresses, file:line of the untested
logic, and the specific cases the new test must cover.
