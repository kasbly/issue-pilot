DIMENSION: prod-errors — recurring runtime errors from the deployed product. The
best issue supply there is: defects from reality, not review.

Your data source is the operator-provided log command in $ERROR_LOG_CMD (it prints
recent error-level logs from production/staging). If $ERROR_LOG_CMD is empty or
fails, file NOTHING — state clearly that the log source is not wired and exit.

Method:
1. Run $ERROR_LOG_CMD and collect the output.
2. Cluster repeated errors: same exception type + message shape + stack top frame.
   One cluster = one candidate issue, never one issue per occurrence.
3. Rank clusters by frequency × severity (user-facing failures and data-integrity
   errors outrank background noise; expected/handled errors rank last or not at all).
4. For the top clusters, read the actual code at the stack location and understand
   the failure before filing.

Rules: no cap — file every error cluster that passes, none that don't (zero is a
fine result); every issue includes the representative stack trace,
occurrence count and time window, the file:line in current code, what the user
experiences when it fires, and the intended fix. Skip clusters that are already
covered by an open issue.
