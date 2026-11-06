# mh cloud probe results (2026-11-06)

Question: can a Claude Code web (cloud) environment's setup script install mh so that its
skills, agents and gates run in the session? Answer: **yes, with install plus enable.**

Both runs: environment `mh-probe` (network "Limited", the default), repo CodeKatas (not
method-harness, whose own hooks would confuse the result), the first prompt from
`mh-cloud-probe-prompt.md`.

## Environment facts (both runs)

- user root, `HOME=/root`, `CLAUDE_CODE_REMOTE=true`.
- `claude` at `/opt/node22/bin/claude`, version 2.1.318.
- github.com/wasikarn/method-harness returned HTTP 200 under "Limited" network.
- `CLAUDE_ENV_FILE` is not set in the session.
- No trash CLI on the machine.

## v1: install only

- `claude plugin marketplace add wasikarn/method-harness`: exit 0 (HTTPS clone).
- `claude plugin install mh@wasikarn`: exit 0, but the CLI says the plugin "is disabled by
  default" and to enable it with `claude plugin enable mh@wasikarn`.
- Session: no `mh:` skills or agents; `rm -rf` on a fresh `mktemp -d` dir was **not** blocked.
  Installed, not enforcing.

## v2: install + enable (the setup script in this folder)

- marketplace add exit 0; install exit 0 (same "disabled by default" note); enable exit 0
  ("Successfully enabled plugin: mh (scope: user)").
- `claude plugin list`: mh@wasikarn 1.1.558, enabled.
- `~/.claude/settings.json` has `"enabledPlugins": { "mh@wasikarn": true }`.
- Session sees mh skills (cost-report, harness-audit, learn, memory-lint, attack-proposal,
  deep-audit, ideate, idea-audit, performance-optimizer, tech-humanize, code-architect) and mh
  subagents (backend-architect, blind-spot-hunter, ideate-critic, plan-reviewer,
  requirement-analyst, silent-failure-hunter, test-gap-analyzer, type-design-analyzer).
- Gate check: `rm -rf` on the fresh dir was blocked by a `PreToolUse:Bash` hook with
  `[mh:gate] BLOCKED: rm -rf detected — no trash CLI on this machine — ask the user before a
  destructive delete, or install one`; `ls -d` showed the dir still there. **Gates enforce.**

## What this changes

- The plugin route works in the cloud, contrary to the spec draft's premise
  (`cloud-bundle-spec-draft-2026-11-06.md`, Out of Scope: "not supported by the platform").
  A setup script with marketplace add, install and enable is enough; the vendored `.claude`
  bundle is not needed to get gates into a cloud session.
- Gap: the irrecoverable gate's fix hint suggests installing trash, which a cloud session has
  no package for by default. The setup script could install `trash-cli`, or the gate's
  message could stop suggesting it when `CLAUDE_CODE_REMOTE=true`.
- Not tested: whether a hook `ask` reaches a person in an interactive web session, unattended
  (`MH_UNATTENDED`) behaviour, setup-script time on a cold cache, and per-session cost of the
  marketplace clone.
