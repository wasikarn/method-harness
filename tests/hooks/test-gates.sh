#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal \$ in test payload strings is intentional
# Gate unit tests: simulates PreToolUse JSON payloads and asserts allow/deny/ask.
# Each test_deny call expects exit 2; test_allow expects exit 0 + empty stdout;
# test_ask expects exit 0 + a permissionDecision: ask JSON on stdout.
# Run standalone: bash tests/hooks/test-gates.sh
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Isolate the gate-verdict journal (hooks/gates/_journal.py) from this file's
# 165+ deny/ask assertions -- run standalone (this file's own header
# invites it), it would otherwise silently append rows to the operator's
# real ~/.local/share/kbg/metrics/gate-decisions.jsonl.
_JOURNAL_TMP="$(mktemp -d)"
trap 'trash "$_JOURNAL_TMP" 2>/dev/null || true' EXIT
export MH_GATE_JOURNAL_PATH="$_JOURNAL_TMP/gate-decisions.jsonl"
IRRECOVERABLE="$ROOT/hooks/gates/irrecoverable.sh"
TASK_COMPLETE="$ROOT/hooks/gates/task-complete-separation.sh"
SUBAGENT_GIT_GUARD="$ROOT/hooks/gates/subagent-git-guard.sh"
SUBAGENT_SPAWN_GUARD="$ROOT/hooks/gates/subagent-spawn-guard.sh"
ROUTINE_TRIGGER_GUARD="$ROOT/hooks/gates/routine-trigger-guard.sh"

pass=0
fail=0

# Build a minimal Bash tool payload. The command is JSON-encoded by jq (not
# printf %s) so commands containing quotes/backslashes (e.g. mysql -e "DROP
# TABLE...", find -exec ... \;) don't produce malformed JSON that silently
# degrades to an empty command downstream; -a keeps non-ASCII as \uXXXX
# escapes, as json.dumps did. Piped via stdin, not argv: a GH #140-style
# oversized command (700k chars) as a literal exec() argument exceeds Linux's
# MAX_ARG_STRLEN (128 KiB per argument, a hard kernel cap absent on macOS),
# so the tool itself fails to exec with "Argument list too long" before ever
# reaching the gate under test -- confirmed live on Ubuntu 24.04. jq reads
# stdin, and the encoded string goes to the printf builtin (no exec), so
# neither step has that limit. jq starts faster than python3.
bash_payload() { printf '{"tool_name": "Bash", "tool_input": {"command": %s}}\n' "$(printf '%s' "$1" | jq -Rsa .)"; }

# Build a Write tool payload. Uses json.dumps (see bash_payload above) so
# content containing quotes/backslashes doesn't produce malformed JSON.
write_payload() {
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]}}))' "$1" "$2"
}

# Build an Edit tool payload. Same json.dumps rationale as write_payload.
edit_payload() {
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1], "new_string": sys.argv[2]}}))' "$1" "$2"
}

# Build a TaskUpdate payload. $1=status (or empty to omit the field),
# $2=agent_type (or empty = main session, field omitted). Uses json.dumps so
# the agent_type string is safely encoded.
taskupdate_payload() {
  python3 -c '
import json, sys
status, agent, agent_id = sys.argv[1], sys.argv[2], sys.argv[3]
ti = {"taskId": "T1"}
if status:
    ti["status"] = status
d = {"tool_name": "TaskUpdate", "tool_input": ti}
if agent:
    d["agent_type"] = agent
if agent_id:
    d["agent_id"] = agent_id
print(json.dumps(d))
' "$1" "$2" "${3-$2}"
}

# Same shape as taskupdate_payload but the agent_id KEY is always forced
# present at an explicit value, including "" or JSON null -- taskupdate_payload
# above treats a falsy $3 as "omit the key" (main session shape), which cannot
# express "key present but empty/null" (GH #155: the .py gate's old `if not
# agent_id` check treated presence-with-empty/null the same as absence, same
# gap as GH #154 fixed in subagent-spawn-guard.py). $3 == "__NULL__" emits
# JSON null; anything else is used as the literal string value (including "").
taskupdate_payload_forced_id() {
  python3 -c '
import json, sys
status, agent, agent_id_raw = sys.argv[1], sys.argv[2], sys.argv[3]
ti = {"taskId": "T1"}
if status:
    ti["status"] = status
d = {"tool_name": "TaskUpdate", "tool_input": ti}
if agent:
    d["agent_type"] = agent
d["agent_id"] = None if agent_id_raw == "__NULL__" else agent_id_raw
print(json.dumps(d))
' "$1" "$2" "$3"
}

# Build a Bash tool-call payload carrying agent_id (or empty = main
# session). Separate from bash_payload() (used by many pre-existing tests
# with no agent fields at all) to avoid touching that signature.
bash_agent_payload() {
  python3 -c '
import json, sys
cmd, agent_id = sys.argv[1], sys.argv[2]
d = {"tool_name": "Bash", "tool_input": {"command": cmd}}
if agent_id:
    d["agent_id"] = agent_id
print(json.dumps(d))
' "$1" "$2"
}

# Build a Bash tool-call payload with the agent_id KEY forced present at an
# explicit value, including "" or JSON null (C1b, harness gap-audit
# 2026-09-20) -- mirrors agent_payload_forced_id() below for the Bash tool,
# needed because irrecoverable.py's two nested-spawn call sites (top-level
# command and the bash -c/eval unwrapped body) are gated on agent_id
# PRESENCE, not truthiness, and bash_agent_payload() above can't express
# "key present but empty/null" (it omits the key entirely when $2 is falsy).
# $2 == "__NULL__" emits JSON null; anything else is the literal string value.
bash_agent_payload_forced_id() {
  python3 -c '
import json, sys
cmd, agent_id_raw = sys.argv[1], sys.argv[2]
d = {"tool_name": "Bash", "tool_input": {"command": cmd}}
d["agent_id"] = None if agent_id_raw == "__NULL__" else agent_id_raw
print(json.dumps(d))
' "$1" "$2"
}

# Build an Agent tool-call payload. $1=subagent_type for the dispatch (tool_input),
# $2=agent_id of the CALLER (empty = main session), $3=agent_type of the caller
# (optional, for the deny message only — the gate's logic keys on agent_id, not
# this field, same distinction task-complete-separation.py documents).
agent_payload() {
  python3 -c '
import json, sys
subagent_type, agent_id, agent_type = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"tool_name": "Agent", "tool_input": {"prompt": "do work", "description": "task", "subagent_type": subagent_type}}
if agent_id:
    d["agent_id"] = agent_id
if agent_type:
    d["agent_type"] = agent_type
print(json.dumps(d))
' "$1" "$2" "${3-}"
}

# Build an Agent tool-call payload with the agent_id KEY forced present at an
# explicit value, including "" or JSON null -- agent_payload() above treats a
# falsy $2 as "omit the key" (main session shape), which cannot express
# "key present but empty/null" (GH #154 gap 2: the .py gate's old `if not
# agent_id` check treated presence-with-empty/null the same as absence).
# $2 == "__NULL__" emits JSON null; anything else is used as the literal string
# value (including "").
agent_payload_forced_id() {
  python3 -c '
import json, sys
subagent_type, agent_id_raw = sys.argv[1], sys.argv[2]
d = {"tool_name": "Agent", "tool_input": {"prompt": "do work", "description": "task", "subagent_type": subagent_type}}
d["agent_id"] = None if agent_id_raw == "__NULL__" else agent_id_raw
print(json.dumps(d))
' "$1" "$2"
}

# Build an Agent tool-call payload where the agent_id KEY is written as the
# JSON _ escape for the underscore (agent_id) instead of a literal
# underscore -- valid JSON decoding to the key "agent_id", but the RAW text
# never contains the substring "agent_id" (GH #154 gap 1: the .sh gate's old
# bash fast-path was a raw-text substring match performed before any JSON
# parsing, so an escaped key silently bypassed it). Built with chr(92) rather
# than a literal backslash so the escape survives untouched through argv/tool
# transports that would otherwise decode _ before it reaches this script.
agent_payload_escaped_id_key() {
  python3 -c '
key = "agent" + chr(92) + "u005f" + "id"
print("{\"tool_name\": \"Agent\", \"tool_input\": {\"prompt\": \"do work\", "
      "\"description\": \"task\", \"subagent_type\": \"general-purpose\"}, \"" + key + "\": \"agent-1\"}")
'
}

# Build a RemoteTrigger or CronCreate tool-call payload ($1 = tool name).
# $1 = tool name. $2 = action (optional -- omitted means no "action" key at all,
# to test the missing-action path separately from an empty/unrecognized one).
routine_trigger_payload() {
  if [ "$#" -ge 2 ]; then
    python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"action": sys.argv[2]}}))' "$1" "$2"
  else
    python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {}}))' "$1"
  fi
}

# Expect the gate to BLOCK (exit 2) by its own decision. A fail-closed wrapper (irrecoverable.sh) turns
# a Python crash into exit 2 too, which once hid a TypeError from every deny row (GH #245), so a
# Traceback or "internal error" on stderr fails the row.
_ERRF="$_JOURNAL_TMP/stderr"  # cleaned by the EXIT trap above
test_deny() {
  local gate="$1" desc="$2" payload="$3"
  local rc
  rc=$(echo "$payload" | bash "$gate" 2>"$_ERRF"; echo $?)
  if /usr/bin/grep -qE 'Traceback|internal error' "$_ERRF"; then
    echo "  ❌ DENY came from a crash, not the gate's own rule: $desc ($(tail -1 "$_ERRF"))" >&2
    fail=$((fail + 1))
  elif [[ "$rc" == "2" ]]; then
    echo "  ✅ DENY: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ DENY EXPECTED but got exit $rc: $desc" >&2
    fail=$((fail + 1))
  fi
}

# Expect exit 2 FROM the fail-closed wrapper after an internal error: the one case test_deny rejects.
test_deny_failclosed() {
  local gate="$1" desc="$2" payload="$3"
  local rc
  rc=$(echo "$payload" | bash "$gate" 2>"$_ERRF"; echo $?)
  if [[ "$rc" == "2" ]] && /usr/bin/grep -q 'internal error' "$_ERRF"; then
    echo "  ✅ DENY (fail-closed): $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ FAIL-CLOSED DENY EXPECTED but got exit $rc: $desc" >&2
    fail=$((fail + 1))
  fi
}

# Expect the gate to ALLOW (exit 0 + empty stdout — no permissionDecision JSON).
test_allow() {
  local gate="$1" desc="$2" payload="$3" envvar="${4:-}"
  local rc
  if [ -n "$envvar" ]; then
    rc=$(echo "$payload" | env "$envvar" bash "$gate" 2>/dev/null; echo $?)
  else
    rc=$(echo "$payload" | bash "$gate" 2>/dev/null; echo $?)
  fi
  if [[ "$rc" == "0" ]]; then
    echo "  ✅ ALLOW${envvar:+ (env)}: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ ALLOW EXPECTED but got exit $rc: $desc" >&2
    fail=$((fail + 1))
  fi
}

# Expect the gate to ASK (exit 0 + permissionDecision: ask JSON on stdout).
test_ask() {
  local gate="$1" desc="$2" payload="$3"
  local out rc
  out=$(echo "$payload" | bash "$gate" 2>/dev/null); rc=$?
  # stdout must be exactly ONE JSON object: two concatenated objects are not valid JSON (GH #254 validator).
  if [[ "$rc" == "0" ]] && printf '%s' "$out" | python3 -c 'import json,sys; assert json.loads(sys.stdin.read())["hookSpecificOutput"]["permissionDecision"] == "ask"' 2>/dev/null; then
    echo "  ✅ ASK: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ ASK EXPECTED but got exit $rc out='$out': $desc" >&2
    fail=$((fail + 1))
  fi
}

echo "=== irrecoverable gate ==="
test_deny  "$IRRECOVERABLE" "rm -rf"                    "$(bash_payload 'rm -rf /tmp/test')"
test_deny  "$IRRECOVERABLE" "rm -fr variant"            "$(bash_payload 'rm -fr /tmp/test')"
test_deny  "$IRRECOVERABLE" "git push --force"          "$(bash_payload 'git push --force origin develop')"
test_deny  "$IRRECOVERABLE" "git push -f"               "$(bash_payload 'git push -f origin develop')"
test_deny  "$IRRECOVERABLE" "--no-verify"               "$(bash_payload 'git commit --no-verify -m msg')"
test_deny  "$IRRECOVERABLE" "git reset --hard"          "$(bash_payload 'git reset --hard HEAD~1')"
test_deny  "$IRRECOVERABLE" "git clean -f"              "$(bash_payload 'git clean -f')"
test_deny  "$IRRECOVERABLE" "git clean -fd"             "$(bash_payload 'git clean -fd')"
test_allow "$IRRECOVERABLE" "safe rm (no -rf)"          "$(bash_payload 'rm /tmp/file.txt')"
test_allow "$IRRECOVERABLE" "git push no force"         "$(bash_payload 'git push origin develop')"
test_allow "$IRRECOVERABLE" "git reset soft"            "$(bash_payload 'git reset --soft HEAD~1')"
test_allow "$IRRECOVERABLE" "normal bash command"       "$(bash_payload 'ls -la')"

# Raw-substring matching produced both false positives (blocked safe commands merely mentioning
# a pattern in quoted text) and bypasses (quoted/tokenization tricks slipped past the regex).
test_allow "$IRRECOVERABLE" "grep for rm -rf text (was a false positive)" \
  "$(bash_payload 'grep -rn "rm -rf" scripts/')"
test_allow "$IRRECOVERABLE" "commit msg mentioning rm -rf (was a false positive)" \
  "$(bash_payload 'git commit -m "docs: warn against rm -rf usage"')"
test_deny  "$IRRECOVERABLE" "quoted rm word (was a bypass)" \
  "$(bash_payload "'rm' -rf /tmp/x")"
test_deny  "$IRRECOVERABLE" "find -exec rm (was a bypass)" \
  "$(bash_payload 'find /tmp/x -exec rm {} \;')"
test_deny  "$IRRECOVERABLE" "git checkout -- discards changes (was a bypass)" \
  "$(bash_payload 'git checkout -- .')"
test_deny  "$IRRECOVERABLE" "git switch --force (was a bypass)" \
  "$(bash_payload 'git switch --force main')"
test_deny  "$IRRECOVERABLE" "git commit --amend (was a bypass)" \
  "$(bash_payload 'git commit --amend')"
test_deny  "$IRRECOVERABLE" "dd to raw device (was a bypass)" \
  "$(bash_payload 'dd if=/dev/zero of=/dev/disk2')"
test_deny  "$IRRECOVERABLE" "SQL DROP TABLE (was a bypass)" \
  "$(bash_payload 'mysql -e "DROP TABLE users"')"
# H3 (harness gap-audit, 2026-09-20): the same DROP/TRUNCATE check names all
# four SQL clients (line 938's argv0 tuple) but only mysql had a test.
test_deny  "$IRRECOVERABLE" "SQL DROP DATABASE via psql (H3, was untested)" \
  "$(bash_payload 'psql -c "DROP DATABASE x"')"
test_deny  "$IRRECOVERABLE" "SQL DROP TABLE via sqlite3 (H3, was untested)" \
  "$(bash_payload 'sqlite3 db.sqlite "DROP TABLE users"')"
test_deny  "$IRRECOVERABLE" "SQL TRUNCATE via mariadb (H3, was untested)" \
  "$(bash_payload 'mariadb -e "TRUNCATE orders"')"
# Rule shapes a mutation run showed no row pinned (each mutant survived the whole file).
test_deny  "$IRRECOVERABLE" "rm -Rf: the capital-R recursive flag" \
  "$(bash_payload 'rm -Rf /tmp/test')"
test_deny  "$IRRECOVERABLE" "find -execdir rm: the -execdir action, not just -exec" \
  "$(bash_payload 'find /tmp/x -execdir rm {} \;')"
test_deny  "$IRRECOVERABLE" "git push -uf: a force flag bundled with other short flags" \
  "$(bash_payload 'git push -uf origin develop')"
test_deny  "$IRRECOVERABLE" "mysql -e drop table: the SQL verb in lower case" \
  "$(bash_payload 'mysql -e "drop table users"')"
test_deny  "$IRRECOVERABLE" "psql -c DROP SCHEMA: a schema drop, not just table/database" \
  "$(bash_payload 'psql -c "DROP SCHEMA public CASCADE"')"
test_deny  "$IRRECOVERABLE" "git config core.HooksPath: the hook-bypass key in any case" \
  "$(bash_payload 'git config core.HooksPath /dev/null')"
test_deny  "$IRRECOVERABLE" "git add -A (was prose-only)" \
  "$(bash_payload 'git add -A')"
test_deny  "$IRRECOVERABLE" "git add . (was prose-only)" \
  "$(bash_payload 'git add .')"
test_allow "$IRRECOVERABLE" "git add named file (must not over-block)" \
  "$(bash_payload 'git add foo.txt')"
# GH #200: --pathspec-from-file's VALUE is a pathspec list the gate cannot read, so any use denies
# (same policy as restore/checkout above).
test_deny  "$IRRECOVERABLE" "GH #200: git add --pathspec-from-file <(...) can stage everything" \
  "$(bash_payload 'git add --pathspec-from-file <(printf .)')"
test_deny  "$IRRECOVERABLE" "GH #200: git add --pathspec-from-file=<file> can stage everything" \
  "$(bash_payload 'git add --pathspec-from-file=paths.txt')"
test_deny  "$IRRECOVERABLE" "GH #200: git add --pathspec-from-file=- reads stdin pathspecs" \
  "$(bash_payload 'git add --pathspec-from-file=-')"
# GH #290: doas is a privilege wrapper like sudo; its -u/-C take a value.
for _c in "doas rm -rf x" "doas git reset --hard" "doas git add -A" "doas -u root rm -rf x" \
          "doas -n rm -rf x" "doas -C /etc/doas.conf rm -rf x" "doas -uroot rm -rf x" \
          "echo hi && doas rm -rf x"; do
  test_deny  "$IRRECOVERABLE" "GH #290: $_c is judged like the bare command" "$(bash_payload "$_c")"
done
for _c in "doas ls /root" "doas -u root cat x" "doas git status"; do
  test_allow "$IRRECOVERABLE" "GH #290 control: $_c is benign, must not over-block" "$(bash_payload "$_c")"
done
# GH #289: whole-tree pathspec spellings stage everything like a bare `.`; named paths stay allowed.
for _c in "git add :/" "git add ':/'" "git add '*'" "git add '**'" "git add ./" "git add ':(top)'" \
          "git add ':/*'" "git add ':(top,glob)**'" "git add -f '*'"; do
  test_deny  "$IRRECOVERABLE" "GH #289: $_c stages the whole tree" "$(bash_payload "$_c")"
done
for _c in "git add :/foo.txt" "git add ':(top)foo.txt'" "git add src/*.py" "git add ./foo.txt" "git add '*.md'"; do
  test_allow "$IRRECOVERABLE" "GH #289 control: $_c names a path, must not over-block" "$(bash_payload "$_c")"
done
# GH #308: more spellings real git (git add -n, checked in a temp repo) treats as the whole tree:
# dot components joined by one or more slashes, a "./*" glob, and exclude-only pathspecs.
for _c in "git add ./." "git add ././" "git add .//" "git add .//." "git add ./**" "git add './*'" "git add './**'" \
          "git add ':!x'" "git add ':^x'" "git add ':(exclude)x'" "git add ':(top,exclude)x'" "git add ':(exclude,top)x'" \
          "git add ':!x' ':!y'" "git add -f ':!x'" "git add -- ':!x'" "git add --chmod=+x ':!x'" "git add --chmod +x ':!x'" \
          "git add :!x" "git add :^x" "git add ':'" "git add '::'" "git add ':' src" "git add ':.'" "git add ':./'" "git add ':*'" "git add ':***'"; do
  test_deny  "$IRRECOVERABLE" "GH #308: $_c stages the whole tree" "$(bash_payload "$_c")"
done
# Narrow shapes stay allowed: a positive pathspec beside an exclude, dotfile globs, `.` inside a name,
# and the top-anchored dot forms that select nothing in real git.
for _c in "git add src/a.txt" "git add ./a.txt" "git add .gitignore" "git add ./.gitignore" "git add src ':!x'" \
          "git add ':!x' src" "git add ':(exclude)x' src/a.txt" "git add -- src ':!x'" "git add ./src/." "git add '.*'" \
          "git add ./.env" "git add ./sub//a.txt" "git add -- ./a.txt" "git add :!x src" "git add src :^x" "git add :/src/a.txt" "git add -- ':!x' -weird"; do
  test_allow "$IRRECOVERABLE" "GH #308 control: $_c names a path, must not over-block" "$(bash_payload "$_c")"
done
# GH #315: real git (git add -n, 7-file temp repo) collapses "x/.." lexically, so a name then ".."
# is the whole tree; so are the magic-colon combos below. ".." alone names an ancestor dir.
for _c in "git add src/.." "git add sub/.." "git add '*/..'" "git add src/../" "git add src/../." "git add ./src/.." \
          "git add src//.." "git add src/./.." "git add sub/deep/../.." "git add nonexist/.." "git add 'src/../*'" \
          "git add '**/..'" "git add '.../..'" "git add a.txt/.." "git add ':(glob)src/..'" "git add ':(literal)*/..'" \
          "git add -- src/.." "git add -f src/.. a.txt" "git add '::.'" "git add '://'" "git add ':///*'" "git add ':/^.'" \
          "git add ':/!x'" "git add ':/:'" "git add '::*'" "git add .." "git add ../" "git add 'src\\/..'" \
          "git add '?*'" "git add '*?'" "git add './.*//../?*'" "git add ':(top,glob)***/*'" "git add ':(glob)**/**'" \
          "git add ':(glob)**/?*'"; do
  test_deny  "$IRRECOVERABLE" "GH #315: $_c stages the whole tree" "$(bash_payload "$_c")"
done
for _c in "git add src/../a.txt" "git add sub/deep/.." "git add src/.../.." "git add ../foo.txt" "git add 'src/..x'" \
          "git add src/..." "git add ':/::'" "git add '://x'" "git add ':!x' src/.../.." "git add ./sub/../a.txt" "git add '?'" "git add '*?.txt'" \
          "git add '**/*'" "git add ':(glob)*/**'" "git add ':(glob)*/*'"; do
  test_allow "$IRRECOVERABLE" "GH #315 control: $_c names a path, must not over-block" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "git checkout branch (must not over-block)" \
  "$(bash_payload 'git checkout main')"
test_allow "$IRRECOVERABLE" "git checkout -m --conflict merge feature: the style word is an option value, not a path" \
"$(bash_payload 'git checkout -m --conflict merge feature')"
test_allow "$IRRECOVERABLE" "git checkout --conflict diff3 feature" \
"$(bash_payload 'git checkout --conflict diff3 feature')"
test_deny  "$IRRECOVERABLE" "git checkout --conflict merge <tree> <path> still discards" \
"$(bash_payload 'git checkout --conflict merge HEAD~1 file')"
test_deny  "$IRRECOVERABLE" "git checkout --conflict=merge <tree> <path> still discards" \
"$(bash_payload 'git checkout --conflict=merge HEAD~1 file')"
test_allow "$IRRECOVERABLE" "git checkout -b new branch (must not over-block)" \
  "$(bash_payload 'git checkout -b new-branch')"
test_allow "$IRRECOVERABLE" "git checkout -b new branch from start-point (create, not tree+path)" \
  "$(bash_payload 'git checkout -b feat origin/develop')"
test_deny  "$IRRECOVERABLE" "git checkout -b with tree-ish AND path still denied" \
  "$(bash_payload 'git checkout -b feat HEAD~1 file.txt')"
# The force check only matched the exact token "-f"/ "--force", missing a bundled short-flag
# cluster like "-qf" (quiet+force).
test_deny "$IRRECOVERABLE" "git checkout -qf bundled force flag (was a bypass)" \
  "$(bash_payload 'git checkout -qf other-branch')"
test_deny "$IRRECOVERABLE" "git switch -fq bundled force flag (was a bypass)" \
  "$(bash_payload 'git switch -fq other-branch')"
# The fix scans bundled clusters for "f" but must stop at a value-taking flag letter (checkout's
# -b/-B, switch's -c/-C) so the branch-name argument itself isn't misread as more bundled flags.
test_allow "$IRRECOVERABLE" "git checkout -bfoo (branch name starting with f, must not over-block)" \
  "$(bash_payload 'git checkout -bfoo')"
test_allow "$IRRECOVERABLE" "git switch -cfoo (branch name starting with f, must not over-block)" \
  "$(bash_payload 'git switch -cfoo')"
test_allow "$IRRECOVERABLE" "git checkout -Bfoo (uppercase stop-char variant, must not over-block)" \
  "$(bash_payload 'git checkout -Bfoo')"
test_allow "$IRRECOVERABLE" "git switch -Cfoo (uppercase stop-char variant, must not over-block)" \
  "$(bash_payload 'git switch -Cfoo')"
# A HEREDOC-authored commit message (this repo's own documented convention) that merely mentions
# "git checkout X Y" in prose was tokenized as a real command and falsely denied.
test_allow "$IRRECOVERABLE" "quoted-delimiter heredoc body mentioning checkout no longer false-blocks" \
  "$(bash_payload $'git commit -m "$(cat <<\'EOF\'\nthis mentions git checkout old new extra in prose\nEOF\n)"')"
test_deny "$IRRECOVERABLE" "dangerous cmd inside a heredoc feeding an interpreter still blocked" \
  "$(bash_payload $'bash <<EOF\nrm -rf /tmp/danger\nEOF')"
# Newline and '&' are command separators in bash but shlex ate newline as whitespace and '&'
# wasn't in OPERATORS — a dangerous command after either hid inside the first command's window.
test_deny  "$IRRECOVERABLE" "dangerous cmd after newline" \
  "$(bash_payload $'echo hi\nrm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "dangerous cmd after & (background)" \
  "$(bash_payload 'echo done & rm -rf /tmp/x')"

# A backslash-newline inside a "#" comment is not a continuation: the newline still separates.
test_deny  "$IRRECOVERABLE" "backslash-newline inside a # comment does not hide the next real command (exact repro)" \
  "$(bash_payload $'git status # comment \\\ngit push origin develop --force')"
test_deny  "$IRRECOVERABLE" "same shape, comment with no trailing backslash (pre-existing case, must stay denied)" \
  "$(bash_payload $'git status # comment\ngit push origin develop --force')"
test_deny  "$IRRECOVERABLE" "real backslash-newline continuation (no comment) still joins tokens for detection" \
  "$(bash_payload $'git push --force \\\n  origin develop')"
test_allow "$IRRECOVERABLE" "legit backslash-newline continuation outside a comment still allows (no false split)" \
  "$(bash_payload $'git log --oneline \\\n  -5')"

# A backslash-newline continuation with NO leading whitespace on the continuation line bypassed
# force-push detection.
test_deny  "$IRRECOVERABLE" "backslash-newline continuation with NO leading whitespace on the next line (exact repro, was a bypass)" \
  "$(bash_payload $'git push \\\n--force origin develop')"
test_deny  "$IRRECOVERABLE" "same shape, leading whitespace on the next line (already worked, stays denied)" \
  "$(bash_payload $'git push \\\n  --force origin develop')"
# Adjacent shapes: back-to-back continuations gluing flags, and a trailing continuation.
test_deny  "$IRRECOVERABLE" "two whitespace-less continuations back to back, force flag glued onto the second (adjacent-shape check)" \
  "$(bash_payload $'git push origin\\\ndevelop --for\\\nce')"
test_allow "$IRRECOVERABLE" "trailing whitespace-less continuation at the very end of the command, nothing after it (no crash, no dangerous token)" \
  "$(bash_payload $'git push origin develop\\\n')"
# The DQ-quoted branch of _newlines_to_seps had the identical unremoved- newline defect for a
# continuation inside a double-quoted string (bash strips backslash-newline there too).
test_deny  "$IRRECOVERABLE" "whitespace-less continuation inside a double-quoted flag still reassembles (adjacent-shape check)" \
  "$(bash_payload $'git push "--for\\\nce" origin develop')"
test_deny  "$IRRECOVERABLE" "trailing # comment on the same line does not hide the command before it" \
  "$(bash_payload 'git push origin develop --force # not a real flag, just a comment')"

# ANSI-C ($'...') quoting resolves escape sequences in real bash.
test_deny "$IRRECOVERABLE" "ANSI-C quoted argv0 splice (gi\$'\x74' push --force, was a bypass)" \
  "$(bash_payload "gi\$'\\x74' push --force origin develop")"
# Negative control 1: an ordinary single-quoted argument (no \$'...' form, never enters the
# ANSI-C regex at all) must stay correctly classified.
test_allow "$IRRECOVERABLE" "ordinary single-quoted commit message unaffected by ANSI-C normalization" \
  "$(bash_payload "git commit -m 'a normal message'")"
# Negative control 2: a REAL \$'...' payload that DOES enter the new decode path.
test_allow "$IRRECOVERABLE" "ANSI-C commit message with embedded \\n stays one window, not force-push (real decode-path exercise)" \
  "$(bash_payload $'git commit -m $\'line1\\nline2\'')"

# A command-substitution splice (backtick or \$(...)) vanishes in real bash once its output
# splices into the surrounding text.
test_deny "$IRRECOVERABLE" "argv0-level backtick splice (gi\`true\`t push --force, GH #129)" \
  "$(bash_payload 'gi`true`t push --force origin develop')"
test_deny "$IRRECOVERABLE" "git-subcommand-level backtick splice (git pu\`true\`sh --force, clean argv0 but spliced sub, GH #129)" \
  "$(bash_payload 'git pu`true`sh --force')"
test_deny "$IRRECOVERABLE" "argv0-level \$(...) splice, different KNOWN_DANGEROUS candidate (gi\$(true)t reset --hard, GH #129)" \
  "$(bash_payload 'gi$(true)t reset --hard')"
# Negative controls: the duplication must not over-deny.
test_allow "$IRRECOVERABLE" "substitution in an ARGUMENT, not the dispatch token (ls \$(pwd)) -- argv0 stays clean, never enters duplication" \
  "$(bash_payload 'ls $(pwd)')"
test_allow "$IRRECOVERABLE" "substitution IS the whole dispatch token but resolves to a benign subcommand (\$(which git) status)" \
  "$(bash_payload '$(which git) status')"
test_allow "$IRRECOVERABLE" "substitution IS the dispatch token, candidate set has no dangerous match (\$(command -v ls) -la)" \
  "$(bash_payload '$(command -v ls) -la')"
test_allow "$IRRECOVERABLE" "argv0-level \$(...) splice resolving to a benign git subcommand (gi\$(true)t status, proves duplication does not over-deny)" \
  "$(bash_payload 'gi$(true)t status')"
test_allow "$IRRECOVERABLE" "ordinary bare \$VAR usage stays untouched by the placeholder pass (git push \$REMOTE \$BRANCH)" \
  "$(bash_payload 'git push $REMOTE $BRANCH')"
# Blanking a substitution SPAN must not DISCARD its body.
test_deny "$IRRECOVERABLE" "substitution BODY is the dangerous command, not just the dispatch token (echo \$(git push --force), was silently allowed by a blank-only pass)" \
  "$(bash_payload 'echo $(git push --force)')"
