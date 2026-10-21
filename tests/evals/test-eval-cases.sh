#!/usr/bin/env bash
# test-eval-cases.sh: static check of evals/<case>/ for the review-agent and skill evals.
# `claude plugin eval` is early-access gated, so this keeps the suite loadable
# without running it: every case has prompt.md (case.yaml is only required when
# the case needs scaffolded fixture files) and at least one outcome grader
# (regex/llm/file_exists/baseline, not just tool_used/tool_order — counted from
# each grader's own frontmatter, not a whole-file grep), the scaffold_script
# (inline `|` block or an external sibling file — the CLI only accepts the
# latter, confirmed empirically 2026-09-13) runs in a temp dir and writes the
# files the prompt names, and every regex grader's pattern compiles as a JS
# RegExp via `node` — Python's re module is NOT the same dialect: it silently
# accepts inline `(?i)`, which JS rejects. The real eval runtime is Bun
# (JavaScriptCore), confirmed 2026-09-14 by extracting the installed CLI
# binary's embedded source (it calls `new RegExp(pattern, flags)` directly)
# and matching its exact `(?i)` error text against `bun -e`, not `node -e`;
# `node`/V8 is used here only as a same-family proxy — both engines reject
# inline `(?i)` identically, so it still catches the bug class, but a report
# of the *specific* engine should say Bun, not V8 — this last check runs for
# every case including prompt.md-only ones (no case.yaml to scaffold).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
EVALS="$HERE/../../evals"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
command -v node >/dev/null || { echo "node required (validates regex graders against the real JS engine)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'trash "$TMP" 2>/dev/null || true' EXIT

# Cases whose prompt deliberately does not name a subagent_type/skill: they prove
# the agent/skill must NOT be dispatched for an out-of-scope or misrouted ask.
NO_DISPATCH_EXPECTED="code-architect-trivial-no-dispatch perf-regression-routing backend-architect-file-blueprint-misroute ideate-critic-security-review-misroute"

# A prompt states the task, never the verdict the graders expect (GH #389): scan the body
# (frontmatter stripped, since names/tags like `planted` live there) for words that hand the
# subject the answer. Narrow on purpose -- it cannot catch a paraphrased trigger fact; moving the
# fixture into scaffold.sh is what fixes those. Prints `line: text` per hit, exits 1 on any.
prompt_tells() {
  python3 - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
start = 0
if lines and lines[0] == "---":
    for i in range(1, len(lines)):
        if lines[i] == "---":
            start = i + 1
            break
rx = re.compile(r"\bplanted\b|\brubric\b|\bgrader\b|\bno bugs?\b|\baccurate\b|correctly implemented", re.I)
hits = [f"{i + 1}: {l.strip()}" for i, l in enumerate(lines) if i >= start and rx.search(l)]
print("\n".join(hits))
sys.exit(1 if hits else 0)
PY
}

# One node process compiles every regex grader's pattern up front (one spawn per pattern was
# ~half this test's runtime). The per-case check below reads this cache and still spawns node
# itself for any pattern the cache lacks, so a parse mismatch here can never skip a check.
JS_CACHE="$TMP/js-regex-cache.json"
python3 - "$EVALS" <<'PY' | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  const out = {};
  for (const [p, f] of JSON.parse(s)) {
    try { new RegExp(p, f); out[p + "\u0000" + f] = null; } catch (e) { out[p + "\u0000" + f] = String(e); }
  }
  process.stdout.write(JSON.stringify(out));
});' > "$JS_CACHE" || echo '{}' > "$JS_CACHE"
import glob, json, os, re, sys
pairs = []
for f in glob.glob(os.path.join(sys.argv[1], "*", "graders", "*.md")):
    m = re.match(r"---\n([\s\S]*?)\n---\n", open(f).read())
    if not m or "type: regex" not in m.group(1):
        continue
    p = re.search(r"^pattern: '(.*)'$", m.group(1), re.M) or re.search(r'^pattern: "(.*)"$', m.group(1), re.M)
    if p:
        fl = re.search(r"^flags: (\w+)$", m.group(1), re.M)
        pairs.append([p.group(1), fl.group(1) if fl else ""])
