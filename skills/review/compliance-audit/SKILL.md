---
name: compliance-audit
description: "Compliance-audit: verify a finished implementation against its plan; a fresh-context verifier reruns the gauntlet. Not for claim audits (/mh:deep-audit)."
argument-hint: "[plan-path|pr-number|commit-range]"
disable-model-invocation: true
disable-model-invocation-reason: a done-declaration gate — the user decides when compliance is checked and what counts as compliant, not the model
model: inherit
effort: xhigh
---

# Implementation Compliance Audit

Prove a finished implementation matches the plan that was approved for it — every planned
requirement landed, no unexplained deviation, no regression. This is a conformance check against
a specific prior plan, not a general code review: quality/security/style lenses belong to
`mattpocock-skills:code-review`. Pre-code mirror image: `mh:plan-reviewer` reviews the plan before code
exists; this audits the diff after.

**When to use / not:** use after a plan-driven change. Don't use for an unplanned diff
(`mattpocock-skills:code-review`).

## Core Principles

- **Maker ≠ checker.** The agent that implemented the plan cannot be the sole grader of its own
  work — `docs/reference/operating-model.md`'s "The maker never grades its own work". Phase 2 dispatches a fresh-context
  verifier with no memory of the implementation session, primary on Codex — a different model
  family, not just a fresh context window.
- **Ground truth is the plan's text and the actual diff at a pinned commit** — not a summary of
  what you remember doing.
- **Falsify, don't rubber-stamp.** Deviations you already know about get pre-declared (Phase 2)
  and then checked against what the verifier finds independently — a pre-declared deviation the
  verifier also confirms is *justified*; one only you listed, with no sanctioning text or
  citable sign-off, is not accepted just because you said so first.
