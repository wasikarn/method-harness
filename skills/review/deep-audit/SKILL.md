---
name: deep-audit
description: "Deep-audit: post-implementation audit: verify every claim, score before/after, fix gaps, re-score. Use after an implementation pass. Not for plan conformance (/mh:compliance-audit) or first-pass review (/code-review)."
model: inherit
effort: xhigh
---

Audit everything implemented or changed in this session as if someone else built it. The
session output is a set of claims; each one is true only once evidence outside the model's own
memory says so.

## 1. Reconstruct scope from the tree, not from memory

Scope is what git shows, since a compacted session remembers a retelling, not the work. Find
the session's first commit from the reflog or the session start time, then list:

```bash
git log --oneline --since="<session start>"        # or <first-sha>^..HEAD
git diff <first-sha>^..HEAD --stat; git status --porcelain
```

Uncommitted-only work is the diff alone. Add files edited outside git (memory store, settings,
sibling repos) by name. When the session worked from a plan's file list, re-sweep every tracked
file with a fresh grep for the changed names and paths: the plan's list is a claim about which
files were affected, not the set itself. Then read the diff and trace how the pieces work
together end to end, noting assumptions, implicit behaviour, and anything the session claimed
but never ran. Done when every changed file is listed with the session's claim about it and
your own note on it.

## 2. Score the baseline on the fixed rubric

Score each dimension 0–10 from evidence. Same rubric every run, so runs compare.

| dimension | weight | evidence that earns the score |
|---|---|---|
| Correctness | 3 | tests, checks, or a reproduced command exit code |
| Completeness | 2 | every item of the request traced to a file or an explicit "left out" |
| Claim accuracy | 2 | each claim in commits, docs, and replies re-run or re-read |
| Regression safety | 2 | gauntlet or equivalent green; sibling callers of changed code checked |
| Simplicity | 1 | no abstraction, file, or line without a caller or a reader |

Evidence is read in the operating-model order: deterministic result, then this run's
trajectory, then rollback history, then model confidence last. A dimension with no evidence is
marked **insufficient evidence** and passed through as such; a guessed score is worse than none
(Rule 14).

The model scores each dimension and writes reasons; the plugin's `scripts/_lib/weighted-score.py`
does the arithmetic — the weighted total, the pass/fail call, and the "insufficient evidence"
renormalization — so a wrong hand sum can never reach a Final Verdict:
```
python3 "${CLAUDE_SKILL_DIR}/../../../scripts/_lib/weighted-score.py" <<< '{"scores": [
  {"id": "correctness", "score": <0-10>, "max": 10, "weight": 3, "insufficient": <bool>},
  {"id": "completeness", "score": <0-10>, "max": 10, "weight": 2, "insufficient": <bool>},
  {"id": "claim_accuracy", "score": <0-10>, "max": 10, "weight": 2, "insufficient": <bool>},
  {"id": "regression_safety", "score": <0-10>, "max": 10, "weight": 2, "insufficient": <bool>},
  {"id": "simplicity", "score": <0-10>, "max": 10, "weight": 1, "insufficient": <bool>}
], "floorPct": 0.5, "passThreshold": 7.0, "perturb": 0.20}'
```
`perturb` runs a weight-sensitivity check: every scored weight is independently moved ±20%, and
the output's `sensitivity.verdictStable` says whether `pass` can flip anywhere in that box. `false`
means the total is closer to the threshold than the bare number reads — report it (see Final
output below), don't silently drop it.
An `insufficient`-flagged dimension is dropped from both the numerator and the denominator
(why: `references/rationale.md`).
`pass` in the output is `total >= 7.0` with no scored dimension under 50% of its own max (`5`);
report `belowFloor` and any insufficient-evidence dimensions to the operator either way. **The
script fails closed:** malformed input (a missing field, a non-numeric score, or every dimension
flagged insufficient) exits non-zero with a reason on stderr — treat that as a hard `fail`,
never as license to fall back to computing the total by hand.

Claim accuracy is scored on whether the claim was true when made; later evidence that makes it
true is separate current-state work.

## 3. Hunt gaps with a Codex-primary fresh-context checker

The maker never grades its own work (`docs/reference/operating-model.md`). Build the checker's
brief in the `docs/reference/spawn-brief.md` shape, with **only step 1's scope list** (the
changed paths and the commit range/diff to review) and this task's framing: assume the session
is complacent; find what it missed across correctness, edge cases, failure modes, hidden
assumptions, regressions, missing checks, consistency between files (doc versus code, two docs
disagreeing), and drift between intent and code; every finding cites one checkable fact (a
`path:line`, or a backticked command). **Withhold step 1's own per-file claims/notes and step 2's rubric scores** —
the checker re-derives its own read of the diff from the artifact itself, never from the
orchestrator's already-formed opinion of it (the CoVe "joint" failure mode; why each step-3 rule
exists: `references/rationale.md`, not needed to run). Add one line to the brief itself: this run
is investigation-only — reading files and running read-only commands (`git log`, `git diff`,
`cat`, `rg`) is expected and required.

