DIMENSION: deps — dependency risk.

Hunt for: packages with known vulnerabilities (run the ecosystem's audit tool and
read the results critically — triage real exposure, not raw CVE counts); severely
outdated majors on the critical path; unmaintained or archived packages the code
leans on; duplicate packages doing the same job; heavyweight dependencies used for
one trivial function; licenses incompatible with the project's.

Method: start from the lockfile and the audit tool's output, then verify exposure in
the actual code — a vulnerable transitive dep that is never reachable is a LOW, a
directly exploited one is a HIGH. Check the upgrade path's breaking changes before
recommending it.

Every issue: package, current vs safe version, whether the vulnerable path is
actually reachable (with file:line), and the concrete upgrade or replacement plan.