test_allow "$IRRECOVERABLE" "re-appended substitution body is ordinary commit-message prose, not a command (git commit -m \"\$(cat msg.txt)\") -- proves body re-append does not false-deny" \
  "$(bash_payload 'git commit -m "$(cat msg.txt)"')"
# A SINGLE-quoted $(...) is inert in bash and must not be extracted as a body; a DOUBLE-quoted
# one is live and must still be caught.
test_allow "$IRRECOVERABLE" "single-quoted \$(...) is inert prose, must not be extracted and re-denied (git commit -m single-quote prose mentioning \$(git push --force))" \
  "$(bash_payload "git commit -m 'prose mentioning \$(git push --force)'")"
test_deny "$IRRECOVERABLE" "double-quoted argv0 splice stays a live vector, not given the single-quote passthrough (\"gi\$(true)t\" push --force)" \
  "$(bash_payload '"gi$(true)t" push --force')"

# An apostrophe inside a blanked substitution body raises ValueError in shlex; the old raw
# cmd.split() fallback carried no PH, so the splice was silently allowed.
test_deny "$IRRECOVERABLE" "backtick splice with an apostrophe inside the body defeats the old raw cmd.split() fallback (gi\`it's\`t push --force, was silently ALLOWed)" \
  "$(bash_payload $'gi`it\'s`t push --force')"
test_deny "$IRRECOVERABLE" "\$(...) splice with an apostrophe inside the body, same bypass shape (gi\$(it's)t push --force, was silently ALLOWed)" \
  "$(bash_payload $'gi$(it\'s)t push --force')"

# Bug 2 (false-DENY): the KNOWN_DANGEROUS/KNOWN_GIT_SUBS candidate duplication runs every
# candidate's check against the SAME rest/scan tokens, and two of those checks were bare letter-
# containment against a whole joined-flags string rather than a real flag-boundary test.
test_allow "$IRRECOVERABLE" "substitution dispatch token resolving to a benign command, long flag falsely read as rm -rf (\$(which node) --before=1, was a false DENY)" \
  "$(bash_payload '$(which node) --before=1')"
test_allow "$IRRECOVERABLE" "git diff splice, long flag falsely read as git clean -f (git di\$(true)ff --find-renames, was a false DENY)" \
  "$(bash_payload 'git di$(true)ff --find-renames')"
test_allow "$IRRECOVERABLE" "git show splice, long flag falsely read as git clean -f (git sh\$(true)ow --format=fuller, was a false DENY)" \
  "$(bash_payload 'git sh$(true)ow --format=fuller')"

# The _SQ_SPAN regex used to detect inert single-quoted text paired literal apostrophe
# CHARACTERS wherever they fell, with zero notion of real shell quote state.
test_deny "$IRRECOVERABLE" "contraction apostrophes inside double quotes pair up ACROSS a real \$(...) splice, hiding it as inert single-quoted data (was a live bypass)" \
  "$(bash_payload $'echo "it\'s" ; gi$(true)t push --force ; echo "isn\'t"')"
test_allow "$IRRECOVERABLE" "same stray contraction apostrophe shifts pairing so a REAL single-quoted -m argument is no longer matched as one span (was a false DENY of inert commit-message text)" \
  "$(bash_payload $'echo "it\'s" ; git commit -m \'see $(git push --force)\'')"

# "$(true)-rf" IS "-rf" in bash but blanks to "PH-rf", which no longer starts with "-", so every
# flag-shape check missed it; PH is stripped before each such check.
test_deny "$IRRECOVERABLE" "empty-substitution splice hides rm -rf's dash (rm \$(true)-rf /tmp/x, was silently ALLOWed)" \
  "$(bash_payload 'rm $(true)-rf /tmp/x')"
test_deny "$IRRECOVERABLE" "same bug via backticks (rm \`true\`-rf /tmp/x, was silently ALLOWed)" \
  "$(bash_payload 'rm `true`-rf /tmp/x')"
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git push --force's dashes (git push \$(true)--force, was silently ALLOWed)" \
  "$(bash_payload 'git push $(true)--force')"
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git clean -f's dash (git clean \$(true)-f, was silently ALLOWed)" \
  "$(bash_payload 'git clean $(true)-f')"
# Negative control: the substitution sits inside a QUOTED ARGUMENT VALUE (a real -m message),
# not in flag position.
test_allow "$IRRECOVERABLE" "substitution inside a quoted -m message value, not a bare flag position (git commit -m \"\$(cat msg.txt)\") -- must stay ALLOW" \
  "$(bash_payload 'git commit -m "$(cat msg.txt)"')"

# The $(...)/${...} closer-search used to stop at the FIRST ")" byte, not the matching one, so
# a nested paren left the span un-blanked.
test_deny "$IRRECOVERABLE" "nested function-construct inside \$(...) defeats the old first-byte closer-search, real bash resolves to git push --force (GH #139, was a silent bypass)" \
  "$(bash_payload 'gi$(f() { :; }; f)t push --force origin develop')"

# Companion DoS check for the same fix: depth-counting a closer-search that never balances (an
# adversarial flood of unclosed "$(" starts) must stay bounded by a work budget instead of
# costing O(remaining length) PER start.
DEPTH_FLOOD_CMD=$(python3 -c 'print("$(" * 50000)')
depth_flood_start=$(date +%s)
depth_flood_out=$(bash_payload "$DEPTH_FLOOD_CMD" | timeout 10 bash "$IRRECOVERABLE" 2>/dev/null)
depth_flood_rc=$?
depth_flood_elapsed=$(( $(date +%s) - depth_flood_start ))
if [[ "$depth_flood_rc" == "2" ]] && [ "$depth_flood_elapsed" -le 10 ]; then
  echo "  ✅ DENY: 50,000x unclosed \"\$(\" flood completes within a generous ceiling (GH #139 fail-closed budget-exhaustion fix)"
  pass=$((pass + 1))
else
  echo "  ❌ depth-scan work-budget expected fast deny but got rc=$depth_flood_rc elapsed=${depth_flood_elapsed}s out='$depth_flood_out'" >&2
  fail=$((fail + 1))
fi

# Leading-PH strip applied to every flag check (Layer 1), the wrapper/re-pointing loops
# (Layer 2), and standalone vanish tokens compacted out (Layer 3).
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git stash drop (git stash \$(true)drop, was silently ALLOWed)" \
  "$(bash_payload 'git stash $(true)drop')"
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git stash clear (git stash \$(true)clear, was silently ALLOWed)" \
  "$(bash_payload 'git stash $(true)clear')"
test_deny "$IRRECOVERABLE" "baseline: plain git stash drop, no splice at all (must still deny)" \
  "$(bash_payload 'git stash drop')"
test_deny "$IRRECOVERABLE" "baseline: plain git stash clear, no splice at all (must still deny)" \
  "$(bash_payload 'git stash clear')"
# A splice landing mid-basename or mid-SQL-keyword needs full PH removal, not a leading strip.
test_deny "$IRRECOVERABLE" "empty-substitution splice hides dd's of=/dev/ prefix (was silently ALLOWed)" \
  "$(bash_payload 'dd if=/dev/zero $(true)of=/dev/sda')"
test_deny "$IRRECOVERABLE" "baseline: plain dd of=/dev, no splice (must still deny)" \
  "$(bash_payload 'dd if=/dev/zero of=/dev/sda')"
test_deny "$IRRECOVERABLE" "splice lands mid-keyword in a destructive SQL statement (DR\$(true)OP TABLE, was silently ALLOWed -- the old check only handled a LEADING splice, not one INSIDE a keyword)" \
  "$(bash_payload 'mysql -e "DR$(true)OP TABLE users"')"
test_deny "$IRRECOVERABLE" "baseline: plain destructive SQL, no splice (must still deny)" \
  "$(bash_payload 'mysql -e "DROP TABLE users"')"
# --- Layer 2, exhaustive-grep finds: the prefix-wrapper unwrap loops
# (env/nice/sudo/command/nohup/time) and the xargs/docker-exec re-pointing never stripped a
# leading PH from the flags they read either.
test_deny "$IRRECOVERABLE" "docker exec flag splice defeats the inner-command re-point, hiding destructive SQL (docker exec \$(true)-i c1 mysql -e DROP TABLE, was silently ALLOWed)" \
  "$(bash_payload 'docker exec $(true)-i c1 mysql -e "DROP TABLE users"')"
test_deny "$IRRECOVERABLE" "docker exec-itself splice defeats the inner-command re-point, hiding destructive SQL (docker \$(true)exec c1 mysql -e DROP TABLE, was silently ALLOWed)" \
  "$(bash_payload 'docker $(true)exec c1 mysql -e "DROP TABLE users"')"
# --- Layer 3: a standalone unquoted vanish token shifts fixed-index reads.
test_allow "$IRRECOVERABLE" "Layer 3 negative control: \$(which git) status -- compacted window drops argv0 entirely, must stay ALLOW" \
  "$(bash_payload '$(which git) status')"

# Appending recovered substitution bodies with a plain " ; " separator left no newline to
# terminate an earlier, still-open "#" comment.
test_deny "$IRRECOVERABLE" "trailing comment after a live substitution buried the recovered body in an open shlex comment (echo \$(git push --force)  # push it, was silently ALLOWed)" \
  "$(bash_payload 'echo $(git push --force)  # push it')"
test_deny "$IRRECOVERABLE" "same bug via a # embedded inside an EARLIER recovered body (echo \$(echo hi # note) \$(git push --force), was silently ALLOWed)" \
  "$(bash_payload 'echo $(echo hi # note) $(git push --force)')"
test_deny "$IRRECOVERABLE" "baseline: same splice with no comment at all, no bug involved (must stay denied)" \
  "$(bash_payload 'echo $(git push --force)')"

# Finding 5 (MEDIUM, live, universal): _scan_once tracked in_squote/ in_dquote but had no
# in_comment state, so a substitution-shaped string sitting INSIDE a real "#" comment still got
# matched, blanked, and its body collected as if it were live code.
test_allow "$IRRECOVERABLE" "a substitution-shaped fake payload sitting inside a real # comment must not be recovered as a live body (git status # see also: \$(git push --force), followed by a real newline and echo done, was a false DENY)" \
  "$(bash_payload $'git status # see also: $(git push --force)\necho done\n')"

# The closer-search does not track quotes INSIDE a span, so a span crossing a quote char left a
# valid command unbalanced and falsely denied; re-parse of the original cmd tells the cases apart.
test_allow "$IRRECOVERABLE" "read-only python3 heredoc with an unmatched \${ inside a properly-quoted string desyncs _blank_substitutions own quote tracking (was a false DENY with no override)" \
  "$(bash_payload $'python3 - <<\'PY\'\n "10k unmatched ${ (20KB)": "${ "*10000,\n}\nPY\n')"
# Negative control: a genuinely malformed command (unterminated quote, no _scan_once span
# involved at all) must still deny with the same message.
test_deny "$IRRECOVERABLE" "genuinely malformed command, unterminated quote unrelated to any substitution span (must still deny)" \
  "$(bash_payload "echo 'unterminated")"
# Negative control: the two GH #129 apostrophe-in-body bypass tests already above
# (backtick/\$(...) splice with an apostrophe inside the recovered body) must still deny.
test_deny "$IRRECOVERABLE" "Finding 4 fix must not reopen the GH #129 apostrophe-in-body bypass, backtick form (gi\`it's\`t push --force, must stay DENY)" \
  "$(bash_payload $'gi`it\'s`t push --force')"
test_deny "$IRRECOVERABLE" "Finding 4 fix must not reopen the GH #129 apostrophe-in-body bypass, \$(...) form (gi\$(it's)t push --force, must stay DENY)" \
  "$(bash_payload $'gi$(it\'s)t push --force')"

# The fallback split must be separator-aware: a bare cmd.split() glued "};git" into one token.
test_deny "$IRRECOVERABLE" "Finding 4 fallback must not glue a dangerous SECOND command onto its no-space ; separator (echo \${y:-\"a}b\"};git push --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"};git push --force')"
test_deny "$IRRECOVERABLE" "same bug via a no-space && separator (echo \${y:-\"a}b\"}&&git push --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"}&&git push --force')"
test_deny "$IRRECOVERABLE" "baseline: same compound command with the ; surrounded by whitespace, no bug involved (must stay denied)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; git push --force')"

# A splice reaching only the fallback path carries raw substitution syntax, no PH; duplication
# also fires on raw syntax.
test_deny "$IRRECOVERABLE" "Finding 4 fallback duplication trigger missed a spliced ARGV0 with no PH (echo \${y:-\"a}b\"} ; gi\$(true)t push --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; gi$(true)t push --force')"
test_deny "$IRRECOVERABLE" "same bug, spliced git SUBCOMMAND instead of argv0 (echo \${y:-\"a}b\"} ; git pu\$(true)sh --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; git pu$(true)sh --force')"
test_deny "$IRRECOVERABLE" "same argv0 bug with the dangerous command BEFORE the quote-crossing span (gi\$(true)t push --force ; echo \${y:-\"a}b\"}, was silently ALLOWed)" \
  "$(bash_payload 'gi$(true)t push --force ; echo ${y:-"a}b"}')"
test_deny "$IRRECOVERABLE" "same subcommand bug with the dangerous command BEFORE the quote-crossing span (git pu\$(true)sh --force ; echo \${y:-\"a}b\"}, was silently ALLOWed)" \
  "$(bash_payload 'git pu$(true)sh --force ; echo ${y:-"a}b"}')"
# Negative controls: the widened trigger must not over-deny once the fallback path is live.
test_allow "$IRRECOVERABLE" "fallback-path splice resolving to a benign git subcommand (echo \${y:-\"a}b\"} ; gi\$(true)t status, must stay ALLOW even though duplication tries argv0==git -- the quote-crossing span forces the fallback so this token never gets PH at all, only _has_raw_subst catches it)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; gi$(true)t status')"

# The fallback path must tokenize the SAME blanked pipeline as the primary path, or every
# downstream PH-based check is blind on it.
FORCE_FALLBACK='echo ${y:-"a}b"} ; '
test_deny "$IRRECOVERABLE" "sweep: docker exec re-point splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}docker exec \$(true)-i c1 mysql -e \"DROP TABLE users\"")"
test_deny "$IRRECOVERABLE" "sweep: rm -rf leading-dash splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}rm \$(true)-rf /tmp/x")"
test_deny "$IRRECOVERABLE" "sweep: find -exec splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}find /tmp/x \$(true)-exec rm {} \\;")"
test_deny "$IRRECOVERABLE" "sweep: find -delete splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}find /tmp/x \$(true)-delete")"
test_deny "$IRRECOVERABLE" "sweep: git --no-verify splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git commit \$(true)--no-verify -m msg")"
test_deny "$IRRECOVERABLE" "sweep: git push --force splice reaching scan, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git push \$(true)--force origin develop")"
test_deny "$IRRECOVERABLE" "sweep: git clean -f splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git clean \$(true)-f")"
test_deny "$IRRECOVERABLE" "sweep: git stash drop splice on args[0], fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git stash \$(true)drop")"
test_deny "$IRRECOVERABLE" "sweep: dd of=/dev splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}dd if=/dev/zero \$(true)of=/dev/sda")"
test_deny "$IRRECOVERABLE" "sweep: SQL DROP mid-keyword splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}mysql -e \"DR\$(true)OP TABLE users\"")"
# Negative controls: the systemic fallback-blanking fix must not over-deny.
test_allow "$IRRECOVERABLE" "sweep neg: benign command after a forced fallback (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}ls -la")"
test_allow "$IRRECOVERABLE" "sweep neg: git status after a forced fallback (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}git status")"
test_allow "$IRRECOVERABLE" "sweep neg: git push safe after a forced fallback (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}git push origin develop")"
test_allow "$IRRECOVERABLE" "sweep neg: commit message mentioning rm -rf, fallback path (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}git commit -m \"docs: warn against rm -rf\"")"

# A PH/raw-subst splice landing MID-FLAG (not leading) defeated every flag-recovery check
# written as "t.lstrip(PH) == '--force'".
test_deny "$IRRECOVERABLE" "mid-flag splice, git push --force (--for\$(true)ce, was silently ALLOWed)" \
  "$(bash_payload 'git push --for$(true)ce origin develop')"
test_deny "$IRRECOVERABLE" "mid-flag splice, git reset --hard (--har\$(true)d, was silently ALLOWed)" \
  "$(bash_payload 'git reset --har$(true)d HEAD~1')"
test_deny "$IRRECOVERABLE" "mid-flag splice, git commit --amend (--am\$(true)end, was silently ALLOWed)" \
  "$(bash_payload 'git commit --am$(true)end -m x')"
test_deny "$IRRECOVERABLE" "mid-flag splice reaches the flag check via the fallback path too, not just the primary shlex path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git push --for\$(true)ce origin develop")"
# Negative controls: the same flags with no splice at all must stay denied exactly as before.
test_deny "$IRRECOVERABLE" "baseline: plain --force with no splice still denies (unaffected by the fix)" \
  "$(bash_payload 'git push --force origin develop')"
test_deny "$IRRECOVERABLE" "baseline: plain --hard with no splice still denies (unaffected by the fix)" \
  "$(bash_payload 'git reset --hard HEAD~1')"
test_deny "$IRRECOVERABLE" "baseline: plain --amend with no splice still denies (unaffected by the fix)" \
  "$(bash_payload 'git commit --amend -m x')"

test_allow "$IRRECOVERABLE" "git push --force-with-lease (safe variant)" \
  "$(bash_payload 'git push --force-with-lease origin develop')"
test_allow "$IRRECOVERABLE" "git push --force-with-lease with refspec (still safe)" \
  "$(bash_payload 'git push --force-with-lease=main:12345 origin develop')"
test_allow "$IRRECOVERABLE" "git push --force-with-lease --force-if-includes (safest variant)" \
  "$(bash_payload 'git push --force-with-lease --force-if-includes origin develop')"
test_allow "$IRRECOVERABLE" "git push normal (no force)" \
  "$(bash_payload 'git push origin develop')"

# A leading git GLOBAL flag (-C/-c/--git-dir/--work-tree/ --config-env, bare or
# combined -Cpath/--git-dir=path) set sub to the flag itself, so the push/worktree/--no-verify
# gates were bypassable by prefixing it.
test_deny "$IRRECOVERABLE" "git -C /repo push --force (global-flag bypass)" \
  "$(bash_payload 'git -C /repo push --force origin develop')"
test_deny "$IRRECOVERABLE" "git -Cpath push --force (combined -C)" \
  "$(bash_payload 'git -C/repo push --force origin develop')"
test_deny "$IRRECOVERABLE" "git --no-pager push --force (non-value global)" \
  "$(bash_payload 'git --no-pager push --force origin develop')"
test_deny "$IRRECOVERABLE" "git -c key=val push --force (value global -c)" \
  "$(bash_payload 'git -c core.foo=bar push --force origin develop')"
test_allow "$IRRECOVERABLE" "git -C /repo status (global flag, safe sub)" \
  "$(bash_payload 'git -C /repo status')"
test_allow "$IRRECOVERABLE" "git -C /repo log (no sub after globals→no-op safe)" \
  "$(bash_payload 'git -C /repo')"
test_deny "$IRRECOVERABLE" "--no-verify on earlier line (multiline bypass)" \
  "$(bash_payload $'echo staging\ngit commit --no-verify -m msg')"
test_allow "$IRRECOVERABLE" "echo --no-verify (git-specific, no false positive)" \
  "$(bash_payload 'echo --no-verify is a git flag')"
# GH #233: a quoted operator-only argument must not split the command and hide a later flag.
test_deny "$IRRECOVERABLE" "GH #233 quoted ; then --no-verify" \
  "$(bash_payload 'git commit -m ";" --no-verify')"
test_deny "$IRRECOVERABLE" "GH #233 quoted ; then commit -n" \
  "$(bash_payload 'git commit -m ";" -n')"
test_deny "$IRRECOVERABLE" "GH #233 quoted && then commit -n" \
  "$(bash_payload 'git commit -m "&&" -n')"
test_deny "$IRRECOVERABLE" "GH #233 quoted | then commit -n" \
  "$(bash_payload 'git commit -m "|" -n')"
test_deny "$IRRECOVERABLE" "GH #233 single-quoted ; then push -f" \
  "$(bash_payload "git push origin ';' -f")"
test_deny "$IRRECOVERABLE" "GH #233 quoted ; then branch -D" \
  "$(bash_payload 'git branch ";" -D')"
test_deny "$IRRECOVERABLE" "GH #233 real ; after quoted ; still splits" \
  "$(bash_payload 'git commit -m ";" ; git commit -n -m x')"
# GH #310: a backslash-escaped operator-only token is a literal word, not a separator.
test_deny "$IRRECOVERABLE" "GH #310 escaped ; then push -f" \
  "$(bash_payload 'git push \; -f')"
test_deny "$IRRECOVERABLE" "GH #310 escaped | then push -f" \
  "$(bash_payload 'git push \| -f')"
test_deny "$IRRECOVERABLE" "GH #310 escaped & then commit -n" \
  "$(bash_payload 'git commit -m x \& -n')"
test_deny "$IRRECOVERABLE" "GH #310 escaped && then branch -D" \
  "$(bash_payload 'git branch \&\& -D x')"
test_deny "$IRRECOVERABLE" "GH #310 escaped ( then commit -n" \
  "$(bash_payload 'git commit -m x \( -n')"
test_deny "$IRRECOVERABLE" "GH #310 escaped ) then push -f" \
  "$(bash_payload 'git push \) -f')"
test_deny "$IRRECOVERABLE" "GH #310 escaped ; inside double quotes then push -f" \
  "$(bash_payload 'git push "a\;" -f')"
test_deny "$IRRECOVERABLE" "GH #310 doubled backslash before ; is a real separator" \
  "$(bash_payload 'git commit -m x \\; git commit -n -m y')"
test_deny "$IRRECOVERABLE" "GH #310 real ; after escaped ; still splits" \
  "$(bash_payload 'git commit -m x \; ; git commit -n -m y')"
test_allow "$IRRECOVERABLE" "GH #310 control: escaped ; as commit message arg" \
  "$(bash_payload 'git commit -m \;')"
test_allow "$IRRECOVERABLE" "GH #310 control: find -exec escaped ; terminator" \
  "$(bash_payload 'find . -name x -exec echo {} \;')"
test_allow "$IRRECOVERABLE" "GH #310 control: real ; separates, later -f is not git's" \
  "$(bash_payload 'git status ; ls -f')"
test_allow "$IRRECOVERABLE" "GH #233 control: commit message is a quoted ;" \
  "$(bash_payload 'git commit -m ";"')"
test_allow "$IRRECOVERABLE" "GH #233 control: quoted ; argument to printf then rm word" \
  "$(bash_payload 'printf "%s\n" ";" rm -rf x')"
test_deny "$IRRECOVERABLE" "git restore . (discards worktree)" \
  "$(bash_payload 'git restore .')"
test_deny "$IRRECOVERABLE" "git restore -- file (discards worktree)" \
  "$(bash_payload 'git restore -- file.txt')"
test_deny "$IRRECOVERABLE" "git restore file (pathspec, no branch ambiguity)" \
  "$(bash_payload 'git restore src/index.ts')"
test_deny "$IRRECOVERABLE" "git restore --worktree file (explicit worktree mode)" \
  "$(bash_payload 'git restore --worktree file.txt')"
test_deny "$IRRECOVERABLE" "git restore --staged --worktree file (worktree touched)" \
  "$(bash_payload 'git restore --staged --worktree file.txt')"
test_allow "$IRRECOVERABLE" "git restore --staged file (index-only, recoverable)" \
  "$(bash_payload 'git restore --staged file.txt')"
test_allow "$IRRECOVERABLE" "git restore --staged . (un-stage all, recoverable)" \
  "$(bash_payload 'git restore --staged .')"
test_allow "$IRRECOVERABLE" "git restore --staged (no pathspec, no-op)" \
  "$(bash_payload 'git restore --staged')"
test_deny "$IRRECOVERABLE" "git checkout HEAD~1 file (tree-ish + path)" \
  "$(bash_payload 'git checkout HEAD~1 src/index.ts')"
test_allow "$IRRECOVERABLE" "git checkout main (1 nonflag = branch switch)" \
  "$(bash_payload 'git checkout main')"

# A shell redirection token (">", "2>&1", ">/dev/null", ...) is consumed by bash before it ever
# reaches git's own argv -- counting it toward checkout's nonflag-arg tally falsely turned an
# everyday idiom into a "tree-ish + path" deny (found live, 2026-09-29, while exercising the
# checkout-isolation pilot: `git checkout <branch> 2>&1` was blocked).
test_allow "$IRRECOVERABLE" "git checkout main 2>&1 (redirection must not count as a 2nd nonflag arg)" \
  "$(bash_payload 'git checkout main 2>&1')"
test_allow "$IRRECOVERABLE" "git checkout main >/dev/null (stdout redirect must not over-block)" \
  "$(bash_payload 'git checkout main >/dev/null')"
test_allow "$IRRECOVERABLE" "git checkout main >>log.txt (append redirect must not over-block)" \
  "$(bash_payload 'git checkout main >>log.txt')"
test_allow "$IRRECOVERABLE" "git checkout main <in.txt (input redirect must not over-block)" \
  "$(bash_payload 'git checkout main <in.txt')"
test_allow "$IRRECOVERABLE" "git checkout main 2>&1 | cat (redirect + pipe must not over-block)" \
  "$(bash_payload 'git checkout main 2>&1 | cat')"
# The redirection strip must not swallow a real dangerous token that happens to sit right before,
# or disguise itself as, a redirection -- these must all still deny.
test_deny "$IRRECOVERABLE" "git checkout -- file.txt 2>&1 (deny survives trailing redirection)" \
  "$(bash_payload 'git checkout -- file.txt 2>&1')"
test_deny "$IRRECOVERABLE" "git checkout HEAD~1 file 2>&1 (tree-ish+path deny survives trailing redirection)" \
  "$(bash_payload 'git checkout HEAD~1 src/index.ts 2>&1')"
# Round-2 regression (found by an adversarial Codex pass against the first attempt at this fix,
# 2026-09-29, see security-gate-token-strip-needs-quote-state memory): a space-separated bare
# digit is a REAL positional arg, not an fd prefix, unless glued with no space to the operator --
# and a QUOTED redirect-lookalike character must never be treated as a real operator.
test_deny "$IRRECOVERABLE" "git checkout HEAD 2 >/dev/null (space-separated digit is a real 2nd pathspec, not an fd prefix)" \
  "$(bash_payload 'git checkout HEAD 2 >/dev/null')"
test_deny "$IRRECOVERABLE" "git checkout HEAD 2 2>/dev/null (real 2nd pathspec PLUS a glued fd-prefixed redirect, still 2 real nonflag args)" \
  "$(bash_payload 'git checkout HEAD 2 2>/dev/null')"
test_allow "$IRRECOVERABLE" "git checkout HEAD 2>/dev/null (glued fd prefix on the ONLY digit present, genuinely 1 real nonflag arg)" \
  "$(bash_payload 'git checkout HEAD 2>/dev/null')"
test_deny "$IRRECOVERABLE" 'rm -r ">" -f file (quoted redirect-lookalike must not hide a real -f)' \
  "$(bash_payload 'rm -r ">" -f hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'git checkout HEAD ">tracked" (quoted > must not be treated as a real operator)' \
  "$(bash_payload 'git checkout HEAD ">tracked"')"
test_deny "$IRRECOVERABLE" 'git restore ">tracked" (same quoted-operator check on restore)' \
  "$(bash_payload 'git restore ">tracked"')"
