DIMENSION: bugs — runtime errors waiting to happen.

Hunt for: unhandled promise rejections and missing await; error paths that swallow
or mislabel failures; null/undefined dereferences on optional data; race conditions
around shared state; off-by-one and boundary mistakes; resource leaks (unclosed
handles, listeners, intervals); crash paths reachable from user input.

Method: pick a subsystem you have not seen recently and read it deeply — follow the
data from entry point to storage and back. Trace what happens when each external
call fails. A finding is real only if you can name the exact input or sequence that
triggers it.

Every issue: the failing scenario, the file:line evidence, why it matters in
production, and the smallest fix you would accept.
