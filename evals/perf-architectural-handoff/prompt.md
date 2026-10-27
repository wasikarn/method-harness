---
name: perf-architectural-handoff
tags: [performance-optimizer, planted]
runs: 3
max_turns: 35
timeout_seconds: 700
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob, Agent, Skill]
---
`enrichOrdersWithCurrentPrice` in `src/enrich_orders.js` is too slow at our real order volume
(thousands of orders/minute) — see `bench.js` and `docs/pricing-api.md` for the shape of the
problem. We already tried parallelizing the calls with `Promise.all` last sprint: it blew past the
vendor's 50 req/s rate limit and got our API key temporarily banned, so that's off the table at
our volume. The vendor has no batch endpoint and a contract renegotiation isn't happening this
quarter. Use the `mh:performance-optimizer` skill for this (Skill tool, `skill: "mh:performance-optimizer"`). End with the full report as your final message.
