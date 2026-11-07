#!/usr/bin/env bash
# scripts/gate-differential.sh (GH #411): old-vs-new gate replay that prints diff classes only.
# Checks: identical copies give 0 diffs; a planted one-rule change gives exactly its class and
# never prints the secret-shaped command it replayed; a --slug outside this project is refused;
# --replay reads only this project's transcript dirs; the real gate journal is never written;
# the caller's env and cwd never reach the gates (GH #888); fork mode matches bash mode and drops
# fork-only diffs (GH #889); a slower new side lands in `slower` (GH #890); the opt-in cache of the old
# side keys on the gate's closure, never stores load artifacts and never writes a replay record (GH #893).
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

echo "=== GH #891: a gate's closure hash ==="
CLOSURE="$ROOT/scripts/_lib/gate_closure.py"
# The spec: the gate's own .sh and .py, _run.py, and every shared _* or *.awk file in hooks/gates that the
# gate uses (its name, without the extension, is a word in the gate's text or in a shared file it uses),
# each as "<name>\0<sha256 of its bytes>\n", sorted by name. The sets below are today's, read by hand:
# a gate that starts or stops using a shared file must change this table too.
want_files() {
  case "$1" in
    irrecoverable) echo "_bracex.py _journal.py _run.py brace-route.awk irrecoverable.py irrecoverable.sh" ;;
    subagent-git-guard) echo "_bracex.py _journal.py _quotemask.py _run.py subagent-git-guard.py subagent-git-guard.sh" ;;
    secret-scan) echo "_journal.py _run.py _silent_fastpath.sh secret-scan.py secret-scan.sh" ;;
  esac
}
spec_closure() { # <dir> <file...>
  python3 - "$@" <<'PY2'
import hashlib, os, sys
d, names = sys.argv[1], sorted(sys.argv[2:])
h = hashlib.sha256()
for n in names:
    h.update(n.encode() + b"\0" + hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest().encode() + b"\n")
print(h.hexdigest())
PY2
}
for g in irrecoverable subagent-git-guard secret-scan; do
  files=$(python3 "$CLOSURE" --files --dir "$T/same" "$g" | tr '\n' ' ' | sed 's/ $//')
  if [ "$files" = "$(want_files "$g")" ]; then ok "closure of $g covers exactly the files it uses"; else bad "closure files of $g: '$files' want '$(want_files "$g")'"; fi
  got=$(python3 "$CLOSURE" --dir "$T/same" "$g")
  # shellcheck disable=SC2046 # one file name per word
  want=$(spec_closure "$T/same" $(want_files "$g"))
  if [ -n "$got" ] && [ "$got" = "$want" ]; then ok "closure --dir of $g matches the spec hash"; else bad "closure --dir $g: got '$got' want '$want'"; fi
done
# The same tree read from git gives the same hash; another gate's edit leaves it alone; a shared module's
# edit, an .awk edit and the gate's own edit change it.
R="$T/closure-repo"; mkdir -p "$R/hooks"; cp -R "$GATES" "$R/hooks/gates"
git -C "$R" init -q && git -C "$R" add hooks && git -C "$R" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com commit -qm base
c0=$(cd "$R" && python3 "$CLOSURE" --rev HEAD subagent-git-guard)
if [ "$c0" = "$(python3 "$CLOSURE" --dir "$R/hooks/gates" subagent-git-guard)" ]; then ok "closure --rev equals --dir on the same tree"; else bad "closure --rev $c0 differs from --dir"; fi
closure_after() { # <file> <label>: append a line to hooks/gates/<file>, commit, print sgg's closure at HEAD
  printf '# edit\n' >>"$R/hooks/gates/$1"
  git -C "$R" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com commit -qam "$1" && (cd "$R" && python3 "$CLOSURE" --rev HEAD subagent-git-guard)
}
c1=$(closure_after irrecoverable.py)
if [ "$c1" = "$c0" ]; then ok "an edit to another gate keeps subagent-git-guard's closure"; else bad "another gate's edit changed the closure"; fi
c2=$(closure_after _journal.py)
if [ "$c2" != "$c1" ]; then ok "an edit to a shared _* module changes the closure"; else bad "a _journal.py edit kept the closure"; fi
irr_awk=$(cd "$R" && python3 "$CLOSURE" --rev HEAD irrecoverable)
c3=$(closure_after brace-route.awk)
if [ "$c3" = "$c2" ] && [ "$(cd "$R" && python3 "$CLOSURE" --rev HEAD irrecoverable)" != "$irr_awk" ]; then
  ok "an edit to brace-route.awk changes irrecoverable's closure (it uses it), not subagent-git-guard's"
