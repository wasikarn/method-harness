---
name: code-architect-ambiguous-requirement
tags: [code-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
Add a referral rewards feature: when a user refers a friend who signs up, the referrer gets $10
credit via `CreditLedger.add_credit()` (see `src/domain/credit_ledger.py`). Signup already tracks
`referred_by` (see `src/domain/user.py` and `src/api/signup_routes.py`). Use the
`mh:code-architect` skill for this (Skill tool, `skill: "mh:code-architect"`) to produce a full implementation blueprint. End with the full blueprint as your final message.
