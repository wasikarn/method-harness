#!/usr/bin/env bash
# Behavioral tests for hooks/gates/_journal.py, restored 2026-09-12 after commit
# 2cac98c8 deleted the central-dispatcher version with no replacement. Covers:
# a deny verdict journals a row, an allow-only payload adds none (volume
# control), the fail-safe (an unwritable journal path must never change the
# gate's own exit code/stdout, using an ENOTDIR fixture that is uid-independent
# -- a chmod-based fixture is a no-op as root, which this repo's own podman
# ubuntu:24.04 dry-run lane runs as), and a gate-id drift guard (each gate's
# hardcoded GATE_ID constant must actually exist in hooks/hook-registry.json).
# Run standalone: bash tests/hooks/test-gate-journal.sh
set -uo pipefail

# This file tests the HOME-fallback path directly (cases 1-4) and the
# override explicitly (case 5) -- unset any ambient MH_GATE_JOURNAL_PATH
# first, since scripts/run-gauntlet.sh's hook-test layer sets one for the
# whole suite and it would otherwise silently win over every HOME= prefix
# below, making cases 1-4 write nowhere the assertions look.
unset MH_GATE_JOURNAL_PATH

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'python3 "$ROOT/tests/_lib/tmp_delete.py" "$WORK"' EXIT

pass=0
fail=0
check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

payload_bash() { # payload_bash <command>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"session_id":"sess-journal-test"}))' "$1"
}

payload_edit() { # payload_edit <file_path> <old_string> <new_string>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]},"session_id":"sess-journal-test"}))' "$1" "$2" "$3"
}

echo "=== gate-verdict journal ==="
cd "$ROOT" || exit 1

# --- Case 1: a deny verdict writes a journal row ---
HOME="$WORK/case1"; mkdir -p "$HOME"
JOURNAL="$HOME/.local/share/kbg/metrics/gate-decisions.jsonl"
payload_bash "rm -rf /" | HOME="$HOME" bash hooks/gates/irrecoverable.sh >/dev/null 2>&1; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "irrecoverable.sh denies rm -rf / (rc=2)" "$ok"
ok=1
[ -f "$JOURNAL" ] && /usr/bin/grep -q '"decision": "deny"' "$JOURNAL" && /usr/bin/grep -q '"id": "gate:bash:irrecoverable"' "$JOURNAL" && ok=0
check "deny verdict journaled with correct id/decision" "$ok"

# --- Case 2: an allow-only payload adds no row (volume control) ---
HOME="$WORK/case2"; mkdir -p "$HOME"
JOURNAL2="$HOME/.local/share/kbg/metrics/gate-decisions.jsonl"
payload_bash "ls -la" | HOME="$HOME" bash hooks/gates/irrecoverable.sh >/dev/null 2>&1; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "irrecoverable.sh allows ls -la (rc=0)" "$ok"
ok=1; [ ! -s "$JOURNAL2" ] && ok=0
check "allow-only dispatch does not add a journal row" "$ok"

# --- Case 3: the fail-safe. Point HOME at a path whose PARENT is a regular
# file, so os.makedirs raises ENOTDIR regardless of uid (a chmod-based
# unwritable-directory fixture is a no-op as root). Assert BOTH the gate's own
# exit code/stdout is unchanged AND the write genuinely failed (no journal
# file anywhere under the isolated HOME) -- either assertion alone can't tell
# "the write failed safely" from "the write never happened to fail". ---
NOT_A_DIR="$WORK/not-a-dir"
: > "$NOT_A_DIR"
BROKEN_HOME="$NOT_A_DIR/sub"

payload_bash "rm -rf /" | HOME="$BROKEN_HOME" bash hooks/gates/irrecoverable.sh >/dev/null 2>&1; deny_broken_rc=$?
ok=1; [ "$deny_broken_rc" -eq 2 ] && ok=0
check "deny verdict unchanged (still exit 2) when the journal path is unwritable (ENOTDIR)" "$ok"