else bad "a brace-route.awk edit: sgg $c2 -> $c3, irrecoverable did not move"; fi
irr_before=$(cd "$R" && python3 "$CLOSURE" --rev HEAD irrecoverable); ss_before=$(cd "$R" && python3 "$CLOSURE" --rev HEAD secret-scan)
c3b=$(closure_after _quotemask.py)
if [ "$c3b" != "$c3" ] && [ "$(cd "$R" && python3 "$CLOSURE" --rev HEAD irrecoverable)" = "$irr_before" ] \
  && [ "$(cd "$R" && python3 "$CLOSURE" --rev HEAD secret-scan)" = "$ss_before" ]; then
  ok "an edit to _quotemask.py changes only the closure of the gate that uses it"
else bad "a _quotemask.py edit: sgg $c3 -> $c3b, irrecoverable or secret-scan moved too"; fi
c3=$c3b
c4=$(closure_after subagent-git-guard.py)
if [ "$c4" != "$c3" ]; then ok "an edit to the gate itself changes the closure"; else bad "the gate's own edit kept the closure"; fi
# A shared file that only _run.py names is a member too (_run.py runs every gate through bash's path).
cp -R "$GATES" "$T/runscan"; printf 'X = 1\n' >"$T/runscan/_runonly.py"; printf '# loads _runonly\n' >>"$T/runscan/_run.py"
if /usr/bin/grep -qx _runonly.py <<<"$(python3 "$CLOSURE" --files --dir "$T/runscan" secret-scan)"; then
  ok "a shared file named only in _run.py joins every gate's closure"