**Priming:** when you already have direct evidence pointing at something specific (a concrete
claim you can name, not "check everything harder"), you may name it in the brief and ask the
checker to verify or refute it. **When the brief primes any item, require one `findings[]` entry
per primed item, `summary` starting `CONFIRMED:` or `DISPUTED:`** — otherwise "checked and
cleared" reads the same as "never looked".

**Fingerprint scope before dispatch.** For every path step 1 put in scope (committed-diff files,
any staged/untracked/uncommitted files, any named out-of-git file — memory store, settings),
record whether it exists and, if so, a content hash of its bytes on disk. Pipe the paths, one per
line, to the script, which writes the manifest:
```
printf '%s\n' <scope paths> | python3 "${CLAUDE_SKILL_DIR}/scripts/scope-fingerprint.py" snapshot "$MANIFEST"
```
`$MANIFEST` is a file outside the repo (a fresh `mktemp`), so it never lands in scope itself.

**Dispatch, Codex primary:**
```
codex exec --sandbox read-only --model <selected-model> -c model_reasoning_effort=<selected-effort> --cd <repo-root> \
  --output-last-message <file> --output-schema <schema-file>
```
Choose `<selected-model>` and `<selected-effort>` using
`docs/reference/codex-integration-map.md`'s task/account-cost policy; normally Sol/medium
for this adversarial checker. Resolve the tier to a slug, never type one:
`python3 "${CLAUDE_SKILL_DIR}/../../../scripts/_lib/codex-resolve-model.py" sol --effort medium`
(non-zero exit: follow the map's substitution rule and say so); name the resolved slug in the
report. Check availability and remaining quota before a substantial run.
Raise effort only for a concrete reasoning need; acceptance criteria below never weaken.
`<schema-file>` is `references/checker-output-schema.json` (this skill's own JSON Schema for
`{contract_version, pass, findings[], checked[], scope_ok, unexpected_files[]}`). The sandbox plus
the brief's no-mutation line is not an unqualified "read-only, guaranteed".

**Accept the result only if all of:** `codex exec` exits 0; the output-last-message file's raw
text validates through the same `scripts/check-verdict.py` the fallback path uses (all six fields,
**`checked[]` non-empty**, citation-shaped `evidence`):
```
python3 "${CLAUDE_SKILL_DIR}/scripts/check-verdict.py" < <output-last-message file>
```
Exit 0 = accept; exit 1 = reject, a fallback trigger below; exit 2 = a `NEEDS-DECISION`
escalation, surfaced to the operator as an open question (its meaning:
`references/codex-fallback.md`). Schema validity alone is not enough: `--output-schema` cannot enforce citation shape.
The result also shows real review evidence — findings that each cite one checkable fact, or an explicit, legitimate
zero-findings pass (see below) — and does not state or imply it couldn't or didn't complete the
review. Schema-valid JSON that still refuses in prose is not review evidence. A `pass:
false` result **with real, evidenced findings is a successful run that found problems** — never
a failure, never a fallback trigger.

**On any other outcome** — non-zero exit, empty or malformed output, a schema mismatch, timeout,
auth failure, or a semantic refusal — fall back to a Claude `Explore`/review agent (same brief)
and note "independence reduced for this pass" in the final report. Its return contract is the 6-key
`{contract_version, pass, findings[], checked[], scope_ok, unexpected_files[]}`, validated by
`check-verdict.py` on its raw final message. `references/codex-fallback.md` — that contract and `check-verdict.py` validation. **Load before dispatching the
fallback.**

**Re-fingerprint after the checker returns:**
```
python3 "${CLAUDE_SKILL_DIR}/scripts/scope-fingerprint.py" compare "$MANIFEST"
```
Exit 0 means scope is stable; exit 1 prints one `changed:`/`appeared:`/`disappeared:` line per
drifted path; exit 2 means the manifest is missing, unreadable or empty, which counts as unstable. A
mismatch against the pre-dispatch manifest — a changed hash, a path that appeared or
disappeared — means a concurrent session touched scope
mid-check (this session keeps working in its own worktree while the checker runs): rebuild scope from git and
re-run the checker once.

**If the fallback also fails to produce a valid result, or the manifest is still unstable after
that retry**, this is not a soft note: it hard-forces the Final Verdict below to **fail,
reason "verification incomplete"** — overriding whatever step 2's rubric total would otherwise
say. Say plainly this means the audit
couldn't verify the work, not that the work is wrong — the two are different claims.

The checker returns `{contract_version, pass, findings[], checked[], scope_ok, unexpected_files[]}` — its own
return value, distinct from this skill's Final Verdict and report in "Final output" below.

Reconcile its findings with your own. A finding survives only with a concrete trigger; a
speculative "consider X" is dropped. Rank survivors by severity, impact, likelihood, confidence,
and effort. Zero survivors is a valid result: an already-high baseline is a legitimate baseline,
and only evidence separates "nothing worth fixing" from "under-audited".

## 4. Confirm, then fix

Present the ranked findings and confirm with one **AskUserQuestion**:

- `Apply all fixes now` (findings low-risk and inside the session's scope)
- `Apply only some` (a finding is out of scope or needs its own decision); ask which
- `Skip fixes, report findings only` (review-only pass); 0 fixes also skips step 6 (its own
  trigger, 2+ landed fixes, can't hold) — go straight to step 7 with the baseline as both scores

Skip the ask only when the same turn already said "audit and fix"; an earlier or implied
authorization is not that.

Each fix names its failure class (Rule 4: missing_context, bad_tool_contract, missing_guardrail,
weak_verification) and lands test-first where a test can express it: the new test is red on the
pre-fix code and green after, and that red run is part of the evidence. Every change carries a
quality rationale; a change that only moves the score is left out.

## 5. Re-verify

- Re-run the tests and checks the fixes touch, plus the repo gate (`scripts/run-gauntlet.sh` or
  the project's equivalent).
- Check each fix's own mechanism for a new regression before scoring its dimension resolved: a
  fix for one problem can reopen another, and a test that only documents the new behaviour
  hides that. Close a self-inflicted regression in the same pass when it is cheap.
- When any fix touched 2+ files or a test, re-run step 3's checker once over the union of all
  fixes (Rule 13), not one dispatch per fix.
- A fix in a hook, gate, or plugin file is correct in the repo before it protects a session: the
  running copy (plugin cache version, restarted session) is a separate claim; say which one the
  evidence covers.

## 6. Whole-picture adversarial challenge (when step 4's fixes can interact)

Trigger: step 4 applied 2+ fixes, OR applied exactly 1 fix that touched a function, early-exit
path, return value, or emitted string that other code, a test, or an out-of-scope consumer reads.
Skip only when
step 4 applied 0 fixes, or its 1 fix was fully local (nothing else reads what it changed) — step
3's checker already covers a fully-local single fix point-by-point. Why the trigger is not a bare
fix count: `references/rationale.md`.

Dispatch `mh:blind-spot-hunter` (`Agent` tool, reuse — do not write a new agent for this) against
the **combined delta**: every file step 1 put in scope, unioned with every fix commit from step
4, framed as a system-level challenge, not a repeat of step 3. `references/whole-picture-brief.md`
— how to frame that brief, and what to report if the dispatch fails. **Load before dispatching
step 6.**

Findings from this pass go through the same **Confirm, then fix** gate as step 4 (a fresh
`AskUserQuestion`, same three options) — never applied silently. Any fix made here re-enters step
5 (re-verify) before the final re-score in step 7; this step's own fixes do not get a second
whole-picture pass on top (Rule 13's 3-round stop applies here too — if the fixes from this step
seem to need another combined-fix check, stop and report the loop instead of continuing
indefinitely).

A clean result from this pass (`CLEAN`, per the agent's own output contract) is reported the same
way step 3's zero-findings pass is: a legitimate outcome, not a skipped check. A failed dispatch
is neither: it did not run, and the Final output says so (see the reference above).

## 7. Re-score on the same rubric

Report before, after, absolute delta, and percentage, per dimension and overall. When a baseline
is zero or near it, give the absolute delta and say the percentage is not meaningful.

An improvement counts only when post-change evidence beats the baseline on the predefined
criteria. If the score did not move, say so and say why.

## Final output

Line one is the **Final Verdict**: pass or fail against the threshold in step 2, with the
reason and a confidence level, stated plainly — check step 3's hard-fail override first; when it
fires, it wins regardless of the step-2 total. The total and the pass/fail call are copied from
`weighted-score.py`'s output, never computed by hand. When `sensitivity.verdictStable` is `false`,
append a fragility clause **after** the pass/fail word — e.g. "pass (7.3/10, confidence high;
fragile — range [6.9, 7.6] under ±20% weight perturbation)" — never before it, so the existing
grader contract (`Final Verdict… (pass|fail)`) keeps matching. Then:

1. Baseline score (per dimension, weighted total)
2. Findings, each marked by source (step 3's checker, step 6's whole-picture pass when it ran, or your own)
3. Changes made, each with its failure class
4. Verification evidence (commands and exit codes)
5. Final score and before → after
6. Remaining risks, **insufficient evidence** dimensions, and the scope boundary: the audit
   covers the diff it was pointed at, not the neighbourhood around it

The report is evidence-backed proof of whether the work improved, written for a reader who
did not watch the session.
