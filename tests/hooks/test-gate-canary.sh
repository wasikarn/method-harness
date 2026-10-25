#!/usr/bin/env bash
# scripts/gate-canary.sh (run by pre-commit on staged gates) must pass on the
# shipped gates and fail on the two slips that locked Bash machine-wide on
# 2026-09-05: a NameError in irrecoverable.py, and an apostrophe inside a
# gate's embedded python string (GH #146 shape).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
CANARY="$ROOT/scripts/gate-canary.sh"
pass=0; fail=0
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

tmp=$(mktemp -d)
trap '[ -n "$tmp" ] && trash "$tmp" 2>/dev/null || true' EXIT
fresh() { cp "$ROOT"/hooks/gates/*.sh "$ROOT"/hooks/gates/*.py "$tmp"/; }

bash "$CANARY" "$ROOT/hooks/gates" >/dev/null 2>&1
check "shipped gates pass the canary" $?

fresh
python3 -c "
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace('import json, os, re, shlex, sys', 'import json, os, re, shlex, sys\nundefined_name_xyz()', 1)
open(p, 'w').write(s)" "$tmp/irrecoverable.py"
bash "$CANARY" "$tmp" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "injected NameError in irrecoverable.py fails the canary" $?

fresh
# The Write/Edit wrappers skip python on a benign payload (_silent_fastpath.sh); the canary must
# still run it, or a slip in secret-scan.py ships past pre-commit.
python3 -c "
import sys; p = sys.argv[1]; s = open(p).read()
open(p, 'w').write('undefined_name_xyz()\n' + s)" "$tmp/secret-scan.py"
bash "$CANARY" "$tmp" secret-scan.sh >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "injected NameError in secret-scan.py fails the canary despite the fast path" $?

fresh
# Synthetic fixture, not a real shipped gate: every gate that used to embed
# `python3 -c '...'` has been extracted to a sibling .py (irrecoverable,
# test-integrity, config-write-guard, subagent-git-guard,
# task-complete-separation — GH #146/#148/#149), so pinning this check to a
# real filename breaks the moment that file's extraction lands. This gate
# shape (embedded python3 -c block) is what gate-canary.sh's detection
# mechanism must still catch even after every currently-shipped gate stops
# using it.
cat > "$tmp/canary-fixture-apostrophe.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
python3 -c '
import json, sys
json.load(sys.stdin)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse"}}))
'
FIXTURE
chmod +x "$tmp/canary-fixture-apostrophe.sh"
python3 -c "
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace('import json, sys', 'import json, sys  # it' + chr(39) + 's', 1)
open(p, 'w').write(s)" "$tmp/canary-fixture-apostrophe.sh"
bash "$CANARY" "$tmp" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "apostrophe inside an embedded python string fails the canary" $?

fresh
trash "$tmp/canary-fixture-apostrophe.sh"
# A sourced _*.sh helper is not a gate: one that exits 1 when run directly must not fail the canary.
printf '#!/usr/bin/env bash\necho "Error: sourced helper run as a gate" >&2\nexit 1\n' > "$tmp/_helper-probe.sh"
bash "$CANARY" "$tmp" >/dev/null 2>&1
check "a _*.sh helper is skipped, not run as a gate" $?

echo ""
echo "test-gate-canary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
