DIMENSION: security — exploitable weaknesses, not theoretical ones.

Hunt for: missing or wrong authorization checks (especially object-level: can user A
read user B's record by changing an id?); multi-tenant data isolation gaps; injection
(SQL, command, template, path traversal); secrets in code, logs, or error responses;
unsafe deserialization; missing rate limits on expensive or sensitive endpoints;
tokens/sessions that never expire or leak scope.

Method: think like an attacker with a valid low-privilege account. For each endpoint
you audit, ask: what happens if I change the id? omit the field? replay the request?
Only file findings with a plausible exploit path — grade each HIGH/MEDIUM by how
easily a real attacker reaches it.

Every issue: the attack scenario step by step, file:line evidence, impact, and the fix.
