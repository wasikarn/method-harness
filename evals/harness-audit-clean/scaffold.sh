#!/usr/bin/env bash
mkdir -p agents skills/meta/demo/scripts hooks/gates
cat > agents/checker.md <<'FIXTURE_EOF'
---
name: checker
description: "Reviews a diff for swallowed errors. Use when a PR touches try/catch or fallbacks."
bucket: utility
tools: Read, Grep
model: sonnet
effort: low
---

Read-only reviewer; returns findings, never edits.
FIXTURE_EOF
cat > skills/meta/demo/SKILL.md <<'FIXTURE_EOF'
---
name: demo
description: "Prints the fleet's version. Use when asked which demo version is installed."
model: inherit
effort: low
---

# demo

Run `bash "${CLAUDE_SKILL_DIR}/scripts/version.sh"`.
FIXTURE_EOF
printf '#!/usr/bin/env bash\necho 1.0.0\n' > skills/meta/demo/scripts/version.sh
cat > hooks/gates/noop.sh <<'FIXTURE_EOF'
#!/usr/bin/env bash
echo "${CLAUDE_PLUGIN_ROOT:-}"
# check-74 fixture siblings (not real hooks, never invoked) -- named here so
# check 11's orphan-hook scan treats them as transitively wired, same as the
# real irrecoverable.sh -> irrecoverable.py sibling-script pattern.
_py1="$(dirname "$0")/irrecoverable.py"
_py2="$(dirname "$0")/subagent-git-guard.py"
_py3="$(dirname "$0")/subagent-spawn-guard.py"
_py4="$(dirname "$0")/task-complete-separation.py"
FIXTURE_EOF
# check 74 wants the four gate files the real plugin ships; stubs copied from tests/skills/harness-audit/known-bad/fleet-good/hooks/gates/.
cat > hooks/gates/irrecoverable.py <<'FIXTURE_EOF'
# Fixture for check 74: presence-check idiom present three times, as in the real file.
if ("agent_id" in d) and _nested_spawn(cmd):
    pass
if ("agent_id" in d) and _nested_spawn(body):
    pass
if ("agent_id" in d) and _nested_spawn(cmd, True):
    pass
FIXTURE_EOF
cat > hooks/gates/subagent-git-guard.py <<'FIXTURE_EOF'
# Fixture for check 74: presence-check idiom present, as in the real file.
if "agent_id" not in d:
    pass
FIXTURE_EOF
cat > hooks/gates/subagent-spawn-guard.py <<'FIXTURE_EOF'
# Fixture for check 74: presence-check idiom present, as in the real file.
if "agent_id" not in d:
    pass
FIXTURE_EOF
cat > hooks/gates/task-complete-separation.py <<'FIXTURE_EOF'
# Fixture for check 74: presence-check idiom present, as in the real file.
if "agent_id" not in d:
    pass
agent_id = d.get("agent_id")
FIXTURE_EOF
cat > hooks/hooks.json <<'FIXTURE_EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/gates/noop.sh\"","timeout":8}]}]}}
FIXTURE_EOF