- **Per-item verdict, not a blended score.** Compliance is a checklist of booleans (CONFORMS /
  DEVIATED / MISSING / UNVERIFIABLE — the last for a requirement the gauntlet genuinely can't
  exercise, e.g. it needs a live external service; never used to paper over a verifier that
  didn't try), not a graded quality signal. Report the open count, not a percentage.
- **`pass` is never true on requirements alone.** It requires every requirement CONFORMS or is an
  *accepted* DEVIATED, **and** the gauntlet exits 0, **and** `scope_ok` is true, **and**
  `unexpected_files` is empty (a diff that touched something the plan never named). A gauntlet that
  can't be run (missing tool, timeout) is a failure to verify, never a skip-therefore-pass.
- **No remediation in this version.** A real gap gets reported, not silently auto-fixed — see
  Phase 3.

---

## Phase 1: Locate the Plan + Scope the Audit

**Goal**: identify what was actually approved, and pin the exact revision before spending any
verifier budget.

**Actions**:
1. Check whether the user supplied a plan path, PR number, or commit range. If not, prefer the
   plan already in this conversation's context — it survives even if the file on disk changes
   later. **Don't trust the plan file on disk as a fallback**: a later plan-mode entry in the
   same session can overwrite it in place, same filename (seen in four sessions, CC
   2.1.263-267), so mtime-newest can be stale. If neither
   conversation context nor the user's own words give a clear source, ask explicitly which plan
   to audit rather than guessing from a file on disk.
2. Extract every discrete requirement from the plan — numbered findings, phases, explicit "must"
   statements — into a flat checklist. This is the audit's ground truth.
3. Identify the diff to audit across **every** repo the plan touched (a multi-repo plan lists
   each repo separately). State explicitly, not just "the commit range": the plan's own
   version/source, the base SHA, and the head SHA.
4. **Pin the revision safely.** This session's own worktree keeps moving while it keeps working —
   a diff checked at one revision while tests run against another silently produces a wrong
   verdict. Create an isolated, non-moving checkout: `git worktree add --detach <path> <head-sha>`
   (cleaned up after Phase 2). If the pinned SHA can't be cleanly checked out, the verdict is
   "cannot verify" (`scope_ok: false`), never a silent pass/fail against the wrong tree. Keep
   this head SHA: the verdict covers only it, and Phase 3's ship step re-checks it with
   `scripts/check-head.sh`.
5. Present the requirement checklist in prose, plus any deviation you're already aware of. Gate
   with `AskUserQuestion` **only when the plan source is genuinely ambiguous** (multi-repo, no
   conversation context, no user-named path) — otherwise proceed; a wrong scope with one verifier
   is a cheap re-run. **Never enter plan mode for this**: it can overwrite the plan file being
   audited (step 1), and its read-only mode blocks step 4's worktree pin and the Phase 2 gauntlet.

---

## Phase 2: Pre-Declare, Then One Codex-Primary Verifier

**Goal**: separate "I already know this differs from the plan, here's why" from what the audit
must discover independently, then get an independent answer from a different model family.

**Actions**:
1. If you already know of deviations, list each with its reason — this is a lightweight
   paragraph, not a gate of its own. Carry it forward unopened; step 3 is where it gets checked,
   not asserted. Starts empty if you have no first-hand deviation knowledge — step 3 still
   catches anything real.
2. Dispatch **one** verifier at the pinned worktree from step 1.4. Primary: `codex exec --sandbox workspace-write
   --cd <worktree> --model <selected-model> -c model_reasoning_effort=<selected-effort>
   --output-last-message <file> --output-schema <schema-file>` (sandbox and cwd explicit, not the
   config-dependent default). `<schema-file>` is `references/verifier-output-schema.json` (this
   skill's own JSON Schema for `{contract_version, requirements[], gauntlet, scope_ok, unexpected_files[]}` —
   `mh:deep-audit`'s `checker-output-schema.json` is the pattern this copies). Select the
   model/effort through `docs/reference/codex-integration-map.md`: Terra/medium for explicit
   requirements, Sol/medium when interpretation is material. Resolve the tier to a slug, never
   type one: `python3 "${CLAUDE_SKILL_DIR}/../../../scripts/_lib/codex-resolve-model.py" <tier> --effort medium`
   with `<tier>` = `terra` for explicit requirements, `sol` when interpretation is material
   (non-zero exit: follow the map's substitution rule and say so); name the resolved slug in the
   report. Check availability and quota first.
   On rate-limit or Codex's absence, fall back to a Claude `general-purpose` subagent (no new
   bespoke agent type) — note "independence reduced for this pass" in the final report.
   - **Validate before trusting, on both paths.** Pipe the verifier's raw output (the
     `--output-last-message` file's contents on the Codex path; the agent's final message text on
     the Claude-fallback path) through `scripts/check-verdict.py <pinned-sha>` — the pinned SHA
     generated in step 1.4 is the script's *only* source of truth for cross-checking
     `gauntlet.sha` (the script never derives one; it runs on the host tree, where `HEAD` is the
     wrong ref). A verifier reporting a different SHA is rejected even if its object is
     otherwise schema-valid. Exit 0 = exactly one schema-valid verdict at the right SHA, with
     `pass` computed by the script itself, never read from the verifier's own claim. Exit 2 = the verifier returned `NEEDS-DECISION` instead of
     guessing — a valid non-guess, surface it to the operator. Exit 1 = malformed, ambiguous, or
     SHA-mismatched output; retry the dispatch once before treating it as "cannot verify"
     (`scope_ok: false`) — a rejected verdict must never reach Phase 3's report as if it were
     ground truth.
   - **Sandbox contract**: `workspace-write`, scoped *only* to the disposable worktree — never
     the session's own worktree it was pinned from (the gauntlet writes `__pycache__` and logs, so
     `read-only` is wrong). Before/after the run, diff the worktree's tracked files against the pinned SHA;
     any tracked-file change beyond expected build artifacts is itself a finding ("verifier
     modified source"), never a silent pass. The worktree is discarded after, so leftover
     untracked artifacts don't matter.
   - **A gauntlet failure can be caused by the sandbox itself, not the diff** (tests writing
     scratch state via `mktemp` outside the worktree fail under `workspace-write`). On any
     non-zero gauntlet exit, before reporting it as a finding: **the verifier itself** (never
     main, per the re-run rule below) re-runs the identical gauntlet command at the plan's base
     SHA, in the same sandbox, **in a second, separate detached worktree pinned at the base SHA
     (`git worktree add --detach <second-path> <base-sha>`), removed after the re-run — never by
     checking out the base SHA inside the worktree already pinned at head**: that switch is a
     tracked-file change the before/after check above flags, and the head-pinned worktree the
     rest of Phase 2 uses stays untouched. Identical failure at base → pre-existing/environmental, not
     this diff's regression → return `NEEDS-DECISION` naming the specific failing test(s) and
     both exit codes, per `references/verifier-brief.md`'s existing escape hatch, rather than
     either a silent pass or an unexplained `DEVIATED`. Base SHA passes cleanly in the same
     sandbox → the failure is real, report it as a genuine gauntlet failure, no exception.
   - **Don't redirect `TMPDIR`/scratch I/O into the worktree to "confine" it further** — the
     before/after tracked-diff check is the enforcement, and a temp dir inside a git repo breaks
     tests that assume otherwise (`tests/skills/memory-lint/test_memory_lint.py`'s not-a-git-repo
     test). Keep the normal temp-file defaults; only repo writes stay inside the worktree.
   - The verifier receives **only** its slice of the plan's requirements plus the pinned SHA —
     **not** your Phase 2 deviation list, **not** your narrative of what you did, and **never** a
     plan-file path (it may already hold this audit's own scope by the time the verifier reads it).
   - **Adversarial-completeness mandate** for any requirement whose own text names a security/
     gate/auth/validation surface — read `references/verifier-brief.md` before writing the brief:
     enumerate in-family bypass permutations from the actual validation code; in-family →
     downgrades the verdict, out-of-family → known-gap noted separately, not folded in.
   - The verifier **reruns the repo's real gauntlet command itself, in the pinned worktree** —
     don't trust an in-session "green" claim carried over from implementation, and don't have
     main re-run it directly (main reads and scores the returned output; the validator does the
     re-verification — the same crux this file names).
   - The verifier returns, per requirement: **CONFORMS** / **DEVIATED** (state what changed, and
     whether the justification is *accepted* — sanctioned by the plan/requirement text itself, or
     a **citable** sign-off, e.g. a backticked command or `path:line` — `check-verdict.py`
     mechanically rejects an *accepted* DEVIATED whose `note` is bare prose, not merely restated
     from the pre-declared list) / **MISSING** / **UNVERIFIABLE** (the gauntlet genuinely cannot
     exercise this requirement — never a substitute for actually trying). Plus: the exact
     gauntlet command run, the SHA tested, its exit code, and its **verbatim output or tail** —
     never a summary; losing this loses the property the agent was kept around for.
   - Escape hatch only, for genuinely large/multi-repo plans: fan out up to Rule 13's 10-per-wave
     cap, one verifier per natural boundary. Not the default — the common case (single-repo,
     single-phase) stays at exactly one verifier.

---

## Phase 3: Reconcile + Report (no remediation)

**Goal**: falsify the pre-declared deviations against the independent finding, then report — not
fix.

**Actions**:
1. **If more than one verifier dispatch happened for the same requirement** (a retry, or a
   second run for any reason) **and they returned different verdicts on it** (e.g. CONFORMS vs.
   DEVIATED on the identical pinned SHA/requirement): don't silently pick one. Read the cited
   requirement's actual hunk in the diff yourself, record **both raw
   verdicts** in the requirement's `note`, and default to `DEVIATED`/`accepted: false` unless
   reading the diff yourself clearly settles which run was right — a disagreement is itself
   evidence the requirement is closer to the line than a single clean CONFORMS would suggest.
   Compare the verifier's independently-found deviations against Phase 2 step 1's pre-declared
   list. Match on both sides *and* the justification is accepted → set that requirement's
   `accepted: true` **and write the sanctioning citation into its `note`** in a citation shape
   (a backticked command, or `path:line` — the plan-text location or sign-off commit that
   sanctioned it); `check-verdict.py` rejects an accepted DEVIATED whose `note` is bare prose,
   so the re-run below fails on a note that only says "matched the pre-declared list".
   Verifier found one you didn't list, or one you listed but couldn't sanction
   with plan text or citable sign-off → an unflagged/unaccepted gap; `accepted: false` (or leave
   `MISSING` as-is). This reconciliation step is the only hand judgment in Phase 3. Then **re-run
   `check-verdict.py` on the object with these `accepted` values applied** — this second run's
   `pass` is authoritative, since only it reflects Phase 3's reconciliation. Everything after this re-run (`pass`, the
   per-requirement table) comes from the script's output, not a second eyeball pass.
2. Report, in this order:
   - One-line verdict headline: N/N conform, open-item count.
   - Per-requirement table: **CONFORMS** / **DEVIATED (accepted)** / **DEVIATED (unaccepted)** /
     **MISSING** / **UNVERIFIABLE**. No blended percentage.
   - The gauntlet run's exact command, SHA, exit code, and verbatim/tail output.
   - `scope_ok` and any `unexpected_files[]` (diff touched something the plan never named).
3. **No automated fixer, no re-verify-only-the-touched-item in this version** (it could miss a
   regression the fix caused elsewhere). If real gaps are found, the report hands them back — fixing and re-running `/mh:compliance-audit` again is a separate,
   later invocation, not an automatic loop.
4. **Suggested next step**, read straight from step 1's Phase-3 re-run of `check-verdict.py`'s
   computed `pass` — never re-derived by eye here:
   - `pass` true → done; ship/merge if not already, but only after
     `bash "${CLAUDE_SKILL_DIR}/scripts/check-head.sh" <pinned-sha> <branch>` exits 0 (fetch
     first for a remote branch; for a PR, also pass `gh pr merge --match-head-commit
     <pinned-sha>`; where a repo ships its own merge script, run `check-head.sh` and that script in one
     command; the script pins the head it reads, so a small race remains). Exit 1 = the branch moved since the audit: the verdict does not cover the
     new head, so re-run `/mh:compliance-audit` before shipping.
   - `pass` false for any reason — an open requirement, a failed gauntlet, `scope_ok: false`, or
     a non-empty `unexpected_files[]` —
     blocks "done," even with a clean requirement table. Consider `mh:post-mortem` only if a gap
     reveals a systemic pattern, not for a one-off miss.

**Done.**

## Anti-Patterns

- Auditing from memory of "what I think I did" instead of the actual diff.
- Letting the implementing session's own verifier grade its own work — no fresh context, no audit.
- Treating a pre-declared deviation as accepted just because it was listed first.
- Reporting compliance as one blended percentage instead of a per-requirement verdict.
- Trusting "gauntlet was green during implementation" without re-running it fresh.
- Declaring done with an open MISSING or unaccepted DEVIATED still on the table.
- Entering plan mode to gate audit scope — risks overwriting the plan being audited, and its read-only mode blocks the worktree pin and gauntlet run (Phase 1).
- Running the verifier against the session's own live worktree instead of a pinned detached one.
