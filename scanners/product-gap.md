DIMENSION: product-gap — the product promises something the code doesn't deliver.

Hunt for: flows that dead-end (a button that leads nowhere, a state with no way
back); features stubbed or half-built behind TODOs; backend capabilities with no UI
to reach them (config fields, endpoints, flags nothing exposes); empty states that
strand new users instead of guiding them; settings that save but change nothing;
error states with no recovery path; obvious feature asymmetries (can create but not
edit, can add but not remove).

Method: walk the product as a demanding new user would, but through the code — trace
each navigation target, each conditional render, each "coming soon". Cross-check
backend routes against what the UI actually calls.

Every issue: the user story that breaks ("as a user I try X…"), file:line evidence,
and what "complete" looks like.
