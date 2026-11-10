#!/usr/bin/env bash
# doctrine-bootstrap.sh's python3-missing message must name every gate in
# hooks/gates/*.sh, derived at run time -- not a hand-maintained list (LOW,
# harness gap-audit 2026-09-20: the old hardcoded string named 5 of the 7
# real gate wrappers, silently missing subagent-spawn-guard and
# codex-setup-guard). This test proves the list tracks the fleet: it builds a
# fixture gates/ dir, runs the script with python3 hidden from PATH, and
# checks a newly-added fixture gate shows up in the message without any
# script edit.
# Run standalone: bash tests/hooks/test-doctrine-bootstrap.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/_lib/tmp-delete.sh"
SCRIPT="$ROOT/hooks/session/doctrine-bootstrap.sh"

pass=0
fail=0
assert() {
  local desc="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc" >&2
    fail=$((fail + 1))
  fi
}

fixture=$(mktemp -d)
mkdir -p "$fixture/docs" "$fixture/hooks/gates"
echo "# fixture methodology" > "$fixture/docs/METHODOLOGY.md"
: > "$fixture/hooks/gates/alpha-gate.sh"
: > "$fixture/hooks/gates/beta-gate.sh"

# PATH with only what the script itself needs (cat, basename) and none of
# python3/jq/node, so the three preflight checks all fire without touching
# the real system tools.
noop_bin=$(mktemp -d)
ln -s /bin/cat "$noop_bin/cat"
ln -s /usr/bin/basename "$noop_bin/basename"
strip_path="$noop_bin"

out=$(CLAUDE_PLUGIN_ROOT="$fixture" PATH="$strip_path" /bin/bash "$SCRIPT" 2>/dev/null)

/usr/bin/grep -q "alpha-gate" <<<"$out" && /usr/bin/grep -q "beta-gate" <<<"$out" && ok=1 || ok=0
assert "python3-missing message names every current hooks/gates/*.sh file" "$ok"

# Add a third gate to the fixture -- the message must pick it up without any
# script change, proving the list isn't hardcoded.
: > "$fixture/hooks/gates/gamma-gate.sh"
out2=$(CLAUDE_PLUGIN_ROOT="$fixture" PATH="$strip_path" /bin/bash "$SCRIPT" 2>/dev/null)
/usr/bin/grep -q "gamma-gate" <<<"$out2" && ok=1 || ok=0
assert "a newly-added gate file appears in the message with no script edit" "$ok"

# (2026-09-21) The glob-empty fallback used to be a second hand-maintained
# literal list (7 names, hooks/gates/ had 8). No real gate basename may appear
# in the script's code lines at all; comments are stripped first because the
# history note above the loop legitimately names two gates.
hardcoded=0
code=$(sed 's/#.*$//' "$SCRIPT")
for g in "$ROOT"/hooks/gates/*.sh; do
  name=$(basename "$g" .sh)
  /usr/bin/grep -q -- "$name" <<<"$code" && hardcoded=$((hardcoded + 1))
done
[[ "$hardcoded" == "0" ]] && ok=1 || ok=0
assert "no real gate name is hardcoded in the script's code (found $hardcoded)" "$ok"

# An unreadable docs/METHODOLOGY.md (a partial or corrupt plugin cache, an unset root) must announce itself:
# a hook fails open with a diagnostic, never with silence, or a session starts with no doctrine and no sign.
missing_out=$(CLAUDE_PLUGIN_ROOT="$fixture/no-such-root" /bin/bash "$SCRIPT" 2>/dev/null)
/usr/bin/grep -q "<!-- mh:doctrine-missing -->" <<<"$missing_out" && ok=1 || ok=0
assert "an unreadable METHODOLOGY.md prints the mh:doctrine-missing marker" "$ok"
/usr/bin/grep -q "$fixture/no-such-root/docs/METHODOLOGY.md" <<<"$missing_out" && ok=1 || ok=0
assert "the marker names the path it could not read" "$ok"
/usr/bin/grep -q "<doctrine>" <<<"$missing_out" && ok=0 || ok=1
assert "no empty <doctrine> block is printed when the file is unreadable" "$ok"
present_out=$(CLAUDE_PLUGIN_ROOT="$fixture" /bin/bash "$SCRIPT" 2>/dev/null)
/usr/bin/grep -q "doctrine-missing" <<<"$present_out" && ok=0 || ok=1
assert "a readable METHODOLOGY.md prints no missing marker" "$ok"
# A file that exists but yields nothing (empty from a partial cache, or mode 000) must announce itself too.
bad_root=$(mktemp -d)
mkdir "$bad_root/docs"
: > "$bad_root/docs/METHODOLOGY.md"
empty_out=$(CLAUDE_PLUGIN_ROOT="$bad_root" /bin/bash "$SCRIPT" 2>/dev/null)
/usr/bin/grep -q "<!-- mh:doctrine-missing -->" <<<"$empty_out" && ok=1 || ok=0
assert "an empty METHODOLOGY.md prints the mh:doctrine-missing marker" "$ok"
/usr/bin/grep -q "<doctrine>" <<<"$empty_out" && ok=0 || ok=1
assert "no empty <doctrine> block is printed for an empty file" "$ok"
echo "x" > "$bad_root/docs/METHODOLOGY.md"
chmod 000 "$bad_root/docs/METHODOLOGY.md"
if [[ ! -r "$bad_root/docs/METHODOLOGY.md" ]]; then  # root reads mode 000, so the case only exists for other users
  mode0_out=$(CLAUDE_PLUGIN_ROOT="$bad_root" /bin/bash "$SCRIPT" 2>/dev/null)
  /usr/bin/grep -q "<!-- mh:doctrine-missing -->" <<<"$mode0_out" && ok=1 || ok=0
  assert "a METHODOLOGY.md the hook cannot read prints the mh:doctrine-missing marker" "$ok"
fi
chmod 644 "$bad_root/docs/METHODOLOGY.md"
rm_target="$bad_root/docs/METHODOLOGY.md"
trash "$rm_target"
mkdir "$rm_target"  # a directory where the file should be: -s and -r both pass on it
dir_out=$(CLAUDE_PLUGIN_ROOT="$bad_root" /bin/bash "$SCRIPT" 2>/dev/null)
/usr/bin/grep -q "<!-- mh:doctrine-missing -->" <<<"$dir_out" && ok=1 || ok=0
assert "a directory where METHODOLOGY.md should be prints the mh:doctrine-missing marker" "$ok"
tmp_delete "$fixture" "$noop_bin" "$bad_root"

echo
echo "doctrine-bootstrap: $pass passed, $fail failed"
[[ "$fail" == "0" ]]
