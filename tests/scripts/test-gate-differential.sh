#!/usr/bin/env bash
# scripts/gate-differential.sh (GH #411): old-vs-new gate replay that prints diff classes only.
# Checks: identical copies give 0 diffs; a planted one-rule change gives exactly its class and
# never prints the secret-shaped command it replayed; a --slug outside this project is refused;
# --replay reads only this project's transcript dirs; the real gate journal is never written;
# the caller's env and cwd never reach the gates (GH #888); fork mode matches bash mode and drops
# fork-only diffs (GH #889); a slower new side lands in `slower` (GH #890).
# Run standalone: bash tests/scripts/test-gate-differential.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../_lib/harness.sh
. "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
SCRIPT="$ROOT/scripts/gate-differential.sh"
GATES="$ROOT/hooks/gates"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

T=$(fresh_tmpdir)
[ -n "$T" ] && [ -d "$T" ] || { echo "FAIL: no tmpdir" >&2; exit 1; }
# A fake HOME holding a seeded "real" journal: every run below must leave it at 3 lines.
export HOME="$T/home"
JOURNAL="$HOME/.local/share/kbg/metrics/gate-decisions.jsonl"
mkdir -p "$(dirname "$JOURNAL")"
printf '{"seed":1}\n{"seed":2}\n{"seed":3}\n' > "$JOURNAL"
unset MH_GATE_JOURNAL_PATH GAUNTLET_LOCK_DIR
export CLAUDE_CONFIG_DIR="$T/cc"

cp -R "$GATES" "$T/old"
cp -R "$GATES" "$T/same"
cp -R "$GATES" "$T/planted"
# The planted one-rule change: drop the npm pattern from secret-scan.py.
awk '!/\("npm", re\.compile/' "$GATES/secret-scan.py" > "$T/planted/secret-scan.py"
if cmp -s "$GATES/secret-scan.py" "$T/planted/secret-scan.py"; then
  bad "planting the npm rule edit changed nothing (pattern line moved?)"
fi

# Built, never written whole: a live-shaped npm token (no repeated or ascending run).
tok="npm_""$(printf 'Zq8Lm3%.0s' 1 2 3 4 5 6)"
printf 'plain text, no token\nkey=%s\n' "$tok" > "$T/cases.txt"

echo "=== identical copies ==="
out=$(bash "$SCRIPT" --cases "$T/cases.txt" "$T/old" "$T/same" secret-scan 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out"; then
  ok "identical copies: exit 0, diffs=0"
else bad "identical copies (rc=$rc): $out"; fi

echo "=== planted one-rule change ==="
out=$(bash "$SCRIPT" --cases "$T/cases.txt" "$T/old" "$T/planted" secret-scan 2>&1); rc=$?
classes=$(printf '%s\n' "$out" | /usr/bin/grep -c '^  \[')
if [ "$rc" -eq 1 ] && [ "$classes" -eq 1 ] \
   && /usr/bin/grep -q '^  \[1\] stdout | journal ask->none$' <<<"$out"; then
  ok "planted change: exactly one class, 'stdout | journal ask->none', count 1"
else bad "planted change (rc=$rc, classes=$classes): $out"; fi
case "$out" in
  *Zq8Lm3*) bad "planted change: output leaked the secret-shaped command" ;;
  *'[REDACTED]'*) ok "planted change: command redacted" ;;
  *) bad "planted change: no redacted sample shown: $out" ;;
esac

echo "=== git ref as OLD ==="
out=$(bash "$SCRIPT" --cases "$T/cases.txt" HEAD "$T/same" secret-scan 2>&1); rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then ok "git ref OLD resolves (rc=$rc)"
else bad "git ref OLD (rc=$rc): $out"; fi

