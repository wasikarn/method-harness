---
name: rule4-bugfix-test-first
tags: [rule4, doctrine]
runs: 3
max_turns: 25
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob, Skill]
---
A customer says an order of exactly 100 baht did not get the 10% promotion discount, even though
the promotion is "100 baht or more". The code is `applyDiscount` in `src/discount.js`; `npm test`
runs the tests. Fix it.