TESTFILE="$WORK/tests/hooks/test-sample.sh"
mkdir -p "$(dirname "$TESTFILE")"
printf 'check "case one" "$ok1"\n' > "$TESTFILE"
ask_baseline=$(payload_edit "$TESTFILE" 'check "case one" "$ok1"' '' | HOME="$WORK/case1-baseline" bash hooks/gates/test-integrity.sh 2>/dev/null)
ask_broken=$(payload_edit "$TESTFILE" 'check "case one" "$ok1"' '' | HOME="$BROKEN_HOME" bash hooks/gates/test-integrity.sh 2>/dev/null)
ok=1; [ "$ask_broken" = "$ask_baseline" ] && [ -n "$ask_broken" ] && ok=0
check "ask verdict stdout byte-identical whether journal succeeds or fails" "$ok"

# NOT_A_DIR is a regular file, so BROKEN_HOME (a path underneath it) can never
# be created by os.makedirs -- confirm it genuinely never came into existence,
# proving the write really failed rather than the assertion above being
# trivially true either way.
ok=1; [ ! -e "$BROKEN_HOME" ] && ok=0
check "journal write under the unwritable path genuinely failed (no dir ever created)" "$ok"

# --- Case 4: gate-id drift guard -- every gate's hardcoded GATE_ID constant
# must be THE id hook-registry.json assigns to that gate's own .sh file (no
# drift-detection for this exists anywhere else in the harness; check 73
# diffs hooks.json against the registry but never looks inside a gate .py).
# A raw substring search (an earlier version of this check) is too weak: it
# passes as long as the string exists ANYWHERE in the registry, so swapping
# two real gates' GATE_IDs -- silently mislabeling every journaled row from
# both -- goes undetected. Map each gate's .sh filename to its own registry
# entry via the entry's "command" field, then compare ids directly. ---
REGISTRY="$ROOT/hooks/hook-registry.json"

registry_id_for() { # registry_id_for <gate.sh basename>
  python3 -c "
import json, sys
d = json.load(open(sys.argv[2]))
name = sys.argv[1]
for group in d['hooks'].values():
    for entry in group:
        if name in entry.get('command', ''):
            print(entry.get('id', ''))
" "$1" "$REGISTRY"
}
# ids_in_registry <id> <newline-separated ids> -> 0 if <id> is one of them
ids_in_registry() { /usr/bin/grep -qxF -- "$1" <<<"$2"; }

