#!/usr/bin/env bash
# scripts/_lib/transcript-user-turns.py: filters a session .jsonl transcript
# down to its own human-typed turns, skipping tool-result turns.
# Also pins issue #413: skills/meta/learn/SKILL.md calls the script's --json
# mode instead of carrying its own inline filter, and the known differences
# between that retired inline filter and the script are spelled out below.
# Run standalone: bash tests/scripts/test-transcript-user-turns.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/_lib/transcript-user-turns.py"
SKILL="$ROOT/skills/meta/learn/SKILL.md"
fail=0

python3 "$SCRIPT" --selftest || { echo "FAIL: transcript-user-turns.py selftest"; exit 1; }

TMP="$(mktemp -d)"
trap 'python3 "$ROOT/tests/_lib/tmp_delete.py" "$TMP"' EXIT

# Equivalence check: the retired SKILL filter (frozen copy, verbatim logic)
# vs the script's --json mode, on one fixture covering every edge class.
python3 - "$SCRIPT" "$TMP/fixture.jsonl" <<'PY' || fail=1
import json, subprocess, sys
script, fixture = sys.argv[1], sys.argv[2]

def ev(uid, content, **extra):
    o = {"type": "user", "uuid": uid, "timestamp": "2026-10-04T00:00:00Z",
         "message": {"role": "user", "content": content}}
    o.update(extra)
    return json.dumps(o)

lines = [
    ev("plain", "fix the bug"),
    ev("textblock", [{"type": "text", "text": "second prompt"}]),
    ev("toolres", [{"type": "tool_result", "content": "out"}]),
    ev("notify", "<task-notification><status>completed</status></task-notification>"),
    ev("meta", "Base directory for this skill", isMeta=True),
    ev("compact", "This session is being continued", isCompactSummary=True),
    ev("sidechain", "subagent prompt", isSidechain=True),
    # Qualifying JSON events with no nonblank text:
    ev("blankstr", "   "),
    ev("emptytext", [{"type": "text", "text": ""}]),
    ev("imageonly", [{"type": "image", "source": {}}]),
    # A "user" event whose message carries no role:
    json.dumps({"type": "user", "uuid": "norole", "message": {"content": "no role"}}),
    json.dumps({"type": "assistant", "uuid": "asst", "message": {"role": "assistant", "content": "x"}}),
    "",
    "not json",
]
with open(fixture, "w") as f:
    f.write("\n".join(lines) + "\n")

def old_filter(path):
    # Frozen copy of the filter skills/meta/learn/SKILL.md carried before #413.
    out = []
    for line in open(path):
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except ValueError: continue
        if o.get('type') != 'user' or o.get('isMeta') or o.get('isCompactSummary'): continue
        msg = o.get('message', {})
        if msg.get('role') != 'user': continue
        content = msg.get('content')
        if isinstance(content, str) and content.startswith('<task-notification>'):
            continue
        if isinstance(content, list) and any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in content):
            continue
        out.append(o["uuid"])
    return out

res = subprocess.run([sys.executable, script, "--json", fixture],
                     capture_output=True, text=True)
assert res.returncode == 0, res.stderr
new_rows = [json.loads(l) for l in res.stdout.splitlines()]
new = [r["uuid"] for r in new_rows]
old = old_filter(fixture)

expect_both = ["plain", "textblock", "sidechain"]
expect_old_only = ["blankstr", "emptytext", "imageonly"]  # no nonblank text
expect_new_only = ["norole"]  # script does not check message.role
ok = True
def check(name, got, want):
    global ok
    if got != want:
        ok = False
        print("FAIL: %s: got %r, want %r" % (name, got, want))
check("both", [u for u in old if u in new], expect_both)
check("old-only (blank text)", [u for u in old if u not in new], expect_old_only)
check("script-only (no role)", [u for u in new if u not in old], expect_new_only)
check("turn numbering", [r["turn"] for r in new_rows], list(range(1, len(new_rows) + 1)))
check("text field", new_rows[0]["text"] if new_rows else None, "fix the bug")
sys.exit(0 if ok else 1)
PY

# The SKILL must call the script, not re-describe a filter of its own.
if ! /usr/bin/grep -q 'transcript-user-turns.py" --json' "$SKILL"; then
  echo "FAIL: learn SKILL.md does not call transcript-user-turns.py --json"; fail=1
fi
if /usr/bin/grep -q 'python3 -c' "$SKILL"; then
  echo "FAIL: learn SKILL.md still carries an inline python3 -c filter"; fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: test-transcript-user-turns"
