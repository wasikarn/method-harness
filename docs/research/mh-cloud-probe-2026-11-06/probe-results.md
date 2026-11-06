# mh cloud probe results (2026-11-06)

Question: can a Claude Code web (cloud) environment's setup script install mh so that its
skills, agents and gates run in the session? Answer: **yes, with install plus enable.**

All runs: environment `mh-probe` (network "Limited · no domains · package managers on", the
default; github.com was still reachable, so no run failed for network reasons), repo CodeKatas (not
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

## v3: first version of `scripts/cloud-setup.sh`

Same environment. That version differs from the shipped one: it also called `claude plugin
enable` for mattpocock-skills (removed since), used fixed 35 s caps, and ran a plain
`apt-get update` then `install`. After review the shipped script gives each step up to 60 s
inside a 270 s total budget (mh first, then trash-cli, then mattpocock-skills) and reuses
`.claude/hooks/session-start.sh`'s apt pattern (root or `sudo -n`, noninteractive, install
before update). Those changes were checked locally with stub commands, not re-run in the cloud.
- Every step exit 0 except that extra enable: exit 1, "already enabled". mattpocock-skills
  installs enabled; only mh needs `enable`.
- `apt-get update` and `apt-get install -y trash-cli` worked as root: `/usr/bin/trash-put`.
- `claude plugin list`: mattpocock-skills 1.3.2 and mh 1.1.558, both enabled.
- Skills from both plugins visible in the session.
- Gate check: `rm -rf` blocked with `[mh:gate] BLOCKED: rm -rf detected — use trash instead`;
  the dir survived. With trash-cli present, the gate offers the trash path, not "ask the user".
- The setup-script dialog says the result is cached so later sessions start quickly.

## What this changes

- The plugin route works in the cloud, contrary to the spec draft's premise
  (`cloud-bundle-spec-draft-2026-11-06.md`, Out of Scope: "not supported by the platform").
  A setup script with marketplace add, install and enable is enough; the vendored `.claude`
  bundle is not needed to get gates into a cloud session.
- A cloud machine has no trash CLI by default; `scripts/cloud-setup.sh` installs trash-cli, so
  the gate's own hint applies unchanged.
- Decision (operator, 2026-11-06): ship the setup script, drop the vendored-bundle plan.
- Version lag: cloud-environments docs say later sessions start from a snapshot of the setup
  script's result and the script reruns only when it or the allowed hosts change, or after
  about 7 days. So a gate fix merged to develop can take up to about 7 days to reach cloud
  sessions unless the operator edits the setup script. `scripts/cloud-setup.sh` marks a line
  for that.
- Not tested: whether a hook `ask` reaches a person in an interactive web session, unattended
  runs, and whether a cloud session started from the snapshot shows the old mh version in
  `claude plugin list` after a merge (check on the next merge).