json.dump(pairs, sys.stdout)
PY

n=0
for d in "$EVALS"/*/; do
  c=$(basename "$d"); n=$((n + 1))
  [ "$c" = "results" ] && { n=$((n - 1)); continue; }
  [ "$c" = "mocks" ] && { n=$((n - 1)); continue; }
  [ -f "$d/prompt.md" ] || { bad "$c: prompt.md missing"; continue; }
  if ! tells=$(prompt_tells "$d/prompt.md"); then
    bad "$c: prompt.md tells the subject the expected answer:"$'\n'"$tells"; continue
  fi
  has_case_yaml=0; [ -f "$d/case.yaml" ] && has_case_yaml=1
  g=$(ls "$d/graders"/*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$g" -ge 2 ] || { bad "$c: $g graders (need >=2)"; continue; }
  # Frontmatter-scoped, not a whole-file grep: a grader's own body prose can otherwise
  # contain a line like "type: llm" (in an explanation) and get miscounted as an outcome
  # grader even when its actual frontmatter type is tool_used/tool_order.
  outcome_graders=0
  for gf in "$d"/graders/*.md; do
    [ -f "$gf" ] || continue
    if awk '/^---$/{n++; next} n==1' "$gf" | /usr/bin/grep -qE '^type: (regex|llm|file_exists|baseline)$'; then
      outcome_graders=$((outcome_graders + 1))
    fi
  done
  [ "$outcome_graders" -ge 1 ] || { bad "$c: no outcome grader (only tool_used/tool_order)"; continue; }
  if [ "$has_case_yaml" -eq 1 ]; then
    /usr/bin/grep -q '^schema_version: "1.1"' "$d/case.yaml" || { bad "$c: case.yaml lacks schema_version 1.1"; continue; }
  fi
  case " $NO_DISPATCH_EXPECTED " in
    *" $c "*) : ;;
    *) case "$c" in
    tech-humanize-*) /usr/bin/grep -q 'skill: "mh:tech-humanize"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    harness-audit-*) /usr/bin/grep -q 'skill: "mh:harness-audit"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    post-mortem-*)   /usr/bin/grep -q '^/mh:post-mortem' "$d/prompt.md" || { bad "$c: prompt.md does not invoke the skill by slash command"; continue; } ;;
    compliance-audit-*) /usr/bin/grep -q '^/mh:compliance-audit' "$d/prompt.md" || { bad "$c: prompt.md does not invoke the skill by slash command"; continue; } ;;
    memory-lint-*)   /usr/bin/grep -q 'skill: "mh:memory-lint"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    learn-*)         /usr/bin/grep -q 'skill: "mh:learn"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    ideate-critic-*) /usr/bin/grep -q 'subagent_type: "mh:ideate-critic"' "$d/prompt.md" || { bad "$c: prompt.md does not name a subagent_type"; continue; } ;;
    ideate-*)        /usr/bin/grep -q 'skill: "mh:ideate"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    idea-audit-*)    /usr/bin/grep -q 'skill: "mh:idea-audit"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    deep-audit-*)    /usr/bin/grep -q 'skill: "mh:deep-audit"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    cost-report-*)   /usr/bin/grep -q 'skill: "mh:cost-report"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    ste-lint-*)      /usr/bin/grep -q 'skill: "mh:ste-lint"' "$d/prompt.md" || { bad "$c: prompt.md does not name the skill"; continue; } ;;
    *) /usr/bin/grep -q 'subagent_type: "mh:' "$d/prompt.md" || { bad "$c: prompt.md does not name a subagent_type"; continue; } ;;
    esac ;;
  esac

  if [ "$has_case_yaml" -eq 1 ]; then
    # scaffold_script: extract the block (inline `|` form) or read the external sibling
    # file it names (the CLI only accepts the latter — confirmed empirically 2026-09-13,
    # inline content is mis-parsed as a literal path and fails to load), run it in a
    # temp workspace, check every file prompt.md names.
    ws="$TMP/$c"; mkdir -p "$ws"
    python3 - "$d/case.yaml" "$d" > "$ws/scaffold.sh" <<'PY'
import sys, os
case_yaml, case_dir = sys.argv[1], sys.argv[2]
lines = open(case_yaml).read().splitlines()
out, on = [], False
external = None
for l in lines:
    if on:
        if l.strip() and not l.startswith("    "):
            break
        out.append(l[4:])
    elif l.strip() == "scaffold_script: |":
        on = True
    else:
        s = l.strip()
        if s.startswith("scaffold_script:") and not s.endswith("|"):
            external = s.split(":", 1)[1].strip()
if external:
    path = os.path.join(case_dir, external)
    sys.stdout.write(open(path).read() if os.path.isfile(path) else "")
else:
    sys.stdout.write("\n".join(out) + "\n")
PY
    [ -s "$ws/scaffold.sh" ] || { bad "$c: scaffold_script empty or its external file missing"; continue; }
    if ! (cd "$ws" && bash scaffold.sh >/dev/null 2>&1); then bad "$c: scaffold_script failed"; continue; fi
    missing=0
    for f in $(/usr/bin/grep -oE '`[A-Za-z0-9_./-]+\.(py|md|ts|tsx|json)`' "$d/prompt.md" | tr -d '`' | sort -u); do
      [ -f "$ws/$f" ] || { bad "$c: scaffold did not write $f"; missing=1; }
    done
    [ "$missing" -eq 0 ] || continue
  fi

  # every grader has column-0 frontmatter with a type (the runner skips a grader
  # whose fence is indented, silently -- caught by a validator 2026-09-06), and
  # every regex grader's pattern compiles. contract.md / clean.md must also match a
  # verdict line in the shape the agent actually emits: all three live runs on
  # 2026-09-06 wrote it bold or after a `Verdict:` label, which a bare `(^|\n)\s*`
  # anchor rejects (deep-audit finding, v1.1.22).
  case "$c" in
    blind-spot-hunter-planted|silent-failure-hunter-planted) sample=$'## Verdict\n\n**1 MEDIUM, 2 LOW**' ;;
    blind-spot-hunter-clean|silent-failure-hunter-clean)     sample=$'## Verdict\n\n**CLEAN**' ;;
    test-gap-analyzer-planted)    sample=$'**Verdict:** `4 GAPS, highest 6/10`' ;;
    test-gap-analyzer-clean)      sample=$'**Verdict:** `COVERED`' ;;
    type-design-analyzer-planted) sample=$'**6 CONCERNS across 4 types, lowest Encapsulation 4/10**' ;;
    type-design-analyzer-clean)   sample=$'**SOUND**' ;;
    plan-reviewer-planted)        sample='verdict: needs-revision' ;;
    plan-reviewer-clean)          sample=$'findings: []\nverdict: production-ready' ;;
    requirement-analyst-planted)  sample='verdict: needs-clarification' ;;
    requirement-analyst-clean)    sample='verdict: ready' ;;
    tech-humanize-*)              sample='FIXTURE' ;;
    harness-audit-*)              sample=$'=== Summary ===\nCritical: 0\nWarnings: 1\nInfo:     4\n' ;;
    post-mortem-complete)         sample=$'## 1. Summary\n\n## 2. Symptom\n\n## 3. Root Cause (Mechanism)\n\n## 4. Symptom Linkage\n\n## 5. Fix\n\n## 6. Discovery Method\n\n## 7. Escape Reason\n\n## 8. Failure class\n\n## 9. Validation Proof\n\n## 10. Follow-Ups\n\n## 11. Assumption Trace' ;;
    post-mortem-missing-input)    sample='Before drafting I need the fourth input: passing validation.' ;;
    memory-lint-*)                sample='memories: 3 | links: 3 | linked: 3 | MEMORY.md: 3% of load cap | findings: 0' ;;
    learn-*)                      sample='FIXTURE' ;;
    compliance-audit-*)           sample='FIXTURE' ;;
    ideate-run)                   sample=$'- ring-buffer CAS counters [N7 V8 F9]\n★ **token lease** because...\nWhat if we took this seriously: ...' ;;
    ideate-abort)                 sample=$'```python\nwith open("notes.txt") as f:\n    for line in f:\n        ...\n```' ;;
    deep-audit-*)                 sample='**Final Verdict:** pass (7.8/10, confidence high)' ;;
    idea-audit-*)                 sample='**Decision: adopt** (weighted total 82/100, threshold 70) — primary-source fidelity 32/35, fit 18/20' ;;
    cost-report-planted)          sample=$'=== Cost summary ===\nnote: 1 of 3 rows predate dedup_usage (2026-09-04)\ntotal:     $10.0000  (3 sessions)' ;;
    cost-report-clean)            sample='Cost tracker not set up: /tmp/x/metrics/costs.jsonl not found. Enable the stop:cost-tracker hook and finish a session first.' ;;
    ste-lint-planted)             sample='notes.md line 5: rule 8.1 semicolon
notes.md line 3: rule 6.3 31 words (limit 25)
Do not skip the smoke test; a failed smoke test blocks the release.' ;;
    ste-lint-clean)               sample='status.md: no confirmed findings
The build is green. Tests pass. Deploy is ready.' ;;
    ste-lint-file-prose-only)     sample='mixed.md line 3: rule 8.1 semicolon
```bash
echo "a;b"
```' ;;
    *) sample='' ;;
  esac
  # Cases outside the table above (agent-dispatch suites whose output has no fixed
  # verdict token — a full report or a JSON contract, not a "Verdict:" line) skip the
  # discrimination check below; the universal frontmatter/regex-compile check still
  # runs for them. Their content quality was verified via real ablation pilot runs,
  # not this static proxy (see evals/README.md per suite).
  # Skill cases have no verdict token. Their proof is the fixture itself: every regex grader
  # pattern must match the scaffolded input (a not_contains tell is really planted, a contains
  # specific is really there), or the grader cannot discriminate.
  if [ "$sample" = FIXTURE ]; then
    sample=$(cat "$ws"/*.md "$ws"/*/*.md 2>/dev/null)
  fi
  # ste-lint reports rather than rewrites: a `wrong` sample proves a last_message
  # grader would reject an incorrect report, not just accept a correct one.
  wrong=''
  case "$c" in
    ste-lint-planted)         wrong='status.md: no confirmed findings, file is clean.' ;;
    ste-lint-file-prose-only) wrong='mixed.md line 6: rule 8.1 semicolon inside the code block' ;;
  esac
  if ! python3 - "$d/graders" "$sample" "$wrong" "$JS_CACHE" <<'PY'