ok=0
for f in "$ROOT"/hooks/gates/*.py; do
  [ "$(basename "$f")" = "_journal.py" ] && continue
  # One .sh can back several hook events (subagent-verdict-gate.sh: SubagentStop
  # + PreToolUse, GH #160), each with its own registry id and its own GATE_ID*
  # constant in the .py -- so every GATE_ID* must be one of THAT .sh's ids.
  ids=$(/usr/bin/grep -oE 'GATE_ID[A-Z_]* = "[^"]+"' "$f" | sed 's/.* = "//; s/"$//')
  [ -z "$ids" ] && continue  # this gate has no journal wiring (none expected today)
  sh_name="$(basename "$f" .py).sh"
  registry_ids=$(registry_id_for "$sh_name")
  for id in $ids; do
    ids_in_registry "$id" "$registry_ids" || { echo "  drift: $f's GATE_ID=$id is not among hook-registry.json's ids for $sh_name ($(echo "$registry_ids" | tr '\n' ' '))" >&2; ok=1; }
  done
done
check "every gate's GATE_ID matches hook-registry.json's own entry for that gate" "$ok"

# --- Case 4b: mutation proof the tightened check above isn't vacuous --
# assign irrecoverable's GATE_ID to config-write-guard's (a real id, just the
# wrong gate's) and confirm registry_id_for("irrecoverable.sh") still
# disagrees with it. A raw substring search would have missed this, since
# "gate:write:config-guard" genuinely exists in the registry. ---
MUTANT="$WORK/mutant-irrecoverable.py"
cp "$ROOT/hooks/gates/irrecoverable.py" "$MUTANT"
sed -i.bak 's/GATE_ID = "gate:bash:irrecoverable"/GATE_ID = "gate:write:config-guard"/' "$MUTANT"
mutant_id=$(/usr/bin/grep -oE 'GATE_ID = "[^"]+"' "$MUTANT" | head -1 | sed 's/GATE_ID = "//; s/"$//')
mutant_registry_ids=$(registry_id_for "irrecoverable.sh")
ok=1; [ "$mutant_id" = "gate:write:config-guard" ] && [ "$mutant_registry_ids" = "gate:bash:irrecoverable" ] && ! ids_in_registry "$mutant_id" "$mutant_registry_ids" && ok=0
check "mutation proof: an ID swapped to a different real gate's id is caught (not a raw substring hit)" "$ok"

# --- Case 4c: same proof for a two-event gate -- subagent-verdict-gate.sh has
# two registry ids; a GATE_ID that is a real id of a DIFFERENT gate must still
# be caught, while both of its own ids are accepted. ---
verdict_ids=$(registry_id_for "subagent-verdict-gate.sh")
ok=1
[ "$(printf '%s\n' "$verdict_ids" | /usr/bin/grep -c .)" -eq 2 ] \
  && ids_in_registry "gate:agent:subagent-verdict-check" "$verdict_ids" \
  && ids_in_registry "gate:agent:subagent-verdict-check-handback" "$verdict_ids" \
  && ! ids_in_registry "gate:bash:irrecoverable" "$verdict_ids" && ok=0
check "two-event gate: both own ids accepted, another gate's real id rejected" "$ok"

# --- Case 5: MH_GATE_JOURNAL_PATH override is honored (the mechanism
# scripts/run-gauntlet.sh's hook-test layer relies on, instead of swapping
# HOME wholesale -- an earlier version of that fix broke PyYAML-dependent
# tests, since PyYAML resolves via the real HOME's user site-packages). ---
OVERRIDE_PATH="$WORK/case5/custom-journal.jsonl"
payload_bash "rm -rf /" | env -u HOME MH_GATE_JOURNAL_PATH="$OVERRIDE_PATH" bash hooks/gates/irrecoverable.sh >/dev/null 2>&1; rc=$?
ok=1; [ "$rc" -eq 2 ] && ok=0
check "irrecoverable.sh still denies with HOME unset, override path set" "$ok"
ok=1
[ -f "$OVERRIDE_PATH" ] && /usr/bin/grep -q '"decision": "deny"' "$OVERRIDE_PATH" && ok=0
check "MH_GATE_JOURNAL_PATH override is honored, ignoring HOME entirely" "$ok"

# --- Case 5b: GH #378 count key. secret-scan.py journals its suppressed matches as one row with
# count=N; the key is written only when set, so every other gate's row keeps its old shape. ---
J5B="$WORK/case5b/count.jsonl"
MH_GATE_JOURNAL_PATH="$J5B" python3 -c '
import sys; sys.path.insert(0, "hooks/gates")
from _journal import journal
journal("gate:write:secret-scan", "Write", "allow-suppressed", "s1", count=3)
journal("gate:write:secret-scan", "Write", "ask", "s1")'
ok=1
python3 -c '
import json, sys
a, b = [json.loads(l) for l in open(sys.argv[1])]
assert a["decision"] == "allow-suppressed" and a["count"] == 3 and type(a["count"]) is int
assert b["decision"] == "ask" and "count" not in b' "$J5B" 2>/dev/null && ok=0
check "journal(count=3) writes \"count\": 3; a row without count= has no count key" "$ok"
ok=1; [ -f "$OVERRIDE_PATH" ] && ! /usr/bin/grep -q '"count"' "$OVERRIDE_PATH" && ok=0
check "irrecoverable's deny row carries no count key" "$ok"

# --- Case 6: GH #337 shadow mode. A rule id listed in irrecoverable.py's SHADOW_RULES journals
# would_deny/would_ask and allows. The list is a constant in the gate's source (no env var), so the
# test marks a rule shadowed in a copy of hooks/gates/, as case 4b does. ---
shadow_copy() { # shadow_copy <dir> <comma-separated quoted ids>
  mkdir -p "$1" && cp -R "$ROOT/hooks/gates/." "$1/"
  python3 - "$1/irrecoverable.py" "$2" <<'EOF'
import re, sys
p = sys.argv[1]
s, n = re.subn(r"^SHADOW_RULES = .*$", "SHADOW_RULES = frozenset({" + sys.argv[2] + "})", open(p).read(), flags=re.M)
assert n == 1, "SHADOW_RULES line not found exactly once"
open(p, "w").write(s)
EOF
}
rows() { # rows <journal> <decision> <rule> -> count of matching rows
  python3 -c '
import json, sys
n = 0
for line in open(sys.argv[1]):
    r = json.loads(line)
    n += r.get("decision") == sys.argv[2] and r.get("rule") == sys.argv[3]
print(n)' "$1" "$2" "$3" 2>/dev/null || echo 0
}
SH_RM="$WORK/shadow-rm"; shadow_copy "$SH_RM" '"rm-rf"'
SH_GH="$WORK/shadow-gh"; shadow_copy "$SH_GH" '"gh-pr-merge"'

J6="$WORK/case6/plain.jsonl"
payload_bash "rm -rf build" | MH_GATE_JOURNAL_PATH="$J6" bash hooks/gates/irrecoverable.sh >/dev/null 2>&1; rc=$?
ok=1; [ "$rc" -eq 2 ] && [ "$(rows "$J6" deny rm-rf)" = 1 ] && ok=0
check "unshadowed: rm -rf denies (rc=2) and the deny row carries rule rm-rf" "$ok"

J6="$WORK/case6/shadow.jsonl"
out=$(payload_bash "rm -rf build" | MH_GATE_JOURNAL_PATH="$J6" bash "$SH_RM/irrecoverable.sh" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(rows "$J6" would_deny rm-rf)" = 1 ] && [ "$(rows "$J6" deny rm-rf)" = 0 ] && ok=0
check "shadowed rm-rf: same command allowed (rc=0, no stdout), one would_deny row, no deny row" "$ok"
ok=1; /usr/bin/grep -q '"command": "rm -rf build"' "$J6" && ok=0
check "the would_deny row carries the command for gate-report's samples" "$ok"

J6="$WORK/case6/dedupe.jsonl"
payload_bash "rm -rf a; rm -rf b{1}" | MH_GATE_JOURNAL_PATH="$J6" bash "$SH_RM/irrecoverable.sh" >/dev/null 2>&1; rc=$?
ok=1; [ "$rc" -eq 0 ] && [ "$(rows "$J6" would_deny rm-rf)" = 1 ] && ok=0
check "shadowed rule matching in several windows and copies journals once per run" "$ok"

J6="$WORK/case6/later.jsonl"
payload_bash "rm -rf build && git push --force origin main" | MH_GATE_JOURNAL_PATH="$J6" bash "$SH_RM/irrecoverable.sh" >/dev/null 2>&1; rc=$?
ok=1; [ "$rc" -eq 2 ] && [ "$(rows "$J6" would_deny rm-rf)" = 1 ] && [ "$(rows "$J6" deny git-push-force)" = 1 ] && ok=0
check "a shadowed match does not end the scan: a later enforced rule still denies" "$ok"

J6="$WORK/case6/ask.jsonl"
out=$(payload_bash "gh pr merge 5" | MH_GATE_JOURNAL_PATH="$J6" bash "$SH_GH/irrecoverable.sh" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(rows "$J6" would_ask gh-pr-merge)" = 1 ] && ok=0
check "shadowed ask rule: no ask JSON on stdout, one would_ask row" "$ok"
out=$(payload_bash "gh pr merge 5 && gh api repos/o/r/pulls/5/merge -X PUT" | MH_GATE_JOURNAL_PATH="$J6" bash "$SH_GH/irrecoverable.sh" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"] == "ask"' 2>/dev/null && ok=0
check "a shadowed ask does not swallow a later enforced ask in the same run" "$ok"

payload_bash "rm -rf build" | HOME="$BROKEN_HOME" bash "$SH_RM/irrecoverable.sh" >/dev/null 2>&1; rc=$?
ok=1; [ "$rc" -eq 0 ] && ok=0
check "shadowed match with an unwritable journal (ENOTDIR) still allows (rc=0)" "$ok"

# Every id in SHADOW_RULES must name a rule="..." call site, or a typo shadows nothing and the new
# rule enforces silently. Mutation proof: an id with no call site is caught.
shadow_drift() { # shadow_drift <irrecoverable.py> -> ids in SHADOW_RULES with no rule="<id>" call site
  python3 -c '
import ast, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^SHADOW_RULES = frozenset\((.*)\)$", src, re.M)
ids = ast.literal_eval(m.group(1) or "()")
sites = set(re.findall(r"rule=\"([^\"]+)\"", src)) | set(re.findall(r"\(\"([a-z-]+)\", (?:v|_BRACEX_TEXT)\)", src))
print(" ".join(sorted(set(ids) - sites)))' "$1"
}
ok=1; [ -z "$(shadow_drift "$ROOT/hooks/gates/irrecoverable.py")" ] && [ -z "$(shadow_drift "$SH_RM/irrecoverable.py")" ] && ok=0
check "every SHADOW_RULES id names a rule= call site" "$ok"
SH_BAD="$WORK/shadow-bad"; shadow_copy "$SH_BAD" '"rm-fr"'
ok=1; [ "$(shadow_drift "$SH_BAD/irrecoverable.py")" = "rm-fr" ] && ok=0
check "mutation proof: a SHADOW_RULES id with no call site is reported" "$ok"

# --- Case 7: GH #336's views (another reading of the command) carry a rule id of their own. With the
# view shadowed, a deny found only in that reading is journaled under the view's id and allowed, even
# though the rule it matched (rm-rf) enforces; the plain command still denies. ---
for _view in ifs-split var-verb; do
  SH_V="$WORK/shadow-$_view"; shadow_copy "$SH_V" "\"$_view\""
  case "$_view" in
    ifs-split) _vcmd='rm${IFS}-rf build' ;;
    var-verb) _vcmd='X=rm; $X -rf build' ;;
  esac
  J7="$WORK/case7/$_view.jsonl"
  out=$(payload_bash "$_vcmd" | MH_GATE_JOURNAL_PATH="$J7" bash "$SH_V/irrecoverable.sh" 2>/dev/null); rc=$?
  ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(rows "$J7" would_deny "$_view")" = 1 ] && [ "$(rows "$J7" deny rm-rf)" = 0 ] && ok=0
  check "shadowed $_view view: its deny is journaled under $_view and allowed" "$ok"
  payload_bash "rm -rf build" | MH_GATE_JOURNAL_PATH="$J7" bash "$SH_V/irrecoverable.sh" >/dev/null 2>&1; rc=$?
  ok=1; [ "$rc" -eq 2 ] && ok=0
  check "shadowed $_view view: the plain rm -rf still denies" "$ok"
  SH_E="$WORK/enforce-$_view"; shadow_copy "$SH_E" ""
  payload_bash "$_vcmd" | MH_GATE_JOURNAL_PATH="$J7" bash "$SH_E/irrecoverable.sh" >/dev/null 2>&1; rc=$?
  ok=1; [ "$rc" -eq 2 ] && [ "$(rows "$J7" deny "$_view")" = 1 ] && ok=0
  check "enforced $_view view: denies, and the deny row names $_view" "$ok"
done

echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