echo "=== slug outside the project ==="
out=$(bash "$SCRIPT" --replay 3 --slug -home-someone-else "$T/old" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'refusing' <<<"$out"; then
  ok "foreign --slug refused with exit 2"
else bad "foreign --slug (rc=$rc): $out"; fi

echo "=== replay reads this project only ==="
main=$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir)
slug=$(cd -P "$main/.." && pwd | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug/s1/subagents" "$CLAUDE_CONFIG_DIR/projects/${slug}x"
use() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$1"; }
use 'rm -rf build' > "$CLAUDE_CONFIG_DIR/projects/$slug/a.jsonl"
use 'ls -la' > "$CLAUDE_CONFIG_DIR/projects/$slug/s1/subagents/agent-1.jsonl"
{ use 'echo other1'; use 'echo other2'; } > "$CLAUDE_CONFIG_DIR/projects/${slug}x/b.jsonl"
: > "$T/empty.txt"
out=$(bash "$SCRIPT" --cases "$T/empty.txt" --replay 50 "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'replay=2 ' <<<"$out"; then
  ok "replay sampled the 2 commands of this project, none from a sibling-named project"
else bad "replay (rc=$rc): $out"; fi

echo "=== slug traversal out of a worktree prefix ==="
out=$(bash "$SCRIPT" --replay 3 --slug "$slug--claude-worktrees-probe/../foreign" "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'refusing' <<<"$out"; then
  ok "--slug with ../ refused with exit 2"
else bad "--slug traversal (rc=$rc): $out"; fi

echo "=== fuzz ==="
# A small --cases corpus: fuzz still draws its 200 mutations, but the run no longer replays the
# whole irrecoverable fixture set twice (~560 gate spawns, ~60 s). Gate verdicts on that set are
# tests/hooks' job; this file covers the harness, and fixture parsing is checked directly below.
printf 'rm -rf build\ngit reset --hard\n' > "$T/deny.txt"
out=$(bash "$SCRIPT" --cases "$T/deny.txt" --fuzz-seed 7 "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -Eq 'fuzz=[1-9][0-9]*\)' <<<"$out"; then
  ok "fuzz adds seeded cases, 0 diffs on identical copies"
else bad "fuzz (rc=$rc): $out"; fi

echo "=== fixture parsing ==="
# The default corpus (no --cases) is the committed fixtures; parse them without running the gate.
n=$(python3 - "$ROOT/scripts/_lib/gate-differential.py" "$ROOT/tests/hooks/fixtures" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gd", sys.argv[1])
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)
print(len(gd.fixture_cases(sys.argv[2], "irrecoverable")))
PY
)
if [ "$n" -ge 50 ] 2>/dev/null; then ok "fixture corpus parses ($n irrecoverable cases)"
else bad "fixture corpus did not parse (want >=50 cases): $n"; fi

echo "=== real journal untouched ==="
out=$(bash "$SCRIPT" --cases "$T/deny.txt" "$T/old" "$T/same" irrecoverable 2>&1)
n=$(wc -l < "$JOURNAL" | tr -d ' ')
if [ "$n" -eq 3 ]; then ok "real journal still 3 lines after the deny runs"
else bad "real journal grew to $n lines: $out"; fi

echo "=== never queues behind a gauntlet ==="
# A live gauntlet (this test's pid) holds the lock under the fake HOME: the run must neither wait for
# it nor touch it (a 28-min replay in the queue kept every push waiting, 2026-10-27).
lock="$HOME/.cache/mh/gauntlet.lock"
mkdir -p "$lock" && echo "$$" > "$lock/pid"
# WAIT_SECS=0: a reintroduced lock then fails this row at once instead of waiting 1800 s.
out=$(env -u MH_GAUNTLET_LOCK_OWNER GAUNTLET_LOCK_WAIT_SECS=0 bash "$SCRIPT" --cases "$T/deny.txt" "$T/old" "$T/same" irrecoverable 2>&1)
if ! /usr/bin/grep -q 'gauntlet-lock' <<<"$out" && /usr/bin/grep -q 'diffs=0' <<<"$out" && [ "$(cat "$lock/pid")" = "$$" ]; then
  ok "a held gauntlet lock is not waited on and is left to its holder"
else bad "the run waited on or touched the gauntlet lock: $out"; fi

echo "=== canonical env: a caller's gate knob changes nothing (GH #888) ==="
# The planted copy ignores MH_IRR_DEADLINE_SECS. If the knob reached the gates, the old side would
# ask on a 1 us deadline and the new side would deny: a diff that only the caller's env made.
cp -R "$GATES" "$T/noknob"
python3 - "$GATES/irrecoverable.py" "$T/noknob/irrecoverable.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
k = 'os.environ.get("MH_IRR_DEADLINE_SECS", "")'
assert s.count(k) == 1, "knob read moved"
open(sys.argv[2], "w").write(s.replace(k, '""'))
PY
printf 'rm -rf build\n' > "$T/rm.txt"
out=$(MH_IRR_DEADLINE_SECS=0.000001 bash "$SCRIPT" --cases "$T/rm.txt" "$T/old" "$T/noknob" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out"; then
  ok "MH_IRR_DEADLINE_SECS in the caller's env does not reach the gates"
else bad "caller knob leaked into the replay (rc=$rc): $out"; fi

echo "=== canonical env: a mid-merge caller cwd or GIT_DIR changes nothing (GH #888) ==="
# The planted copy never sees a merge. If the gates ran in the caller's cwd (or its GIT_DIR), the
# old side would allow `git add -A` mid-merge and the new side would deny it.
cp -R "$GATES" "$T/nomerge"
python3 - "$GATES/irrecoverable.py" "$T/nomerge/irrecoverable.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
k = "def _mid_merge():\n"
assert s.count(k) == 1, "_mid_merge moved"
open(sys.argv[2], "w").write(s.replace(k, k + "    return False\n"))
PY
M="$T/merging"
mkdir -p "$M"
git -C "$M" init -q && git -C "$M" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$M" rev-parse HEAD > "$M/.git/MERGE_HEAD"
printf 'git add -A\n' > "$T/addall.txt"
out=$(cd "$M" && bash "$SCRIPT" --cases "$T/addall.txt" "$T/old" "$T/nomerge" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out"; then
  ok "a mid-merge caller cwd does not reach the gates"
else bad "caller cwd leaked into the replay (rc=$rc): $out"; fi
out=$(GIT_DIR="$M/.git" bash "$SCRIPT" --cases "$T/addall.txt" "$T/old" "$T/nomerge" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out"; then
  ok "a caller GIT_DIR does not reach the gates"
else bad "caller GIT_DIR leaked into the replay (rc=$rc): $out"; fi

echo "=== fork runner matches the bash runner on the committed fixtures (GH #889) ==="
# A planted message change gives a diff on every irrecoverable deny; both runners must report the
# same classes, counts and samples.
cp -R "$GATES" "$T/reworded"
sed 's/\[mh:gate\] BLOCKED/[mh:gate] BLOCKD/' "$GATES/irrecoverable.py" > "$T/reworded/irrecoverable.py"
fork_out=$(bash "$SCRIPT" --runner fork "$T/old" "$T/reworded" irrecoverable 2>&1); frc=$?
bash_out=$(bash "$SCRIPT" --runner bash "$T/old" "$T/reworded" irrecoverable 2>&1); brc=$?
strip() { /usr/bin/grep -v '^  runner:' <<<"$1"; }
if [ "$frc" -eq 1 ] && [ "$brc" -eq 1 ] && /usr/bin/grep -q '^  runner: fork (fork-only diffs dropped: 0,' <<<"$fork_out" \
   && /usr/bin/grep -q '^  runner: bash' <<<"$bash_out" && [ "$(strip "$fork_out")" = "$(strip "$bash_out")" ] \
   && ! /usr/bin/grep -q 'diffs=0 ' <<<"$fork_out"; then
  ok "fork and bash runners give the same diffs on the fixtures, none dropped"
else bad "fork vs bash on the fixtures (frc=$frc brc=$brc): --- fork: $fork_out --- bash: $bash_out"; fi
cp -R "$GATES" "$T/sgg-reworded"
sed 's/\[mh:gate\] BLOCKED/[mh:gate] BLOCKD/' "$GATES/subagent-git-guard.py" > "$T/sgg-reworded/subagent-git-guard.py"
fork_out=$(bash "$SCRIPT" --runner fork "$T/old" "$T/sgg-reworded" subagent-git-guard 2>&1); frc=$?
bash_out=$(bash "$SCRIPT" --runner bash "$T/old" "$T/sgg-reworded" subagent-git-guard 2>&1); brc=$?
if [ "$frc" -eq 1 ] && [ "$brc" -eq 1 ] && /usr/bin/grep -q '^  runner: fork (fork-only diffs dropped: 0,' <<<"$fork_out" \
   && [ "$(strip "$fork_out")" = "$(strip "$bash_out")" ] && ! /usr/bin/grep -q 'diffs=0 ' <<<"$fork_out"; then
  ok "subagent-git-guard: fork and bash give the same diffs on the fixtures, none dropped"
else bad "sgg fork vs bash on the fixtures (frc=$frc brc=$brc): --- fork: $fork_out --- bash: $bash_out"; fi

# Stub gates: copies of the real dir (the wrapper and secret-scan.py stay real) with irrecoverable.py replaced.
stub() {  # stub DIR PYTHON-BODY: a gates copy whose irrecoverable.py is the given body after reading stdin
  cp -R "$GATES" "$1"
  printf 'import json, sys, time\nd = json.load(sys.stdin)\nc = d["tool_input"]["command"]\n%s\nsys.exit(0)\n' "$2" > "$1/irrecoverable.py"
}

echo "=== a fork-only diff is re-checked through bash and dropped (GH #889) ==="
# irrecoverable.sh allows `ls -la` on its fast path without python, so bash never sees the stub's deny
# of it; fork mode runs python for every command, finds that diff, and must drop it. The `rm` deny
# reaches python on both runners and stays.
stub "$T/s-allow" 'pass'
stub "$T/s-deny" 'if c in ("ls -la", "rm -rf build"): sys.exit(2)'
printf 'ls -la\nrm -rf build\n' > "$T/two.txt"
out=$(bash "$SCRIPT" --cases "$T/two.txt" "$T/s-allow" "$T/s-deny" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=1 ' <<<"$out" && /usr/bin/grep -q '^  \[1\] exit 0->2$' <<<"$out" \
   && /usr/bin/grep -q '^      - ls -la$' <<<"$(/usr/bin/grep -A1 '^  runner: fork (fork-only diffs dropped: 1,' <<<"$out")"; then
  ok "fork-only diff dropped after the bash re-check and named; the confirmed one is kept"
else bad "fork-only re-check (rc=$rc): $out"; fi

echo "=== a fork server that dies falls back to the bash runner (GH #889) ==="
# A gate that os._exits while the server warms it up kills the server: the run goes on through bash.
stub "$T/s-exit" 'import os; os._exit(0)'
out=$(bash "$SCRIPT" --cases "$T/rm.txt" "$T/s-exit" "$T/s-exit" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out" && /usr/bin/grep -q '^  runner: bash (fork server exited' <<<"$out"; then
  ok "a dead fork server falls back to bash"
else bad "dead fork server (rc=$rc): $out"; fi

# bounded SECS DIR ARGS...: run the differential on ARGS in the background, killed at SECS, so a regressed
# bound turns a row red instead of hanging the gauntlet (it has no per-test timeout). DIR is a stub dir
# every process of the run names on its command line. Sets out, rc and took.
bounded() {
  local secs=$1 dir=$2 start pid; shift 2
  start=$(date +%s)
  bash "$SCRIPT" "$@" > "$T/bounded.out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ $(( $(date +%s) - start )) -lt "$secs" ]; do sleep 1; done
  # The run may exit between the check and the kill, so a failed kill is fine.
  if kill -0 "$pid" 2>/dev/null; then pkill -9 -f "$dir"; kill -9 "$pid" 2>/dev/null; fi
  wait "$pid"; rc=$?
  took=$(( $(date +%s) - start ))
  out=$(cat "$T/bounded.out")
}

echo "=== a gate that hangs the server's warm-up falls back to bash in bounded time (GH #889) ==="
stub "$T/s-hang" 'while c == "ls -la": pass'
bounded 90 "$T/s-hang" --cases "$T/rm.txt" "$T/s-allow" "$T/s-hang" irrecoverable
if [ "$rc" -eq 0 ] && [ "$took" -lt 60 ] && /usr/bin/grep -q '^  runner: bash (fork server .*did not answer' <<<"$out"; then
  ok "a hung warm-up falls back to bash (${took} s)"
else bad "hung warm-up (rc=$rc, ${took} s): $out"; fi

echo "=== a timed-out gate's own children are killed with it (GH #889) ==="
# The stub starts a child and outlives the 8 s timeout, on both runners (fork, then bash as a
# near-deadline re-run): each runner kills the gate's whole process group.
# The sleep must be valid on GNU and BSD (one dot, digits: 987.<pid>.<n> exited at once and made this row
# pass vacuously) and outlive the run. Unkilled, it also holds the bash runner's pipes, so that run waits
# for the stub's own 100 s: the row checks the time too, and is itself bounded so it fails, never hangs.
sleep_arg="120.$$$RANDOM"
stub "$T/s-orphan" "if c == 'rm -rf build':
    import subprocess; subprocess.Popen(['sleep', '$sleep_arg']); time.sleep(100)"
bounded 150 "$T/s-orphan" --cases "$T/rm.txt" "$T/s-orphan" "$T/s-orphan" irrecoverable
left=$(pgrep -f "sleep $sleep_arg" | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$left" -eq 0 ] && [ "$took" -lt 60 ] && /usr/bin/grep -q 'near-deadline re-runs: 1)' <<<"$out"; then
  ok "no child of a timed-out gate is left running (${took} s)"
else bad "orphans after a timeout (rc=$rc, left=$left, ${took} s): $out"; pkill -f "sleep $sleep_arg"; fi

echo "=== a child set-up failure is reported, never read as the gate's exit (GH #889) ==="
mkdir -p "$T/srv"
reply=$(printf '{"in": "%s", "out": "%s", "err": "%s"}\n' "$T/srv/missing" "$T/srv/out" "$T/srv/err" \
  | (cd "$T/srv" && python3 -S "$ROOT/scripts/_lib/gate-fork-server.py" "$T/s-allow" irrecoverable 8 2>"$T/srv/server.err"))
if /usr/bin/grep -q '"code": "setup-failed"' <<<"$reply" && /usr/bin/grep -q 'Traceback' "$T/srv/server.err"; then
  ok "set-up failure: reply setup-failed, traceback on the server's stderr"
else bad "set-up failure: reply=$reply stderr=$(cat "$T/srv/server.err" 2>&1)"; fi

echo "=== the engine never reads a broken fork server's reply as a result (GH #889) ==="
# A fake server (FORK_SERVER swapped in the loaded engine) replies per a fake-mode file in each gates
# dir; the bash runner still runs the real stub wrappers. s-allow vs s-deny differ on `rm -rf build`.
cat > "$T/fake-server.py" <<'PY'
import json, os, sys
mode = open(os.path.join(sys.argv[1], "fake-mode")).read().split()
sys.stdout.write("ready\n"); sys.stdout.flush()
n = 0
for line in sys.stdin:
    n += 1
    req = json.loads(line)
    if mode[0] == "setup":
        rep = '{"code": "setup-failed", "secs": 0}'
    elif mode[0] == "garble":
        rep = "not json"
    else:  # die-after-2 CODE: answer two commands with CODE and empty output (the second one near the
        # deadline: over half of 4 s), then exit 3
        if n > 2:
            sys.exit(3)
        for k in ("out", "err"):
            open(req[k], "w").close()
        rep = json.dumps({"code": int(mode[1]), "secs": 0.001 if n == 1 else 2.5})
    sys.stdout.write(rep + "\n"); sys.stdout.flush()
PY
fake() {  # fake OLD NEW CASES RUNNER: the engine with $SERVER (default the fake server), through a fresh temp dir
  local tmp; tmp=$(mktemp -d "$T/fake.XXXXXX")
  python3 - "$ROOT/scripts/_lib/gate-differential.py" "${SERVER:-$T/fake-server.py}" "$1" "$2" "$3" "$4" "$tmp" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gd", sys.argv[1])
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)
gd.FORK_SERVER = sys.argv[2]
import os
if os.environ.get("GD_TIMEOUT"):  # a short hook timeout for the timeout rows
    gd.TIMEOUT = float(os.environ["GD_TIMEOUT"])
if os.environ.get("KILLPG_EPERM"):  # what macOS gives for a group whose only member is a zombie
    def _eperm(*a):
        raise PermissionError(1, "Operation not permitted")
    os.killpg = _eperm
old, new, cases, runner, tmp = sys.argv[3:8]
sys.argv = ["gd", "--old", old, "--new", new, "--gate", "irrecoverable", "--tmp", tmp, "--projects", tmp,
            "--own-slug", "x", "--fixtures", tmp, "--cases", cases, "--runner", runner]
sys.exit(gd.main())
PY
}
for m in setup garble; do
  cp -R "$T/s-allow" "$T/f-$m-a"; echo "$m" > "$T/f-$m-a/fake-mode"
  cp -R "$T/s-deny" "$T/f-$m-b"; echo "$m" > "$T/f-$m-b/fake-mode"
done
out=$(fake "$T/f-setup-a" "$T/f-setup-b" "$T/rm.txt" auto); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=1 ' <<<"$out" && /usr/bin/grep -q '^  runner: bash (fork server could not set up a child' <<<"$out"; then
  ok "setup-failed on both sides falls back to bash, which finds the diff"
else bad "engine setup-failed (rc=$rc): $out"; fi
out=$(fake "$T/f-garble-a" "$T/f-garble-b" "$T/rm.txt" auto); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=1 ' <<<"$out" && /usr/bin/grep -q '^  runner: bash (fork server sent a garbled reply' <<<"$out"; then
  ok "a garbled reply falls back to bash"
else bad "engine garbled reply (rc=$rc): $out"; fi
cp -R "$T/s-allow" "$T/f-die-a"; echo "die-after-2 0" > "$T/f-die-a/fake-mode"
cp -R "$T/s-allow" "$T/f-die-b"; echo "die-after-2 2" > "$T/f-die-b/fake-mode"
printf 'ls -la\nrm -rf build\necho three\n' > "$T/three.txt"
out=$(fake "$T/f-die-a" "$T/f-die-b" "$T/three.txt" auto); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out" \
   && /usr/bin/grep -q '^  runner: bash (fork server exited (rc=3); bash from that command on; before that, fork-only diffs dropped: 1, near-deadline re-runs: 1)$' <<<"$out"; then
  ok "a server dying mid-run: bash for the rest, both counts kept"
else bad "engine mid-run death (rc=$rc): $out"; fi
out=$(fake "$T/f-die-a" "$T/f-die-b" "$T/three.txt" fork); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'fork mode cannot run (fork server exited (rc=3)' <<<"$out"; then
  ok "--runner fork exits 2 when a server dies mid-run"
else bad "--runner fork mid-run death (rc=$rc): $out"; fi

echo "=== an EPERM from the child's setpgid keeps fork mode (PR #899, full-pool replay on macOS) ==="
# The real server with os.setpgid patched to raise EPERM: for the child's own call only (the parent's
# setpgid(pid, pid) still gives it its group, so nothing changes), or for every call (no group: that
# one command goes through bash, and fork mode goes on).
eperm_server() {  # eperm_server OUT child|all
  python3 - "$ROOT/scripts/_lib/gate-fork-server.py" "$1" "$2" <<'PY'
import sys
src, out, which = sys.argv[1:4]
s = open(src).read()
k = "import io, json, os, select, signal, sys, time, traceback\n"
assert s.count(k) == 1, "server imports moved"
patch = ("_real_setpgid = os.setpgid\n"
         "def _eperm(pid, pg):\n"
         "    if %r == 'all' or pid == 0:\n"
         "        raise PermissionError(1, 'Operation not permitted')\n"
         "    return _real_setpgid(pid, pg)\n"
         "os.setpgid = _eperm\n") % which
open(out, "w").write(s.replace(k, k + patch))
PY
}
eperm_server "$T/eperm-child.py" child
eperm_server "$T/eperm-all.py" all
out=$(SERVER="$T/eperm-child.py" fake "$T/s-allow" "$T/s-deny" "$T/two.txt" auto); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=1 ' <<<"$out" \
   && /usr/bin/grep -q '^  runner: fork (fork-only diffs dropped: 1, near-deadline re-runs: 0)$' <<<"$out"; then
  ok "EPERM in the child with the group already set: fork mode as usual"
else bad "child EPERM (rc=$rc): $out"; fi
out=$(SERVER="$T/eperm-all.py" fake "$T/s-allow" "$T/s-deny" "$T/two.txt" auto); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=1 ' <<<"$out" \
   && /usr/bin/grep -q '^  runner: fork (fork-only diffs dropped: 0, near-deadline re-runs: 0, no-own-group re-runs: 2)$' <<<"$out"; then
  ok "no own process group (auto): that command through bash, fork mode kept and counted"
else bad "no own group, auto (rc=$rc): $out"; fi
# PR #899 round 4: --runner fork promises fork mode only, so a command fork cannot run stops the run.
out=$(SERVER="$T/eperm-all.py" fake "$T/s-allow" "$T/s-deny" "$T/two.txt" fork); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q -- '--runner fork: fork mode cannot run (.*own process group' <<<"$out"; then
  ok "no own process group (--runner fork): exits 2 instead of falling back"
else bad "no own group, --runner fork (rc=$rc): $out"; fi

echo "=== killpg EPERM on a timeout crashes neither runner (PR #899 round 3, macOS) ==="
# macOS raises EPERM from killpg when the group's only member is an unreaped zombie. Both runners must
# then kill the process itself and go on. A 1 s hook timeout and a 3 s gate keep the row short.
python3 - "$ROOT/scripts/_lib/gate-fork-server.py" "$T/killpg-eperm.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
k = "import io, json, os, select, signal, sys, time, traceback\n"
assert s.count(k) == 1, "server imports moved"
patch = ("def _eperm(*a):\n    raise PermissionError(1, 'Operation not permitted')\nos.killpg = _eperm\n")
open(sys.argv[2], "w").write(s.replace(k, k + patch))
PY
stub "$T/s-3s" 'time.sleep(3)'
out=$(GD_TIMEOUT=1 KILLPG_EPERM=1 SERVER="$T/killpg-eperm.py" fake "$T/s-3s" "$T/s-3s" "$T/rm.txt" fork); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out" && /usr/bin/grep -q '^  runner: fork (' <<<"$out" \
   && ! /usr/bin/grep -q 'Traceback' <<<"$out"; then
  ok "fork runner: killpg EPERM on a timeout, the child is killed and fork mode goes on"
else bad "fork killpg EPERM (rc=$rc): $out"; fi
out=$(GD_TIMEOUT=1 KILLPG_EPERM=1 fake "$T/s-3s" "$T/s-3s" "$T/rm.txt" bash); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out" && ! /usr/bin/grep -q 'Traceback' <<<"$out"; then
  ok "bash runner: killpg EPERM on a timeout, bash is killed and the run goes on"
else bad "bash killpg EPERM (rc=$rc): $out"; fi
# PR #899 round 4: a grandchild in its own session survives the group kill and holds stdout open, so
# the read after the kill must be bounded too. The 15 s sleeper is killed by its unique argument.
held="15.0$$"
stub "$T/s-held" "import subprocess; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep($held)'], start_new_session=True); time.sleep(3)"
t0=$SECONDS
out=$(GD_TIMEOUT=1 fake "$T/s-held" "$T/s-held" "$T/rm.txt" bash); rc=$?
took=$((SECONDS - t0))
pkill -f "time.sleep($held)"
if [ "$rc" -eq 0 ] && [ "$took" -lt 10 ] && /usr/bin/grep -q 'diffs=0 ' <<<"$out"; then
  ok "bash runner: a timeout does not wait on a grandchild that holds stdout (${took}s)"
else bad "held stdout (rc=$rc, ${took}s): $out"; fi

echo "=== a wrapper change falls back to the bash runner (GH #889) ==="
cp -R "$GATES" "$T/wrapped"
printf '# a changed wrapper\n' >> "$T/wrapped/irrecoverable.sh"
out=$(bash "$SCRIPT" --cases "$T/rm.txt" "$T/old" "$T/wrapped" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q '^  runner: bash (wrapper files differ: irrecoverable.sh)' <<<"$out"; then
  ok "a differing wrapper runs the whole replay through bash"
else bad "wrapper fallback (rc=$rc): $out"; fi

echo "=== --runner fork refuses to fall back (GH #889) ==="
out=$(bash "$SCRIPT" --runner fork --cases "$T/rm.txt" "$T/old" "$T/wrapped" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'fork mode cannot run' <<<"$out"; then
  ok "--runner fork with a changed wrapper exits 2"
else bad "--runner fork fallback (rc=$rc): $out"; fi

echo "=== slower: a stub that sleeps on the new side only (GH #890) ==="
stub "$T/s-slow" 'time.sleep(0.25)'
out=$(bash "$SCRIPT" --cases "$T/rm.txt" "$T/s-allow" "$T/s-slow" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=0 slower=1 ' <<<"$out" && /usr/bin/grep -q '^  slower: 1' <<<"$out"; then
  ok "3x slower and over 200 ms on the new side lands in slower"
else bad "slower on the new side (rc=$rc): $out"; fi
cp -R "$T/s-slow" "$T/s-slow2"
out=$(bash "$SCRIPT" --cases "$T/rm.txt" "$T/s-slow" "$T/s-slow2" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 slower=0 ' <<<"$out"; then
  ok "equal sleeps on both sides are not slower"
else bad "equal sleeps (rc=$rc): $out"; fi

echo "=== near-deadline commands go through bash too (GH #889, #890) ==="
# Over half of irrecoverable's 4 s deadline in fork mode: re-run through bash, and slower on the
# deadline criterion.
stub "$T/s-late" 'time.sleep(2.1)'
out=$(bash "$SCRIPT" --cases "$T/rm.txt" "$T/s-allow" "$T/s-late" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=0 slower=1 ' <<<"$out" \
   && /usr/bin/grep -q '^  runner: fork (fork-only diffs dropped: 0, near-deadline re-runs: 1)' <<<"$out"; then
  ok "a near-deadline command is re-run through bash and counted slower"
else bad "near-deadline (rc=$rc): $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "PASS: test-gate-differential"
exit "$fail"