import sys, os, re, subprocess, json
bad = 0
sample = sys.argv[2]
wrong = sys.argv[3]
try:
    js_cache = json.load(open(sys.argv[4]))
except (OSError, ValueError):
    js_cache = {}
for f in sorted(os.listdir(sys.argv[1])):
    s = open(os.path.join(sys.argv[1], f)).read()
    m = re.match(r"---\n([\s\S]*?)\n---\n", s)
    if not m or not re.search(r"^type: (regex|tool_used|tool_order|file_exists|llm|baseline)$", m.group(1), re.M):
        print(f"  {f}: no column-0 frontmatter with a known type"); bad = 1; continue
    if "type: regex" not in m.group(1):
        continue
    p = re.search(r"^pattern: '(.*)'$", m.group(1), re.M) or re.search(r'^pattern: "(.*)"$', m.group(1), re.M)
    if not p:
        print(f"  no pattern in {f}"); bad = 1; continue
    try:
        rx = re.compile(p.group(1))
    except re.error as e:
        print(f"  bad regex in {f}: {e}"); bad = 1; continue
    fl = re.search(r"^flags: (\w+)$", m.group(1), re.M)
    js_flags = fl.group(1) if fl else ""
    flags = re.I if fl and "i" in fl.group(1) else 0
    key = p.group(1) + "\0" + js_flags
    if key in js_cache:
        reason = js_cache[key]
    else:
        js = subprocess.run(
            ["node", "-e", "new RegExp(process.argv[1], process.argv[2])", "--", p.group(1), js_flags],
            capture_output=True, text=True,
        )
        err_lines = js.stderr.strip().splitlines()
        reason = None if js.returncode == 0 else next(
            (l for l in err_lines if "Error" in l), err_lines[-1] if err_lines else "compile failed")
    if reason is not None:
        print(f"  bad JS regex in {f} (real eval runtime uses JS, not Python re): {reason}")
        bad = 1; continue
    if not sample:
        continue  # no verdict/fixture sample for this case's output shape; compile check above already ran
    if f in ("contract.md", "clean.md"):
        want = "match: not_contains" not in m.group(1)
        if bool(re.search(p.group(1), sample, flags)) != want:
            print(f"  {f}: pattern {'rejects' if want else 'matches'} the verdict sample {sample!r}"); bad = 1
    elif os.path.basename(os.path.dirname(sys.argv[1])).startswith(("tech-humanize-", "ste-lint-")):
        if not re.search(p.group(1), sample, flags | re.M):
            print(f"  {f}: pattern does not match the scaffolded fixture, so it cannot discriminate"); bad = 1
        if wrong and "target: last_message" in m.group(1) and re.search(p.group(1), wrong, flags | re.M):
            print(f"  {f}: pattern matches a deliberately wrong report, so it cannot discriminate"); bad = 1