else bad "_run.py's names are not scanned: $(python3 "$CLOSURE" --files --dir "$T/runscan" secret-scan | tr '\n' ' ')"; fi
out=$(python3 "$CLOSURE" --dir "$T/same" no-such-gate 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "closure of an unknown gate is a usage error"; else bad "unknown gate rc=$rc: $out"; fi

echo "=== GH #891: only a full-pool replay writes a record ==="
# This project's pool is the 2 commands above. Each run gets its own record dir.
records() { python3 -c 'import os, sys; d = sys.argv[1]; print(len(os.listdir(d)) if os.path.isdir(d) else 0)' "$1"; }
closure=$(python3 "$CLOSURE" --dir "$T/same" irrecoverable)
out=$(GATE_REPLAY_RECORD_DIR="$T/rec-all" bash "$SCRIPT" --cases "$T/empty.txt" --replay all "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
f="$T/rec-all/irrecoverable-$closure.json"
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'replay=2 ' <<<"$out" && [ -f "$f" ] && /usr/bin/grep -q 'replay record: written' <<<"$out"; then
  ok "--replay all replays the whole pool and writes the record named for the new side's closure"
else bad "--replay all (rc=$rc, record $(records "$T/rec-all")): $out"; fi
if python3 - "$f" "$closure" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
want = {"gate": "irrecoverable", "closure": sys.argv[2], "full": True, "pool": 2, "replay": 2, "diffs": 0, "slower": 0, "cache": False}
sys.exit(0 if all(r.get(k) == v for k, v in want.items()) and isinstance(r.get("time"), str) and isinstance(r.get("corpus"), int) else 1)
PY
then ok "the record holds the gate, closure, counts and time"; else bad "record fields: $(cat "$f" 2>&1)"; fi
if [ -f "$f" ] && ! /usr/bin/grep -q -e 'rm -rf' -e 'ls -la' "$f"; then ok "the record holds no command text"; else bad "the record leaked a command: $(cat "$f")"; fi
out=$(GATE_REPLAY_RECORD_DIR="$T/rec-some" bash "$SCRIPT" --cases "$T/empty.txt" --replay 1 "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$(records "$T/rec-some")" = 0 ] && /usr/bin/grep -q 'replay record: none' <<<"$out"; then
  ok "a sampled replay (1 of 2) writes no record and says so"
else bad "sampled replay (rc=$rc, records $(records "$T/rec-some")): $out"; fi
out=$(GATE_REPLAY_RECORD_DIR="$T/rec-slug" bash "$SCRIPT" --cases "$T/empty.txt" --replay all --slug "$slug" "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$(records "$T/rec-slug")" = 0 ]; then ok "a --slug replay writes no record (one dir is not the pool)"; else bad "--slug replay wrote a record: $out"; fi
out=$(bash "$SCRIPT" --replay many "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "--replay takes a number or all"; else bad "--replay many rc=$rc: $out"; fi

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
pkill -f "time[.]sleep[(]$held"  # pkill -f takes a regex: bracket the literal . and (
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

echo "=== GH #893: the develop-side cache ==="
# Opt-in (--cache), old side only. A cached run never writes a replay record, and --no-cache beats --cache.
cache_line() { /usr/bin/grep '^  cache:' <<<"$1"; }
hits() { cache_line "$1" | sed -n 's/^  cache: \([0-9]*\) hits.*/\1/p'; }
stored() { cache_line "$1" | sed -n 's/^  cache: [0-9]* hits, \([0-9]*\) stored.*/\1/p'; }
printf 'plain text, no token\nkey=%s\nnote MARKER893 text\n' "$tok" > "$T/cases3.txt"
strip_run() { /usr/bin/grep -v -e '^  runner:' -e '^  cache:' <<<"$1"; }

out=$(GATE_REPLAY_CACHE_DIR="$T/c-off" bash "$SCRIPT" --cases "$T/cases3.txt" "$T/old" "$T/planted" secret-scan 2>&1)
if [ ! -e "$T/c-off" ] && [ -z "$(cache_line "$out")" ]; then ok "no flag: no cache dir, no cache line (opt-in)"; else bad "cache without --cache: $out"; fi

C1="$T/c1"
r1=$(GATE_REPLAY_CACHE_DIR="$C1" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/planted" secret-scan 2>&1); rc1=$?
r2=$(GATE_REPLAY_CACHE_DIR="$C1" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/planted" secret-scan 2>&1); rc2=$?
s1=$(stored "$r1"); h2=$(hits "$r2")
if [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$(hits "$r1")" = 0 ] && [ -n "$s1" ] && [ "$s1" -gt 0 ] && [ "$h2" = "$s1" ] && [ "$(stored "$r2")" = 0 ]; then
  ok "--cache: run 1 stores $s1 old-side results, run 2 hits all $h2 and stores none"
else bad "cache hit/miss (rc $rc1/$rc2): --- 1: $r1 --- 2: $r2"; fi
if [ "$(strip_run "$r1")" = "$(strip_run "$r2")" ]; then ok "a cached run prints the same diffs, counts and samples as the uncached one"
else bad "cached output differs: --- 1: $r1 --- 2: $r2"; fi
if ! /usr/bin/grep -r -q -e MARKER893 -e "$tok" "$C1"; then ok "the cache holds no command text"; else bad "command text in the cache: $(/usr/bin/grep -r -l MARKER893 "$C1")"; fi
if python3 - "$C1" <<'PY'
import glob, json, sys
rows = [json.loads(l) for f in glob.glob(sys.argv[1] + "/*.jsonl") for l in open(f)]
sys.exit(0 if rows and all(set(r) == {"k", "code", "out", "err", "rows", "sig"} and len(r["k"]) == 64 and len(r["out"]) == 64 and len(r["err"]) == 64 for r in rows) else 1)
PY
then ok "a cache row is the command's sha256, the exit code and digests"; else bad "cache row shape: $(cat "$C1"/*.jsonl | head -3)"; fi
# A forged row must show up as a diff: proof the old side came from the cache, not from a re-run.
python3 - "$C1" <<'PY'
import glob, sys
for f in glob.glob(sys.argv[1] + "/*.jsonl"):
    s = open(f).read()
    open(f, "w").write(s.replace('"code": "0"', '"code": "9"'))
PY
r3=$(GATE_REPLAY_CACHE_DIR="$C1" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1)
if /usr/bin/grep -q 'exit 9->0' <<<"$r3" && [ "$(stored "$r3")" = 0 ]; then ok "the old side is read from the cache (a forged exit code shows as a diff)"
else bad "forged cache row not used: $r3"; fi
# GH #893: a damaged cache is a miss or a clean exit 2, never a traceback.
printf '\377\376 not utf-8\n' >> "$(ls "$C1"/*.jsonl | head -1)"
r4=$(GATE_REPLAY_CACHE_DIR="$C1" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1)
if ! /usr/bin/grep -q Traceback <<<"$r4" && /usr/bin/grep -q 'unreadable rows ignored' <<<"$r4"; then ok "a non-UTF-8 cache row is counted and ignored"
else bad "non-UTF-8 cache row: $r4"; fi
chmod 000 "$(ls "$C1"/*.jsonl | head -1)"
r5=$(GATE_REPLAY_CACHE_DIR="$C1" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1); rc5=$?
chmod 600 "$C1"/*.jsonl
if ! /usr/bin/grep -q Traceback <<<"$r5" && [ "$rc5" = 2 ]; then ok "an unreadable cache file exits 2 with a message, no traceback"
else bad "unreadable cache file: rc=$rc5 $r5"; fi
# GH #893: a torn last line (killed run) must not swallow the next stored row.
C6="$T/c6"
setup=$(GATE_REPLAY_CACHE_DIR="$C6" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1) || bad "torn-line set-up run: $setup"
printf '{"k": "torn' >> "$(ls "$C6"/*.jsonl | head -1)"
printf 'one more MARKERTORN case\n' > "$T/cases6.txt"; cat "$T/cases3.txt" >> "$T/cases6.txt"
setup=$(GATE_REPLAY_CACHE_DIR="$C6" bash "$SCRIPT" --cache --cases "$T/cases6.txt" "$T/old" "$T/same" secret-scan 2>&1) || bad "torn-line second run: $setup"
r6=$(GATE_REPLAY_CACHE_DIR="$C6" bash "$SCRIPT" --cache --cases "$T/cases6.txt" "$T/old" "$T/same" secret-scan 2>&1)
if [ "$(stored "$r6")" = 0 ] && [ "$(hits "$r6")" = 4 ]; then ok "a row stored after a torn line is not lost"
else bad "torn line swallowed a row: $r6"; fi
# A cache file that is a symlink is refused, not followed.
C7="$T/c7"; mkdir -m 700 "$C7"; setup=$(GATE_REPLAY_CACHE_DIR="$C6" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1) || bad "symlink set-up run: $setup"
cp -P "$C6"/*.jsonl "$T/elsewhere.jsonl"; f6=$(basename "$(ls "$C6"/*.jsonl | head -1)"); ln -s "$T/elsewhere.jsonl" "$C7/$f6"
r7=$(GATE_REPLAY_CACHE_DIR="$C7" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1); rc7=$?
if [ "$rc7" = 2 ] && ! /usr/bin/grep -q Traceback <<<"$r7"; then ok "a symlinked cache file is refused (exit 2)"
else bad "symlinked cache file: rc=$rc7 $r7"; fi
if [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$C1")" = 0o700 ]; then ok "a new cache dir is private (0700)"
else bad "cache dir mode"; fi

# Key parts: the closure (every _* and *.awk file, used or not), the runner mode, and --no-cache.
cp -R "$T/old" "$T/old-extra"; printf 'X = 1\n' > "$T/old-extra/_unused_sibling.py"
r=$(GATE_REPLAY_CACHE_DIR="$T/c2" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1) || bad "key set-up run: $r"
r=$(GATE_REPLAY_CACHE_DIR="$T/c2" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old-extra" "$T/same" secret-scan 2>&1)
if [ "$(hits "$r")" = 0 ] && [ "$(stored "$r")" -gt 0 ]; then ok "an unused _* sibling in the old dir changes the key (closure = every _* file)"
else bad "sibling _* file did not change the key: $r"; fi
cp -R "$T/old" "$T/old-awk"; printf '# edit\n' >> "$T/old-awk/brace-route.awk"
r=$(GATE_REPLAY_CACHE_DIR="$T/c2" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old-awk" "$T/same" secret-scan 2>&1)
if [ "$(hits "$r")" = 0 ]; then ok "an edit to an *.awk file the gate does not name changes the key"; else bad "awk edit kept the key: $r"; fi
mkdir -p "$T/old-pyc/__pycache__"; cp -R "$T/old/." "$T/old-pyc/"; printf 'junk' > "$T/old-pyc/__pycache__/_x.cpython-39.pyc"
r=$(GATE_REPLAY_CACHE_DIR="$T/c2" bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old-pyc" "$T/same" secret-scan 2>&1)
if [ "$(hits "$r")" -gt 0 ] && [ "$(stored "$r")" = 0 ]; then ok "__pycache__ is ignored by the key"; else bad "__pycache__ changed the key: $r"; fi
# secret-scan's wrapper never runs through _run.py, so it is always bash; irrecoverable has both modes.
r=$(GATE_REPLAY_CACHE_DIR="$T/c3" bash "$SCRIPT" --cache --runner fork --cases "$T/rm.txt" "$T/old" "$T/same" irrecoverable 2>&1) || bad "fork set-up run: $r"
r=$(GATE_REPLAY_CACHE_DIR="$T/c3" bash "$SCRIPT" --cache --runner bash --cases "$T/rm.txt" "$T/old" "$T/same" irrecoverable 2>&1)
if [ "$(hits "$r")" = 0 ] && [ "$(stored "$r")" -gt 0 ]; then ok "the runner mode is part of the key (fork rows are not read by a bash run)"
else bad "runner mode not in the key: $r"; fi
# The hint merge-pr.sh and sync-pr-head.sh print for the record run must carry --no-cache (operator rule 2026-11-04).
hint=$(bash -c '. "$1/scripts/_lib/replay-check.sh" && replay_hint origin/develop irrecoverable' _ "$ROOT")
if [ "$hint" = "bash scripts/gate-differential.sh origin/develop irrecoverable --replay all --no-cache" ]; then ok "the replay hint runs with --no-cache"
else bad "replay hint: $hint"; fi
r=$(GATE_REPLAY_CACHE_DIR="$T/c2" bash "$SCRIPT" --cache --no-cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1)
if [ -z "$(cache_line "$r")" ] && /usr/bin/grep -q 'diffs=0 ' <<<"$r"; then ok "--no-cache beats --cache: no cache line, a full run"; else bad "--cache --no-cache: $r"; fi
mkdir -p "$T/h2"
out=$(HOME="$T/h2" env -u GATE_REPLAY_CACHE_DIR bash "$SCRIPT" --cache --cases "$T/cases3.txt" "$T/old" "$T/same" secret-scan 2>&1)
if compgen -G "$T/h2/.cache/mh/gate-replay-cache/*.jsonl" >/dev/null; then ok "the default cache dir is ~/.cache/mh/gate-replay-cache"; else bad "default cache dir: $out"; fi

python3 - "$ROOT/scripts/_lib/gate-differential.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gd", sys.argv[1])
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)
base = ("irrecoverable", "c" * 64, "t" * 64, "fork", {"python3": "3.9", "bash": "5", "awk": "a", "sed": "s"})
b = gd.bucket_id(*base)
assert b == gd.bucket_id(*base), "bucket_id is not deterministic"
variants = [("gate", ("subagent-git-guard",) + base[1:]), ("closure", base[:1] + ("d" * 64,) + base[2:]),
            ("tool hash", base[:2] + ("u" * 64,) + base[3:]), ("mode", base[:3] + ("bash",) + base[4:])]
for k in base[4]:
    variants.append(("version of " + k, base[:4] + (dict(base[4], **{k: "other"}),)))
for name, args in variants:
    assert gd.bucket_id(*args) != b, "the key ignores the " + name
PY
if [ $? -eq 0 ]; then ok "the key covers the gate, closure, tool hash, runner mode and the python3/bash/awk/sed versions"; else bad "bucket_id key parts"; fi

echo "=== GH #893: never read the cache before merge, never write a record from it ==="
CR="$T/c-rec"; RR="$T/r-rec"
out=$(GATE_REPLAY_CACHE_DIR="$CR" GATE_REPLAY_RECORD_DIR="$RR" bash "$SCRIPT" --cache --cases "$T/empty.txt" --replay all "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(records "$RR")" = 0 ] && /usr/bin/grep -q 'replay record: none (a cached run' <<<"$out"; then ok "--cache --replay all writes no record and says why"
else bad "a cached full replay wrote a record (rc=$rc, records $(records "$RR")): $out"; fi
out=$(GATE_REPLAY_CACHE_DIR="$CR" GATE_REPLAY_RECORD_DIR="$RR" bash "$SCRIPT" --cache --cases "$T/empty.txt" --replay all "$T/old" "$T/same" irrecoverable 2>&1)
if [ "$(hits "$out")" -gt 0 ] && [ "$(records "$RR")" = 0 ]; then ok "a second cached full replay, all hits, still writes no record"; else bad "cached rerun: $out"; fi
out=$(GATE_REPLAY_CACHE_DIR="$CR" GATE_REPLAY_RECORD_DIR="$RR" bash "$SCRIPT" --cache --no-cache --cases "$T/empty.txt" --replay all "$T/old" "$T/same" irrecoverable 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(records "$RR")" = 1 ] && [ -z "$(cache_line "$out")" ]; then ok "--no-cache --replay all runs uncached and writes the record"
else bad "--no-cache full replay (rc=$rc, records $(records "$RR")): $out"; fi
if python3 -c 'import glob, json, sys; sys.exit(0 if all(json.load(open(f))["cache"] is False for f in glob.glob(sys.argv[1] + "/*.json")) else 1)' "$RR"; then
  ok "that record says cache: false"; else bad "record cache field: $(cat "$RR"/*.json)"; fi
RR2="$T/r-rec2"
out=$(GATE_REPLAY_CACHE_DIR="$T/c-none" GATE_REPLAY_RECORD_DIR="$RR2" bash "$SCRIPT" --cases "$T/empty.txt" --replay all "$T/old" "$T/same" irrecoverable 2>&1)
if [ "$(records "$RR2")" = 1 ] && [ ! -e "$T/c-none" ]; then ok "a plain --replay all (no flag) is uncached and writes the record"; else bad "plain full replay: $out"; fi

echo "=== GH #893: results the cache never stores ==="
python3 - "$ROOT/scripts/_lib/gate-differential.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gd", sys.argv[1])
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)
# A cached old-side row must not depend on the caller's shell or interpreter setup (GH #893, #888).
for k, v in (("BASH_ENV", "/x"), ("ENV", "/x"), ("PYTHONPATH", "/x"), ("PYTHONHOME", "/x"), ("PYTHONSTARTUP", "/x"), ("LANG", "th_TH.UTF-8"), ("LC_ALL", "th_TH.UTF-8"), ("LC_CTYPE", "th_TH.UTF-8")):
    os.environ[k] = v
env = gd.canonical_env("/h")
leaked = [k for k in ("BASH_ENV", "ENV", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "LANG", "LC_CTYPE") if k in env]
assert not leaked, "caller variables reach the gates: %s" % leaked
assert env.get("LC_ALL") == "C", "the locale must be fixed: %r" % env.get("LC_ALL")
assert env["HOME"] == "/h"
PY
if [ $? -eq 0 ]; then ok "canonical env drops BASH_ENV, PYTHON* and the caller's locale"; else bad "canonical env leaks caller setup"; fi
python3 - "$ROOT/scripts/_lib/gate-differential.py" "$T" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("gd", sys.argv[1])
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)
tmp = sys.argv[2]  # inside the test's own temp dir, which the cleanup trap deletes
def res(code="0", out=b"", err=b"", rows=()):
    p = os.path.join(tmp, "j.jsonl")
    with open(p, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    return gd.finish("/g", code, out, err, p, 0.1)
assert not res().skip, "a plain allow is storable"
assert not res("2", err=b"[mh:gate] BLOCKED: x", rows=[{"decision": "deny", "rule": "r1"}]).skip, "a plain deny is storable"
assert res("timeout").skip, "a timeout must not be stored"
assert res(rows=[{"decision": "ask", "rule": "deadline"}]).skip, "an irrecoverable deadline ask must not be stored"
assert res(out=b'{"permissionDecision": "ask", "permissionDecisionReason": "[mh:gate] x: the gate\'s 4s time budget ran out before every command was checked; confirm the batch"}',
           rows=[{"decision": "ask"}]).skip, "a batch-budget ask must not be stored"
assert res("2", err=b"[mh:gate] BLOCKED: subagent (g) command took longer than the gate's 5 s time limit to check (9 characters); write it", rows=[{"decision": "deny"}]).skip, "sgg's time-limit deny (no rule) must not be stored"
assert res("2", err=b"[mh:gate] BLOCKED: subagent (g) context-mode batch: not every command could be checked in the gate's 5 s time limit; split", rows=[{"decision": "deny"}]).skip
assert res("137").skip and res("-9").skip, "a gate killed by a signal must not be stored"
r = res("0", out=b"hello-cmd-text", err=b"err-cmd-text", rows=[{"decision": "allow", "cmd": "row-cmd-text"}])
assert "cmd-text" not in repr(r), "a Result keeps digests, not text: " + repr(r)
PY
if [ $? -eq 0 ]; then ok "finish() flags timeouts, deadline asks, batch-budget asks and sgg time-limit denies; keeps digests only"; else bad "unstorable results"; fi
stub "$T/s-tl" 'sys.stderr.write("[mh:gate] BLOCKED: subagent (x) command took longer than the gate'"'"'s 5 s time limit to check\n"); sys.exit(2)'
stub "$T/s-dn" 'sys.stderr.write("[mh:gate] BLOCKED: plain\n"); sys.exit(2)'
out=$(GATE_REPLAY_CACHE_DIR="$T/c-tl" bash "$SCRIPT" --cache --cases "$T/rm.txt" "$T/s-tl" "$T/s-tl" irrecoverable 2>&1)
out2=$(GATE_REPLAY_CACHE_DIR="$T/c-tl" bash "$SCRIPT" --cache --cases "$T/rm.txt" "$T/s-tl" "$T/s-tl" irrecoverable 2>&1)
if [ "$(stored "$out2")" = 0 ] && [ "$(hits "$out2")" = 0 ] && /usr/bin/grep -q ' 1 not storable' <<<"$out2"; then ok "an old side that denies on a time limit is never cached"; else bad "time-limit deny cached: $out2"; fi
out=$(GATE_REPLAY_CACHE_DIR="$T/c-dn" bash "$SCRIPT" --cache --cases "$T/rm.txt" "$T/s-dn" "$T/s-dn" irrecoverable 2>&1)
out2=$(GATE_REPLAY_CACHE_DIR="$T/c-dn" bash "$SCRIPT" --cache --cases "$T/rm.txt" "$T/s-dn" "$T/s-dn" irrecoverable 2>&1)
if [ "$(hits "$out2")" -gt 0 ] && [ "$(stored "$out2")" = 0 ]; then ok "an ordinary deny is cached and hit"; else bad "ordinary deny not cached: $out2"; fi

echo "=== GH #893: a cached old side does not hide a slower new side ==="
# A hit has no old time, so every command at 200 ms or more is re-run on both sides, uncached.
for n in 1 2; do
  out=$(GATE_REPLAY_CACHE_DIR="$T/c-slow" bash "$SCRIPT" --cache --cases "$T/rm.txt" "$T/s-allow" "$T/s-slow" irrecoverable 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && /usr/bin/grep -q 'diffs=0 slower=1 ' <<<"$out"; then ok "run $n of a cached slow new side: slower=1"; else bad "cached slower run $n (rc=$rc): $out"; fi
done
for n in 1 2; do
  out=$(GATE_REPLAY_CACHE_DIR="$T/c-slow2" bash "$SCRIPT" --cache --cases "$T/rm.txt" "$T/s-slow" "$T/s-slow2" irrecoverable 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'diffs=0 slower=0 ' <<<"$out"; then ok "run $n of equal sleeps with a cached old side: not slower"; else bad "cached equal sleeps run $n (rc=$rc): $out"; fi
done

echo "=== GH #893: a gate's imports stay inside the closure pattern ==="
# The cache key hashes the gate's .sh and .py, every _* file and every *.awk file. A gate that imports or
# runs another sibling would change behaviour without changing the key. Imports are read from the AST
# (import, from-import, __import__ with a literal); the wrapper is scanned for sibling file names outside
# comment lines.
outside() { # <gates dir>: print "<gate file>: <sibling>" for each reach outside the pattern
  python3 - "$1" <<'PY'
import ast, os, re, sys
d = sys.argv[1]
files = sorted(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n)))
gates = {n[:-3] for n in files if n.endswith(".sh") and not n.startswith("_")}
def inside(n, gate):
    return n.startswith("_") or n.endswith(".awk") or n in (gate + ".sh", gate + ".py")
bad = []
for g in sorted(gates):
    for n in (g + ".sh", g + ".py"):
        if n not in files:
            continue
        text = open(os.path.join(d, n)).read()
        others = [f for f in files if not inside(f, g)]
        if n.endswith(".py"):
            mods = set()
            for node in ast.walk(ast.parse(text)):
                if isinstance(node, ast.Import):
                    mods |= {a.name.split(".")[0] for a in node.names}
                elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
                    mods.add(node.module.split(".")[0])
                elif isinstance(node, ast.Call) and getattr(node.func, "id", "") == "__import__" and node.args \
                        and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                    mods.add(node.args[0].value.split(".")[0])
            for f in others:
                if f.endswith(".py") and f[:-3] in mods:
                    bad.append("%s: %s" % (n, f))
        else:
            code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
            for f in others:
                if re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(f) + r"(?![A-Za-z0-9_-])", code):
                    bad.append("%s: %s" % (n, f))
print("\n".join(bad))
PY
}
res=$(outside "$GATES")
if [ -z "$res" ]; then ok "no gate in hooks/gates reaches a sibling outside the closure pattern"; else bad "a gate reaches outside the closure pattern: $res"; fi
cp -R "$GATES" "$T/reach"; printf 'X = 1\n' > "$T/reach/helper.py"; printf 'import helper\n' >> "$T/reach/secret-scan.py"
res=$(outside "$T/reach")
if [ "$res" = "secret-scan.py: helper.py" ]; then ok "the check names a planted non-_ sibling import"; else bad "planted import not caught: '$res'"; fi
cp -R "$GATES" "$T/reach2"; printf 'X = 1\n' > "$T/reach2/helper.sh"; printf 'bash "$(dirname "$0")/helper.sh"\n' >> "$T/reach2/secret-scan.sh"
res=$(outside "$T/reach2")
if [ "$res" = "secret-scan.sh: helper.sh" ]; then ok "the check names a planted non-_ sibling run by a wrapper"; else bad "planted wrapper reach not caught: '$res'"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "PASS: test-gate-differential"
exit "$fail"
