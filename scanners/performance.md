DIMENSION: performance — measurable waste users can feel.

Hunt for: N+1 database queries; missing indexes implied by query patterns; large
payloads or bundles shipped where a fraction is used; work done per-request that
could be cached or precomputed; synchronous blocking in hot paths; unbounded lists
without pagination; polling where events exist; duplicate fetches of the same data.

Method: follow the hottest user journeys (login, main list views, search, save) and
count the real work each one triggers — queries, round trips, bytes. A finding must
name the multiplier ("this renders 50 items → 50 queries"), not just "could be faster".

Every issue: the journey affected, the measured or counted cost, file:line evidence,
and the intended fix with its expected gain.