sys.exit(bad)
PY
  then bad "$c: a grader is malformed"; continue; fi
  ok "$c"
done
# Not an exact literal (harness gap-audit 2026-09-20 already fixed this same
# anti-pattern in README.md/operating-model.md below) -- the count legitimately
# drifts up as cases are added. A floor instead catches the real failure mode:
# the $EVALS glob resolving to the wrong/empty path, or a mass deletion, both
# of which would otherwise make every per-case check above vacuously pass on
# zero iterations.
# Negative control for prompt_tells: a clean prompt passes, the same prompt with one tell
# appended to its body must fail, or the scan above proves nothing.
ctl="$EVALS/deep-audit-planted/prompt.md"
if prompt_tells "$ctl" >/dev/null; then ok "prompt_tells passes a clean prompt"; else bad "prompt_tells flags the clean control $ctl"; fi
cp "$ctl" "$TMP/tell-control.md" && echo "There is no planted bug in this fixture." >> "$TMP/tell-control.md"
if prompt_tells "$TMP/tell-control.md" >/dev/null; then bad "prompt_tells missed a tell appended to a clean prompt"; else ok "prompt_tells catches an appended tell"; fi

[ "$n" -ge 40 ] || bad "expected at least 40 eval cases (sanity floor -- \$EVALS glob may be wrong), found $n"

# README.md and operating-model.md used to hardcode "29" (harness gap-audit,
# 2026-09-20: the count had drifted to 70 with no test catching it). Both now
# point at this recompute command instead of a literal -- assert neither
# regressed back to a bare number that can go stale again.
RECOMPUTE_CMD='find evals -mindepth 1 -maxdepth 1 -type d ! -name results | wc -l'
for doc in "$HERE/../../README.md" "$HERE/../../docs/reference/operating-model.md"; do
  /usr/bin/grep -qF "$RECOMPUTE_CMD" "$doc" || bad "$(basename "$doc"): eval-case count no longer points at the recompute command"
done

echo "eval-cases: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
