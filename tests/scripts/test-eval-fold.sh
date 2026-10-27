#!/usr/bin/env bash
# test-eval-fold.sh — scripts/eval-fold.sh + scripts/_lib/eval-fold.py without model calls:
# the folded/kept plugin builder for two agents that still have eval cases, the compare table on
# hand-made aggregate-result.json fixtures, and the --runs floor.
set -uo pipefail
# The fixture-repo check below runs `git init`; a hook-exported GIT_DIR would retarget it at the real repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$ROOT/scripts/_lib/eval-fold.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
TMP="$(mktemp -d)" || exit 1
[ -n "$TMP" ] || { echo "test-eval-fold: mktemp gave an empty path" >&2; exit 1; }
trap 'trash "$TMP"' EXIT

echo "=== eval-fold self-test ==="

guarded() { (cd "$ROOT" && shasum .claude-plugin/plugin.json agents/*.md && find skills -type f -exec shasum {} +) | sort; }
guarded >"$TMP/before"

for a in blind-spot-hunter plan-reviewer; do
  out="$TMP/$a"
  if ! python3 "$LIB" build "$ROOT" "$a" "$out" >"$TMP/$a.allow" 2>"$TMP/$a.err"; then
    bad "$a: build failed: $(cat "$TMP/$a.err")"; continue
  fi
  [ -f "$out/kept/agents/$a.md" ] && [ ! -e "$out/folded/agents/$a.md" ] \
    && ok "$a: agent kept in kept, removed in folded" || bad "$a: agent file presence wrong"
  /usr/bin/grep -qx "name: $a" <<<"$(head -3 "$out/folded/skills/fold/$a/SKILL.md")" \
    && ok "$a: folded SKILL.md carries the agent's name" || bad "$a: folded SKILL.md missing or misnamed"
  python3 - "$out" <<'PY' && ok "$a: manifests enable the plugin, only folded lists ./skills/fold/" || bad "$a: manifest wrong"
import json, sys
k = json.load(open(sys.argv[1] + "/kept/.claude-plugin/plugin.json"))
f = json.load(open(sys.argv[1] + "/folded/.claude-plugin/plugin.json"))
assert k["defaultEnabled"] is True and f["defaultEnabled"] is True
assert "./skills/fold/" in f["skills"] and "./skills/fold/" not in k["skills"]
PY
  # every case tagged for the agent: no subagent dispatch left in the folded prompt, no Agent
  # tool_used grader left that names the agent
  left=$(python3 - "$out/folded/evals" "$a" <<'PY'
import os, re, sys
d, a = sys.argv[1], sys.argv[2]
for c in sorted(os.listdir(d)):
    p = os.path.join(d, c, "prompt.md")
    if not os.path.isfile(p) or not re.search(r"^tags:\s*\[\s*" + re.escape(a) + r"\b", open(p).read(), re.M):
        continue
    if "subagent_type" in open(p).read():
        print(p)
    for g in os.listdir(os.path.join(d, c, "graders")):
        t = open(os.path.join(d, c, "graders", g)).read()
        if re.search(r"^tool:\s*Agent\s*$", t, re.M) and re.search(r"^input_match:.*" + re.escape(a), t, re.M):
            print(g)
PY
)
  [ -z "$left" ] && ok "$a: no Agent dispatch left in folded cases" || bad "$a: still dispatches: $left"
  # positive checks: what the fold must have written, not only what it must have removed
  probs=$(python3 - "$ROOT" "$out" "$a" <<'PY'
import json, os, re, subprocess, sys
root, out, a = sys.argv[1:]
def parts(t):  # (frontmatter, body) split by hand, independent of eval-fold.py's split_fm
    assert t.startswith("---\n"), "no frontmatter"
    end = t.index("\n---\n", 4)
    return t[4:end], t[end + 5:]
afm, abody = parts(open(f"{root}/agents/{a}.md").read())
sfm, sbody = parts(open(f"{out}/folded/skills/fold/{a}/SKILL.md").read())
if sbody != abody:
    print("SKILL.md body is not byte-identical to the agent body")
for key in ("model", "effort"):
    pin = re.search(rf"^{key}:\s*(\S+)", afm, re.M)
    got = re.search(rf"^{key}:\s*(\S+)", sfm, re.M)
    if not pin or not got or pin.group(1) != got.group(1):
        print(f"SKILL.md {key} does not match the agent pin")
def node_match(pattern, s):
    r = subprocess.run(["node", "-e", "process.exit(new RegExp(process.argv[1]).test(process.argv[2]) ? 0 : 1)",
                        pattern, s])
    return r.returncode == 0
for c in sorted(os.listdir(f"{root}/evals")):
    kp = f"{root}/evals/{c}/prompt.md"
    if not os.path.isfile(kp) or not re.search(r"^tags:\s*\[\s*" + re.escape(a) + r"\b", open(kp).read(), re.M):
        continue
    fp = open(f"{out}/folded/evals/{c}/prompt.md").read()
    if "subagent_type" in open(kp).read() and not (f"`mh:{a}` skill" in fp and f'skill: "mh:{a}"' in fp):
        print(f"{c}: Skill sentence missing from the folded prompt")
    if re.search(r"^allowed_tools:", open(kp).read(), re.M):
        at = re.search(r"^allowed_tools:\s*\[([^\]]*)\]", fp, re.M)
        if not at or "Skill" not in [t.strip() for t in at.group(1).split(",")]:
            print(f"{c}: folded prompt's allowed_tools lacks Skill")
    gdir = f"{root}/evals/{c}/graders"
    for g in os.listdir(gdir):
        kt = open(f"{gdir}/{g}").read()
        if not (re.search(r"^tool:\s*Agent\s*$", kt, re.M) and re.search(r"^input_match:.*" + re.escape(a), kt, re.M)):
            continue
        fpath = f"{out}/folded/evals/{c}/graders/{g}"
        if not os.path.isfile(fpath):
            print(f"{c}/{g}: converted grader missing"); continue
        ft = open(fpath).read()
        if not re.search(r"^tool:\s*Skill\s*$", ft, re.M):
            print(f"{c}/{g}: converted grader is not tool: Skill")
        m = re.search(r"^input_match:\s*'(.*)'\s*$", ft, re.M)
        if not m:
            print(f"{c}/{g}: no single-quoted input_match"); continue
        pat = m.group(1).replace("''", "'")
        if not node_match(pat, json.dumps({"skill": f"mh:{a}"})) or not node_match(pat, json.dumps({"skill": a})):
            print(f"{c}/{g}: input_match misses a Skill input for {a}")
        if node_match(pat, json.dumps({"skill": "mh:tech-humanize"})):
            print(f"{c}/{g}: input_match also matches another skill")
    calls = f"{out}/folded/evals/{c}/graders/fold-agent-calls.md"
    if not os.path.isfile(calls) or not re.search(r"^tool:\s*Agent\s*$", open(calls).read(), re.M):
        print(f"{c}: folded case lacks the fold-agent-calls counter")
PY
)
  [ -z "$probs" ] && ok "$a: folded skill, prompts and graders carry the expected content" || bad "$a: $probs"
done

# A tagged fire case whose dispatch sentence the rewrite can't find must stop the build;
# a should-not-fire case (an Agent grader naming the agent with max: 0) builds without one.
fx="$TMP/fixture-repo"
mkdir -p "$fx/.claude-plugin" "$fx/agents" "$fx/evals/x-case/graders"
echo '{"name": "mh", "defaultEnabled": false, "skills": []}' >"$fx/.claude-plugin/plugin.json"
printf -- '---\nname: x-agent\ndescription: "X."\nmodel: opus\neffort: high\n---\nBody.\n' >"$fx/agents/x-agent.md"
printf -- '---\nname: x-case\ntags: [x-agent, planted]\nallowed_tools: [Read, Agent]\n---\nAsk the x-agent about it, somehow.\n' >"$fx/evals/x-case/prompt.md"
printf -- '---\ntype: regex\ntarget: last_message\nmatch: contains\npattern: ok\n---\nOutcome.\n' >"$fx/evals/x-case/graders/finding.md"
git -C "$fx" init -q
git -C "$fx" add -- .claude-plugin agents evals
python3 "$LIB" build "$fx" x-agent "$TMP/fx-out-fire" >/dev/null 2>&1 \
  && bad "build accepted a fire case with no dispatch sentence to rewrite" || ok "build stops on a fire case with no rewritable dispatch sentence"
printf -- '---\ntype: tool_used\ntool: Agent\ninput_match: x-agent\nmin: 0\nmax: 0\narm: both\n---\nShould not fire.\n' >"$fx/evals/x-case/graders/no-agent-dispatch.md"
git -C "$fx" add -- evals
python3 "$LIB" build "$fx" x-agent "$TMP/fx-out-nofire" >"$TMP/fx.allow" 2>"$TMP/fx.err" \
  && ok "build accepts a should-not-fire case with no dispatch sentence" || bad "build refused a should-not-fire case: $(cat "$TMP/fx.err")"
/usr/bin/grep -qx 'Agent,Read,Skill' "$TMP/fx.allow" 2>/dev/null \
  && ok "allow-tools: union of case allowed_tools plus Skill" || bad "allow-tools: got '$(cat "$TMP/fx.allow")'"

guarded >"$TMP/after"
cmp -s "$TMP/before" "$TMP/after" && ok "repo manifest, agents/ and skills/ unchanged" || bad "build touched the repo"

python3 "$LIB" build "$ROOT" plan-reviewer "$ROOT/evals/results/should-not-exist" >/dev/null 2>&1 \
  && bad "build accepted an output dir inside the repo" || ok "build refuses an output dir inside the repo"
[ ! -e "$ROOT/evals/results/should-not-exist" ] || bad "build wrote inside the repo"

# compare fixtures. case-a flips (kept PP, folded FF). case-b is the same, but one folded run
# called Agent twice and the other has no counter. case-c: one folded run errored; left out, the
# clean folded run matches kept, so the case is "same" (counting the error would make it worse).
python3 - "$TMP" <<'PY2'
import json, sys
d = sys.argv[1]
def run(finding, calls=None, skipped=False, explanation=None):
    gs = [{"name": "dispatch-confirmed", "passed": False, "weight": 1},
          {"name": "finding", "passed": finding, "weight": 1}]
    if calls is not None or explanation is not None:
        gs.append({"name": "fold-agent-calls", "passed": True, "weight": 1,
                   "explanation": explanation or f"Agent called {calls}x (expected 0..\u221e)"})
    return {"error": None, "skippedPaidGraders": skipped, "graders": gs}
# case-d: one folded run hit the cost cap (llm graders marked failed unjudged); left out, so "same".
# case-e: the counter is present but its wording is unreadable: must print ?, never 0.
kept = {"costUsd": 1.0, "cases": [
    {"name": "case-a", "arms": {"with": [run(True), run(True)]}},
    {"name": "case-b", "arms": {"with": [run(True), run(False)]}},
    {"name": "case-c", "arms": {"with": [run(True), run(True)]}},
    {"name": "case-d", "arms": {"with": [run(True), run(True)]}},
    {"name": "case-e", "arms": {"with": [run(True), run(True)]}}]}
folded = {"costUsd": 1.0, "cases": [
    {"name": "case-a", "arms": {"with": [run(False, 0), run(False, 0)]}},
    {"name": "case-b", "arms": {"with": [run(True, 2), run(False)]}},
    {"name": "case-c", "arms": {"with": [{"error": "timeout", "graders": []}, run(True, 0)]}},
    {"name": "case-d", "arms": {"with": [run(False, 0, skipped=True), run(True, 0)]}},
    {"name": "case-e", "arms": {"with": [run(True, explanation="tool count unavailable"), run(True, 0)]}}]}
json.dump(kept, open(f"{d}/kept.json", "w"))
json.dump(folded, open(f"{d}/folded.json", "w"))
PY2
if python3 "$LIB" compare "$TMP/kept.json" "$TMP/folded.json" >"$TMP/cmp.out" 2>&1; then
  /usr/bin/grep -qE '^  finding +PP +FF +\*$' "$TMP/cmp.out" && ok "compare marks the flipped grader" || bad "compare: no flip mark: $(cat "$TMP/cmp.out")"
  [ "$(/usr/bin/grep -cE '^  finding .*\*$' "$TMP/cmp.out")" -eq 1 ] && ok "compare leaves unchanged cases unmarked (errored run excluded)" || bad "compare: wrong flip count: $(cat "$TMP/cmp.out")"
  /usr/bin/grep -qE '^  finding +PP +EP *$' "$TMP/cmp.out" && ok "compare shows an errored run as E" || bad "compare: errored run not shown as E"
  /usr/bin/grep -q 'dispatch-confirmed .*(mechanism, not scored)' "$TMP/cmp.out" && ok "compare keeps dispatch graders out of the score" || bad "compare: dispatch grader scored"
  /usr/bin/grep -q 'folded worse 1, folded better 0, same 4' "$TMP/cmp.out" && ok "compare verdict leaves errored and cost-capped runs out" || bad "compare summary: $(tail -5 "$TMP/cmp.out")"
  /usr/bin/grep -q 'errored runs (not in the verdict): kept 0, folded 1' "$TMP/cmp.out" && ok "compare counts errored runs apart" || bad "compare: errored runs not counted"
  /usr/bin/grep -q 'cost-capped runs (skippedPaidGraders; not in the verdict): kept 0, folded 1' "$TMP/cmp.out" && ok "compare counts cost-capped runs apart" || bad "compare: cost-capped runs not counted"
  /usr/bin/grep -qE '^  finding +PP +SP *$' "$TMP/cmp.out" && ok "compare shows a cost-capped run as S" || bad "compare: cost-capped run not shown as S"
  /usr/bin/grep -qE '^  dispatch-confirmed +FF +EF ' "$TMP/cmp.out" && /usr/bin/grep -qE '^  fold-agent-calls +- +EP ' "$TMP/cmp.out" && ok "an errored run with no graders still shows E in every cell" || bad "compare: errored run with graders [] lost its E"
  /usr/bin/grep -q 'folded Agent calls per run: E, 0$' "$TMP/cmp.out" && ok "an errored run shows E, not ?, in the Agent-call line" || bad "compare: errored run Agent-call line: $(/usr/bin/grep 'calls per run' "$TMP/cmp.out")"
  /usr/bin/grep -q 'folded Agent calls per run: ?, 0 ' "$TMP/cmp.out" && ok "an unreadable counter prints ?, not 0" || bad "compare: unreadable counter not shown as ?"
  /usr/bin/grep -q 'folded Agent calls per run: 2, ? .*DELEGATED' "$TMP/cmp.out" && ok "compare flags a folded run that delegated, and an unknown count" || bad "compare: delegation not flagged: $(cat "$TMP/cmp.out")"
  [ "$(/usr/bin/grep -c '<- DELEGATED' "$TMP/cmp.out")" -eq 1 ] && ok "compare flags only the delegating case" || bad "compare: wrong DELEGATED count"
  /usr/bin/grep -q 'model' <<<"$(head -6 "$TMP/cmp.out")" && /usr/bin/grep -q 'tool limits' <<<"$(head -6 "$TMP/cmp.out")" \
    && ok "compare header names the model and tool-limit confounds" || bad "compare: header lacks confounds"
else
  bad "compare failed: $(cat "$TMP/cmp.out")"
fi
echo '{"cases":[{"name":"x","arms":{"without":[]}}]}' >"$TMP/nowith.json"
python3 "$LIB" compare "$TMP/nowith.json" "$TMP/folded.json" >/dev/null 2>&1 \
  && bad "compare accepted a result with no 'with' arm" || ok "compare fails loudly without a 'with' arm"

# dry run (no model calls: build + claude plugin validate): commands are labeled examples;
# --keep leaves the temp dir and says where
if bash "$ROOT/scripts/eval-fold.sh" blind-spot-hunter --keep >"$TMP/dry.out" 2>&1; then
  /usr/bin/grep -q 'example' "$TMP/dry.out" && ok "dry run labels the printed commands as examples" || bad "dry run: no example label"
  kept_dir=$(sed -n 's/^eval-fold: kept temp dir: //p' "$TMP/dry.out")
  if [ -n "$kept_dir" ] && [ -d "$kept_dir/folded/skills/fold/blind-spot-hunter" ]; then
    ok "--keep leaves the temp dir"; trash "$kept_dir"
  else
    bad "--keep: no kept temp dir reported: $(cat "$TMP/dry.out")"
  fi
else
  bad "dry run failed: $(cat "$TMP/dry.out")"
fi

bash "$ROOT/scripts/eval-fold.sh" plan-reviewer --runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "eval-fold.sh refuses --runs 1" || bad "eval-fold.sh --runs 1 exited $rc, want 2"

echo "eval-fold: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