# Round-3 regression (found by a 2nd-round adversarial Codex pass against round 2's rewrite,
# 2026-09-29): a "#" glued mid-word into a redirect target ("out#suffix") is a literal filename
# character in real bash, not a comment start -- bash only treats "#" as a comment when it opens a
# new word. The redirect-target consumption loop stopped at ANY unquoted "#", silently dropping
# everything after it (including a real trailing dangerous pathspec) from the scan. Confirmed this
# exact payload correctly denies on the unmodified (pre-this-fix) gate.
test_deny "$IRRECOVERABLE" 'git checkout HEAD >out#suffix file (# glued mid-target must not truncate the scan)' \
  "$(bash_payload 'git checkout HEAD >out#suffix hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'rm -r >out#suffix -f file (same # mid-target check on rm)' \
  "$(bash_payload 'rm -r >out#suffix -f hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'git reset >out#suffix --hard (same # mid-target check on reset)' \
  "$(bash_payload 'git reset >out#suffix --hard')"
test_allow "$IRRECOVERABLE" 'git checkout main > #comment ("#" as the FIRST target char is still a real comment)' \
  "$(bash_payload 'git checkout main > #comment')"
# Round-4 regression (found by a 3rd-round adversarial Codex pass, 2026-09-29): same class of bug
# as the "#" fix above, for "{"/"}" -- verified empirically (`bash -n -c 'echo out{suffix'` is
# valid bash, unlike the same test with "(" or ")") that a bare "{"/"}" mid-word is just a literal
# character, not a real shell metacharacter, so the target-consumption loop must not stop there.
test_deny "$IRRECOVERABLE" 'git checkout HEAD >out{suffix file ({ glued mid-target must not truncate the scan)' \
  "$(bash_payload 'git checkout HEAD >out{suffix hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'git checkout HEAD >out}suffix file (} glued mid-target must not truncate the scan)' \
  "$(bash_payload 'git checkout HEAD >out}suffix hooks/gates/irrecoverable.py')"

# GH #178: a bare "#" mid-word in an ORDINARY argument (not a redirect target) was mistaken for a
# comment start ANYWHERE by shlex's own commenters="#" (never overridden -- it has no word-position
# awareness), hiding a real trailing dangerous command. Fixed by swapping a non-boundary "#" for a
# HASH_LIT placeholder (added to lex.wordchars) before shlex ever sees it, so only a genuine
# word-boundary "#" still reaches shlex's own comment-stripping.
test_deny "$IRRECOVERABLE" 'GH #178: bare # mid-word must not hide a real trailing rm -rf' \
  "$(bash_payload 'echo foo#suffix; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178: double ## mid-word, same check' \
  "$(bash_payload 'echo foo##bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178: # right after a blanked $(...) substitution must not hide the rest' \
  "$(bash_payload 'echo $(true)#x; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178: same check inside a bash -c body' \
  "$(bash_payload 'bash -c "echo foo#bar; rm -rf hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #178: # mid-word inside a $(...) body re-scanned on the fixed-point pass' \
  "$(bash_payload 'echo "$(cat foo#bar)"; rm -rf hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #178 control: bare # mid-word with nothing dangerous after it still allows' \
  "$(bash_payload 'echo foo#bar')"
test_allow "$IRRECOVERABLE" 'GH #178 control: a genuine word-boundary "#" comment is still stripped' \
  "$(bash_payload 'git checkout main # trailing comment')"

# GH #178 round 2 (adversarial Codex pass found this before ship): an escaped separator
# ("\ ", "\;", "\|", "\&", "\(") is still a LITERAL character in bash, not a real word break, so a
# "#" right after it is mid-word too -- out[-1] alone can't tell an escaped separator from a real
# one (both leave the same byte). Fixed with a `last_escaped` flag tracking whether the last
# appended char came from an escaped pair, discounted from the "#" boundary check.
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped space before # must not hide a real trailing rm -rf' \
  "$(bash_payload 'echo foo\ #bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped semicolon before #, same check' \
  "$(bash_payload 'echo foo\;#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped pipe before #, same check' \
  "$(bash_payload 'echo foo\|#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped ampersand before #, same check' \
  "$(bash_payload 'echo foo\&#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped open-paren before #, same check' \
  "$(bash_payload 'echo foo\(#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped close-paren before #, same check' \
  "$(bash_payload 'echo foo\)#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped space after a blanked $(...) placeholder before #, same check' \
  "$(bash_payload 'echo $(true)\ #x; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped space right after a closing double-quote before #, same check' \
  "$(bash_payload 'echo "x"\ #bar; rm -rf hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #178 round 2 control: escaped space before # with nothing dangerous after still allows' \
  "$(bash_payload 'echo foo\ #bar')"
test_allow "$IRRECOVERABLE" 'GH #178 round 2 control: an EVEN run of escaped backslashes leaves the next separator real, so # is a genuine comment' \
  "$(bash_payload 'echo foo\\\\ #realcomment; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2 control: a backslash-escaped # itself is never re-examined as a boundary/non-boundary case' \
  "$(bash_payload 'echo foo\#bar; rm -rf hooks/gates/irrecoverable.py')"

# GH #181: a "#" right after a process substitution's closing ")" (<(...)/>(...)) has the same
# word-boundary gap GH #178 fixed for a plain mid-word "#" -- unlike "$(...)"/backtick, this file
# never recognized <(...)/>(...) at all, so its closing ")" reached the "#"-boundary check as a
# bare character (")" is in _REDIRECT_TARGET_STOP, wrongly read as a real word break). Fixed by
# blanking <(...)/>(...) to PSUB (its own placeholder, distinct from "$(...)"'s PH -- see PSUB's
# own comment) before _blank_redirections or the "#"-boundary check ever see it, with the body
# re-appended and re-scanned like a real $(...) body.
test_deny "$IRRECOVERABLE" 'GH #181: # right after <(...) must not hide a real trailing rm -rf' \
  "$(bash_payload 'echo <(true)#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #181: same check with >(...) (output process substitution)' \
  "$(bash_payload 'echo >(true)#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #181: same check with a git subcommand after the ;' \
  "$(bash_payload 'echo <(true)#bar; git reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #181 control: a dangerous command INSIDE <(...) is still denied (no # trick needed)' \
  "$(bash_payload 'echo <(rm -rf hooks/gates/irrecoverable.py)')"
test_allow "$IRRECOVERABLE" 'GH #181 control: an ordinary process-substitution idiom with nothing dangerous still allows' \
  "$(bash_payload 'diff <(sort /etc/hosts) <(sort /etc/hosts)')"

# GH #181 round 2 (adversarial Codex pass found these before ship): 3 bugs in the first <(...)/>(...)
# recognition attempt.
test_deny "$IRRECOVERABLE" 'GH #181 round 2 finding 1: a quoted ) inside the body must not prematurely close the span' \
  "$(bash_payload 'echo <(echo ")"; rm -rf hooks/gates/irrecoverable.py)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 2 finding 1, >(...) variant' \
  "$(bash_payload 'echo >(echo ")"; rm -rf hooks/gates/irrecoverable.py)')"
test_allow "$IRRECOVERABLE" 'GH #181 round 2 finding 2: <(...) inside double quotes is inert text, must not get its body re-scanned' \
  "$(bash_payload 'echo "<(rm -rf hooks/gates/irrecoverable.py)"')"
test_allow "$IRRECOVERABLE" 'GH #181 round 2 finding 3: a pure <(...) arg to checkout is a real nonflag arg but never a real worktree pathspec' \
  "$(bash_payload 'git checkout main <(true) 2>&1')"
test_allow "$IRRECOVERABLE" 'GH #181 round 2 finding 3, two pure <(...) args, same reasoning' \
  "$(bash_payload 'git checkout HEAD <(true) <(true) 2>&1')"
test_deny "$IRRECOVERABLE" 'GH #181 round 2 control: a real 2-nonflag tree-ish+path checkout, no substitution, still denies' \
  "$(bash_payload 'git checkout HEAD~1 hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #181 round 2 control: a $(...)-derived path arg (attacker-controlled value) still counts toward checkout tree-ish+path' \
  "$(bash_payload 'git checkout main $(echo hooks/gates/irrecoverable.py) 2>&1')"

# deep-audit 2026-09-29: PSUB's exclusion landed on checkout's nonflag count only; restore's
# nearly-identical pathspec check (same "a pure PSUB token is never a real worktree pathspec"
# reasoning) was missed, so a pure <(...)/>(...) argument false-denied restore -- same failure
# class as GH #181 round 2 finding 3, one rule over.
test_allow "$IRRECOVERABLE" 'deep-audit: a pure <(...) arg to restore is a real nonflag arg but never a real worktree pathspec' \
  "$(bash_payload 'git restore <(true) 2>&1')"
test_allow "$IRRECOVERABLE" 'deep-audit: same check with >(...) (output process substitution)' \
  "$(bash_payload 'git restore >(true) 2>&1')"
test_deny "$IRRECOVERABLE" 'deep-audit control: a real pathspec arg to restore still denies (no substitution)' \
  "$(bash_payload 'git restore hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'deep-audit control: a $(...)-derived path arg (attacker-controlled value) still counts toward restore' \
  "$(bash_payload 'git restore $(echo hooks/gates/irrecoverable.py) 2>&1')"

# blind-spot-hunter (2026-09-29), whole-picture pass on the restore/PSUB fix above plus the
# already-merged checkout/PSUB exclusion (4e739ca7): 4 confirmed HIGH-severity gaps, all
# empirically baseline-checked to isolate which commit introduced each one.
# F1 (introduced by the restore/PSUB fix just above, same session): --pathspec-from-file's VALUE
# is read by git as a list of real pathspecs -- excluding a pure PSUB token from the pathspec
# count is wrong here, since the process substitution's OUTPUT (not the token itself) is the
# actual pathspec source.
test_deny "$IRRECOVERABLE" 'deep-audit F1: restore --pathspec-from-file <(...) reads real pathspecs from the fd, must still deny' \
  "$(bash_payload 'git restore --pathspec-from-file <(echo hooks/gates/irrecoverable.py) 2>&1')"
# F2 (introduced upstream by c47f624a's new _blank_redirections: a bare "<" with an empty target
# is silently deleted instead of counted, pre-dating PSUB/#181 entirely): same flag on checkout.
test_deny "$IRRECOVERABLE" 'deep-audit F2: checkout --pathspec-from-file <(...) same gap, one subcommand over' \
  "$(bash_payload 'git checkout HEAD --pathspec-from-file <(echo f) 2>&1')"
# F3/F4 (introduced by 4e739ca7's PSUB): scan is PH-stripped (line ~1269) BEFORE the "!= PSUB"
# check runs, so a glued "$(...)<(...)" token (no space -- one shlex token, "PH_char+PSUB_char")
# collapses to a value textually identical to a lone PSUB once PH is stripped, wrongly inheriting
# PSUB's "safe to exclude" treatment even though the $(...) half is attacker-controlled.
test_deny "$IRRECOVERABLE" 'deep-audit F3: restore, glued \$(...)<(...) must not collapse to excluded-PSUB after PH-stripping' \
  "$(bash_payload 'git restore $(echo "hooks/gates/irrecoverable.py :^x")<(true) 2>&1')"
test_deny "$IRRECOVERABLE" 'deep-audit F4: checkout, same glued-token collapse' \
  "$(bash_payload 'git checkout main $(echo "hooks/gates/irrecoverable.py :^x")<(true) 2>&1')"
# Controls: the fix for F1/F2 must not touch a --pathspec-from-file-less command, and the fix for
# F3/F4 must not touch a pure (unglued) PSUB token, which still correctly allows.
test_allow "$IRRECOVERABLE" 'deep-audit control: checkout with a pure (unglued) PSUB arg still allows (round 2 behavior unchanged)' \
  "$(bash_payload 'git checkout main <(true) 2>&1')"
test_allow "$IRRECOVERABLE" 'deep-audit control: restore with a pure (unglued) PSUB arg still allows' \
  "$(bash_payload 'git restore <(true) 2>&1')"

# GH #181 round 3 (adversarial Codex pass found this before ship): a body extracted from <(...)/
# >(...) is spliced back as its own statement only ONCE, after the whole scan finishes -- a
# DIFFERENT-type substitution nested inside it (a backtick inside "<(...)") was never re-examined,
# so it survived unblanked to shlex, still glued to its neighbor text and evading exact-match
# dispatch. Fixed by recursively re-scanning the extracted body (this branch only; the sibling
# "$(...)"/"${...}" branches share the identical gap, confirmed pre-existing, filed separately).
test_deny "$IRRECOVERABLE" 'GH #181 round 3: a backtick nested inside <(...) must not survive unblanked to shlex' \
  "$(bash_payload 'echo <(echo `rm -rf hooks/gates/irrecoverable.py`)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 3, >(...) variant' \
  "$(bash_payload 'echo >(echo `rm -rf hooks/gates/irrecoverable.py`)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 3, a git subcommand nested inside the backtick' \
  "$(bash_payload 'echo <(echo `git reset --hard`)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 3 control: 1000-deep nested <(...) with a real rm -rf innermost fails closed, no crash/traceback' \
  "$(bash_payload "$(python3 -c "print('echo ' + '<(' * 1000 + 'rm -rf hooks/gates/irrecoverable.py' + ')' * 1000)")")"

# GH #188: bash's named-fd redirect "{var}>file" was not a recognized redirect. The outer tokenizer
# split "{fd}" into "{" "fd" "}" ("{"/"}" are window breaks), cutting the command off before a real
# pathspec (fail-open); the bash -c/eval tokenizer kept "{fd}" as one nonflag arg (over-deny).
# GH #219: whether "{fd}>" is a redirect depends on the binary (bash 4+/ksh/zsh yes; macOS sh, bash 3.2,
# dash no, where it is a literal pathspec), so both readings are checked and any deny wins. A branch
# switch with a named-fd redirect is therefore an accepted over-deny (it was allowed under #188).
test_deny "$IRRECOVERABLE" 'GH #219: {fd}>/dev/null on a branch switch denies, {fd} may be a literal pathspec (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: same (eval)' \
  "$(bash_payload 'eval "git checkout main {fd}>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: same (direct)' \
  "$(bash_payload 'git checkout main {fd}>/dev/null')"
test_deny "$IRRECOVERABLE" 'GH #219: {fd} stays a literal restore pathspec on macOS sh / bash 3.2 / dash (sh -c)' \
  "$(bash_payload 'sh -c "git restore {fd}>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: same (direct)' \
  "$(bash_payload 'git restore {fd}>x')"
test_deny "$IRRECOVERABLE" 'GH #219: zsh reads {fd}&>x as a named fd, so it hides the subcommand slot (direct)' \
  "$(bash_payload 'git {fd}&>x reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #219: same (eval)' \
  "$(bash_payload 'eval "git {fd}&>x clean -fd"')"
test_allow "$IRRECOVERABLE" 'GH #219 control: a named-fd redirect on a harmless command still allows' \
  "$(bash_payload 'bash -c "git status {fd}>/dev/null"')"
test_allow "$IRRECOVERABLE" 'GH #219 control: {fd}>x before a plain branch-less log allows (direct)' \
  "$(bash_payload 'git log {fd}>x')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}> redirect does not hide a real tree-ish+path checkout (direct)' \
  "$(bash_payload 'git checkout HEAD {fd}>/dev/null hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #188 control: same, bash -c' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}>/dev/null hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188 control: a mid-word x{fd}>f is a literal pathspec "x{fd}" plus a plain redirect, not a named fd' \
  "$(bash_payload 'git checkout main x{fd}>/dev/null')"
# #208 validator round 1: ">|" (noclobber) was not an operator, so "{fd}>" matched, the target
# stopped at "|", and "|x <path>" became a pipe that cut the window before <path>.
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x does not hide a tree-ish+path checkout (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>| x (spaced target), same (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}>| x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|/dev/null -- <path>, same (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}>|/dev/null -- hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x does not hide a restore pathspec (sh -c)' \
  "$(bash_payload 'sh -c "git restore {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x, same (eval)' \
  "$(bash_payload 'eval "git checkout HEAD {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x, same (sudo bash -c)' \
  "$(bash_payload 'sudo bash -c "git checkout HEAD {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'plain >|x does not hide a tree-ish+path checkout (was allowed on develop too)' \
  "$(bash_payload 'git checkout HEAD >|x hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'plain 2>|x, same (was allowed on develop too)' \
  "$(bash_payload 'git checkout HEAD 2>|x hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #219: {fd}>|/dev/null on a branch switch denies (literal {fd} pathspec reading, bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}>|/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: {fd}<>/dev/null on a branch switch denies, same (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}<>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #188 control: {fd}<>x does not hide a tree-ish+path checkout (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}<>x hooks/gates/irrecoverable.py"')"
# bash takes a {var} prefix only where an fd number is allowed: never on &> / &>>, so "{fd}&>x"
# is the literal word "{fd}" (a pathspec here) plus a redirect.
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>x is a literal {fd} pathspec, not a named fd (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}&>x"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>/dev/null after a branch is a second nonflag (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}&>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>/dev/null is a literal restore pathspec (sh -c)' \
  "$(bash_payload 'sh -c "git restore {fd}&>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>/dev/null, same (eval)' \
  "$(bash_payload 'eval "git checkout main {fd}&>/dev/null"')"
# A deleted redirect leaves a space, so ")" and ";" are not glued into one ");" token.
test_deny "$IRRECOVERABLE" 'deleted redirect leaves a space: (echo a)>x;rm -rf <dir> denies' \
  "$(bash_payload '(echo a)>x;rm -rf build')"
test_deny "$IRRECOVERABLE" 'deleted redirect leaves a space: (true)>/dev/null;git reset --hard denies' \
  "$(bash_payload '(true)>/dev/null;git reset --hard')"
# After an escaped char ("x\ {fd}>f") "{fd}>" is read as a redirect too: keeping "{" as text let
# the outer tokenizer break the window at "{", dropping the "-f" after it.
test_deny "$IRRECOVERABLE" 'escaped-space word before {fd}>: rm -r x\ {fd}>/dev/null -f denies' \
  "$(bash_payload 'rm -r x\ {fd}>/dev/null -f')"
test_deny "$IRRECOVERABLE" 'GH #188 control: an escaped \{fd}>x is the literal word {fd}, a second nonflag' \
  "$(bash_payload 'git checkout main \{fd}>x')"

# GH #197: -S is --staged (index only), also bundled and as a --stage abbreviation; -W still wins.
test_allow "$IRRECOVERABLE" 'GH #197: git restore -S <path> is index-only' \
  "$(bash_payload 'git restore -S hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #197: git restore -qS <path> (bundled) is index-only' \
  "$(bash_payload 'git restore -qS hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #197: git restore --stage <path> (abbreviation) is index-only' \
  "$(bash_payload 'git restore --stage hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197: git restore -S -W <path> still discards worktree changes' \
  "$(bash_payload 'git restore -S -W hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197: git restore -SW <path> (bundled) still discards worktree changes' \
  "$(bash_payload 'git restore -SW hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197: git restore -S --worktree <path> still discards worktree changes' \
  "$(bash_payload 'git restore -S --worktree hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197 control: git restore <path> with neither flag still denies' \
  "$(bash_payload 'git restore hooks/gates/irrecoverable.py')"
# GH #189: `git restore --staged` plus -W or a --worktree abbreviation still targets the worktree.
test_deny "$IRRECOVERABLE" 'GH #189: git restore --staged -W <path> discards worktree changes' \
  "$(bash_payload 'git restore --staged -W hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #189: git restore --staged --work <path> (abbreviation) discards worktree changes' \
  "$(bash_payload 'git restore --staged --work hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #189: git restore --staged -qW <path> (bundled) discards worktree changes' \
  "$(bash_payload 'git restore --staged -qW hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #189 control: git restore --staged --worktree <path> still denies' \
  "$(bash_payload 'git restore --staged --worktree hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #189 control: git restore --staged <path> alone (index only) allows' \
  "$(bash_payload 'git restore --staged hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #189 control: -sW is -s (source) with value W, not -W, so --staged -sW <path> allows' \
  "$(bash_payload 'git restore --staged -sW hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #189 control: after -- every token is a pathspec, so --staged -- -Wfile allows' \
  "$(bash_payload 'git restore --staged -- -Wfile')"

# GH #249: restore's -m is --merge (no value), not a commit message flag; the -m value-skip must not eat the pathspec.
test_deny "$IRRECOVERABLE" 'GH #249: git restore -m . discards worktree changes' \
  "$(bash_payload 'git restore -m .')"
test_deny "$IRRECOVERABLE" 'GH #249: git restore -W -m file discards worktree changes' \
  "$(bash_payload 'git restore -W -m file.txt')"
test_deny "$IRRECOVERABLE" 'GH #249: git restore --conflict=merge -m . discards worktree changes' \
  "$(bash_payload 'git restore --conflict=merge -m .')"
# GH #249: -s/--source take a value, so "-s --staged" makes --staged the source and the restore still targets the worktree.
test_deny "$IRRECOVERABLE" 'GH #249: -s --staged -sHEAD file (--staged is the source value)' \
  "$(bash_payload 'git restore -s --staged -sHEAD file.txt')"
test_deny "$IRRECOVERABLE" 'GH #249: --source --staged --source=HEAD . (--staged is the source value)' \
  "$(bash_payload 'git restore --source --staged --source=HEAD .')"
test_deny "$IRRECOVERABLE" 'GH #249: -qs --staged -sHEAD file (cluster ending in s takes the next token)' \
  "$(bash_payload 'git restore -qs --staged -sHEAD file.txt')"
test_allow "$IRRECOVERABLE" 'GH #249 control: --source=HEAD --staged file (glued value, real --staged) allows' \
  "$(bash_payload 'git restore --source=HEAD --staged file.txt')"
test_allow "$IRRECOVERABLE" 'GH #249 control: -s HEAD --staged file (value is HEAD, real --staged) allows' \
  "$(bash_payload 'git restore -s HEAD --staged file.txt')"
test_deny "$IRRECOVERABLE" 'audit-0930 F3: git checkout -m . (checkout -m is --merge, no value)' \
  "$(bash_payload 'git checkout -m .')"
test_deny "$IRRECOVERABLE" 'audit-0930 F3: git checkout -m -- file discards worktree changes' \
  "$(bash_payload 'git checkout -m -- file.txt')"
test_allow "$IRRECOVERABLE" 'audit-0930 F3 control: git checkout -m <branch> is a merge-switch' \
  "$(bash_payload 'git checkout -m main')"
test_allow "$IRRECOVERABLE" 'GH #249 control: git commit -m message still skips its value' \
  "$(bash_payload 'git commit -m "restore . later"')"

# The gate correctly denies each idiom below TODAY, but no test held the deny path, so a
# mutation to the wrapper-unwrap / hooksPath / branch-delete / backstop logic survived the whole
# suite (fail-open, undetected).
test_deny  "$IRRECOVERABLE" "sudo rm -rf (wrapper unwrap)" \
  "$(bash_payload 'sudo rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo -u <user> rm -rf (issue #115: value-taking flag bypass)" \
  "$(bash_payload 'sudo -u alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo --user=<user> rm -rf (issue #115, = form)" \
  "$(bash_payload 'sudo --user=alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "env VAR=val rm -rf (env-assignment wrapper)" \
  "$(bash_payload 'env FOO=1 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "env -u VAR rm -rf (env-unset-flag wrapper)" \
  "$(bash_payload 'env -u FOO rm -rf /tmp/x')"
# GH #216: `rtk proxy <cmd>` and `rtk run` run <cmd> unfiltered, and rtk's own verbs
# (`rtk find`, `rtk git`) dispatch to the real command, so a destructive command behind any
# of them must be classified exactly as it is bare.
test_deny  "$IRRECOVERABLE" "rtk proxy rm -f -r (GH #216: rtk proxy wrapper)" \
  "$(bash_payload 'rtk proxy rm -f -r /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy rm -rf (GH #216)" \
  "$(bash_payload 'rtk proxy rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk run -c \"rm -rf\" (GH #216: rtk run -c body)" \
  "$(bash_payload 'rtk run -c "rm -rf /tmp/x"')"
test_deny  "$IRRECOVERABLE" "rtk run --command '...' (GH #216: long form)" \
  "$(bash_payload "rtk run --command 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "rtk run rm -rf (GH #216: positional args form)" \
  "$(bash_payload 'rtk run rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy find -delete (GH #216)" \
  "$(bash_payload 'rtk proxy find . -delete')"
test_deny  "$IRRECOVERABLE" "rtk find -delete (GH #216: rtk verb dispatches to find)" \
  "$(bash_payload 'rtk find . -delete')"
test_deny  "$IRRECOVERABLE" "rtk proxy git push --force (GH #216)" \
  "$(bash_payload 'rtk proxy git push --force origin main')"
test_deny  "$IRRECOVERABLE" "rtk git reset --hard (GH #216: rtk verb dispatches to git)" \
  "$(bash_payload 'rtk git reset --hard')"
test_deny  "$IRRECOVERABLE" "env rtk proxy rm -rf (GH #216: chained with env)" \
  "$(bash_payload 'env FOO=1 rtk proxy rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy env rm -rf (GH #216: env behind rtk)" \
  "$(bash_payload 'rtk proxy env rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy sudo rm -rf (GH #216: sudo behind rtk)" \
  "$(bash_payload 'rtk proxy sudo rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy bash -c 'rm -rf' (GH #216: shell body behind rtk)" \
  "$(bash_payload "rtk proxy bash -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "rtk run -c \"a; rm -rf\" (GH #216: rm after a separator inside the body)" \
  "$(bash_payload 'rtk run -c "echo hi; rm -rf /tmp/x"')"
# Controls: the unwrap must not turn ordinary rtk usage into a denial.
test_allow "$IRRECOVERABLE" "rtk proxy ls -la (GH #216 control)" \
  "$(bash_payload 'rtk proxy ls -la')"
test_allow "$IRRECOVERABLE" "rtk proxy rm file (GH #216 control: no -r/-f)" \
  "$(bash_payload 'rtk proxy rm /tmp/x')"
test_allow "$IRRECOVERABLE" "rtk grep foo (GH #216 control)" \
  "$(bash_payload 'rtk grep foo src')"
test_allow "$IRRECOVERABLE" "rtk find . -name x (GH #216 control)" \
  "$(bash_payload 'rtk find . -name x')"
test_allow "$IRRECOVERABLE" "rtk run -c \"ls\" (GH #216 control)" \
  "$(bash_payload 'rtk run -c "ls -la"')"
test_allow "$IRRECOVERABLE" "rtk gain (GH #216 control: rtk meta command)" \
  "$(bash_payload 'rtk gain')"
test_allow "$IRRECOVERABLE" "rtk proxy git status (GH #216 control)" \
  "$(bash_payload 'rtk proxy git status')"
# rtk run/err/test/summary join their args and run them through `sh -c` (verified live: a quoted
# `;` starts a second command), unlike `rtk proxy`, which executes its args as an argv.
test_deny  "$IRRECOVERABLE" "rtk run 'rm -rf' (GH #216: one quoted string is a shell line)" \
  "$(bash_payload "rtk run 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "rtk err 'git push --force' (GH #216)" \
  "$(bash_payload "rtk err 'git push --force origin main'")"
test_deny  "$IRRECOVERABLE" "rtk test 'git reset --hard' (GH #216)" \
  "$(bash_payload "rtk test 'git reset --hard'")"
test_deny  "$IRRECOVERABLE" "rtk summary 'find -delete' (GH #216)" \
  "$(bash_payload "rtk summary 'find . -delete'")"
test_deny  "$IRRECOVERABLE" "rtk run echo 'x;' rm -rf (GH #216: quoted separator joins into a second command)" \
  "$(bash_payload "rtk run echo 'hi;' rm -rf /tmp/x")"
test_deny  "$IRRECOVERABLE" "rtk err true 'x;' rm -rf (GH #216)" \
  "$(bash_payload "rtk err true 'x;' rm -rf /tmp/x")"
test_allow "$IRRECOVERABLE" "rtk err 'ls -la' (GH #216 control)" \
  "$(bash_payload "rtk err 'ls -la'")"
test_allow "$IRRECOVERABLE" "rtk test 'echo hi' (GH #216 control)" \
  "$(bash_payload "rtk test 'echo hi'")"
test_allow "$IRRECOVERABLE" "rtk summary 'git status' (GH #216 control)" \
  "$(bash_payload "rtk summary 'git status'")"
test_deny  "$IRRECOVERABLE" "nice -n 5 rm -rf (nice with value flag)" \
  "$(bash_payload 'nice -n 5 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "nice rm -rf (bare nice wrapper)" \
  "$(bash_payload 'nice rm -rf /tmp/x')"

# --- operator-glue / grouping-token bypass: without punctuation_chars, "echo hi;rm -rf x"
# tokenized as one glued word "hi;rm" and "(rm -rf x)" left "(" as argv0.
test_deny  "$IRRECOVERABLE" "glued semicolon, no space (was a bypass)" \
  "$(bash_payload 'echo hi;rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "glued &&, no space (was a bypass)" \
  "$(bash_payload 'echo hi&&rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "glued pipe, no space (was a bypass)" \
  "$(bash_payload 'echo hi|rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "subshell wrap, no space (was a bypass)" \
  "$(bash_payload '(rm -rf /tmp/x)')"
test_deny  "$IRRECOVERABLE" "brace group (was a bypass)" \
  "$(bash_payload '{ rm -rf /tmp/x; }')"
test_allow "$IRRECOVERABLE" "quoted semicolon stays literal (must not over-block)" \
  "$(bash_payload 'git commit -m "a;b"')"
test_deny  "$IRRECOVERABLE" "sudo -nu <user> bundled short flags (was a bypass)" \
  "$(bash_payload 'sudo -nu alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo -Sku <user> bundled short flags (was a bypass)" \
  "$(bash_payload 'sudo -Sku alice rm -rf /tmp/x')"
test_allow "$IRRECOVERABLE" "sudo -un <user>: u's value is the attached 'n', alice is the real wrapped cmd (must not over-block)" \
  "$(bash_payload 'sudo -un alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "xargs rm -rf (rm via xargs)" \
  "$(bash_payload 'echo /tmp/x | xargs rm -rf')"
test_deny  "$IRRECOVERABLE" "docker exec CONTAINER rm -rf (unwrap inner destructive)" \
  "$(bash_payload 'docker exec c1 rm -rf /data')"
# GH #227: shell bodies nest (`sh -c "sh -c '...'"`), xargs and find -exec hand a body to a
# shell, and `exec -a NAME` puts a value flag before the command.
test_deny  "$IRRECOVERABLE" "nested sh -c (GH #227)" \
  "$(bash_payload "sh -c \"sh -c 'rm -rf /tmp/x'\"")"
test_deny  "$IRRECOVERABLE" "three-deep bash -c (GH #227)" \
  "$(bash_payload "bash -c 'bash -c \"bash -c \\\"rm -rf /tmp/x\\\"\"'")"
test_deny  "$IRRECOVERABLE" "xargs sh -c body (GH #227)" \
  "$(bash_payload "echo a | xargs sh -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "xargs -I{} bash -c body (GH #227)" \
  "$(bash_payload "xargs -I{} bash -c 'rm -rf {}'")"
test_deny  "$IRRECOVERABLE" "find -exec sh -c body (GH #227)" \
  "$(bash_payload "find . -exec sh -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "exec -a NAME then the command (GH #227)" \
  "$(bash_payload 'exec -a foo rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo exec -a NAME then the command (GH #227)" \
  "$(bash_payload 'sudo exec -a foo rm -rf /tmp/x')"
# GH #213: spaced long options on wrappers, keywords after `time`, `)` before a spawn.
test_deny  "$IRRECOVERABLE" "timeout --kill-after N DUR cmd (GH #213)" \
  "$(bash_payload 'timeout --kill-after 5 10 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "nice --adjustment N cmd (GH #213)" \
  "$(bash_payload 'nice --adjustment 5 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "stdbuf --output L cmd (GH #213)" \
  "$(bash_payload 'stdbuf --output L rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "ionice --class 3 cmd (GH #213)" \
  "$(bash_payload 'ionice --class 3 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "time ! cmd keyword after a wrapper (GH #213)" \
  "$(bash_payload 'time ! rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "nested spawn after a case-arm ) (GH #213)" \
  "$(bash_agent_payload 'case x in x) claude -p x ;; esac' fork)"
test_allow "$IRRECOVERABLE" "timeout --kill-after N DUR benign (GH #213)" \
  "$(bash_payload 'timeout --kill-after 5 10 ls /tmp/x')"
test_allow "$IRRECOVERABLE" "nice --adjustment N benign (GH #213)" \
  "$(bash_payload 'nice --adjustment 5 ls /tmp/x')"
test_allow "$IRRECOVERABLE" "time ! benign (GH #213)" \
  "$(bash_payload 'time ! ls /tmp/x')"
test_allow "$IRRECOVERABLE" "case arm with a non-spawn command (GH #213)" \
  "$(bash_agent_payload 'case x in x) claude --version ;; esac' fork)"
test_deny  "$IRRECOVERABLE" "shell nested past the depth cap (GH #227)" \
  "$(python3 -c 'import json,shlex;b="git status"
for _ in range(8): b="sh -c "+shlex.quote(b)
print(json.dumps({"tool_name":"Bash","tool_input":{"command":b}}))')"
test_deny  "$IRRECOVERABLE" "exec -la NAME bundled value flag (GH #227)" \
  "$(bash_payload 'exec -la x rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "bash -c -- body (GH #227)" \
  "$(bash_payload "bash -c -- 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "find -name sh -exec bash -c body: shell is the word after -exec (GH #227)" \
  "$(bash_payload "find . -name sh -exec bash -c 'rm -rf {}' +")"
test_deny  "$IRRECOVERABLE" "find second -exec after an escaped semicolon (GH #227)" \
  "$(bash_payload 'find . -exec true \; -exec rm -rf {} \;')"
test_deny  "$IRRECOVERABLE" "find -ok sh -c body (GH #227)" \
  "$(bash_payload "find . -ok sh -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "xargs -I{} -- sh -c body (GH #227)" \
  "$(bash_payload "echo a | xargs -I{} -- sh -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "nested body with an ANSI-C quoted command (GH #227)" \
  "$(bash_payload "sh -c \"sh -c \$'rm -rf /tmp/x'\"")"
test_allow "$IRRECOVERABLE" "nested body with an ANSI-C quoted benign command (GH #227)" \
  "$(bash_payload "sh -c \"sh -c \$'git status'\"")"
test_allow "$IRRECOVERABLE" "find -name sh with a benign -exec (GH #227)" \
  "$(bash_payload 'find . -name sh -exec ls {} +')"
test_allow "$IRRECOVERABLE" "nested sh -c, benign body (GH #227)" \
  "$(bash_payload "sh -c \"sh -c 'ls /tmp'\"")"
test_allow "$IRRECOVERABLE" "xargs sh -c, benign body (GH #227)" \
  "$(bash_payload "xargs sh -c 'echo hi'")"
test_allow "$IRRECOVERABLE" "find -exec sh -c, benign body (GH #227)" \
  "$(bash_payload "find . -exec sh -c 'ls {}' \\;")"
test_allow "$IRRECOVERABLE" "exec -a NAME, benign command (GH #227)" \
  "$(bash_payload 'exec -a foo ls /tmp')"
# 2026-09-29 deep-audit of #227: exec's -a takes an ATTACHED name too (`exec -alpha CMD` runs CMD
# with argv0 "lpha"); only a cluster whose first `a` is its last char takes the next token.
test_deny  "$IRRECOVERABLE" "exec -alpha CMD: attached name, command still runs (audit of #227)" \
  "$(bash_payload 'exec -alpha rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "exec -aa CMD: attached name (audit of #227)" \
  "$(bash_payload 'exec -aa rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "exec -afooa CMD: attached name ending in a (audit of #227)" \
  "$(bash_payload 'exec -afooa git push --force origin main')"
test_allow "$IRRECOVERABLE" "exec -alpha CMD, benign command (audit of #227)" \
  "$(bash_payload 'exec -alpha ls /tmp')"
# Options after -c: bash/sh keep parsing options and take the first non-option word as the body.
test_deny  "$IRRECOVERABLE" "bash -c -e body (audit of #227)" \
  "$(bash_payload "bash -c -e 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "sh -c -x body nested (audit of #227)" \
  "$(bash_payload "sh -c \"sh -c -x 'rm -rf /tmp/x'\"")"
test_deny  "$IRRECOVERABLE" "bash -c -o pipefail body: -o takes a value (audit of #227)" \
  "$(bash_payload "bash -c -o pipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "bash -c -e, benign body (audit of #227)" \
  "$(bash_payload "bash -c -e 'git status'")"
# find -exec / xargs put a wrapper before the shell or runner.
test_deny  "$IRRECOVERABLE" "find -exec env sh -c body (audit of #227)" \
  "$(bash_payload "find . -exec env sh -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "find -exec sudo git push --force (audit of #227)" \
  "$(bash_payload 'find . -exec sudo git push --force origin main \;')"
test_deny  "$IRRECOVERABLE" "find -exec rtk run -c body (audit of #227)" \
  "$(bash_payload "find . -exec rtk run -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "xargs rtk run -c body (audit of #227)" \
  "$(bash_payload "echo a | xargs rtk run -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "xargs env sh -c body (audit of #227)" \
  "$(bash_payload "echo a | xargs env sh -c 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "find -exec env sh -c, benign body (audit of #227)" \
  "$(bash_payload "find . -exec env sh -c 'git status' \\;")"
test_allow "$IRRECOVERABLE" "xargs rtk run -c, benign body (audit of #227)" \
  "$(bash_payload "echo a | xargs rtk run -c 'git status'")"
# A shell name spelled with an empty substitution (`s$(true)h`) is still the shell, under find -exec too.
test_deny  "$IRRECOVERABLE" "find -exec s\$(true)h -c body: placeholder in the shell name (audit of #227)" \
  "$(bash_payload 'find . -exec s$(true)h -c '"'"'rm -rf /tmp/x'"'"' \;')"
test_deny  "$IRRECOVERABLE" "top-level s\$(true)h -c body (audit of #227)" \
  "$(bash_payload 's$(true)h -c '"'"'rm -rf /tmp/x'"'"'')"
# Whole-picture pass of the audit: a short-option cluster ending in o/O takes the next word as its
# value (`-eo pipefail`), including the -c cluster itself (`-ceo pipefail`).
test_deny  "$IRRECOVERABLE" "bash -c -eo pipefail body: cluster ending in o takes a value (audit of #227)" \
  "$(bash_payload "bash -c -eo pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -ceo pipefail body: the -c cluster itself takes a value (audit of #227)" \
  "$(bash_payload "bash -ceo pipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "bash -c -eo pipefail, benign body (audit of #227)" \
  "$(bash_payload "bash -c -eo pipefail 'git status'")"
# In zsh -O is a plain flag (no value), so `zsh -cO body` runs the body; only -o takes a value there.
test_deny  "$IRRECOVERABLE" "zsh -cO body: -O takes no value in zsh (audit of #227)" \
  "$(bash_payload "zsh -cO 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "zsh -ceO body (audit of #227)" \
  "$(bash_payload "zsh -ceO 'rm -rf /tmp/x'")"
# Remaining option gaps (bash getopt: every o/O in a cluster takes one following word, the -c may sit
# anywhere in the cluster, and `+e` / `+o name` are option words too; the tokenizer splits `+` off).
test_deny  "$IRRECOVERABLE" "bash -oc pipefail body: o before c (gap follow-up to #227)" \
  "$(bash_payload "bash -oc pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -Oc extglob body (gap follow-up to #227)" \
  "$(bash_payload "bash -Oc extglob 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -coo pipefail errexit body: two value flags (gap follow-up to #227)" \
  "$(bash_payload "bash -coo pipefail errexit 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -c -oo pipefail errexit body (gap follow-up to #227)" \
  "$(bash_payload "bash -c -oo pipefail errexit 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -c +e body (gap follow-up to #227)" \
  "$(bash_payload "bash -c +e 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -c +o pipefail body (gap follow-up to #227)" \
  "$(bash_payload "bash -c +o pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "zsh -c +O body: -O takes no value in zsh (gap follow-up to #227)" \
  "$(bash_payload "zsh -c +O 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "sh -c \"bash -oc pipefail body\" nested (gap follow-up to #227)" \
  "$(bash_payload "sh -c \"bash -oc pipefail 'rm -rf /tmp/x'\"")"
test_allow "$IRRECOVERABLE" "bash -oc pipefail, benign body (gap follow-up to #227)" \
  "$(bash_payload "bash -oc pipefail 'git status'")"
test_allow "$IRRECOVERABLE" "bash -c +e, benign body (gap follow-up to #227)" \
  "$(bash_payload "bash -c +e 'git status'")"
# zsh, ksh and dash follow getopt: an `o` followed by more letters has them as its attached value
# (`-opipefail`), so the body is the next word; bash instead takes the next word for every `o`.
test_deny  "$IRRECOVERABLE" "zsh -c -opipefail body: attached option value (gap follow-up to #227)" \
  "$(bash_payload "zsh -c -opipefail 'rm -rf /tmp/x' ignored")"
test_deny  "$IRRECOVERABLE" "ksh -c -oerrexit body: attached option value (gap follow-up to #227)" \
  "$(bash_payload "ksh -c -oerrexit 'rm -rf /tmp/x' ignored")"
test_deny  "$IRRECOVERABLE" "zsh -c +opipefail body: attached value after a split + (gap follow-up to #227)" \
  "$(bash_payload "zsh -c +opipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "zsh -c +opipefail 'echo' then a dangerous-looking argument (gap follow-up to #227)" \
  "$(bash_payload "zsh -c +opipefail 'echo hi' 'rm -rf /tmp/x'")"
# bash's --rcfile / --init-file take a file: the word after them is an option value, not the body.
test_deny  "$IRRECOVERABLE" "bash --rcfile FILE -oc pipefail body: the file is not the body (audit 3 of #227)" \
  "$(bash_payload "bash --rcfile /dev/null -oc pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "env bash --init-file FILE -Oc extglob body (audit 3 of #227)" \
  "$(bash_payload "env bash --init-file /dev/null -Oc extglob 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "bash --rcfile FILE -oc pipefail, benign body (audit 3 of #227)" \
  "$(bash_payload "bash --rcfile /dev/null -oc pipefail 'git status'")"
# ksh93 runs a first operand that is not a readable file as the command string, no -c needed.
test_deny  "$IRRECOVERABLE" "ksh 'body' with no -c runs the string (audit 3 of #227)" \
  "$(bash_payload "ksh 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -o pipefail 'body' with no -c (audit 3 of #227)" \
  "$(bash_payload "ksh -o pipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "ksh with a script operand and a benign later word (audit 3 of #227)" \
  "$(bash_payload "ksh deploy.sh 'git status'")"
# ksh joins every operand word into the command string (`ksh 'echo a' --hard` runs `echo a --hard`), and a
# -c after the operand is part of that string, not an option (blind-spot pass, audit 3 of #227).
test_deny  "$IRRECOVERABLE" "ksh operand then -c: the operand is still the command (audit 3 of #227)" \
  "$(bash_payload "ksh 'rm -rf /tmp/x' -c true")"
test_deny  "$IRRECOVERABLE" "ksh -- operand then -c (audit 3 of #227)" \
  "$(bash_payload "ksh -- 'rm -rf /tmp/x' -c true")"
test_deny  "$IRRECOVERABLE" "ksh operands joined: 'git reset' --hard (audit 3 of #227)" \
  "$(bash_payload "ksh 'git reset' --hard")"
test_allow "$IRRECOVERABLE" "ksh benign operand then -c (audit 3 of #227)" \
  "$(bash_payload "ksh 'git status' -c true")"
# -s reads commands from stdin (the operand is a positional parameter), -n and -D run nothing: the operand is not a command.
test_allow "$IRRECOVERABLE" "ksh -s operand is a positional parameter (audit 5 of #227)" \
  "$(bash_payload "ksh -s 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "ksh -n operand is not run (audit 5 of #227)" \
  "$(bash_payload "ksh -n 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "ksh -xD operand is not run (audit 5 of #227)" \
  "$(bash_payload "ksh -xD 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -sc body still runs (audit 5 of #227)" \
  "$(bash_payload "ksh -sc 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -x operand still runs (audit 5 of #227)" \
  "$(bash_payload "ksh -x 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -onounset: the n and s are the -o value (audit 5 of #227)" \
  "$(bash_payload "ksh -onounset 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -o nounset: the value word is not a flag cluster (audit 5 of #227)" \
  "$(bash_payload "ksh -o nounset 'rm -rf /tmp/x'")"
# A later + option turns the flag back off (`-n +n` runs the operand), so any + option keeps the scan.
test_deny  "$IRRECOVERABLE" "ksh -n +n operand runs (audit 5 whole-picture pass)" \
  "$(bash_payload "ksh -n +n 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -n +o noexec operand runs (audit 5 whole-picture pass)" \
  "$(bash_payload "ksh -n +o noexec 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "env ksh -s +s operand runs (audit 5 whole-picture pass)" \
  "$(bash_payload "env ksh -s +s 'git reset --hard'")"
# Under find, `-exec` after `bash -c` is bash's option letters (e x e c), not a second find action.
test_deny  "$IRRECOVERABLE" "find -exec bash -c -exec body: -exec is a shell cluster (gap follow-up to #227)" \
  "$(bash_payload "find . -exec bash -c -exec 'rm -rf /tmp/x' \\;")"
test_deny  "$IRRECOVERABLE" "find -exec env bash -c -exec body (gap follow-up to #227)" \
  "$(bash_payload "find . -exec env bash -c -exec 'rm -rf /tmp/x' \\;")"
test_allow "$IRRECOVERABLE" "find -exec bash -c -exec, benign body (gap follow-up to #227)" \
  "$(bash_payload "find . -exec bash -c -exec 'git status' \\;")"
# A `{} +` terminator splits the window, so a second -exec starts with `+`.
test_deny  "$IRRECOVERABLE" "find -exec true {} + then a second -exec sh -c body (audit of #227)" \
  "$(bash_payload "find . -exec true {} + -exec sh -c 'rm -rf /x' sh {} +")"
test_allow "$IRRECOVERABLE" "find -exec true {} + then a benign second -exec (audit of #227)" \
  "$(bash_payload 'find . -exec true {} + -exec ls {} +')"
# Fix C appends one window per action flag: a flood of -exec words, or nested `find -exec find`, must
# stay inside the gate's own 8s hook timeout (the deny must not arrive after the budget).
_timed_case() {  # <name> <expected rc> <command>
  local name="$1" want="$2" cmd="$3" t0 rc t1
  t0=$(date +%s)
  bash_payload "$cmd" | timeout 10 bash "$IRRECOVERABLE" >/dev/null 2>&1; rc=$?
  t1=$(( $(date +%s) - t0 ))
  if [[ "$rc" == "$want" ]] && [ "$t1" -le 4 ]; then
    echo "  ✅ $name (rc=$rc in ${t1}s)"; pass=$((pass + 1))
  else
    echo "  ❌ $name: expected rc=$want within 4s, got rc=$rc in ${t1}s" >&2; fail=$((fail + 1))
  fi
}
_timed_case "find -exec sh -c body followed by 3000 more -exec words is denied fast (audit of #227)" 2 \
  "$(python3 -c "print(\"find . -exec sh -c 'rm -rf /x' \" + '-exec ' * 3000 + '\\\\;')")"
_timed_case "3000 chained xargs env xargs is denied fast, not quadratic (audit of #227)" 2 \
  "$(python3 -c "print('echo a | xargs ' + 'env xargs ' * 3000 + 'git status')")"
test_allow "$IRRECOVERABLE" "a short xargs env xargs chain, benign (audit of #227)" \
  "$(bash_payload "echo a | xargs env xargs env git status")"
_timed_case "25 nested find -exec find stays fast and allowed (audit of #227)" 0 \
  "$(python3 -c "print('find . ' + '-exec find . ' * 25 + '-print')")"
# --- git -c core.hooksPath= : the --no-verify-equivalent hook bypass ---
test_deny  "$IRRECOVERABLE" "git -c core.hooksPath= (hook bypass, space form)" \
  "$(bash_payload 'git -c core.hooksPath=/tmp/evil commit -m x')"
test_deny  "$IRRECOVERABLE" "git -ccore.hooksPath= (hook bypass, joined form)" \
  "$(bash_payload 'git -ccore.hooksPath=/tmp/evil commit -m x')"
test_deny  "$IRRECOVERABLE" "git config core.hooksPath <other> (persistent hook bypass)" \
  "$(bash_payload 'git config core.hooksPath /dev/null')"
test_deny  "$IRRECOVERABLE" "git config --unset core.hooksPath (persistent hook bypass)" \
  "$(bash_payload 'git config --unset core.hooksPath')"
test_allow "$IRRECOVERABLE" "git config core.hooksPath git-hooks (documented wiring)" \
  "$(bash_payload 'git config core.hooksPath git-hooks')"
test_allow "$IRRECOVERABLE" "git -c user.name= (benign -c config, must not over-block)" \
  "$(bash_payload 'git -c user.name=x commit -m y')"
# 2026-09-20 audit: the -c branch did an exact-case startswith("core.hooksPath=")
# check while the sibling `git config` branch two lines below already lowercased --
# git itself treats the key case-insensitively, so a differently-cased key bypassed
# this gate while still working as a real hook-path override.
test_deny  "$IRRECOVERABLE" "git -c core.HOOKSPATH= (case-insensitive hookspath bypass, was silently ALLOWed)" \
  "$(bash_payload 'git -c core.HOOKSPATH=/tmp/evil commit -m x')"
test_deny  "$IRRECOVERABLE" "git -cCore.HooksPath= (joined form, mixed case, was silently ALLOWed)" \
  "$(bash_payload 'git -cCore.HooksPath=/tmp/evil commit -m x')"
# 2026-09-21 deep-audit: real git honors --config-env=KEY=VAR / --config-env KEY=VAR
# exactly like -c KEY=<value of VAR>, but only -c was checked.
test_deny  "$IRRECOVERABLE" "git --config-env=core.hooksPath=VAR (joined form, hook bypass, was silently ALLOWed)" \
  "$(bash_payload 'git --config-env=core.hooksPath=EVIL commit -m x')"
test_deny  "$IRRECOVERABLE" "git --config-env core.hookspath=VAR (split form, lowercase key, was silently ALLOWed)" \
  "$(bash_payload 'git --config-env core.hookspath=EVIL commit -m x')"
test_allow "$IRRECOVERABLE" "git --config-env=user.name=X (benign key, must not over-block)" \
  "$(bash_payload 'git --config-env=user.name=X commit -m x')"
# 2026-09-21 deep-audit: a bare NAME=value assignment prefix made argv0 "FOO=bar",
# so every token-dispatched deny (rm, git push --force, ...) fell through.
test_deny  "$IRRECOVERABLE" "FOO=bar rm -rf (assignment prefix, was silently ALLOWed)" \
  "$(bash_payload 'FOO=bar rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "FOO=bar git push --force (assignment prefix, was silently ALLOWed)" \
  "$(bash_payload 'FOO=bar git push --force origin main')"
test_deny  "$IRRECOVERABLE" "GIT_CONFIG_PARAMETERS=core.hooksPath=... git commit (env-var hook bypass, was silently ALLOWed)" \
  "$(bash_payload 'GIT_CONFIG_PARAMETERS="'"'"'core.hooksPath=/dev/null'"'"'" git commit -m x')"
test_deny  "$IRRECOVERABLE" "env GIT_CONFIG_PARAMETERS=core.hooksPath=... git commit (same via env wrapper)" \
  "$(bash_payload 'env GIT_CONFIG_PARAMETERS="'"'"'core.hooksPath=/dev/null'"'"'" git commit -m x')"
test_allow "$IRRECOVERABLE" "FOO=bar ls (assignment prefix on a benign command)" \
  "$(bash_payload 'FOO=bar ls')"
# --- git branch force-delete: discards unmerged commits ---
test_deny  "$IRRECOVERABLE" "git branch -D (force-delete short flag)" \
  "$(bash_payload 'git branch -D main')"
test_deny  "$IRRECOVERABLE" "git branch --delete --force (long-flag force-delete)" \
  "$(bash_payload 'git branch --delete --force develop')"
test_deny  "$IRRECOVERABLE" "git branch -fD (bundled force-delete flags)" \
  "$(bash_payload 'git branch -fD master')"
# Operator policy 2026-09-30: a force-delete is allowed unless it may hit main/master/develop.
test_allow "$IRRECOVERABLE" "git branch -D on a feature branch is allowed" \
  "$(bash_payload 'git branch -D claude/gate-restore-S-197-2026-09-29')"
test_allow "$IRRECOVERABLE" "git branch -D on several feature branches is allowed" \
  "$(bash_payload 'git branch -D feat/a fix-b')"
test_allow "$IRRECOVERABLE" "git branch --delete --force on a feature branch is allowed" \
  "$(bash_payload 'git branch --delete --force featurex')"
test_allow "$IRRECOVERABLE" "a name that only contains main is not protected" \
  "$(bash_payload 'git branch -D maintenance feat/main-fix')"
test_deny  "$IRRECOVERABLE" "git branch -D with a protected name among others" \
  "$(bash_payload 'git branch -D feat/a develop')"
test_deny  "$IRRECOVERABLE" "git branch -D Main (case-insensitive filesystem)" \
  "$(bash_payload 'git branch -D Main')"
test_deny  "$IRRECOVERABLE" "git branch -D refs/heads/master" \
  "$(bash_payload 'git branch -D refs/heads/master')"
test_deny  "$IRRECOVERABLE" "git branch -D with a quoted protected name" \
  "$(bash_payload 'git branch -D "ma"in')"
test_deny  "$IRRECOVERABLE" "git branch -D -- main (name after --)" \
  "$(bash_payload 'git branch -D -- main')"
test_deny  "$IRRECOVERABLE" "git branch -D with a substituted name" \
  "$(bash_payload 'git branch -D $(git branch --show-current)')"
test_deny  "$IRRECOVERABLE" "git branch -D with a variable name" \
  "$(bash_payload 'git branch -D $b')"
test_deny  "$IRRECOVERABLE" "git branch -D with a glob" \
  "$(bash_payload 'git branch -D ma*')"
test_deny  "$IRRECOVERABLE" "git branch -D @{-1} (the previous branch, may be main)" \
  "$(bash_payload 'git branch -D @{-1}')"
test_deny  "$IRRECOVERABLE" "git branch -D with a quoted ; before main (splits the window)" \
  "$(bash_payload "git branch -D f1 ';' main")"
test_deny  "$IRRECOVERABLE" "git branch -D with an escaped & before develop" \
  "$(bash_payload 'git branch -D f1 \& develop')"
test_deny  "$IRRECOVERABLE" "git branch -D ma{i,}n (mid-word brace expansion)" \
  "$(bash_payload 'git branch -D ma{i,}n')"
test_deny  "$IRRECOVERABLE" "xargs appends main to git branch -D" \
  "$(bash_payload 'echo main | xargs git branch -D f1')"
test_deny  "$IRRECOVERABLE" "xargs -I replaces the name with main" \
  "$(bash_payload 'echo main | xargs -I X git branch -D X')"
test_deny  "$IRRECOVERABLE" "git branch -D chained after another command keeps the deny" \
  "$(bash_payload 'git fetch && git branch -D f1')"
test_allow "$IRRECOVERABLE" "git -C path branch -D feature is allowed" \
  "$(bash_payload 'git -C /tmp/r branch -D feat/a')"
test_allow "$IRRECOVERABLE" "git branch -rD origin/feature is allowed" \
  "$(bash_payload 'git branch -rD origin/feat-a')"
# Deep-audit 2026-10-01: @ inside a name is a valid refname and literal to the shell there. # is not:
# zsh extendedglob turns "ma#in" into a glob that can match a "main" entry in the cwd.
test_allow "$IRRECOVERABLE" "git branch -D with @ inside a name is allowed" \
  "$(bash_payload 'git branch -D feature@v2')"
test_deny  "$IRRECOVERABLE" "git branch -D ma#in (a zsh extendedglob for main) keeps the deny" \
  "$(bash_payload 'git branch -D ma#in')"
test_deny  "$IRRECOVERABLE" "git branch -D name@{1} keeps the deny" \
  "$(bash_payload 'git branch -D feat@{1}')"
test_deny  "$IRRECOVERABLE" "git branch -D f1 #main (a word-leading # is a comment) keeps the deny" \
  "$(bash_payload 'git branch -D f1 #main')"
test_deny  "$IRRECOVERABLE" "git branch -D maſter (U+017F folds to master on APFS)" \
  "$(bash_payload 'git branch -D maſter')"
test_deny  "$IRRECOVERABLE" "git branch -D maﬆer (U+FB06 folds to st)" \
  "$(bash_payload 'git branch -D maﬆer')"
test_deny  "$IRRECOVERABLE" "git branch -D with no name" \
  "$(bash_payload 'git branch -D')"
test_deny  "$IRRECOVERABLE" "git -C repo branch -D develop" \
  "$(bash_payload 'git -C /tmp/r branch -D develop')"
test_allow "$IRRECOVERABLE" "git branch newbranch (create, must not over-block)" \
  "$(bash_payload 'git branch newbranch')"
test_allow "$IRRECOVERABLE" "git branch featureD (name containing D, must not over-block)" \
  "$(bash_payload 'git branch featureD')"
# 2026-09-20 audit: git accepts an unambiguous prefix of any long flag
# (--no-veri for --no-verify, etc). Every exact-string `== "--force"`-style
# check below was bypassed live by git's own long-option abbreviation feature.
# push --force is deliberately NOT tested here: git rejects a shortened
# --forc as ambiguous with --force-with-lease/--force-if-includes, so that
# call site is confirmed non-exploitable and was left untouched by the fix.
test_deny  "$IRRECOVERABLE" "git commit --no-veri (abbreviated --no-verify, was silently ALLOWed)" \
  "$(bash_payload 'git commit --no-veri -m msg')"
test_deny  "$IRRECOVERABLE" "git reset --ha (abbreviated --hard, was silently ALLOWed)" \
  "$(bash_payload 'git reset --ha HEAD~1')"
test_deny  "$IRRECOVERABLE" "git commit --amen (abbreviated --amend, was silently ALLOWed)" \
  "$(bash_payload 'git commit --amen')"
test_deny  "$IRRECOVERABLE" "git clean --forc (abbreviated --force, was silently ALLOWed)" \
  "$(bash_payload 'git clean --forc')"
test_deny  "$IRRECOVERABLE" "git branch --del --forc (abbreviated delete+force, was silently ALLOWed)" \
  "$(bash_payload 'git branch --del --forc main')"
test_deny  "$IRRECOVERABLE" "git switch --discard-ch (abbreviated --discard-changes, was silently ALLOWed)" \
  "$(bash_payload 'git switch --discard-ch main')"
test_deny  "$IRRECOVERABLE" "git add --al (abbreviated --all, was silently ALLOWed)" \
  "$(bash_payload 'git add --al')"
# deep-audit fix-round 3, 2026-09-20: the len()>3 guard excluded 2-char-
# after-"--" tokens from ever being checked, regardless of whether real git
# accepts them unambiguously -- live-confirmed `git reset --h` and
# `git clean --f` both ran for real and destroyed data.
test_deny  "$IRRECOVERABLE" "git reset --h (1-char abbreviated --hard, was silently ALLOWed)" \
  "$(bash_payload 'git reset --h')"
test_deny  "$IRRECOVERABLE" "git clean --f (1-char abbreviated --force, was silently ALLOWed)" \
  "$(bash_payload 'git clean --f')"
# Dangerous-direction control: the abbreviation helper must not itself start
# denying git's own already-documented noisy neighbors (an ambiguous prefix
# these long forms don't uniquely resolve to, or a flag never named in the
# specific per-call-site long_forms list).
test_allow "$IRRECOVERABLE" "git push --force-with-lease still allowed (prefix helper is call-site-scoped, not global)" \
  "$(bash_payload 'git push --force-with-lease origin develop')"
test_allow "$IRRECOVERABLE" "git diff --find-renames still allowed (unrelated long flag, not a --force/--hard/--amend prefix)" \
  "$(bash_payload 'git diff --find-renames')"
# --- fail-closed internal-error backstop: a payload that makes the
# Python raise (command is a JSON array, not a string) must still exit 2, never fall open.
test_deny_failclosed "$IRRECOVERABLE" "non-string command payload triggers the fail-closed backstop (exit 2, not fail-open)" \
  '{"tool_name":"Bash","tool_input":{"command":["rm","-rf","/x"]}}'

# --- GH #140: unbounded shlex tokenize cost on an oversized raw command string.
_len_pad=$(python3 -c "print('A' * 700000)")

_rc=$(bash_payload "git push --force origin $_len_pad" | timeout 2 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (<2s): oversized single-token dangerous command still denies (GH #140 length cap)"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (<2s) but got exit $_rc: oversized dangerous command (GH #140 length cap)" >&2
  fail=$((fail + 1))
fi

# Direction-pinning: the SAME oversized padding on a BENIGN tail (git status matches no deny
# pattern at all) must ALSO deny fast.
_rc=$(bash_payload "git status $_len_pad" | timeout 2 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (<2s): oversized BENIGN-tail command still denies -- pins the cap, not a pattern match (GH #140)"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (<2s) but got exit $_rc: oversized benign-tail command (GH #140 length cap)" >&2
  fail=$((fail + 1))
fi

# Negative control: a realistic, modestly-sized legitimate command.
test_allow "$IRRECOVERABLE" "realistic longer commit message, well under the GH #140 length cap -> still allows" \
  "$(bash_payload 'git commit -m "Implement feature X with detailed rationale covering edge cases and rollback plan for the release"')"

# 2026-09-29 deep-audit (Codex checker + a wrapper x verb sweep): a denied command hidden by a
# SPELLING its rule did not know. Every case below was already open before the gate chain (0 flips
# against the pre-chain gate), none is a regression. (a) command position after a shell keyword
# (do/then/else/elif/if/while/until/!), a wrapper missing from PREFIX_WRAPPERS (exec, timeout,
# ...), and the |& pipe; the same commands split over lines were already denied. (b) the short or
# bundled form of a flag the rule only checked long: commit -n is --no-verify, branch -d -f is -D,
# add -Af is add -A.
for _c in \
  'for d in a b; do rm -rf /tmp/x; done' \
  'while true; do git reset --hard; done' \
  'until false; do rm -rf /tmp/x; done' \
  'if true; then git add -A; fi' \
  'if false; then :; else rm -rf /tmp/x; fi' \
  'if false; then :; elif true; then rm -rf /tmp/x; fi' \
  'if false; then :; elif rm -rf /tmp/x; then :; fi' \
  'if rm -rf /tmp/x; then echo ok; fi' \
  'while git reset --hard; do :; done' \
  'until rm -rf /tmp/x; do :; done' \
  'while ! rm -rf /tmp/x; do :; done' \
  'coproc rm -rf /tmp/x' \
  'for d in a; do FOO=1 rm -rf "$d"; done' \
  'for d in a; do timeout 5 rm -rf "$d"; done' \
  '! rm -rf /tmp/x' \
  'exec rm -rf /tmp/x' \
  'true |& rm -rf /tmp/x' \
  'timeout 5 rm -rf /tmp/x' \
  'timeout -s KILL 5 rm -rf /tmp/x' \
  'timeout -k 2 -s KILL 5 rm -rf /tmp/x' \
  'timeout --signal KILL 5 rm -rf /tmp/x' \
  'gtimeout 5 rm -rf /tmp/x' \
  'setsid rm -rf /tmp/x' \
  'stdbuf -oL rm -rf /tmp/x' \
  'stdbuf -i 0 -e 0 -o 0 rm -rf /tmp/x' \
  'ionice -c3 rm -rf /tmp/x' \
  'ionice -c 3 -n 4 rm -rf /tmp/x' \
  'for d in a; do git commit -n -m x; done' \
  'git commit -n -m x' \
  'git commit -nm x' \
  'git commit -anm x' \
  'git commit -m x -n' \
  'git branch -d -f main' \
  'git branch -df develop' \
  'git branch -fd master' \
  'git branch -d --force main' \
  'git branch --delete -f develop' \
  'git branch -r -d -f origin/main' \
  'git add -Af' \
  'git add -fA' \
  'git add -vA' ; do
  test_deny "$IRRECOVERABLE" "spelling variant still denied: $_c" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" "subagent spawns claude through the exec wrapper (spawn guard shares the wrapper list)" \
  "$(bash_agent_payload 'exec claude -p "x"' fork)"
test_deny  "$IRRECOVERABLE" "subagent spawns claude through timeout (spawn guard shares the wrapper list)" \
  "$(bash_agent_payload 'timeout 60 claude -p "x"' fork)"
# Controls: none of the fixes may deny an ordinary command that only LOOKS similar. The keyword
# strip applies at command position only, so a keyword used as an argument or inside a quoted
# message is data, and -n only counts on `commit` (push -n is --dry-run).
for _c in \
  'for d in a b; do echo "$d"; done' \
  'for f in a.txt b.txt; do git add "$f"; done' \
  'if true; then echo hi; fi' \
  'while read l; do echo "$l"; done < list.txt' \
  '! git diff --quiet' \
  'echo do rm -rf x' \
  'echo then git add -A' \
  'git log --grep do' \
  'true |& cat' \
  'timeout 5 ls' \
  'timeout -s KILL 5 make test' \
  'exec ls' \
  'setsid ls' \
  'stdbuf -oL ls' \
  'ionice -c3 ls' \
  'git commit -m msg' \
  'git commit -am msg' \
  'git commit -mnew' \
  'git commit -Fnotes.txt' \
  'git commit -tnotes.txt -m x' \
  'git commit -uno -m x' \
  'git commit -m "fix n handling, then rm -rf notes"' \
  'git push -n' \
  'git branch -d merged-branch' \
  'git branch --delete merged-branch' \
  'git add file.py' \
  'git add -u' \
  'git add -p' \
  'git add -n file.py' \
  'git add -f ignored.txt' ; do
  test_allow "$IRRECOVERABLE" "spelling-variant control still allowed: $_c" "$(bash_payload "$_c")"
done

# Round 2 of the same audit (whole-picture pass over the round-1 fix). (a) Regression the round-1
# wrapper names introduced: a token that only STARTS with a wrapper word ("timeout=30", "exec-bot")
# dead-ended the spawn anchor's regex, so `env timeout=30 claude -p x` stopped denying. (b) The spawn
# anchor did not see loop keywords: `for i in 1; do claude -p x; done`. (c) shlex fuses glued
# punctuation into ONE token (");", "&&(", ")|", ")|&") that is not in OPERATORS, so the command after
# it stayed an argument and no rule dispatched on it: `(cd a && make); rm -rf build`.
test_deny  "$IRRECOVERABLE" "subagent: env timeout=30 claude -p (wrapper-word prefix token must not defeat the spawn anchor)" \
  "$(bash_agent_payload 'env timeout=30 claude -p "x"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: sudo -u exec-bot claude -p (same anchor dead end)" \
  "$(bash_agent_payload 'sudo -u exec-bot claude -p "x"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: claude -p inside a for/do loop" \
  "$(bash_agent_payload 'for i in 1; do claude -p "x"; done' fork)"
test_deny  "$IRRECOVERABLE" "subagent: claude -p after then" \
  "$(bash_agent_payload 'if true; then claude -p "x"; fi' fork)"
test_deny  "$IRRECOVERABLE" "subagent: claude -p after !" \
  "$(bash_agent_payload '! claude -p "x"' fork)"
test_allow "$IRRECOVERABLE" "subagent control: env timeout=30 with a harmless command" \
  "$(bash_agent_payload 'env timeout=30 echo hi' fork)"
test_allow "$IRRECOVERABLE" "subagent control: a for/do loop with no spawn" \
  "$(bash_agent_payload 'for i in 1; do echo "$i"; done' fork)"
for _c in \
  '(cd a && :); rm -rf x' \
  'cd a&&(git push --force)' \
  'true;(git commit -n -m x)' \
  '(true)|rm -rf x' \
  '(true)|&rm -rf x' \
  'bash -c "(true);rm -rf x"' ; do
  test_deny "$IRRECOVERABLE" "glued punctuation still separates commands: $_c" "$(bash_payload "$_c")"
done
for _c in \
  '(cd sub && make); ls' \
  '(echo a); echo b' \
  'cd a&&(ls)' \
  'env timeout=30 ls' ; do
  test_allow "$IRRECOVERABLE" "glued-punctuation control still allowed: $_c" "$(bash_payload "$_c")"
done

# 2026-09-29 deep-audit 4: `builtin` runs the builtin after it, so `builtin eval rm -rf x` and
# `builtin command git add -A` reached the real command with no wrapper unwrapped (the wrapper x verb
# sweep of the third audit never listed it). It is unwrapped in the rule loop only and is NOT in
# PREFIX_WRAPPERS: as a shared wrapper word it made the spawn anchor's greedy walk cross `&&` and land
# on the last `claude`, so `builtin cd /tmp && claude -p x && claude --version` stopped denying.
# The allow controls carry a candidate token (git/rm) so they reach irrecoverable.py, not the .sh prefilter.
for _c in \
  'builtin eval rm -rf x' \
  'builtin command git add -A' \
  'builtin eval git commit -n -m x' \
  'builtin command git push --force origin main' ; do
  test_deny "$IRRECOVERABLE" "builtin wrapper unwrapped: $_c" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" "subagent: builtin cd && claude -p && claude --version (no greedy walk past the first spawn)" \
  "$(bash_agent_payload 'builtin cd /tmp && claude -p "x" && claude --version' fork)"
test_deny  "$IRRECOVERABLE" "subagent: env builtin=30 claude -p (glued word must not defeat the spawn anchor)" \
  "$(bash_agent_payload 'env builtin=30 claude -p "x"' fork)"
for _c in \
  'builtin echo git status' \
  'builtin cd /tmp && git status' \
  'builtin command git status' \
  'builtin eval echo rm x' \
  'env builtin=30 git status' ; do
  test_allow "$IRRECOVERABLE" "builtin control still allowed: $_c" "$(bash_payload "$_c")"
done
# GH #245: the same greedy walk after an old wrapper (time, timeout, env, ...) crossed the separators
# to the LAST `claude`, and finditer resumed after it, so the earlier spawn was never scanned.
for _c in \
  'time ls; claude -p "x"; claude --version' \
  'timeout 5 ls && claude --bg "x" && claude --help' \
  'env A=1 make || claude --agent x; claude --version' ; do
  test_deny "$IRRECOVERABLE" "subagent: spawn behind an old-wrapper statement still anchored: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
# The eval / sh -c body scan calls the same spawn check (_scan_body). A caller left on an old
# signature raised TypeError, and irrecoverable.sh turned that exit 1 into a fail-closed deny, so
# test_deny could not see the crash: these rows run the .py directly and require its own exit 2.
for _c in \
  'eval claude -p x' \
  'ls; eval claude -p x' \
  'bash -c "claude --bg x"' ; do
  _rc=$(bash_agent_payload "$_c" fork | python3 "$ROOT/hooks/gates/irrecoverable.py" 2>/dev/null; echo $?)
  if [[ "$_rc" == "2" ]]; then
    echo "  ✅ DENY (.py, no crash): $_c"; pass=$((pass + 1))
  else
    echo "  ❌ .py exit $_rc, expected its own deny (2): $_c" >&2; fail=$((fail + 1))
  fi
done
test_allow "$IRRECOVERABLE" "subagent: old-wrapper walk control, no spawn flag: time ls; claude --version; claude --help" \
  "$(bash_agent_payload 'time ls; claude --version; claude --help' fork)"
# GH #320: a wrapper written as a path (`/usr/bin/env claude -p x`) runs the same program. The rule
# loop already compares basenames; the spawn anchor matched the bare word only.
for _c in \
  '/usr/bin/env claude -p "x"' \
  '/usr/bin/nice claude -p "x"' \
  '/opt/homebrew/bin/timeout 5 claude -p "x"' \
  '/usr/bin/env /usr/bin/nice claude --print "x"' \
  '/opt/homebrew/bin/rtk proxy claude -p "x"' \
  'true; /usr/bin/time claude --bg "x"' \
  '/usr/bin/env ls; claude -p "x"; claude --version' ; do
  test_deny "$IRRECOVERABLE" "subagent: spawn behind a wrapper written as a path: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  '/usr/bin/env claude --version' \
  'echo /usr/bin/env claude -p x' \
  '/usr/bin/envy claude -p x' ; do
  test_allow "$IRRECOVERABLE" "subagent: wrapper-path control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
# GH #322: the spawn anchor reads the raw command, so it missed what subagent-git-guard.py learned
# in #317 and #318. A shell drops a backslash before an ordinary character (`cl\aude -p x`,
# `claude --pri\nt x`), and zsh runs a brace group glued to its `{` (`{claude -p x;}`). Each deny
# row runs claude with a spawn flag in sh, bash 3.2, bash 5, dash, zsh and ksh (logging claude stub;
# the glued-brace rows in zsh only); the controls run none.
for _c in \
  'cl\aude -p hello' \
  '\c\l\a\u\d\e -p hello' \
  'e\nv claude -p hello' \
  'ti\me claude -p hello' \
  's\udo claude -p hello' \
  'claude -\p hello' \
  'claude --pri\nt hello' \
  'claude --a\gent x' \
  'claude --b\g x' \
  "bash -c 'cl\\aude -p hello'" \
  'bash -c "cl\aude -p hello"' \
  "eval 'cl\\aude -p hello'" \
  'true; cl\aude --bg x' \
  '{ cl\aude -p hello; }' \
  'echo $(cl\aude -p x)' \
  '/usr/bin/e\nv claude -p hello' \
  '{claude -p hello;}' \
  '{claude -p hello; }' \
  '(){claude -p hello;}' \
  'f(){claude -p x;}; f' \
  '{{claude -p x;};}' \
  'true; {claude -p x;}' \
  'true&&{claude -p x;}' \
  '({claude -p x;})' \
  '{env claude -p x;}' \
  '{cl\aude -p x;}' \
  'echo $({claude -p x;})' \
  'if true; then {claude -p x;}; fi' ; do
  test_deny "$IRRECOVERABLE" "subagent: GH #322 spawn denied (escaped letter / zsh glued brace): $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'cl\\aude -p hello' \
  'cl\\\aude -p hello' \
  'echo cl\aude -p hello' \
  'x{claude -p hello;}' \
  '${claude -p x;}' \
  '{true;}{claude -p x;}' \
  '{claude --version;}' \
  'cl\aude --version' \
  'claude -\v' \
  '\{claude -p x;}' \
  'claude --pri\\nt hello' ; do
  test_allow "$IRRECOVERABLE" "subagent: GH #322 control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
# Every glued `{` is now a command start that walks a wrapper chain; padded shapes must still be
# decided in bounded time (worst measured about 1 s; `timeout 5` turns a regression into rc 124).
for _u in '{env ' '{ env ' '{sudo -u x ' 'e\nv ' ; do
  _c="$(python3 -c 'import sys; print(sys.argv[1] * 2000 + "claude -p x")' "$_u")"
  _rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
  if [[ "$_rc" == "2" ]]; then
    echo "  ✅ DENY (bounded time): GH #322 padded '$_u' x 2000 before claude -p"; pass=$((pass + 1))
  else
    echo "  ❌ DENY EXPECTED (bounded time) but got exit $_rc (124 = timed out): GH #322 padded '$_u' x 2000" >&2; fail=$((fail + 1))
  fi
done
# GH #344: a shell removes the quotes inside a word, so a quoted or partly quoted claude, wrapper or
# flag still runs claude. Each deny row runs claude with a spawn flag in sh, bash 3.2, bash 5, dash, zsh
# and ksh (logging claude stub; $'..' rows in all but dash, the glued-brace row in zsh only); the
# controls run none.
for _c in \
  '"claude" -p x' \
  "cl'a'ude -p x" \
  'cl""aude -p x' \
  "'claude' --print x" \
  'sudo "claude" -p x' \
  '"env" claude -p x' \
  '"sudo" -u x claude -p x' \
  'true; "claude" --bg x' \
  'echo $("claude" -p x)' \
  "bash -c '\"claude\" -p x'" \
  '{ "claude" -p x; }' \
  '{"claude" -p x;}' \
  "claude '-'p x" \
  'claude --"print" x' \
  "\$'claude' -p x" \
  '"cl"\aude -p x' \
  'claude -p"x"' ; do
  test_deny "$IRRECOVERABLE" "subagent: GH #344 spawn denied (quoted word): $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'echo "claude" -p x' \
  '"claude -p x"' \
  '"claudex" -p x' \
  '"A=1" claude -p x' \
  '"claude" --version' \
  'git commit -m "use claude -p"' \
  "echo 'a \"claude\" -p'" ; do
  test_allow "$IRRECOVERABLE" "subagent: GH #344 control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
_c="$(python3 -c 'print("\"e\"nv " * 4000 + "claude -p x")')"
_rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): GH #344 '\"e\"nv ' x 4000 before claude -p"; pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $_rc (124 = timed out): GH #344 '\"e\"nv ' x 4000" >&2; fail=$((fail + 1))
fi
# GH #339: `builtin` before a wrapper runs the wrapper (`builtin command claude --agent x`). It is not a
# wrapper word (it made the greedy walk cross `&&`, see _UNWRAP_ONLY), so the anchor takes one leading
# run of it, only when a wrapper word follows. Each deny row runs claude with a spawn flag in sh, bash 3.2,
# bash 5 and zsh (logging claude stub); the controls run none.
for _c in \
  'builtin command claude --agent x' \
  'builtin exec -a x claude --print x' \
  'builtin builtin command claude -p x' \
  'true; builtin exec claude -p x' \
  'builtin -- command claude -p x' \
  'builtin cd /tmp && claude -p x && claude --version' \
  'builtin command true && claude -p x && claude --version' \
  '{ builtin exec -a x claude -p x; }' ; do
  test_deny "$IRRECOVERABLE" "subagent: GH #339 spawn denied (builtin before a wrapper): $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'builtin command claude --version' \
  'builtin echo claude -p x' \
  'builtin claude -p x' \
  'echo builtin command claude -p x' \
  'builtin cd /tmp && claude --version' ; do
  test_allow "$IRRECOVERABLE" "subagent: GH #339 control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _u in 'builtin ' 'builtin command ' ; do
  _c="$(python3 -c 'import sys; print(sys.argv[1] * 3000 + "command claude -p x")' "$_u")"
  _rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
  if [[ "$_rc" == "2" ]]; then
    echo "  ✅ DENY (bounded time): GH #339 padded '$_u' x 3000 before claude -p"; pass=$((pass + 1))
  else
    echo "  ❌ DENY EXPECTED (bounded time) but got exit $_rc (124 = timed out): GH #339 padded '$_u' x 3000" >&2; fail=$((fail + 1))
  fi
done
# `claude --version`, not `ls`: the .sh fast path skips python for a command with no claude/git in it.
_c="$(python3 -c 'print("builtin " * 3000 + "claude --version")')"
_rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "0" ]]; then
  echo "  ✅ GH #339 padded 'builtin ' x 3000 allow shape finishes in bounded time (rc $_rc)"; pass=$((pass + 1))
else
  echo "  ❌ GH #339 padded 'builtin ' x 3000 allow shape: expected rc 0, got $_rc (124 = timed out)" >&2; fail=$((fail + 1))
fi

echo ""
echo "=== gh merge ask-tier gate (Phase B, 2026-09-28: local defense-in-depth for the PR-review flow) ==="
test_ask   "$IRRECOVERABLE" "gh pr merge <number>"                "$(bash_payload 'gh pr merge 5')"
test_ask   "$IRRECOVERABLE" "gh pr merge with --squash flag"       "$(bash_payload 'gh pr merge --squash 5')"
test_ask   "$IRRECOVERABLE" "gh pr merge with a brace word asks once (two window copies)" "$(bash_payload 'gh pr merge feat{1}')"
test_ask   "$IRRECOVERABLE" "gh pr merge with a \$() argument asks once (compacted copy)" "$(bash_payload 'gh pr merge $(true) 12')"
test_ask   "$IRRECOVERABLE" "gh api .../merge (PUT)"              "$(bash_payload 'gh api repos/wasikarn/method-harness/pulls/5/merge -X PUT')"
test_allow "$IRRECOVERABLE" "gh pr view (not a merge)"             "$(bash_payload 'gh pr view 5')"
test_allow "$IRRECOVERABLE" "gh pr list (not a merge)"             "$(bash_payload 'gh pr list')"
test_allow "$IRRECOVERABLE" "gh pr create (not a merge)"           "$(bash_payload 'gh pr create --title x --body y')"
test_allow "$IRRECOVERABLE" "gh api on an unrelated endpoint"      "$(bash_payload 'gh api repos/wasikarn/method-harness/pulls/5')"

echo ""
echo "=== task-complete-separation gate (maker≠checker: subagent cannot self-complete) ==="
# Maker self-completion is the one thing the harness forbids — a subagent (agent_type present)
# calling TaskUpdate(completed) is blocked at exit 2.
test_deny  "$TASK_COMPLETE" "subagent marks completed (maker self-grade)" \
  "$(taskupdate_payload completed mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "main session marks completed (no agent_type)" \
  "$(taskupdate_payload completed '')"
test_allow "$TASK_COMPLETE" "subagent sets in_progress (not completion)" \
  "$(taskupdate_payload in_progress mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "subagent sets pending (not completion)" \
  "$(taskupdate_payload pending mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "subagent subject/desc update (no status field)" \
  "$(taskupdate_payload '' mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "malformed stdin (fail-safe allow)" \
  '{not valid json'
# Security-review finding (2026-08-31): agent_type is also present for a top-level `claude
# --agent <name>` MAIN session (not a subagent) — keying on it over-blocks that legitimate case.
test_allow "$TASK_COMPLETE" "--agent main session (agent_type set, no agent_id) may still complete" \
  "$(taskupdate_payload completed some-agent-name '')"
# GH #155: same truthiness-vs-presence gap GH #154 fixed in subagent-spawn-guard.py --
# the gate's own stated intent is to key on PRESENCE of agent_id, not a
# non-empty/non-null value. A real payload capture (2026-09-07) never observed an
# empty/null agent_id in practice -- these are hardening tests for a theoretical gap.
test_deny "$TASK_COMPLETE" "GH #155 gap: agent_id present but an empty string still denied" \
  "$(taskupdate_payload_forced_id completed mh:build-error-resolver '')"
test_deny "$TASK_COMPLETE" "GH #155 gap: agent_id present but JSON null still denied" \
  "$(taskupdate_payload_forced_id completed mh:build-error-resolver '__NULL__')"

echo ""
echo "=== nested-spawn deny (irrecoverable.py: a subagent may not spawn a nested claude session via Bash) ==="
# Security-review finding: a subagent retains Bash access, so `claude -p` from Bash spawns a
# nested session that never routes through the Agent tool.
test_deny  "$IRRECOVERABLE" "subagent runs 'claude -p' via Bash (the nested-spawn evasion)" \
  "$(bash_agent_payload 'claude -p "do something"' fork)"
test_deny  "$IRRECOVERABLE" "subagent runs 'claude --agent X --print' via Bash" \
  "$(bash_agent_payload 'claude --agent reviewer --print "check this"' fork)"
test_deny  "$IRRECOVERABLE" "subagent hides the spawn after a semicolon" \
  "$(bash_agent_payload 'echo hi; claude -p "sneaky"' fork)"
test_allow "$IRRECOVERABLE" "subagent runs an unrelated claude invocation (no spawn flag)" \
  "$(bash_agent_payload 'claude --version' fork)"
test_allow "$IRRECOVERABLE" "subagent runs an unrelated Bash command" \
  "$(bash_agent_payload 'ls -la' fork)"
test_allow "$IRRECOVERABLE" "main session runs 'claude -p' via Bash (no agent_id — always allowed)" \
  "$(bash_agent_payload 'claude -p "do something"' '')"
test_allow "$IRRECOVERABLE" "malformed stdin on the Bash leg (fail-safe allow)" \
  '{not valid json'
# H4 (harness gap-audit, 2026-09-20): the ABOVE case allows only because it
# has no destructive token, so the bash fast-path exits before python3 ever
# runs -- it never actually reached the python-side malformed-payload deny
# branch (lines 27-31). A malformed payload that DOES carry a destructive
# substring passes the fast path, then must fail closed once python3's
# json.load() chokes on the truncation -- the two branches must not be
# conflated (one's a pre-python allow, the other's a post-python deny).
test_deny "$IRRECOVERABLE" "truncated JSON carrying a destructive substring reaches python and fails closed (H4, was untested)" \
  '{"tool_input": {"command": "rm -rf /"'

# C1 (harness gap-audit, 2026-09-20): _nested_spawn's outer loop over every
# anchor match times an unbounded inner token scan is O(anchors x
# remaining-length) -- live-reproduced before the fix: 6,000 "claude ("
# anchors in a 48,000-char command (well under _CMD_LEN_CAP's 150,000) took
# 22s, far past this gate's own 8s hooks.json PreToolUse timeout, and Claude
# Code's own hooks reference confirms a timed-out PreToolUse command hook
# lets the tool call continue -- so a slow enough payload silently bypassed
# this whole check. `timeout 5` wraps the assertion itself: a regression
# back to the unbounded scan would make this whole test time out (rc 124),
# not just fail the deny assertion.
dos_payload="$(python3 -c 'print("claude (" * 6000)')"
dos_rc=$(echo "$(bash_agent_payload "$dos_payload" fork)" | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$dos_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): 6,000-anchor nested-spawn scan denies well under the 8s PreToolUse timeout, not a silent bypass"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $dos_rc (124 = timed out, budget regressed): 6,000-anchor nested-spawn scan" >&2
  fail=$((fail + 1))
fi

# C1b (harness gap-audit, 2026-09-20): both _nested_spawn call sites (line
# ~302 top-level command, line ~621 bash -c/eval unwrapped body) gate on
# `"agent_id" in d` -- presence, not truthiness. An empty-string or JSON-null
# agent_id is still a subagent call and must still deny, not fall through as
# if agent_id were absent (main session).
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but empty string still denies a top-level nested spawn" \
  "$(bash_agent_payload_forced_id 'claude -p "sneaky"' '')"
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but JSON null still denies a top-level nested spawn" \
  "$(bash_agent_payload_forced_id 'claude -p "sneaky"' '__NULL__')"
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but empty string still denies a bash -c-wrapped nested spawn" \
  "$(bash_agent_payload_forced_id 'bash -c "claude -p sneaky"' '')"
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but JSON null still denies a bash -c-wrapped nested spawn" \
  "$(bash_agent_payload_forced_id 'bash -c "claude -p sneaky"' '__NULL__')"

test_deny  "$IRRECOVERABLE" "subagent spawns via command substitution" \
  "$(bash_agent_payload 'echo $(claude -p "evil")' fork)"
test_deny  "$IRRECOVERABLE" "subagent spawns with an env-var prefix before claude" \
  "$(bash_agent_payload 'CLAUDE_API_KEY=x claude -p "do something"' fork)"
# Deep-audit fresh adversarial pass, 2026-08-31: the un-anchored regex denied these three real,
# harmless commands because they merely CONTAIN the substring "claude -p" as prose/data, not as
# an invocation.
test_allow "$IRRECOVERABLE" "subagent commits a message mentioning the flag (prose, not invocation)" \
  "$(bash_agent_payload 'git commit -m "mention claude -p in docs"' fork)"
test_allow "$IRRECOVERABLE" "subagent echoes the pattern as a string, not a real invocation" \
  "$(bash_agent_payload 'echo "claude -p"' fork)"
test_allow "$IRRECOVERABLE" "subagent greps for the pattern (auditing this gate itself)" \
  "$(bash_agent_payload 'grep -r "claude -p" docs/' fork)"
# 2026-09-20 audit: _SPAWN_ANCHOR_RE required "claude" immediately after the
# separator/VAR=val chain, with no allowance for a wrapper word -- env/sudo/
# nohup/nice/time/command prefixes, chained or repeated, all bypassed it live.
test_deny  "$IRRECOVERABLE" "subagent: env-wrapped claude -p (wrapper-prefix bypass, was silently ALLOWed)" \
  "$(bash_agent_payload 'env claude -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: chained sudo env claude -p (multi-level wrapper bypass, was silently ALLOWed)" \
  "$(bash_agent_payload 'sudo env claude -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: backslash-escaped \\claude -p (was silently ALLOWed)" \
  "$(bash_agent_payload '\claude -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: env with its own -u flag and a VAR=val before claude -p (was silently ALLOWed)" \
  "$(bash_agent_payload 'env -u X FOO=bar claude -p "evil"' fork)"
# compliance-audit fix-round 2, 2026-09-20: a first fix bounded the wrapper
# chain at depth<=3 to dodge a catastrophic-backtracking shape; an
# independent verifier chained 13 wrappers and got past that cap live.
long_chain="$(python3 -c 'print("env sudo nohup nice time command " * 13 + "claude -p \"evil\"")')"
test_deny  "$IRRECOVERABLE" "subagent: 13-deep wrapper chain past the old depth<=3 bound (was silently ALLOWed)" \
  "$(bash_agent_payload "$long_chain" fork)"
test_allow "$IRRECOVERABLE" "main session: env-wrapped claude -p (no agent_id — always allowed)" \
  "$(bash_agent_payload 'env claude -p "evil"' '')"
# A flat [^|;&]* scan treated any &/;/| as end-of-invocation even inside a quoted prompt, so a
# spawn flag after a quoted separator evaded detection.
test_deny  "$IRRECOVERABLE" "spawn hidden behind an ampersand inside a quoted prompt" \
  "$(bash_agent_payload 'claude "fix A & B" -p' fork)"
test_deny  "$IRRECOVERABLE" "spawn hidden behind a semicolon inside a quoted prompt" \
  "$(bash_agent_payload 'claude "note; then" --print x' fork)"
test_deny  "$IRRECOVERABLE" "spawn hidden behind a pipe inside a single-quoted prompt" \
  "$(bash_agent_payload "claude 'use A | B' --agent x" fork)"
# Cross-segment separation must survive the quote-aware rewrite: a LATER, unrelated command's
# flag must never get credited to an earlier claude invocation that itself carries no spawn
# flag.
test_allow "$IRRECOVERABLE" "unrelated later command's flag does not leak back to claude" \
  "$(bash_agent_payload 'claude --version ; othertool -p' fork)"
# GH #152: the anchor matched "claude" as a mid-token substring (a path segment
# like /tmp/claude-501/... contains a word-bounded "claude"), and the forward
# flag scan did not stop at a newline, so an unrelated later line's flag got
# credited to that false match.
test_allow "$IRRECOVERABLE" "GH #152 exact repro: scratchpad-shaped path plus a later mkdir -p on its own line" \
  "$(bash_agent_payload $'BASE=/private/tmp/claude-501/foo\nmkdir -p "$BASE/work"' fork)"
# Newline-as-separator control, independent of the mid-token anchor fix: a real
# (flag-free) claude mention followed by an unrelated command's -p on the next
# line must not leak back either -- the same property already covered above
# for a ";" separator must also hold for "\n".
test_allow "$IRRECOVERABLE" "unrelated later LINE's flag does not leak back to claude (newline, not semicolon)" \
  "$(bash_agent_payload $'claude --version\nothertool -p' fork)"
# Dangerous-direction control: a false substring match on an earlier line must
# not blind the scan to a REAL spawn on a later line.
test_deny  "$IRRECOVERABLE" "GH #152 control: false path-substring on line 1 does not mask a real spawn on line 2" \
  "$(bash_agent_payload $'BASE=/private/tmp/claude-501/foo\nclaude -p "evil"' fork)"
# Deep-audit adversarial pass, 2026-09-07: the newline-stops-scan rule the GH #152 fix added has
# no concept of $(...) nesting depth. Real bash executes `claude $(\nprintf x\n) -p evil` as ONE
# command (the newline inside the substitution is not a top-level separator), but the scanner's
# flat token walk treated that embedded newline as scan-stopping regardless of nesting, so the
# flag scan never reached `-p` after the substitution closed.
test_deny  "$IRRECOVERABLE" "spawn flag after a command substitution containing an embedded newline must still be caught" \
  "$(bash_agent_payload $'claude $(\nprintf x\n) -p "evil"' fork)"
# code-review round on the GH #152 fix (before it shipped) caught two
# dangerous-direction regressions the fix itself would have introduced --
# both fixed, both locked in here so neither regresses again.
test_deny  "$IRRECOVERABLE" "GH #152 review catch: a shell metacharacter (not just \\s;&|)) right after claude must still anchor" \
  "$(bash_agent_payload 'claude>out.log -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "GH #152 review catch: a backslash-continued line is still one statement, spawn on the continuation line still caught" \
  "$(bash_agent_payload $'bash <<EOF\nclaude \\\\\n  -p "evil"\nEOF' fork)"
# Deep-audit 2026-09-07 paren-depth fix control (advisor-flagged gap): a
# BALANCED $(...) group between an unrelated claude mention and the real
# top-level separator must still let that separator stop the scan once the
# group closes depth back to 0 -- the same GH #152 leak-back property, now
# proven with parens in the mix rather than only newline/semicolon.
test_allow "$IRRECOVERABLE" "GH #152-class control: balanced \$(...) between claude and the real separator does not leak a later command's flag back" \
  "$(bash_agent_payload 'claude --version $(date) ; othertool -p' fork)"
# A stray unmatched ")" before the real separator must clamp at depth 0, not
# go negative -- going negative would require an unrelated later "(" to
# numerically return to 0, incorrectly swallowing everything in between
# (including a real separator) into the scan.
test_allow "$IRRECOVERABLE" "paren-depth clamp control: a stray unmatched ')' before the real separator does not swallow a later command's flag" \
  "$(bash_agent_payload 'claude --version) ; othertool -p' fork)"
# Codex-validator round on the paren-depth fix itself, deep-audit 2026-09-07:
# a backslash-escaped "(" is a literal argument character to claude, NOT a
# real subshell opener -- the depth tracker must not count it, or the real
# ";" right after gets swallowed and an unrelated later command's -p leaks
# back (reproduced live pre-fix: this exact payload was denied).
test_allow "$IRRECOVERABLE" "escaped literal paren control: a backslash-escaped '\\(' is not a real subshell opener, does not leak a later command's flag back" \
  "$(bash_agent_payload 'claude --version \( ; othertool -p' fork)"
# Same property, double backslash before a real newline: an EVEN count of
# backslashes right before a real newline is not a continuation in real bash
# (the pair is one escaped backslash, then the newline is unescaped and
# ends the statement) -- but this file deliberately still treats it as one,
# same safe-direction precedent as the single-backslash case, so a spawn on
# the "continuation" line must still be caught, not narrowed away.
test_deny "$IRRECOVERABLE" "double-backslash-before-newline control: even backslash count still treated as continuation (safe-direction precedent), spawn on the next line still caught" \
  "$(bash_agent_payload $'claude \\\\\n  -p "evil"' fork)"
# Round-2 codex-validator catch on the FIRST attempt at the escaped-paren fix
# (a fixed "backslash + one of these chars" rule with no parity check): an
# EVEN backslash count before a backtick leaves the backtick unescaped and
# LIVE in real bash (the pair is one literal backslash; the backtick opens a
# real command substitution) -- treating it as escaped/inert was a false
# ALLOW, a genuine bypass, reproduced live pre-fix (bash-stub trace showed
# claude actually receiving -p as an argument). Parity tracking (an odd-
# length run escapes the next char, an even-length run doesn't) fixes this.
test_deny "$IRRECOVERABLE" "backslash-parity control: an EVEN backslash count before a backtick leaves it live -- real command substitution still caught, not treated as escaped" \
  "$(bash_agent_payload 'claude \\`printf x; printf y` -p evil' fork)"
# Mirror case, ALLOW direction: an even backslash count before a semicolon
# also leaves the semicolon a real, live separator in real bash (same
# pairing rule) -- must still stop the scan normally, not get swallowed as
# an escaped/inert semicolon.
test_allow "$IRRECOVERABLE" "backslash-parity control: an EVEN backslash count before ';' leaves it a real separator -- later command's flag does not leak back" \
  "$(bash_agent_payload 'claude --version \\; othertool -p' fork)"

# Heredoc-body stripping regression coverage.
test_allow "$IRRECOVERABLE" "heredoc-authored commit message mentioning feat(claude): and --bg in unrelated prose lines no longer false-blocks (GH #121 exact repro)" \
  "$(bash_agent_payload $'git commit -m "$(cat <<\'EOF\'\nfeat(claude): document the nested-spawn gate heredoc fix\nunrelated later line just happens to mention --bg here\nEOF\n)"' fork)"
# Dangerous-direction control: a heredoc body that DOES feed an interpreter is executable code,
# not inert data, so a real nested `claude -p` spawn hidden inside one must still be caught.
test_deny  "$IRRECOVERABLE" "nested claude spawn hidden inside an interpreter-fed heredoc body still blocked (bash <<EOF ... claude -p ... EOF, GH #121 dangerous-direction control)" \
  "$(bash_agent_payload $'bash <<EOF\nclaude -p "evil"\nEOF' fork)"

# --- bash -c / eval one-level unwrap ---
test_deny  "$IRRECOVERABLE" "bash -c with rm -rf inside" \
  "$(bash_payload 'bash -c "rm -rf build"')"
test_deny  "$IRRECOVERABLE" "sh -c with git push --force inside" \
  "$(bash_payload "sh -c 'git push --force origin main'")"
test_deny  "$IRRECOVERABLE" "bash -lc (bundled) with rm -rf inside" \
  "$(bash_payload 'bash -lc "cd x && rm -rf y"')"
test_deny  "$IRRECOVERABLE" "eval with rm -rf inside" \
  "$(bash_payload 'eval "rm -rf build"')"
test_allow "$IRRECOVERABLE" "bash -c with a harmless body" \
  "$(bash_payload 'bash -c "ls -la && git status"')"
test_allow "$IRRECOVERABLE" "bash -c body mentioning rm -rf as data" \
  "$(bash_payload 'bash -c "echo rm -rf is dangerous"')"
# deep-audit 2026-09-06: the unwrap ran before the prefix-wrapper unwrap, never
# blanked a single-quoted body, and the nested-spawn deny never saw inside it.
test_deny  "$IRRECOVERABLE" "sudo bash -c with rm -rf inside (wrapper before shell)" \
  "$(bash_payload "sudo bash -c 'rm -rf x'")"
test_deny  "$IRRECOVERABLE" "env bash -c with git reset --hard inside" \
  "$(bash_payload "env bash -c 'git reset --hard'")"
test_deny  "$IRRECOVERABLE" "bash -c single-quoted body with a spliced argv0" \
  "$(bash_payload "bash -c 'gi\$(true)t push --force origin main'")"
test_deny  "$IRRECOVERABLE" "bash -c single-quoted body hiding the deny inside a substitution" \
  "$(bash_payload "bash -c 'echo \$(git push --force origin main)'")"
test_deny  "$IRRECOVERABLE" "bash -c single-quoted body with a bare-PH slot shift (stash \$(true) drop)" \
  "$(bash_payload "bash -c 'git stash \$(true) drop'")"
test_deny  "$IRRECOVERABLE" "subagent: bash -c hiding a nested claude -p spawn" \
  "$(bash_agent_payload "bash -c 'claude -p hi'" fork)"
test_deny  "$IRRECOVERABLE" "subagent: eval hiding a nested claude --bg spawn" \
  "$(bash_agent_payload "eval 'claude --bg'" fork)"
test_allow "$IRRECOVERABLE" "main session: bash -c claude -p (no agent_id, not a nested spawn)" \
  "$(bash_payload "bash -c 'claude -p hi'")"
test_allow "$IRRECOVERABLE" "sudo bash -c with a harmless body" \
  "$(bash_payload "sudo bash -c 'ls -la'")"
# Non-goal: cat <<EOF | bash, eval "$(cat <<EOF)", fish <<EOF, and a << lookalike inside quotes.
test_allow "$TASK_COMPLETE" "non-TaskUpdate tool with agent_type (out of scope)" \
  "$(python3 -c 'import json; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"ls"},"agent_type":"mh:build-error-resolver"}))')"

echo ""

echo "=== v1.0.0 gate edits (worktree allowed, git add -A merge carve-out, --worktree spawn, stash list) ==="
# Payload with an explicit cwd (irrecoverable.py checks MERGE_HEAD there).
bash_cwd_payload() { python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$2"; }
test_allow "$IRRECOVERABLE" "git worktree add -b x ../y is ALLOWED (single-branch worktree doctrine block removed)" \
  "$(bash_payload 'git worktree add -b x ../y')"
test_allow "$IRRECOVERABLE" "git -C . worktree add -b feature (was denied by the removed worktree block)" \
  "$(bash_payload 'git -C . worktree add -b feature /tmp/wt-feature')"
MERGE_FIX=$(mktemp -d "${TMPDIR:-/tmp}/kbg-merge-fixture.XXXXXX")
NOMERGE_FIX=$(mktemp -d "${TMPDIR:-/tmp}/kbg-nomerge-fixture.XXXXXX")
( cd "$MERGE_FIX" && git init -q -b develop . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && echo a > f && git add f && git -c user.email=t@t -c user.name=t commit -q -m a \
  && git checkout -q -b side && echo b > f && git -c user.email=t@t -c user.name=t commit -q -am b \
  && git checkout -q develop && echo c > f && git -c user.email=t@t -c user.name=t commit -q -am c \
  && git -c user.email=t@t -c user.name=t merge -q side >/dev/null 2>&1; true )
( cd "$NOMERGE_FIX" && git init -q -b develop . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
if git -C "$MERGE_FIX" rev-parse -q --verify MERGE_HEAD >/dev/null; then
  test_allow "$IRRECOVERABLE" "git add -A ALLOWED while MERGE_HEAD exists in the payload cwd (mid-merge carve-out)" \
    "$(bash_cwd_payload 'git add -A' "$MERGE_FIX")"
  test_allow "$IRRECOVERABLE" "git add . ALLOWED mid-merge" \
    "$(bash_cwd_payload 'git add .' "$MERGE_FIX")"
else
  echo "  ❌ merge fixture failed to reach a conflicted state" >&2; fail=$((fail + 1))
fi
test_deny "$IRRECOVERABLE" "git add -A DENIED in a repo with no MERGE_HEAD" \
  "$(bash_cwd_payload 'git add -A' "$NOMERGE_FIX")"
test_deny "$IRRECOVERABLE" "git add --all DENIED with no cwd in the payload (falls back to process cwd, not mid-merge)" \
  "$(bash_payload 'git add --all')"

# M7 (harness gap-audit, 2026-09-20): a bad cwd makes _mid_merge()'s own
# subprocess.run raise (FileNotFoundError), caught by its except -- the deny
# that follows must be distinguishable from a genuine "not mid-merge" deny.
mid_merge_err=$(bash_cwd_payload 'git add -A' "/nonexistent/kbg-mid-merge-probe-$$" | bash "$IRRECOVERABLE" 2>&1 1>/dev/null)
mid_merge_rc=$(bash_cwd_payload 'git add -A' "/nonexistent/kbg-mid-merge-probe-$$" | bash "$IRRECOVERABLE" >/dev/null 2>/dev/null; echo $?)
if [[ "$mid_merge_rc" == "2" ]] && printf '%s' "$mid_merge_err" | /usr/bin/grep -q "mid-merge check itself failed"; then
  echo "  ✅ DENY + diagnostic: git add -A with an unreachable cwd denies AND names that the mid-merge check itself failed"
  pass=$((pass + 1))
else
  echo "  ❌ DENY+diagnostic EXPECTED but got exit $mid_merge_rc, stderr: $mid_merge_err" >&2
  fail=$((fail + 1))
fi

trash "$MERGE_FIX" "$NOMERGE_FIX" 2>/dev/null || true
test_deny "$IRRECOVERABLE" "subagent: claude -p hi via Bash denied" \
  "$(bash_agent_payload 'claude -p hi' fork)"
test_deny "$IRRECOVERABLE" "subagent: claude --worktree x denied (new flag in the ported nested-spawn deny)" \
  "$(bash_agent_payload 'claude --worktree x' fork)"
test_deny "$IRRECOVERABLE" "subagent: claude --bg denied" \
  "$(bash_agent_payload 'claude --bg "run it"' fork)"
# GH #157: a backslash-escaped quote outside a quoted span is a literal
# character in real bash, never a string opener -- the tokenizer must not
# let it swallow the real ";" and credit othertool's -p back to claude.
test_allow "$IRRECOVERABLE" "#157: escaped double quote before a real ; is literal, othertool's -p stays with othertool" \
  "$(bash_agent_payload 'claude \" ; othertool -p "x"' fork)"
test_allow "$IRRECOVERABLE" "#157: escaped single quote before a real ; is literal" \
  "$(bash_agent_payload "claude \\' ; othertool -p 'x'" fork)"
test_allow "$IRRECOVERABLE" "#157 control: escaped quote then claude with no flag" \
  "$(bash_agent_payload 'echo \" ; claude' fork)"
test_allow "$IRRECOVERABLE" "#157 control: claude with a lone escaped quote and no flag" \
  "$(bash_agent_payload 'claude \"' fork)"
test_deny  "$IRRECOVERABLE" "#157 control: real -p after a literal escaped quote still denied" \
  "$(bash_agent_payload 'claude \"x\" -p y' fork)"
test_deny  "$IRRECOVERABLE" "#157 control: real double-quoted span containing ; still swallows it, -p denied" \
  "$(bash_agent_payload 'claude "a ; b" -p y' fork)"
test_deny  "$IRRECOVERABLE" "#157 control: single-quoted escaped quote is a real span, -p denied" \
  "$(bash_agent_payload "claude '\\\"' -p y" fork)"
test_deny  "$IRRECOVERABLE" "#157 control: even backslash run before a quote leaves the quote live, ; swallowed, -p denied" \
  "$(bash_agent_payload 'claude \\"a ; b" -p y' fork)"
test_allow "$IRRECOVERABLE" "main session: claude --worktree x allowed (no agent_id)" \
  "$(bash_agent_payload 'claude --worktree x' '')"
test_allow "$SUBAGENT_GIT_GUARD" "subagent: git stash list allowed (read-only carve-out)" \
  "$(bash_agent_payload 'git stash list' fork)"
test_allow "$SUBAGENT_GIT_GUARD" "subagent: git stash show -p allowed (read-only carve-out)" \
  "$(bash_agent_payload 'git stash show -p' fork)"
test_deny "$SUBAGENT_GIT_GUARD" "subagent: git stash (bare) still denied" \
  "$(bash_agent_payload 'git stash' fork)"
test_deny "$SUBAGENT_GIT_GUARD" "subagent: git stash pop still denied" \
  "$(bash_agent_payload 'git stash pop' fork)"
test_deny "$SUBAGENT_GIT_GUARD" "subagent: git stash listing (not the list verb) still denied" \
  "$(bash_agent_payload 'git stash listing' fork)"

echo ""
echo "=== subagent-spawn-guard (GH #151: a dispatched subagent may not call the Agent tool itself) ==="
test_deny "$SUBAGENT_SPAWN_GUARD" "subagent (general-purpose) calling Agent to spawn its own reviewer" \
  "$(agent_payload 'general-purpose' 'agent-1' 'general-purpose')"
test_deny "$SUBAGENT_SPAWN_GUARD" "subagent (fork) calling Agent with a DIFFERENT subagent_type still denied (closes the same-type-switch evasion from the 2026-08-31 fork-recursive-spawn incident -- the gate never inspects subagent_type)" \
  "$(agent_payload 'general-purpose' 'agent-2' 'fork')"
test_deny "$SUBAGENT_SPAWN_GUARD" "subagent with no agent_type recorded (agent_id alone is the signal) still denied" \
  "$(agent_payload 'mh:silent-failure-hunter' 'agent-3' '')"
test_allow "$SUBAGENT_SPAWN_GUARD" "main session calling Agent (no agent_id) allowed" \
  "$(agent_payload 'general-purpose' '' '')"
test_allow "$SUBAGENT_SPAWN_GUARD" "subagent calling a non-Agent tool (Bash) is out of scope for this gate" \
  "$(bash_agent_payload 'ls -la' fork)"
# GH #154: the gate's own stated intent is to key on PRESENCE of agent_id, not
# a non-empty/non-null value -- these three exercise cases the old bash
# fast-path (raw-text substring match) and old python truthiness check
# (`if not agent_id`) both mishandled as "no agent_id" when the key was in
# fact present. A real payload capture (2026-09-07, matt-harness issue #154)
# never observed an empty/null/escaped agent_id in practice -- these are
# hardening tests for a theoretical gap the gate's own contract should still
# hold against, not evidence the gap is live-exploitable.
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #154 gap 2: agent_id present but an empty string still denied" \
  "$(agent_payload_forced_id 'general-purpose' '')"
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #154 gap 2: agent_id present but JSON null still denied" \
  "$(agent_payload_forced_id 'general-purpose' '__NULL__')"
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #154 gap 1: agent_id key JSON-escaped (\\u005f for the underscore) still denied, not fast-pathed past on raw-text match" \
  "$(agent_payload_escaped_id_key)"
# The .sh gate has no bash-level fast path (removed for GH #154) -- every
# payload always reaches python3, so these exercise the json.load()/
# isinstance() fail-safe branches directly.
test_allow "$SUBAGENT_SPAWN_GUARD" "malformed stdin (fail-safe allow)" \
  '{"agent_id": invalid'
test_allow "$SUBAGENT_SPAWN_GUARD" "valid JSON but non-object payload (fail-safe allow)" \
  '["agent_id"]'
# GH #156: a 5000-digit UNQUOTED int literal used to raise ValueError inside
# json.load() itself (CPython 3.11+'s int-string digit limit), caught by the
# same broad `except Exception: allow` as ordinary malformed JSON -- a
# well-formed-but-huge-int payload bypassed this gate's actual logic instead
# of being parsed and denied normally.
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #156: 5000-digit unquoted agent_id parses and denies, doesn't fail-open past the int-digit limit" \
  "$(printf '{"tool_name":"Agent","tool_input":{"prompt":"x","description":"y","subagent_type":"general-purpose"},"agent_id":%s}' "$(python3 -c "print('9'*5000)")")"

echo ""
echo "=== routine-trigger-guard (ADR 0004 §4/§5 item 6: nothing gated RemoteTrigger before this) ==="
# mh:deep-audit (2026-09-28) found the original version action-blind (asked on
# read-only actions too) and CronCreate misclassified as a Routine trigger --
# both fixed; these cases cover the corrected, narrower scope.
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=create asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'create')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=update asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'update')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=run asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'run')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=create_webhook_trigger asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'create_webhook_trigger')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger with no action key at all fails toward asking" \
  "$(routine_trigger_payload 'RemoteTrigger')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger with an unrecognized future action fails toward asking" \
  "$(routine_trigger_payload 'RemoteTrigger' 'some_future_action')"
# mh:blind-spot-hunter (2026-09-28): a non-string action (list/dict) crashed the gate's
# `action in READ_ONLY_ACTIONS` membership check with an unhandled TypeError, and Claude Code
# treats that non-zero, non-2 exit as non-blocking -- the call went through with no ask.
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger with a non-string (list) action fails toward asking, not a crash-through-allow" \
  "$(python3 -c 'import json; print(json.dumps({"tool_name": "RemoteTrigger", "tool_input": {"action": ["create"]}}))')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=list is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'list')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=get is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'get')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=list_runs is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'list_runs')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=get_run_log is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'get_run_log')"
test_allow "$ROUTINE_TRIGGER_GUARD" "CronCreate is out of scope (session-only, no new credential), allowed" \
  "$(routine_trigger_payload 'CronCreate' 'create')"
test_allow "$ROUTINE_TRIGGER_GUARD" "unrelated tool (Bash) is out of scope for this gate" \
  "$(bash_payload 'ls -la')"
test_allow "$ROUTINE_TRIGGER_GUARD" "malformed stdin (fail-safe allow)" \
  '{"tool_name": invalid'
test_allow "$ROUTINE_TRIGGER_GUARD" "valid JSON but non-object payload (fail-safe allow)" \
  '["RemoteTrigger"]'

# Missing-sibling .py (corrupted/partial plugin install), mirroring the
# irrecoverable.py case below but expecting this gate's own documented
# allow-on-missing-sibling posture, not a deny (mh:deep-audit, 2026-09-28:
# this path was documented in operating-model.md but had no regression test).
MISSPY_RTG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kbg-misspy-rtg.XXXXXX")
cp "$ROUTINE_TRIGGER_GUARD" "$MISSPY_RTG_DIR/routine-trigger-guard.sh"
_errf=$(mktemp "${TMPDIR:-/tmp}/kbg-misspy-rtg-err.XXXXXX")
_out=$(routine_trigger_payload 'RemoteTrigger' 'create' | bash "$MISSPY_RTG_DIR/routine-trigger-guard.sh" 2>"$_errf")
_rc=$?
_ok=1
if [ "$_rc" -eq 0 ] && [ -z "$_out" ] && grep -q '\[mh:gate\]' "$_errf"; then
  _ok=0
fi
if [ "$_ok" -eq 0 ]; then
  echo "  ✅ ALLOW: missing sibling routine-trigger-guard.py -> fails open (exit 0) with [mh:gate] message"
  pass=$((pass + 1))
else
  echo "  ❌ missing sibling routine-trigger-guard.py: expected exit 0 + empty stdout + [mh:gate] message, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2
  fail=$((fail + 1))
fi
rm -f "$_errf"
trash "$MISSPY_RTG_DIR" 2>/dev/null || true

echo "=== fast-path (bash pre-filter that skips python3 on commands that cannot match, added 2026-08-14) ==="
# Irrecoverable gained a bash fast-path so a benign command skips the python3 cold-start.
test_deny  "$IRRECOVERABLE" "r\"\"m -rf (quote-concatenation -> fast-path quote-strip)" \
  "$(bash_payload 'r""m -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "r\\m -rf (backslash-concatenation -> fast-path strip)" \
  "$(bash_payload 'r\m -rf /tmp/x')"
# A backslash-newline continuation splitting the argv0 ITSELF (not just a flag) turns the \n
# escape into a space at the fast-path's own sed step, so "git"/"rm" never survives as one
# substring and the fast path exits 0 before python3.
test_deny  "$IRRECOVERABLE" "gi + backslash-newline + t (argv0 split, was a fast-path bypass)" \
  "$(bash_payload $'gi\\\nt push --force origin develop')"
test_deny  "$IRRECOVERABLE" "r + backslash-newline + m (argv0 split, was a fast-path bypass)" \
  "$(bash_payload $'r\\\nm -rf /tmp/x')"
# The fast path's sed turns a JSON \n or \t escape into a space. A command holding a literal
# backslash then t (JSON: two backslashes then t) was misread as that escape, so the argv0 lost
# its letter and python3 never ran. The shell reads backslash-t as a plain t (fuzz sweep 2026-10-01).
test_deny  "$IRRECOVERABLE" "gi + literal backslash-t (argv0 split, was a fast-path bypass)" \
  "$(bash_payload 'gi\t push --force origin develop')"
test_deny  "$IRRECOVERABLE" "fi + literal backslash-n + d (find argv0 split, was a fast-path bypass)" \
  "$(bash_payload 'fi\nd /tmp/x -delete')"
test_deny  "$IRRECOVERABLE" "control: a real tab between git and its argument still denies" \
  "$(bash_payload $'git\tpush --force origin develop')"
test_allow "$IRRECOVERABLE" "control: literal backslash-t in an unrelated command stays allowed" \
  "$(bash_payload 'printf "a\tb"')"
# GH #309: the argv0 brace rows (r{m,m}, fi{nd,nd}) sit with the other brace-view rows below.
test_allow "$IRRECOVERABLE" "GH #309 control: a brace group and a brace list with no verb stay allowed" \
  "$(bash_payload '{ echo a; }; ls x{a,b}')"
# "gh" was added to the fast-path candidate list alongside the ask-tier gh
# merge rule (Phase B) -- without this, "gh pr merge" would fast-path
# straight to allow, never reaching python3's ask() at all.
test_ask "$IRRECOVERABLE" "gh pr merge reaches python3 through the fast path (not swallowed by it)" \
  "$(bash_payload 'gh pr merge 5')"

echo ""
echo "=== python3-missing fail-open (#93: every deny gate must exit 0 with ONE stderr note, never rc=127 or a silent block) ==="
# A PATH stub dir with the gates' shell dependencies (cat/sed/tr/grep/awk + bash; awk since GH #309) but NO python3.
NOPY_BIN=$(mktemp -d "${TMPDIR:-/tmp}/kbg-nopy.XXXXXX")
for _t in bash cat sed tr grep awk; do
  _src=$(PATH="/usr/bin:/bin" command -v "$_t" || command -v "$_t")
  ln -s "$_src" "$NOPY_BIN/$_t"
done

# Test_nopython_allow <gate> <desc> <payload> [extra env VAR=VAL...]
test_nopython_allow() {
  local gate="$1" desc="$2" payload="$3"; shift 3
  local rc errf
  errf=$(mktemp "${TMPDIR:-/tmp}/kbg-nopy-err.XXXXXX")
  rc=$(echo "$payload" | env "$@" PATH="$NOPY_BIN" bash "$gate" 2>"$errf"; echo $?)
  if [[ "$rc" == "0" ]] && grep -q 'python3 not found' "$errf"; then
    echo "  ✅ NO-PYTHON ALLOW: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ NO-PYTHON ALLOW expected (rc=0 + note) but got rc=$rc, stderr: $(cat "$errf")" >&2
    fail=$((fail + 1))
  fi
  rm -f "$errf"
}

# Test_documented_fastpath_allow <gate> <desc> <payload> [extra env VAR=VAL...] Inverse of
# test_nopython_allow above (same NOPY_BIN instrument, opposite expectation): asserts rc=0
# WITHOUT the "python3 not found" note, i.e.
test_documented_fastpath_allow() {
  local gate="$1" desc="$2" payload="$3"; shift 3
  local rc errf
  errf=$(mktemp "${TMPDIR:-/tmp}/kbg-nopy-err.XXXXXX")
  rc=$(echo "$payload" | env "$@" PATH="$NOPY_BIN" bash "$gate" 2>"$errf"; echo $?)
  if [[ "$rc" == "0" ]] && ! grep -q 'python3 not found' "$errf"; then
    echo "  ✅ DOCUMENTED FAST-PATH ALLOW (GH #134, non-live): $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ documented fast-path allow expected (rc=0, no portability note) but got rc=$rc, stderr: $(cat "$errf")" >&2
    fail=$((fail + 1))
  fi
  rm -f "$errf"
}


test_nopython_allow "$IRRECOVERABLE" "irrecoverable: rm -rf passes with note (was: rc=127 read as fail-CLOSED, blocking every git/rm command)" \
  "$(bash_payload 'rm -rf /tmp/x')"
# Backtick/$(...) fast-path bypass: a command substitution vanishes in real bash ("gi`true`t" IS
# "git" once bash evaluates it) but survives as literal characters through the fast path's
# normalization, so neither "git" nor any other tracked argv0 forms a contiguous substring and
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: backtick-split argv0 (gi\`true\`t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi`true`t push --force origin develop')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$(...)-split argv0 (gi\$(true)t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi$(true)t push --force origin develop')"
# Same class, two more splicing spellings found alongside the backtick/$(...) fix: ${x} with x
# unset expands to nothing ("gi${x}t" IS "git"), and $'...' ANSI-C quoting resolves escapes
# ("gi$'\x74'" IS "git").
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \${x}-split argv0 (gi\${x}t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi${x}t push --force origin develop')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$'...'-split argv0 (gi\$'\x74' push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload "gi\$'\\x74' push --force origin develop")"
# Fresh-context review finding (2026-09-03): $@ and $* are a 5th zero-width splicer the 4-marker
# enumeration above never covered.
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$@-split argv0 (gi\$@t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi$@t push --force origin develop')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$*-split argv0 (gi\$*t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi$*t push --force origin develop')"
# GH #336: mkfs, chmod and source are candidate words, so they reach python.
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: mkfs.ext4 reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'mkfs.ext4 /dev/sda1')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: mke2fs reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'mke2fs /dev/sda1')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: chmod -R 777 reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'chmod -R 777 /')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: source reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'source ./setup.sh')"
# A $ that arrives JSON-\uXXXX-escaped instead of as a literal byte is invisible to the raw
# _has_subst scan above.
test_documented_fastpath_allow "$IRRECOVERABLE" "irrecoverable: JSON \\u0024-escaped \$ around a \${x} splice (gi\\u0024{x}t push --force) -- raw scan blind, documented non-live gap" \
  '{"tool_name":"Bash","tool_input":{"command":"gi\u0024{x}t push --force origin develop"}}'
test_nopython_allow "$TASK_COMPLETE" "task-complete-separation: subagent completion passes with note" \
  "$(taskupdate_payload 'completed' 'refactor-cleaner')"
test_nopython_allow "$SUBAGENT_SPAWN_GUARD" "subagent-spawn-guard: subagent calling Agent passes with note" \
  "$(agent_payload 'general-purpose' 'agent-1' 'general-purpose')"
test_nopython_allow "$ROUTINE_TRIGGER_GUARD" "routine-trigger-guard: RemoteTrigger passes with note" \
  "$(routine_trigger_payload 'RemoteTrigger')"

# Trash-fallback deny message (#93): with python3 present but NO trash CLI on PATH, the rm -rf
# deny must still fire (rc=2) and the message must route to the user instead of prescribing a
# binary the machine doesn't have.
TRASHLESS_BIN=$(mktemp -d "${TMPDIR:-/tmp}/kbg-notrash.XXXXXX")
# Dirname: GH #146 extracted irrecoverable.sh's embedded python3 -c block to a sibling
# irrecoverable.py, resolved via "$(dirname "$0")".
for _t in bash cat sed tr grep python3 dirname; do
  _src=$(PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" command -v "$_t" || command -v "$_t")
  ln -s "$_src" "$TRASHLESS_BIN/$_t"
done
_errf=$(mktemp "${TMPDIR:-/tmp}/kbg-notrash-err.XXXXXX")
_rc=$(bash_payload 'rm -rf /tmp/x' | env PATH="$TRASHLESS_BIN" bash "$IRRECOVERABLE" 2>"$_errf"; echo $?)
if [[ "$_rc" == "2" ]] && grep -q 'no trash CLI' "$_errf" && grep -q 'ask the user' "$_errf"; then
  echo "  ✅ DENY: rm -rf without a trash CLI still denies, message routes to the user (#93)"
  pass=$((pass + 1))
else
  echo "  ❌ rm -rf trashless deny expected (rc=2 + user-routing message) but got rc=$_rc, stderr: $(cat "$_errf")" >&2
  fail=$((fail + 1))
fi
rm -f "$_errf"

echo ""
echo "=== missing sibling .py (corrupted/partial plugin install; follow-up to #146) ==="
# Extracted this gate's embedded python3 -c block into a sibling irrecoverable.py, resolved via
# "$(dirname "$0")/irrecoverable.py".
MISSPY_IRR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kbg-misspy-irr.XXXXXX")
cp "$IRRECOVERABLE" "$MISSPY_IRR_DIR/irrecoverable.sh"
_errf=$(mktemp "${TMPDIR:-/tmp}/kbg-misspy-irr-err.XXXXXX")
_out=$(bash_payload 'rm -rf /tmp/x' | bash "$MISSPY_IRR_DIR/irrecoverable.sh" 2>"$_errf")
_rc=$?
_ok=1
if [ "$_rc" -eq 2 ] && [ -z "$_out" ] && grep -q '\[mh:gate\]' "$_errf" \
   && ! grep -qi "can't open file\|Traceback" "$_errf"; then
  _ok=0
fi
if [ "$_ok" -eq 0 ]; then
  echo "  ✅ DENY: missing sibling irrecoverable.py -> fails closed (exit 2) with [mh:gate] message, no raw traceback"
  pass=$((pass + 1))
else
  echo "  ❌ missing sibling irrecoverable.py: expected exit 2 + [mh:gate] message + no traceback, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2
  fail=$((fail + 1))
fi
rm -f "$_errf"
# Both gates run their .py through the _run.py import stub: with every sibling present but the stub,
# irrecoverable fails closed (exit 2) and subagent-git-guard fails open (exit 0), each with its own message.
MISSRUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kbg-missrun.XXXXXX")
cp "$ROOT"/hooks/gates/*.sh "$ROOT"/hooks/gates/*.py "$MISSRUN_DIR"/
[ -e "$MISSRUN_DIR/_run.py" ] && trash "$MISSRUN_DIR/_run.py"
_errf="$MISSRUN_DIR/err"
_out=$(bash_payload 'rm -rf /tmp/x' | bash "$MISSRUN_DIR/irrecoverable.sh" 2>"$_errf"); _rc=$?
if [ "$_rc" -eq 2 ] && [ -z "$_out" ] && /usr/bin/grep -q '\[mh:gate\].*_run.py missing' "$_errf"; then
  echo "  ✅ DENY: missing _run.py stub -> irrecoverable fails closed (exit 2) with [mh:gate] message"; pass=$((pass + 1))
else
  echo "  ❌ missing _run.py: irrecoverable expected exit 2 + [mh:gate] _run.py message, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2; fail=$((fail + 1))
fi
_out=$(bash_agent_payload 'git stash' fork | bash "$MISSRUN_DIR/subagent-git-guard.sh" 2>"$_errf"); _rc=$?
if [ "$_rc" -eq 0 ] && [ -z "$_out" ] && /usr/bin/grep -q '\[mh:gate\].*_run.py missing' "$_errf"; then
  echo "  ✅ ALLOW: missing _run.py stub -> subagent-git-guard fails open (exit 0) with [mh:gate] message"; pass=$((pass + 1))
else
  echo "  ❌ missing _run.py: subagent-git-guard expected exit 0 + [mh:gate] _run.py message, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2; fail=$((fail + 1))
fi
trash "$MISSRUN_DIR"

# GH #184/#185/#194/#195/#196: fail closed when the command is syntactically ambiguous (nested or
# mixed substitutions, a quoted ")" inside "$(", a "case" inside "$(", brace tokens, eval of a
# substitution) AND names an irrecoverable verb. Raw-text check, so it holds where blanking mis-closes.
# GH #219 (named-fd "{var}>") is not a raw-text rule here: the tokenizer reads it both ways instead (see _blank_redirections).
test_deny "$IRRECOVERABLE" 'GH #184: a quoted ")" inside $() must not hide rm -rf' \
  "$(bash_payload 'echo $(echo ")"; rm -rf /nonexistent-x)')"
test_deny "$IRRECOVERABLE" 'GH #185: backtick nested inside $() must not hide rm -rf' \
  "$(bash_payload 'echo $(echo `rm -rf /nonexistent-x`)')"
test_deny "$IRRECOVERABLE" 'GH #194: brace-hidden flag, git reset {--hard,}' \
  "$(bash_payload 'git reset {--hard,}')"
test_deny "$IRRECOVERABLE" 'GH #194: brace-hidden flag, rm {-rf,} X' \
  "$(bash_payload 'rm {-rf,} /nonexistent-x')"
test_deny "$IRRECOVERABLE" 'GH #194: a flag after a git @{n} revision, git reset HEAD@{1} --hard' \
  "$(bash_payload 'git reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #194: git push origin HEAD@{0} --force' \
  "$(bash_payload 'git push origin HEAD@{0} --force')"
test_deny "$IRRECOVERABLE" 'GH #194: a flag after a git ~{n} revision, git reset HEAD~{1} --hard' \
  "$(bash_payload 'git reset HEAD~{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #194: a flag after a git ^{commit} revision' \
  "$(bash_payload 'git reset HEAD^{commit} --hard')"
test_deny "$IRRECOVERABLE" 'GH #195: a case-pattern ")" inside $() must not hide rm -rf' \
  "$(bash_payload 'echo $(case a in a) rm -rf /nonexistent-x;; esac)')"
test_deny "$IRRECOVERABLE" 'GH #195: case inside $() then a real git reset --hard' \
  "$(bash_payload "echo \$(case a in 'a') true;; esac); git reset --hard")"
test_deny "$IRRECOVERABLE" 'GH #196: eval of a $() that builds rm -rf' \
  "$(bash_payload 'eval "$(echo rm -rf /nonexistent-x)"')"
test_deny "$IRRECOVERABLE" 'GH #196: escaped backtick nested in backticks' \
  "$(bash_payload 'echo `echo \`rm -rf /nonexistent-x\``')"
test_allow "$IRRECOVERABLE" 'ambiguity control: git log with @{1} and no destructive verb' \
  "$(bash_payload 'git log HEAD@{1}')"
test_allow "$IRRECOVERABLE" 'ambiguity control: git diff @{u}' \
  "$(bash_payload 'git diff @{u} --stat')"
test_allow "$IRRECOVERABLE" 'ambiguity control: brace list with no destructive verb' \
  "$(bash_payload 'mkdir -p /tmp/{a,b}')"
test_allow "$IRRECOVERABLE" 'ambiguity control: awk program braces, no destructive verb' \
  "$(bash_payload "awk '{print \$1}' /etc/hosts")"
test_allow "$IRRECOVERABLE" 'ambiguity control: plain $() and backticks with no destructive verb' \
  "$(bash_payload 'echo $(pwd) `date`')"
test_allow "$IRRECOVERABLE" 'ambiguity control: a plain rm of one file, no ambiguity' \
  "$(bash_payload 'rm /tmp/nonexistent-x')"
test_allow "$IRRECOVERABLE" 'ambiguity control: a branch switch with an ordinary $() argument' \
  "$(bash_payload 'git checkout "$(git branch --show-current)"')"
# Deep-audit 2026-09-30 (F1): the verb check must see a git global flag before the sub, and a
# path-qualified rm/git, or every ambiguous shape above is bypassed by respelling the verb.
test_deny "$IRRECOVERABLE" 'audit-0930 F1: git -C . reset {--hard,}' \
  "$(bash_payload 'git -C . reset {--hard,}')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: git --no-pager push origin HEAD@{0} --force' \
  "$(bash_payload 'git --no-pager push origin HEAD@{0} --force')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: git -C "a b" -c x.y=z reset HEAD@{1} --hard' \
  "$(bash_payload 'git -C "a b" -c x.y=z reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: /usr/bin/git reset HEAD~{1} --hard' \
  "$(bash_payload '/usr/bin/git reset HEAD~{1} --hard')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: /bin/rm {-rf,} X' \
  "$(bash_payload '/bin/rm {-rf,} /nonexistent-x')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: case inside $() hiding /bin/rm -rf' \
  "$(bash_payload 'echo $(case a in a) /bin/rm -rf /nonexistent-x;; esac)')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: eval of a $() that builds /bin/rm -rf' \
  "$(bash_payload 'eval "$(echo /bin/rm -rf /nonexistent-x)"')"
test_allow "$IRRECOVERABLE" 'audit-0930 F1 control: git -C . log HEAD@{1} has no destructive verb' \
  "$(bash_payload 'git -C . log HEAD@{1}')"
test_allow "$IRRECOVERABLE" 'audit-0930 F1 control: x.git and --git before a verb word are not git' \
  "$(bash_payload 'echo {a,b} x.git reset --git push')"
# Deep-audit 2026-09-30 (F2): one shape's narrow verb list must not hide another shape's broad one.
test_deny "$IRRECOVERABLE" 'audit-0930 F2: an escaped backtick must not mask a brace-hidden rm flag' \
  "$(bash_payload 'echo \` ; rm {-rf,} /nonexistent-x')"
test_deny "$IRRECOVERABLE" 'audit-0930 F2: a nested substitution must not mask a brace-hidden push flag' \
  "$(bash_payload 'echo $(echo `date`); git push {-f,} origin main')"
# GH #254: a "{" or "}" inside a word is literal in bash, but the tokenizer split the word there and
# started a new window, so the flag after it was never seen by its command's rule.
test_deny "$IRRECOVERABLE" 'GH #254: git reset feat{1} --hard' \
  "$(bash_payload 'git reset feat{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #254: git branch old{1} -D' \
  "$(bash_payload 'git branch old{1} -D')"
test_deny "$IRRECOVERABLE" 'GH #254: git push origin x{1} -f' \
  "$(bash_payload 'git push origin x{1} -f')"
test_deny "$IRRECOVERABLE" 'GH #254: dd if=a{1} of=/dev/disk9' \
  "$(bash_payload 'dd if=a{1} of=/dev/disk9')"
test_deny "$IRRECOVERABLE" 'GH #254: find with a word ending in } before -delete' \
  "$(bash_payload "find . -name '*.log' ! -name keep} -delete")"
test_deny "$IRRECOVERABLE" 'GH #254/#255: a bundled -fu after HEAD@{0}' \
  "$(bash_payload 'git push origin HEAD@{0} -fu')"
test_deny "$IRRECOVERABLE" 'GH #254/#255: an abbreviated --har after HEAD@{1}' \
  "$(bash_payload 'git reset HEAD@{1} --har')"
test_allow "$IRRECOVERABLE" 'GH #254 control: git stash show stash@{1}' \
  "$(bash_payload 'git stash show stash@{1}')"
test_allow "$IRRECOVERABLE" 'GH #254 control: git checkout feat{1} is a branch switch' \
  "$(bash_payload 'git checkout feat{1}')"
test_allow "$IRRECOVERABLE" 'GH #254 control: a { } group with a harmless body' \
  "$(bash_payload '{ echo a; echo b; } > /tmp/nonexistent-x')"
# GH #255: the value-taking git globals are one list (GIT_VALUE_GLOBALS) shared by the parser and the
# ambiguity verb walk; the walk takes escaped values, line continuations and 32 globals; the verb is
# also looked for with quotes and backslashes dropped.
test_deny "$IRRECOVERABLE" 'GH #255: git --namespace x reset --hard' \
  "$(bash_payload 'git --namespace x reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: git --namespace x clean -fd' \
  "$(bash_payload 'git --namespace x clean -fd')"
test_deny "$IRRECOVERABLE" 'GH #255: git --attr-source HEAD push --force' \
  "$(bash_payload 'git --attr-source HEAD push --force origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: git --namespace=x reset --hard' \
  "$(bash_payload 'git --namespace=x reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: nine -C globals before a brace-hidden push flag' \
  "$(bash_payload 'git -C . -C . -C . -C . -C . -C . -C . -C . -C . push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: an escaped-space -C value before reset --hard after @{1}' \
  "$(bash_payload 'git -C My\ Project reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: a line continuation between -C value and reset' \
  "$(bash_payload $'git -C /repo \\\n  reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: an abbreviated --forc after HEAD@{0}' \
  "$(bash_payload 'git push origin HEAD@{0} --forc')"
# Deep-audit 2026-10-01: the ambiguity verb regex is length-bounded (~400 chars of globals), so the
# parser, which resolves the git sub at any length, also denies a destructive sub next to a brace token.
_many_c=$(printf -- '-C . %.0s' $(seq 100))
_many_cfg=$(printf -- '-c a=b %.0s' $(seq 70))
test_deny "$IRRECOVERABLE" 'deep-audit 2026-10-01: 100 -C globals before a brace-hidden push flag' \
  "$(bash_payload "git ${_many_c}push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'deep-audit 2026-10-01: 70 -c globals before a brace-hidden reset flag' \
  "$(bash_payload "git ${_many_cfg}reset {--hard,}")"
test_allow "$IRRECOVERABLE" 'deep-audit 2026-10-01 control: 100 -C globals, a brace, a read-only sub' \
  "$(bash_payload "git ${_many_c}log {a,b}")"
test_deny "$IRRECOVERABLE" 'GH #255: a double-quoted git verb before a brace-hidden flag' \
  "$(bash_payload '"git" push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: a single-quoted git verb before a brace-hidden flag' \
  "$(bash_payload "'git' push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: a backslash inside rm before a brace-hidden flag' \
  "$(bash_payload 'r\m {-rf,} X')"
test_deny "$IRRECOVERABLE" 'GH #255: a quoted verb with a quoted spaced -C value' \
  "$(bash_payload '"git" -C "a b" reset {--hard,} HEAD')"
test_deny "$IRRECOVERABLE" 'GH #255: -c user.name with a quoted space before a brace-hidden flag' \
  "$(bash_payload "git -c user.name='A B' push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: 40 -C globals before a brace-hidden push flag' \
  "$(bash_payload "git $(printf '%.0s-C . ' $(seq 40))push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: a quoted ; inside a -C value before a brace-hidden push flag' \
  "$(bash_payload "git -C 'a;b' push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: a quoted | inside a --namespace value before a brace-hidden flag' \
  "$(bash_payload 'git --namespace "a|b" push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: an escaped ; inside a -C value before a brace-hidden flag' \
  "$(bash_payload 'git -C a\;b push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: a substitution with && inside a quoted -C value' \
  "$(bash_payload 'git -C "$(cd /x && pwd)" push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: -xdf bundle after HEAD@{1}' \
  "$(bash_payload 'git reset HEAD@{1} -xdf')"
test_deny "$IRRECOVERABLE" 'GH #255: an unquoted $( ) with && inside a --namespace value' \
  "$(bash_payload 'git --namespace $(a && b) push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: an unquoted backtick span with ; inside a -C value' \
  "$(bash_payload 'git -C `a;b` push {--force,} origin main')"
test_allow "$IRRECOVERABLE" 'GH #255 control: a quoted ; -C value with a harmless status' \
  "$(bash_payload "git -C 'a;b' status {a,b}")"
test_allow "$IRRECOVERABLE" 'GH #255 control: 40 repeated -C then a brace token runs in bounded time' \
  "$(bash_payload "git $(printf '%.0s-C ' $(seq 40))foo {a,b}")"
test_allow "$IRRECOVERABLE" 'GH #255 control: ls -lrt after HEAD@{1} with a find substitution' \
  "$(bash_payload 'ls -lrt HEAD@{1} $(find . -name x)')"
test_allow "$IRRECOVERABLE" 'GH #255 control: git --namespace x status' \
  "$(bash_payload 'git --namespace x status')"
test_allow "$IRRECOVERABLE" 'GH #255 control: git push origin HEAD@{0} has no flag' \
  "$(bash_payload 'git push origin HEAD@{0}')"
test_allow "$IRRECOVERABLE" 'GH #255 control: echo "git" hello' \
  "$(bash_payload 'echo "git" hello')"

# GH #246: the nested-spawn anchor scan is quadratic on padded input, and a hook past its 8 s timeout
# allows. 48 KB of `env ; ` in front of a hidden `claude -p` took 10 s. A shared work budget now
# denies a command too dense to scan, fast; a subagent only. Tails hold `claude`: irrecoverable.sh
# skips python for a command with no candidate word, so a plain `ls` tail never reaches this scan.
_pad() { python3 -c 'import sys; sys.stdout.write(sys.argv[1] * int(sys.argv[2]))' "$1" "$2"; }
_PAD_ENV=$(_pad 'env ; ' 8000; printf x); _PAD_ENV=${_PAD_ENV%x}  # $(...) strips trailing blanks and newlines
_PAD_NL=$(_pad $'\n' 6000; printf x); _PAD_NL=${_PAD_NL%x}
_t0=$(date +%s)
test_deny "$IRRECOVERABLE" 'GH #246: a spawn hidden behind 48 KB of padding is denied, not timed out into allow' \
  "$(bash_agent_payload "${_PAD_ENV}time ls; claude -p a; claude --version" fork)"
test_deny "$IRRECOVERABLE" 'GH #246: a padded benign command is refused by the work budget, fast' \
  "$(bash_agent_payload "${_PAD_ENV}claude --version" fork)"
test_deny "$IRRECOVERABLE" 'GH #246: 6000 bare newlines before a benign command is refused by the work budget' \
  "$(bash_agent_payload "${_PAD_NL}claude --version" fork)"
test_deny "$IRRECOVERABLE" 'GH #246: padding inside a bash -c body counts against the same budget' \
  "$(bash_agent_payload "bash -c '${_PAD_ENV}claude --version'; bash -c '${_PAD_ENV}claude --version'" fork)"
_el=$(( $(date +%s) - _t0 ))
if [ "$_el" -lt 8 ]; then echo "  ✅ GH #246: every padded shape decided inside the 8 s hook timeout (${_el}s)"; pass=$((pass + 1))
else echo "  ❌ GH #246: padded shapes took ${_el}s, past the hook timeout" >&2; fail=$((fail + 1)); fi
test_allow "$IRRECOVERABLE" 'GH #246 control: the main session is never scanned, padding is allowed' \
  "$(bash_agent_payload "${_PAD_ENV}claude --version" '')"
test_allow "$IRRECOVERABLE" 'GH #246 control: a long ordinary subagent command (20 KB) is still allowed' \
  "$(bash_agent_payload "echo $(_pad x 20000); claude --version" fork)"
test_allow "$IRRECOVERABLE" 'GH #246 control: a 400-line ordinary subagent script is still allowed' \
  "$(bash_agent_payload "$(_pad $'echo hello world\n' 400)claude --version" fork)"

# GH #248: three shapes that reached their target on develop too: a wrapped FIRST statement (the
# greedy walk lands on the last claude), a brace group, and `xargs claude` (xargs was no wrapper here).
for _c in \
  'time claude -p x; claude --version' \
  'env A=1 claude --bg x; claude --help' \
  'timeout 5 claude --agent x && claude --version' \
  '{ claude -p x; }' \
  '{ claude --bg x; } 2>&1' \
  'true; { claude -p x; }' \
  'xargs claude -p x' \
  'xargs -n1 claude --print x' \
  'echo a | xargs -I{} claude -p {}' \
  'nice -n 5 xargs claude -p x' \
  'bash -c "{ claude -p x; }"' \
  'bash -c "time claude -p x; claude --version"' ; do
  test_deny "$IRRECOVERABLE" "GH #248: spawn reached through a wrapped first statement, brace group or xargs: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'time claude --version; claude --help' \
  '{ claude --version; }' \
  'xargs claude --version' \
  'xargs ls' \
  'echo {a,b} claude' \
  'git commit -m "mention claude in docs"' ; do
  test_allow "$IRRECOVERABLE" "GH #248 control: benign claude use still allowed: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #248 control: the main session is never scanned' \
  "$(bash_agent_payload '{ claude -p x; }' '')"
# Deep-audit 5: repo-gotchas asks two awkward shapes of every new wrapper word, here xargs: a glued
# `name=1` (an assignment, not the wrapper) and a decoy whose walk could hide the statements after it.
for _c in \
  'xargs=1 claude -p x' \
  'xargs x && claude -p y && claude --version' ; do
  test_deny "$IRRECOVERABLE" "xargs wrapper awkward shape still denied: $_c" "$(bash_agent_payload "$_c" fork)"
done

# GH #275 follow-up (deep-audit): _AMBIG_FLAG_RE's `[uvnqxfdDrR]*[fdDrR][uvnqxfdDrR]*\b` retried every split
# of a long `-fff...` token (quadratic: 60 KB took 11 s, past the 8 s hook timeout, and a timed-out hook
# allows). `timeout 5` wraps the run, so a regression reads as rc 124, not a slow pass.
_flag_dos_cmd="$(python3 -c 'print("git @{1} -" + "f" * 60000 + "c; git reset --hard")')"
_flag_dos_rc=$(bash_payload "$_flag_dos_cmd" | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_flag_dos_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): a 60 KB non-matching flag token after git @{1} is scanned in bounded time; --hard carries the deny"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $_flag_dos_rc (124 = timed out, quadratic flag scan): 60 KB flag token after git @{1}" >&2
  fail=$((fail + 1))
fi
test_deny  "$IRRECOVERABLE" 'GH #275 control: a short bundled flag after git @{1} denies with no --hard in sight' \
  "$(bash_payload 'git reset HEAD@{1} -xdf; git stash')"
test_allow "$IRRECOVERABLE" 'GH #275 control: a non-bundle flag after git @{1} next to a broad verb is allowed' \
  "$(bash_payload 'git stash show stash@{1} -p')"
# Deep-audit step 6: the narrow-verb push piece `\s-[A-Za-z]*f\b` backed off across a whole long token from
# every git/push anchor in reach (13 s at 140 KB). The escaped backtick selects the narrow regex.
_push_dos_cmd="$(python3 -c 'print("\\`" + "git " * 100 + "push " * 40 + "-" + "f" * 140000 + "c" + "; psql -c \"DROP TABLE users\"")')"
_push_dos_rc=$(bash_payload "$_push_dos_cmd" | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_push_dos_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): a 140 KB flag token behind 100 git and 40 push anchors is scanned in bounded time"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $_push_dos_rc (124 = timed out, quadratic push-flag scan)" >&2
  fail=$((fail + 1))
fi
test_deny  "$IRRECOVERABLE" 'GH #275 control: a short push -f next to an escaped backtick still denies' \
  "$(bash_payload 'echo \` ; git push origin main -f')"

# GH #284: the narrow push piece needed `f` to be the LAST letter of the flag, so a bundle like -fu missed it
# (defense-in-depth: the main parser already denies these). Check the regex itself, since the hook never reaches it.
_narrow_rc=$(python3 - "$ROOT/hooks/gates/irrecoverable.py" <<'PY'
import re, sys
# The module runs the gate at import, so exec only the regex definitions (from _AMBIG_UNIT to _ambiguous).
src = open(sys.argv[1]).read()
block = src[src.index("_AMBIG_UNIT = "):src.index("def _ambiguous(")]
ns = {"re": re}; exec(block, ns)
r = ns["_AMBIG_NARROW_VERB_RE"]
hit = all(r.search(c) for c in ("git push origin main -fu", "git push -uf origin main", "git push origin main -f"))
miss = not any(r.search(c) for c in ("git push -u origin main", "git push origin main -u"))
print(0 if hit and miss else 1)
PY
)
if [[ "$_narrow_rc" == "0" ]]; then
  echo "  ✅ GH #284: narrow push piece matches bundled -fu/-uf, ignores -u"
  pass=$((pass + 1))
else
  echo "  ❌ GH #284: narrow push piece misses a bundled force flag or over-matches -u" >&2
  fail=$((fail + 1))
fi

# GH #340: _AMBIG_GIT_SUB_RE names `switch` but _AMBIG_NARROW_AFTER had no `switch` key, so a narrow-shape
# command (escaped backtick, backtick plus $()) with a git switch raised KeyError: exit 1, which the .sh
# turned into an "internal error" deny. test_deny rejects a crash deny, so these rows need the real rule.
# The narrow piece for switch is "any switch" (like clean/restore): a flag piece missed $'-f' in a substitution
# body, which the main parser never sees, so a plain branch switch in these rare shapes stays denied.
test_deny  "$IRRECOVERABLE" 'GH #340: git switch <branch> next to an escaped backtick denies by rule, not crash' \
  "$(bash_payload 'echo \` ; git switch main')"
test_deny  "$IRRECOVERABLE" 'GH #340: git switch -c next to a backtick plus $() denies by rule, not crash' \
  "$(bash_payload 'x=$(echo `pwd`); git switch -c feat')"
test_deny  "$IRRECOVERABLE" 'GH #340: git switch --discard-changes next to an escaped backtick denies' \
  "$(bash_payload 'echo \` ; git switch --discard-changes main')"
test_deny  "$IRRECOVERABLE" "GH #340: git switch \$'-f' in a backtick body inside \$() denies" \
  "$(bash_payload "echo \$(echo \`git switch \$'-f' main\`)")"
test_deny  "$IRRECOVERABLE" "GH #340: eval of \$() holding git switch \$'-f' denies" \
  "$(bash_payload "eval \"\$(echo git switch \$'-f' main)\"")"
test_allow "$IRRECOVERABLE" 'GH #340 control: git status next to an escaped backtick is allowed' \
  "$(bash_payload 'echo \` ; git status')"
_switch_dos_cmd="$(python3 -c 'print("\\`" + "git status " * 100 + "-" + "q" * 140000 + " switch")')"
_timed_case 'GH #340: a switch after 100 git anchors and a 140 KB token is found in bounded time' 2 "$_switch_dos_cmd"
# Every sub word the ambiguity check finds needs a narrow piece; one with no piece counts as a hit (deny).
_narrow_keys_rc=$(python3 - "$ROOT/hooks/gates/irrecoverable.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = src[src.index("_AMBIG_UNIT = "):src.index("def _ambiguous(")]
ns = {"re": re}; exec(block, ns)
subs = set(re.findall(r"\w+", ns["_AMBIG_GIT_SUB_RE"].pattern.split("(", 2)[2].split(")")[0]))
r = ns["_AMBIG_NARROW_VERB_RE"]
ok = subs == set(ns["_AMBIG_NARROW_AFTER"]) and bool(r.search("git switch main"))
ns["_AMBIG_NARROW_AFTER"].pop("switch")
ok = ok and bool(r.search("git switch main"))  # a sub with no narrow piece fails closed
print(0 if ok else 1)
PY
)
if [[ "$_narrow_keys_rc" == "0" ]]; then
  echo "  ✅ GH #340: every ambiguity sub word has a narrow piece, and a missing piece counts as a hit"
  pass=$((pass + 1))
else
  echo "  ❌ GH #340: an ambiguity sub word has no narrow piece, or a missing piece does not fail closed" >&2
  fail=$((fail + 1))
fi

# GH #349: the narrow pieces read $'-f' in a substitution body as $-f (no blank before the dash), so push,
# reset, checkout, branch, stash and rm let a quoted flag through. The ambiguity check now also reads a view
# with $'..' decoded and $".." as "..". The fuzz also found three narrow pieces narrower than the main parser:
# reset now takes --h/--har, push a +refspec, and checkout a "." that ends at a substitution close.
# Cases (each checked against real shells) live in a fixture.
_ansi_corpus="$ROOT/tests/hooks/fixtures/irrecoverable-ansi-c-flag-cases.txt"
_ansi_want=$(/usr/bin/grep -cE '^(DENY|ALLOW) ' "$_ansi_corpus"); _ansi_got=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #349: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *) test_allow "$IRRECOVERABLE" "GH #349 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" ;;
    *) continue ;;
  esac
  _ansi_got=$((_ansi_got + 1))
done < "$_ansi_corpus"
if [ "$_ansi_want" -ge 20 ] && [ "$_ansi_got" = "$_ansi_want" ]; then
  echo "  ✅ GH #349: corpus replayed every case ($_ansi_got)"; pass=$((pass + 1))
else
  echo "  ❌ GH #349: corpus replayed $_ansi_got of $_ansi_want cases" >&2; fail=$((fail + 1))
fi
_ansi_dos_cmd="$(python3 -c 'print("\\`" + "git " * 100 + "push " * 40 + "$" + chr(39) + "-" + "f" * 140000 + chr(39))')"
_timed_case "GH #349: a 140 KB \$'-f...' flag behind 100 git and 40 push anchors is found in bounded time" 2 "$_ansi_dos_cmd"
_ansi_dos_cmd="$(python3 -c 'print("\\`" + "git " * 100 + "push " * 40 + ("$" + chr(39) + "-u" + chr(39) + " ") * 20000)')"
_timed_case "GH #349: 20000 \$'-u' words behind 100 git and 40 push anchors are allowed in bounded time" 0 "$_ansi_dos_cmd"

# GH #268: a brace inside a word made a second tokenization whose windows doubled the subagent
# work-budget count, so a long benign bash -c body was denied only when it carried a brace.
_long_body="git status; $(printf 'echo x; %.0s' $(seq 650))"
test_allow "$IRRECOVERABLE" 'GH #268 control: subagent, long benign bash -c body, no brace' \
  "$(bash_agent_payload "bash -c \"${_long_body}echo foo1\"" agent-268)"
test_allow "$IRRECOVERABLE" 'GH #268: subagent, long benign bash -c body, brace inside a word' \
  "$(bash_agent_payload "bash -c \"${_long_body}echo foo{1}\"" agent-268)"

# GH #269 F3: a brace token in a -c/-C value or in the sub slot hid the verb (the verb regex needed whitespace before it).
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,push} --force' \
  "$(bash_payload 'git -c {a=b,push} --force origin main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,branch} -D main' \
  "$(bash_payload 'git -c {a=b,branch} -D main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,reset} --hard' \
  "$(bash_payload 'git -c {a=b,reset} --hard')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -c {a=b,clean} -fdx' \
  "$(bash_payload 'git -c {a=b,clean} -fdx')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: git -C {.,push} -f' \
  "$(bash_payload 'git -C {.,push} -f origin main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: the brace sits in the sub slot itself' \
  "$(bash_payload 'git {push,} --force origin main')"
test_deny "$IRRECOVERABLE" 'GH #269 F3: stash inside a -c brace value' \
  "$(bash_payload 'git -c {a=b,stash} drop')"
test_allow "$IRRECOVERABLE" 'GH #269 F3 control: brace -c values, read-only sub' \
  "$(bash_payload 'git -c {a=b,c=d} log')"
test_allow "$IRRECOVERABLE" 'GH #269 F3 control: brace -C values, read-only sub' \
  "$(bash_payload 'git -C {a,b} status')"
test_allow "$IRRECOVERABLE" 'GH #269 F3 control: brace in the sub slot, no destructive word' \
  "$(bash_payload 'git {log,show} --oneline')"

# GH #269 F4: the narrow rm piece only looked at the first flag, and the substitution body is an echo window.
test_deny "$IRRECOVERABLE" 'GH #269 F4: eval of $(echo rm -v -rf x)' \
  "$(bash_payload 'eval "$(echo rm -v -rf /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: eval of $(echo rm --recursive --force x)' \
  "$(bash_payload 'eval "$(echo rm --recursive --force /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: eval of $(echo rm -v -R -f x)' \
  "$(bash_payload 'eval "$(echo rm -v -R -f /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: nested backtick form' \
  "$(bash_payload 'eval "`echo $(echo rm -v -rf /tmp/x)`"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: quoted ) form' \
  "$(bash_payload 'eval "$(echo "a)" ; echo rm -v -rf /tmp/x)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F4: case form' \
  "$(bash_payload 'eval "$(case x in x) echo rm -v -rf /tmp/x;; esac)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F4 control: eval of $(echo rm -v x), no recursive or force flag' \
  "$(bash_payload 'eval "$(echo rm -v /tmp/x)"')"

# GH #269 F1/F2: the narrow shapes had a ~400-char globals limit and a 200-char verb-to-flag limit.
_pad130=$(printf 'a %.0s' $(seq 130))
test_deny "$IRRECOVERABLE" 'GH #269 F1: eval, 100 -C globals, push --force' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'push --force origin main)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: eval, 100 -C globals, reset --hard' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'reset --hard)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: nested backtick form, 100 -C globals' \
  "$(bash_payload 'eval "`echo $(echo git '"$_many_c"'push --force origin main)`"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: quoted ) form, 100 -C globals' \
  "$(bash_payload 'eval "$(echo "a)" ; echo git '"$_many_c"'push --force origin main)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: case form, 100 -C globals' \
  "$(bash_payload 'eval "$(case x in x) echo git '"$_many_c"'push --force origin main;; esac)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: escaped-backtick form, 100 -C globals' \
  "$(bash_payload 'eval "\`echo git '"$_many_c"'push --force origin main\`"')"
test_deny "$IRRECOVERABLE" 'GH #269 F1: the brace form inside eval, 100 -C globals' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'push {--force,} origin main)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F2: eval, push, 130 words before --force' \
  "$(bash_payload 'eval "$(echo git push origin '"$_pad130"'--force)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F2: eval, reset, 130 words before --hard' \
  "$(bash_payload 'eval "$(echo git reset '"$_pad130"'--hard)"')"
test_deny "$IRRECOVERABLE" 'GH #269 F2: eval, branch, 130 words before -D main' \
  "$(bash_payload 'eval "$(echo git branch '"$_pad130"'-D main)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F1 control: eval, 100 -C globals, read-only sub' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'log --oneline)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F1 control: eval, 100 -C globals, push without a force flag' \
  "$(bash_payload 'eval "$(echo git '"$_many_c"'push origin main)"')"
test_allow "$IRRECOVERABLE" 'GH #269 F2 control: eval, push with 130 words and no force flag' \
  "$(bash_payload 'eval "$(echo git push origin '"$_pad130"'main)"')"

# GH #309: bash, ksh and zsh expand a brace inside a word too (dash does not), so a brace glued to a flag,
# a sub word or an add argument hid the verb or flag from the token windows, which read it literally.
# Already denied before the fix (the brace-kept token shows the letter, or a whole-token brace sits next
# to a broad verb); kept so the fix cannot lose them.
for _c in \
  'git restore -S{W,} file.txt' \
  'git {,stash} drop' \
  '{,doas} git push --force origin main' \
  'env{,} git push --force origin main' ; do
  test_deny "$IRRECOVERABLE" "GH #309 regression: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'git add src/{a,b}.py' \
  'git add {README.md,LICENSE}' \
  'git push --for{ce-with-lease,} origin main' \
  'git push origin feat/{a,b}' \
  'rm src/{a,b}.txt' \
  'cp x.{txt,bak}' \
  'mkdir -p src/{a,b}' \
  'git diff HEAD~{1,2}' \
  'git log --format={a,b}' \
  'git commit -m "fix {a,b} parsing"' \
  'echo {a,b}' \
  'ls {a,b}' \
  'ls -l{a,h} x' \
  'git commit -m "{x,y}"' \
  'git log --format={%h,%s}' \
  "jq '{name,id}' file.json" \
  "curl -d '{\"a\":1,\"b\":2}' http://x" \
  "awk '{print \$1,\$2}' f" \
  'echo "git push --fo{rce,} origin main"' \
  'for i in {1..20000}; do echo $i; done' \
  'echo "{1..99999}"' \
  'touch f{0..99}{0..99}.txt' \
  'f() { echo {a,b}; }' \
  '{ git status; }' \
  'echo {a,b} # {c,d}' \
  'echo ${x,y}' ; do
  test_allow "$IRRECOVERABLE" "GH #309 control: a brace that expands to nothing destructive: $_c" "$(bash_payload "$_c")"
done
_timed_case "GH #309: 3000 braced words before a brace-hidden force flag are read inside the hook timeout (brace-view shadow: allowed)" 0 \
  "$(python3 -c "print('echo ' + 'a{b,c}d ' * 3000 + '; git push --fo{rce,rce} origin main')")"
_timed_case "GH #309: 20000 nested brace pairs before a force reset are denied inside the hook timeout" 2 \
  "$(python3 -c "print('{' * 20000 + 'x' + '}' * 20000 + '; git reset --hard')")"
_timed_case "GH #309: 30000 chained brace groups before a hidden reset are denied inside the hook timeout" 2 \
  "$(python3 -c "print('echo ' + '{a,b}' * 30000 + '; git {,\"reset\"} --hard')")"
# A body that blew the depth budget only in the brace view left the flag set, and the next (ifs-split)
# view read it as its own blow-out and returned no windows, so an IFS-hidden rm after it was never read.
for _u in 1000 2000; do
  test_deny "$IRRECOVERABLE" "a depth-budget flag from the brace view does not empty the next view ($_u-char eval body)" \
    "$(bash_payload "$(python3 - "$_u" <<'PY'
import sys
print("eval '$( " + "a" * int(sys.argv[1]) + "'{1..64} ; rm${IFS}-rf${IFS}/tmp/x", end="")
PY
)")"
done
# The 50-handover xargs bound was one counter for every reading: the main reading spent 26, so the ifs-split
# view stopped before it reached the IFS-hidden rm at the end. The bound is per reading.
test_deny "$IRRECOVERABLE" "26 xargs handovers in the main reading leave the ifs-split view its own 50" \
  "$(bash_payload "$(python3 - <<'PY'
print("echo a | xargs env true; " * 26 + "rm${IFS}-rf${IFS}/tmp/x", end="")
PY
)")"
# Stripping leading words one slice at a time copied the rest each step: 75k `!` took 19 s, past the 8 s timeout.
_quad_tail='rm${IFS}-rf${IFS}/tmp/x a{b} c$d'
_timed_case "74900 leading ! words before an IFS rm are stripped in linear time" 2 \
  "$(python3 -c 'import sys; print("! " * 74900 + sys.argv[1], end="")' "$_quad_tail")"
_timed_case "37450 env wrappers before an IFS rm are unwrapped in linear time" 2 \
  "$(python3 -c 'import sys; print("env " * 37450 + sys.argv[1], end="")' "$_quad_tail")"
# Each eval level re-read the same body from scratch, and stripped its `!` words quadratically: 20 KB under
# four evals took 25 s.
_timed_case "a 20 KB ! flood under four evals is denied inside the hook timeout" 2 \
  "$(python3 -c 'import sys; t = sys.argv[1]; print("eval eval eval eval " + "! " * ((20000 - 20 - len(t)) // 2) + t, end="")' "$_quad_tail")"
# Empty alternatives build no new text, so the budget never charged them: 26 groups of {,} made 2^26 empty
# strings (4.7 s, 1.8 GB), and at 27 the gate ran past the 8 s hook timeout and failed open on the raw reset.
# 28 groups: the old gate does not finish inside the 10 s timeout (rc 124), so the row is red there on any machine.
_timed_case "GH #309 audit: 28 chained {,} groups before a raw force reset are denied inside the hook timeout" 2 \
  "$(python3 -c "print('false && echo ' + '{,}' * 28 + '; git reset --hard')")"
# A character range is not charged per item either, and the head x tail product was never checked: 1.1M items times
# seven {,} groups copied 140M strings (12 s) before the only cap check.
_timed_case "GH #309 audit: a 1.1M-item range times seven {,} groups before a raw reset is denied inside the hook timeout" 2 \
  "$(python3 -c "print('echo {a..' + chr(0x10FFFF) + '}' + '{,}' * 7 + '; git reset --hard')")"
_timed_case "GH #309: nested groups whose real expansion (120000 chars) is under the cap are not denied for a double charge" 0 \
  "$(python3 -c "L = 30000; print('echo {{' + 'A' * L + ',' + 'B' * L + '},{' + 'C' * L + ',' + 'D' * L + '}}')")"
_timed_case "GH #309: a 60000-char word before a brace is allowed fast" 0 \
  "$(python3 -c "print('echo ' + 'a' * 60000 + '{b,c}')")"
test_deny "$IRRECOVERABLE" "GH #309: a brace expansion over the length cap denies, never skips the copy" \
  "$(bash_payload "git add $(python3 -c "print('a' * 70000)"){b,c,d}")"

# GH #336: $IFS splitting, a verb held in a variable, mkfs, chmod 777 and rm --no-preserve-root.
# Cases (each deny shape checked in real shells) live in a fixture. A WOULD_* line is a shadow rule
# (GH #337): allowed with a would_* journal row, and enforced once SHADOW_RULES drops it.
_c336="$ROOT/tests/hooks/fixtures/irrecoverable-336-cases.txt"
_enf336="$_JOURNAL_TMP/enforced-gates"
mkdir -p "$_enf336" && cp -R "$ROOT/hooks/gates/." "$_enf336/"
python3 - "$_enf336/irrecoverable.py" <<'EOF'
import re, sys
s, n = re.subn(r"^SHADOW_RULES = .*$", "SHADOW_RULES = frozenset()", open(sys.argv[1]).read(), flags=re.M)
assert n == 1
open(sys.argv[1], "w").write(s)
EOF
_would336() { # <decision> <rule> <cmd>: shadowed -> allow + one would_* row; enforced copy -> deny/ask
  local dec="$1" rule="$2" cmd="$3" j="$_JOURNAL_TMP/w336.jsonl" out rc rows
  : > "$j"
  out=$(bash_payload "$cmd" | MH_GATE_JOURNAL_PATH="$j" bash "$IRRECOVERABLE" 2>/dev/null); rc=$?
  rows=$(python3 -c 'import json,sys; print(sum(json.loads(l).get("decision") == "would_" + sys.argv[2] and json.loads(l).get("rule") == sys.argv[3] for l in open(sys.argv[1])))' "$j" "$dec" "$rule")
  if [[ "$rc" == "0" && -z "$out" && "$rows" == "1" ]]; then
    echo "  ✅ SHADOW would_$dec $rule: $cmd"; pass=$((pass + 1))
  else
    echo "  ❌ SHADOW would_$dec $rule expected (rc=0, no stdout, 1 row), got rc=$rc rows=$rows: $cmd" >&2; fail=$((fail + 1))
  fi
  if [[ "$dec" == "deny" ]]; then
    test_deny "$_enf336/irrecoverable.sh" "GH #336 enforced once promoted: $cmd" "$(bash_payload "$cmd")"
  else
    test_ask "$_enf336/irrecoverable.sh" "GH #336 enforced once promoted: $cmd" "$(bash_payload "$cmd")"
  fi
}
_want336=$(/usr/bin/grep -cE '^(DENY|ALLOW|WOULD_DENY|WOULD_ASK) ' "$_c336"); _got336=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #336: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *)
      : > "$_JOURNAL_TMP/a336.jsonl"
      test_allow "$IRRECOVERABLE" "GH #336 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a336.jsonl"
      if [ -s "$_JOURNAL_TMP/a336.jsonl" ]; then
        echo "  ❌ GH #336 control journaled a row (a shadow rule fired): ${_line#ALLOW }" >&2; fail=$((fail + 1))
      fi ;;
    WOULD_DENY\ *) _r="${_line#WOULD_DENY }"; _would336 deny "${_r%% *}" "${_r#* }" ;;
    WOULD_ASK\ *) _r="${_line#WOULD_ASK }"; _would336 ask "${_r%% *}" "${_r#* }" ;;
    *) continue ;;
  esac
  _got336=$((_got336 + 1))
done < "$_c336"
# Each view re-reads the whole command (up to _VIEW_LEN_CAP), and a timed-out hook allows.
_pad336="$(printf 'echo a; %.0s' $(seq 1200))"
_timed_case "GH #336: var-verb view (shadow), target after 10 KB of statements, read in bounded time" 0 "${_pad336}X=rm; \$X -rf build"
_timed_case "GH #336: ifs-split view, target after 10 KB of statements, denied in bounded time" 2 "${_pad336}rm\${IFS}-rf build"
_timed_case "GH #336: var-verb view, 1200 references of one benign variable, allowed in bounded time" 0 "X=ls; $(printf 'echo $X %.0s' $(seq 1200))"
_timed_case "GH #336: chmod with 4000 a+rw words, allowed in bounded time" 0 "chmod -R $(printf 'a+rw %.0s' $(seq 4000))build"
# Padding past _VIEW_LEN_CAP (20,000) used to drop the enforced ifs-split view while the parser ran up
# to _CMD_LEN_CAP (150,000), so a 21 KB word in front of rm${IFS}-rf allowed it.
_big336="$(printf 'a%.0s' $(seq 21000))"
_timed_case "GH #336: ifs-split view, target after a 21 KB word, denied in bounded time" 2 "echo ${_big336}; rm\${IFS}-rf\${IFS}./build"
_timed_case "GH #336: ifs-split view, target after 48 KB of statements, denied in bounded time" 2 \
  "$(printf 'echo a; %.0s' $(seq 6000))rm\${IFS}-rf\${IFS}./build"
_timed_case "GH #336 control: a 21 KB heredoc is allowed in bounded time" 0 "cat > notes.txt <<'EOF'
${_big336}
EOF"
_timed_case "GH #336 control: a 21 KB heredoc with a plain assignment is allowed in bounded time" 0 "X=1; cat > notes.txt <<'EOF'
\$X ${_big336}
EOF"
if [ "$_want336" -ge 60 ] && [ "$_got336" = "$_want336" ]; then
  echo "  ✅ GH #336: corpus replayed every case ($_got336)"; pass=$((pass + 1))
else
  echo "  ❌ GH #336: corpus replayed $_got336 of $_want336 cases" >&2; fail=$((fail + 1))
fi

# GH #309: bash, ksh and zsh expand a brace inside a word too (dash does not), so a brace glued to a flag,
# a sub word, an add argument or argv0 hid the verb or flag from the token windows, which read it literally.
# The expanded text is read as the "brace-view" view, which ships shadow first (GH #337): each row is
# allowed with one would_deny row, and denied once the id leaves SHADOW_RULES (the enforced copy).
# ('git add {.,}' is not a row: the enforced copy also turns the shadowed source-file rule on, which asks
# for the literal '{ ., }' reading, so its stdout is not empty; it is the same bypass as 'git add {..,}'.)
for _c in \
  'r{m,m} -rf /tmp/x' \
  'fi{nd,nd} /tmp/x -delete' \
  'git push --fo{rce,rce} origin main' \
  'git push --forc{e,e-with-lease} origin main' \
  'git push "--fo"{rce,} origin main' \
  'git push --forc{e..e} origin main' \
  'git restore -S --wor{ktree,} file.txt' \
  'git branch --del{ete,ete} --forc{e,e} main' \
  'git add {..,}' \
  'git add {-A,}' \
  'git add {:/,}' \
  'git add {*,}' \
  'git add {--pathspec-from-file=list,}' \
  'git add -{-pathspec-from-file=list,}' \
  'git {,add} .' \
  'git {,add} -A' \
  'git a{dd,dd} .' \
  'git -C . a{dd,dd} .' \
  'git pu{sh,} --force origin main' \
  'git rest{ore,ore} .' \
  'git br{anch,anch} -D main' \
  'r{"m",} -rf /tmp/x' \
  "r{'m',} -rf /tmp/x" \
  'r{\m,} -rf /tmp/x' \
  'r{m,$x} -rf /tmp/x' \
  'fi{"nd",} /tmp -delete' \
  'git {,"reset"} --hard' \
  'git -C . {,"reset"} --hard' \
  'git {,"clean"} -fd' \
  'git {,"push"} --force origin main' \
  "git {,'push'} --force origin main" \
  "bash -c 'git {,\"reset\"} --hard'" \
  'git push --fo{r,}{ce,} origin main' \
  'git push --fo{r{ce,x},} origin main' \
  '{r,}{m,} -rf /tmp/x' \
  '{r{m,},} -rf /tmp/x' \
  'git push "--"{x,force} origin main' \
  "git push \$'--'{x,force} origin main" \
  'git push origin main {--forc,x}"e"' \
  'git push \--fo{rce,} origin main' \
  $'git push --fo{rce,\\\n} origin main' \
  'git push --forc{e..e..1} origin main' \
  'r{m..m..1} -rf /tmp/x' \
  'echo {x,#$}; git {,"reset"} --hard' \
  $'# {x,y}\'\ngit {,"reset"} --hard' \
  'rm {-rf,\ } /tmp/x' \
  '{$(:),git} push --force origin main' \
  '{f,"x y"}ind . -delete' \
  '{,git} reset --hard' \
  '{,git} push --force origin main' \
  'env {,git} push --force origin main' \
  '{,git} push origin +main' \
  '{r,"x y"}m -rf /tmp/x' \
  'r{{x},m} -rf /tmp/x' \
  'git {{,},reset} --hard' \
  '{A=1}},git} reset --hard' \
  '{A=1}},git} push --force origin main' \
  '{A=1}},rm} -rf /tmp/x' \
  '{A="x y",git} reset --hard' \
  "{A='x y',git} reset --hard" \
  '{r..3}m -rf /tmp/x' \
  'r{m,x\ y} -rf /tmp/x' \
  'r{m,"x\"y z"} -rf /tmp/x' \
  'f{ind,x\ y} /tmp/x -delete' \
  $'true \\\\\nr{m,} -rf /tmp/x' \
  $'r\\\n{m,} -rf /tmp/x' \
  $'f{ind,x\ry} /tmp/x -delete' \
  $'r{m,x\xc2\xa0y} -rf /tmp/x' \
  'f{ind,<(:)} /tmp/x -delete' \
  'echo <(r{m,} -rf /tmp/x)' \
  'r{m,<(: x)} -rf /tmp/x' \
  'f{ind,>(: x)} /tmp/x -delete' \
  'echo x\ #; r{m,} -rf /tmp/x' \
  'echo x\;#; r{m,} -rf /tmp/x' \
  'chmod -R {777..0} /tmp/x' \
  'chmod {777..700} -R /' \
  "r{m,<('\\')} -rf /tmp/x" \
  'f{ind,>(: "a b")} /tmp/x -delete' ; do  # an escaped blank or quote inside the group: the fast path must reach python
  _would336 deny brace-view "$_c"
done
# The .sh fast path hands a command to python only when brace-route.awk sees an expanding group, so the
# awk must see every shape _bracex expands: enumerate each string of { } , x . up to 7 characters (97,655; plus
# two wider alphabets with backslash, quote, blank, newline, CR, NBSP and "<("),
# wrap it in the hook payload, and fail on any that expands but is not routed (a single-level grep missed
# r{{x},m} and a stray "}" before the comma, "{A=1}},git}": GH #309 review). The same shapes up to 6
# characters are also run through the bash on PATH (echo), and _bracex must read the same words: it mirrors
# bash's own scan (a "}" closes a group only after a comma or "..", "{" then "}" at a word start is no group).
_drift=$(python3 - "$ROOT" <<'PYEOF'
import itertools, json, shutil, subprocess, sys
root = sys.argv[1]
sys.path.insert(0, root + "/hooks/gates")
import _bracex
cmds, shapes = [], []
for n in range(1, 8):
    for t in itertools.product("{},x.", repeat=n):
        c = "echo r" + "".join(t) + " -rf"
        try:
            e = _bracex.expand_text(c, 150000)
        except Exception:
            continue
        if e != c:
            cmds.append(c)
        if n <= 6:
            shapes.append((c, e.split()))
# Wider alphabets with a backslash, quotes, a blank, a newline, CR, NBSP and "<(" (up to 5 and 4 characters,
# routing only: most of these are not valid shell): "r{m,x\\ y} -rf" hid its verb from an awk that read the JSON escape pair, then the blank.
for alpha, top in (("{},x\\ \"'", 5), ("{},x\\ \n\r\xa0<()", 4)):
    for n in range(1, top + 1):
        for t in itertools.product(alpha, repeat=n):
            c = "echo r" + "".join(t) + " -rf"
            try:
                e = _bracex.expand_text(c, 150000)
            except Exception:
                continue
            if e not in (c, _bracex._strip_continuations(c)):  # a stripped line continuation alone is no expansion
                cmds.append(c)
pay = lambda c: json.dumps({"tool_name": "Bash", "tool_input": {"command": c}})
out = subprocess.run(["awk", "-f", root + "/hooks/gates/brace-route.awk"], input="\n".join(pay(c) for c in cmds) + "\n",
                     capture_output=True, text=True).stdout.split()
miss = [c for c, o in zip(cmds, out) if o == "0"]
bad, nbash = [], 0
bash = shutil.which("bash")
if bash:
    got = subprocess.run([bash, "-c", "\n".join(c for c, _ in shapes)], capture_output=True, text=True).stdout.split("\n")[:-1]
    if len(got) == len(shapes):
        nbash = len(got)
        bad = [c for (c, e), g in zip(shapes, got) if g.split() != e[1:]]
print(len(cmds), len(out), len(miss), nbash, len(bad), " | ".join((miss + bad)[:5]))
PYEOF
)
read -r _dn _do _dm _bn _bb _drest <<< "$_drift"
# _bn must be well above 0: a bash that is missing or fails compared nothing, and "0 differences" then proved nothing.
if [ "${_dn:-0}" -gt 1000 ] && [ "$_dn" = "${_do:-x}" ] && [ "${_dm:-1}" = "0" ] && [ "${_bb:-1}" = "0" ] && [ "${_bn:-0}" -gt 1000 ]; then
  echo "  ✅ GH #309: brace-route.awk routes all $_dn enumerated brace shapes _bracex expands; _bracex matches bash on $_bn"
  pass=$((pass + 1))
else
  echo "  ❌ GH #309: brace-route.awk missed ${_dm:-?} of ${_dn:-?} expanding shapes, _bracex differs from bash on ${_bb:-?} of ${_bn:-?} (first: $_drest)" >&2
  fail=$((fail + 1))
fi
# An awk that starts but fails cannot vouch for a brace command: the fast path hands it to python (the
# over-cap expansion is a structural deny, so it enforces while brace-view is shadowed).
_BADAWK="$_JOURNAL_TMP/badawk"  # a subdir of the file's own temp dir: its EXIT trap cleans it
if mkdir "$_BADAWK"; then
  _badpay=$(bash_payload 'echo {a..z}{a..z}{a..z}{a..z}')
  for _stub in "exit 1:fails (exit 1)" "exit 0:prints nothing (exit 0)"; do
    printf '#!/bin/sh\n%s\n' "${_stub%%:*}" > "$_BADAWK/awk"; chmod +x "$_BADAWK/awk"
    _rc=$(echo "$_badpay" | PATH="$_BADAWK:$PATH" bash "$IRRECOVERABLE" >/dev/null 2>&1; echo $?)
    if [ "$_rc" = "2" ]; then
      echo "  ✅ GH #309: an awk that ${_stub#*:} sends the command to python (denied, rc 2)"
      pass=$((pass + 1))
    else
      echo "  ❌ GH #309: an awk that ${_stub#*:} must send the command to python, got rc $_rc" >&2
      fail=$((fail + 1))
    fi
  done
else
  echo "  ❌ GH #309: could not create the stub dir for the failing-awk rows" >&2
  fail=$((fail + 1))
fi
# A payload over 2000 characters with a "{" used to go to python unscanned; python's tokenizer then denied a
# heredoc line that mixes both quote marks (`v[:1] in '"\''`) that develop's fast path never sent there. The
# awk now bounds its own work, so a long f-string/dict heredoc with no expanding group stays on the fast path.
test_allow "$IRRECOVERABLE" "GH #309: a 2 KB python heredoc with braces and a mixed-quote line (no group expands) stays allowed" \
  "$(bash_payload "$(python3 -c "print(\"python3 - <<'PY'\\n\" + \"\".join(f\"x{i} = {{'a': {i}}}\\n\" for i in range(120)) + \"v[:1] in '\\\"\\\\''\\nPY\")")")"
# _deny_ambiguous returns inside brace-view only: any other view (ifs-split enforces) still ends on it.
if /usr/bin/grep -qE '_VIEW\[0\] == "brace-view"' "$ROOT/hooks/gates/irrecoverable.py"; then
  echo "  ✅ GH #309: _deny_ambiguous skips only the brace-view view"
  pass=$((pass + 1))
else
  echo "  ❌ GH #309: _deny_ambiguous must return only inside brace-view" >&2
  fail=$((fail + 1))
fi
# A structural deny takes no id, so it enforces even while brace-view is shadowed: a raw noncharacter
# (U+FDD0-U+FDEF, the expander's own stand-ins) is refused rather than read.
test_deny "$IRRECOVERABLE" "GH #309: a stand-in noncharacter in a command with a brace denies" \
  "$(bash_payload $'echo a\xef\xb7\x98\xef\xb7\x98E {x,"y"}\ngit {,"reset"} --hard\nE')"
# A private-use icon (Nerd Fonts live at U+E000) is an ordinary character, not a stand-in.
test_allow "$IRRECOVERABLE" "GH #309 control: a private-use icon in a command with a brace is allowed" \
  "$(bash_payload $'echo \xee\x80\x80 {a,b}')"
# A single-quoted span that is valid JSON is data, not a runnable command (the weighted-score call of
# every deep-audit): chained objects there used to multiply past the cap and deny. Anything that is not
# valid JSON is still read as command text (bash -c bodies), padded or not.
_json309='{"scores": [{"id":"a","score":9,"max":10,"weight":3,"insufficient":false},{"id":"b","score":9,"max":10,"weight":2,"insufficient":false},{"id":"c","score":8,"max":10,"weight":2,"insufficient":false},{"id":"d","score":8,"max":10,"weight":2,"insufficient":false},{"id":"e","score":8,"max":10,"weight":1,"insufficient":false}], "floorPct": 0.5}'
test_allow "$IRRECOVERABLE" "GH #309 control: a JSON here-string with chained objects is data, allowed (no TooBig)" \
  "$(bash_payload "python3 weighted-score.py <<< '$_json309'")"
test_deny "$IRRECOVERABLE" "GH #309: a bash -c body that only starts like JSON is still expanded (structural deny over the cap)" \
  "$(bash_payload "bash -c '$_json309; git {,\"reset\"} --hard'")"
_would336 deny brace-view "bash -c '{\"a\":1}; git {,\"reset\"} --hard; {x,y}'"
# A brace that cannot expand (no comma, no range: an f-string field, "{x}") stays on the shell fast path, so
# a heredoc body whose quotes the tokenizer cannot balance is not newly denied by the brace routing.
_c309h=$(cat <<'XEOF'
python3 - <<'EOF'
old = '''        secs = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
        if secs < 60: return f"{int(secs)}s"'''
new = '''        secs = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
        if secs < 0: return "0s"  # future/clock-skewed ts -- don't print a negative age
        if secs < 60: return f"{int(secs)}s"'''
for path in ["/tmp/test-dashboard.py", "commands/review-dashboard.md"]:
    with open(path) as f:
        content = f.read()
    if old in content:
        content = content.replace(old, new)
        with open(path, "w") as f:
            f.write(content)
        print("patched:", path)
    else:
        print("MISS:", path)
EOF
XEOF
)
test_allow "$IRRECOVERABLE" "GH #309 control: a heredoc with f-string braces and an apostrophe takes the fast path, allowed" \
  "$(bash_payload "$_c309h")"
# A double-quoted body can be a shell's command text (bash -c "..."), which expands braces itself, so double
# quotes are still read as command text. The cost is a known over-deny: a double-quoted JSON body with more
# than a few chained objects (curl -d "{...}") exceeds the cap and is denied.
_would336 deny brace-view 'bash -c "r{m,} -rf /tmp/x"'
# An uncaught error would exit 1, which does not block: 3000 nested substitutions must exit 2.
test_deny "$IRRECOVERABLE" "GH #309: 3000 nested dollar-paren spans in a command with a brace deny (exit 2, no traceback)" \
  "$(bash_payload "$(python3 -c "print('echo {a,b} ' + '\"\$(' * 3000)")")"

# GH #375: a git global's value split by shlex at $, :, @ or a non-ASCII letter (-C $R) took the
# variable's name for the subcommand. Cases (each deny shape checked in real shells) live in a fixture.
_c375="$ROOT/tests/hooks/fixtures/irrecoverable-375-cases.txt"
_want375=$(/usr/bin/grep -cE '^(DENY|ALLOW) ' "$_c375"); _got375=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #375: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *)
      : > "$_JOURNAL_TMP/a375.jsonl"
      test_allow "$IRRECOVERABLE" "GH #375 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a375.jsonl"
      if [ -s "$_JOURNAL_TMP/a375.jsonl" ]; then
        echo "  ❌ GH #375 control journaled a row: ${_line#ALLOW }" >&2; fail=$((fail + 1))
      fi ;;
    *) continue ;;
  esac
  _got375=$((_got375 + 1))
done < "$_c375"
# The re-read global part is one more window per git window; a hook timeout allows.
_timed_case "GH #375: 4000 '-C \$R' globals before reset --hard, denied in bounded time" 2 \
  "git $(printf -- '-C $R %.0s' $(seq 4000))reset --hard"
_timed_case "GH #375: 4000 '-C \$R' globals before status, allowed in bounded time" 0 \
  "git $(printf -- '-C $R %.0s' $(seq 4000))status"
_timed_case "GH #375: reset --hard after 2000 benign '-C \$R' git statements, denied in bounded time" 2 \
  "$(printf 'git -C $R status; %.0s' $(seq 2000))git -C \$R reset --hard"
_timed_case "GH #375: glue only inside the subcommand word appends no window, allowed in bounded time" 0 \
  "git -C \$R status\$X"
_timed_case "GH #375: 20 KB value of glued \$a\$b words before reset --hard, denied in bounded time" 2 \
  "git -C $(printf '$a%.0s' $(seq 10000)) reset --hard"
if [ "$_want375" -ge 50 ] && [ "$_got375" = "$_want375" ]; then
  echo "  ✅ GH #375: corpus replayed every case ($_got375)"; pass=$((pass + 1))
else
  echo "  ❌ GH #375: corpus replayed $_got375 of $_want375 cases" >&2; fail=$((fail + 1))
fi

# GH #405 F1: a ${...} or $(...) glued to a git global blanks into the same word (-C<PH>), which
# read only as a bare -C taking the subcommand as its value. Either expansion (empty or word-split
# " /repo") must be read; `-C${D} $R` checks the empty reading of the GH #375 window stays.
# F2: chmod reads its mode word only, so a file named 777 is not a mode.
for _c405 in 'git -C${R} reset --hard' 'git -C${R} push --force origin main' 'git -C${R:-.} reset --hard' \
    'git -C$(pwd) reset --hard' 'git --git-dir${G} reset --hard' 'git -C${D} /repo reset --hard' \
    'git -C${D} $R reset --hard' 'chmod -R 777 x' 'chmod -R a+rwx x' 'chmod 777 /' 'chmod a+rwx ~' 'chmod -R $(m) 777 x' 'chmod -R -- 777 x'; do
  test_deny "$IRRECOVERABLE" "GH #405: $_c405" "$(bash_payload "$_c405")"
done
# A substitution inside the flag name (-${X}C) is not its value, as on develop. chmod 777 on one
# plain path is out of the rule's scope (GH #336: recursive, / or ~ only).
for _c405 in 'git -C${R} status' 'git -C$(pwd) log --oneline' 'git -${X}C reset --hard' \
    'chmod -R 755 777' 'chmod -R 755 a+rwx' \
    'chmod 755 / 777' 'chmod 777 x' 'chmod a+rwx x'; do
  test_allow "$IRRECOVERABLE" "GH #405 control: $_c405" "$(bash_payload "$_c405")"
done
_timed_case "GH #405: reset --hard after 2000 benign '-C\${R}' git statements, denied in bounded time" 2 \
  "$(printf 'git -C${R} status; %.0s' $(seq 2000))git -C\${R} reset --hard"

# GH #409 R1: a comma mode is one shell word whose clauses are each a mode (the tokenizer cuts it at
# + and ,). R2: a word that is only an expansion ($V, "$V", $1) may be empty, so it is not the mode
# word. R3: a substitution before a git global's flag letters (${E}-C${R}) still carries its value.
for _c409 in 'chmod -R u+s,a+rwx x' 'chmod -R g+w,a+rwx /tmp/x' 'chmod -R a-x,a+rwx x' \
    'chmod -R +t,a+rwx x' 'chmod -R u=rwx,ugo=rwx x' 'chmod u+s,a+rwx /' 'chmod -R -x,a+rwx x' 'chmod -R x -x,a+rwx' \
    'chmod -R $V 777 /tmp/x' 'chmod $V 777 /' 'chmod $F -v 777 /' 'chmod -R $1 777 x' \
    'chmod -R $V a+rwx x' 'chmod -R "$V" 777 x' \
    'git ${E}-C${R} reset --hard' 'git $(true)-C$(pwd) reset --hard' 'git -${E}C${R} reset --hard' \
    'git ${E}-c${X} reset --hard' 'git ${E}-C${R} push --force'; do
  test_deny "$IRRECOVERABLE" "GH #409: $_c409" "$(bash_payload "$_c409")"
done
for _c409 in 'git -${X}C reset --hard' 'chmod -R 755 777' 'chmod -R 755 a+rwx' 'chmod 755 / 777' \
    'chmod 777 x' 'git -C${R} status' 'chmod -R u+s,g+w x' 'chmod -R $V 755 x'; do
  test_allow "$IRRECOVERABLE" "GH #409 control: $_c409" "$(bash_payload "$_c409")"
done
_timed_case "GH #409: a comma mode after 2000 benign chmod statements, denied in bounded time" 2 \
  "$(printf 'chmod 644 x; %.0s' $(seq 2000))chmod -R u+s,a+rwx x"

# GH #382: the wrapper, assignment and argv0 walks read a split value ($U, a:b) or a dropped empty word
# ("") one token off. Every statement is also read as shell words (glued runs joined, "" kept).
_c382="$ROOT/tests/hooks/fixtures/irrecoverable-382-cases.txt"
_want382=$(/usr/bin/grep -cE '^(DENY|ALLOW) ' "$_c382"); _got382=0
while IFS= read -r _line; do
  case "$_line" in
    DENY\ *) test_deny "$IRRECOVERABLE" "GH #382: ${_line#DENY }" "$(bash_payload "${_line#DENY }")" ;;
    ALLOW\ *)
      : > "$_JOURNAL_TMP/a382.jsonl"
      test_allow "$IRRECOVERABLE" "GH #382 control: ${_line#ALLOW }" "$(bash_payload "${_line#ALLOW }")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a382.jsonl"
      if [ -s "$_JOURNAL_TMP/a382.jsonl" ]; then
        echo "  ❌ GH #382 control journaled a row: ${_line#ALLOW }" >&2; fail=$((fail + 1))
      fi ;;
    *) continue ;;
  esac
  _got382=$((_got382 + 1))
done < "$_c382"
# The word copy is one more window per statement that holds a split or empty word; a hook timeout allows.
_timed_case "GH #382: 4000 '-u \$U' sudo flags before git reset --hard, denied in bounded time" 2 \
  "sudo $(printf -- '-u $U %.0s' $(seq 4000))git reset --hard"
_timed_case "GH #382: 4000 '-u \$U' sudo flags before git status, allowed in bounded time" 0 \
  "sudo $(printf -- '-u $U %.0s' $(seq 4000))git status"
_timed_case "GH #382: rm -rf after 2000 benign 'X=\$Y make' statements, denied in bounded time" 2 \
  "$(printf 'X=$Y make; %.0s' $(seq 2000))X=\$Y rm -rf build"
_timed_case "GH #382: 20 KB glued \$a\$a sudo user before git reset --hard, denied in bounded time" 2 \
  "sudo -u $(printf '$a%.0s' $(seq 10000)) git reset --hard"
_timed_case "GH #382: 2000 empty -C values before reset --hard, denied in bounded time" 2 \
  "git $(printf -- '-C \"\" %.0s' $(seq 2000))reset --hard"
_timed_case "GH #382: 4000 empty words then git status, allowed in bounded time" 0 \
  "echo $(printf '\"\" %.0s' $(seq 4000)); git status"
if [ "$_want382" -ge 60 ] && [ "$_got382" = "$_want382" ]; then
  echo "  ✅ GH #382: corpus replayed every case ($_got382)"; pass=$((pass + 1))
else
  echo "  ❌ GH #382: corpus replayed $_got382 of $_want382 cases" >&2; fail=$((fail + 1))
fi

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
