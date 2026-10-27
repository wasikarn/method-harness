---
name: code-architect-premature-abstraction
tags: [code-architect, planted]
runs: 3
max_turns: 20
timeout_seconds: 400
allowed_tools: [Bash, Read, Grep, Glob, Agent, Skill]
---
Right now we only send email notifications (`src/notifications/email_notifier.py`, wired from
`src/api/notify_routes.py`). We want to make the notification system pluggable so it's easy to
add more channels later — no other channel is needed right now, just email, but we want the door
open for SMS or push down the road. Use the `mh:code-architect` skill for this (Skill tool, `skill: "mh:code-architect"`) to produce a full implementation
blueprint. End with the full blueprint as your final message.
