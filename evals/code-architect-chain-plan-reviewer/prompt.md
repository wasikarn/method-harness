---
name: code-architect-chain-plan-reviewer
tags: [code-architect, chain]
runs: 3
max_turns: 30
timeout_seconds: 900
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
Add a referral rewards feature: when a user refers a friend who signs up, the referrer gets $10
credit via `CreditLedger.add_credit()` (see `src/domain/credit_ledger.py`). Signup already tracks
`referred_by` (see `src/domain/user.py` and `src/api/signup_routes.py`). Use the
`mh:code-architect` skill for this (Skill tool, `skill: "mh:code-architect"`) to produce a full
implementation blueprint. Before anyone
builds it, have the `mh:plan-reviewer` agent review that blueprint: dispatch it through the Agent
tool and pass the full blueprint text, unedited, in its prompt. Return the plan-reviewer's report
as your final message.
