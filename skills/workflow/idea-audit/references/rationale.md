# idea-audit: design rationale

Why each rule in `SKILL.md` exists. Not needed to run the skill; read it before changing a rule.

## Contents

- Phase 0 and pre-flight
- Phase 1: saving the source
- Phase 1: analysts
- Phase 2: attacker dispatch
- Phase 3: scoring
- Phase 4: artifact

## Phase 0 and pre-flight

- Check 3 is a hard precondition, not a desirability judgment: Phase 1 cannot save a source that
  does not exist, so explicit invocation skips checks 1-2 only.
- Phase 0 searches `qmd` `llm-wiki` first because the operator's second-brain rule (`CLAUDE.md`,
  "Second Brain (llm-wiki)") requires it ahead of any web search for a research or citation
  question.
- The explicit pick exists because a wrong-source audit burns the whole Phase 1-3 pipeline (up to
  3 agents) on the wrong artifact; one confirmation question is far cheaper.
- `mh:ideate` output is out of scope: a freshly brainstormed idea has no external primary source,
  so every Phase 1/2 check would degrade to `Not independently checkable`.
  `agents/ideate-critic.md` scores ideate's own ideas instead.

## Phase 1: saving the source

- The host saves the source, not Agent A: a subagent pasting source text through its own
  dispatch prompt would itself break the untrusted-source rule.
- The scratchpad, never a repo-relative path: an in-repo scratch dir is untracked but not
  gitignored, trips `skills/meta/harness-audit/scripts/checks/70-stray-top-level-entries-working-tree-clutter.sh`'s
  allowlist, collides across concurrent sessions, and leaves untrusted text where a later
  session's grep could surface it unlabeled. A per-run `<slug>` avoids a collision when the skill
  runs twice in one session.
- Raw `curl`, not `WebFetch`: `WebFetch`'s HTML-to-Markdown extraction is lossy, and a
  model-processed derivative is exactly the paraphrase the untrusted-source rule routes around.
- `curl -f` exits non-zero and writes no file on a hard HTTP error (verified live on a real 404).
  The 2 KiB floor guards what `-f` misses: a soft failure that returns HTTP 200 with useless
  content (bot wall, login page, redirect stub). A short real source can trip it too, but a false
  trip only downgrades to `insufficient evidence`, which is cheaper than grading a bot-wall page as
  primary evidence.
- Agent A reads the saved copy because a second fetch can return different content (a paraphrase,
  another page revision), and Agent A and the attacker would then check two different texts.
- A post-hoc phrase mismatch means Agent A did not follow the read-the-saved-copy rule, not that
  the saved file is bad, so the fix is to distrust Agent A's claims, not to banner-downgrade the file.
- The quote cap exists because Agent A's report is pasted whole into the attacker prompt; any
  quoted source text rides into that instruction context. The cap shrinks that path; `checked[]`
  in Phase 2 is the real backstop.
- A real incident in this repo came from a checkable claim (session transcripts) that nobody
  checked before it shipped; hence "check what is checkable now" and "one instance is not
  verification".

## Phase 1: analysts

- `general-purpose`, not `Explore`: `Explore`'s own description warns against open-ended analysis
  and reads excerpts rather than whole files, which both analysts must avoid.

## Phase 2: attacker dispatch

- `<skill-dir>` must be absolute: `--cd <repo-root>` moves the cwd to the repo root, where a bare
  `references/attacker-output-schema.json` does not resolve (verified live).
- The attacker gets the source's absolute path because `codex exec --help` documents `--sandbox`
  as governing writes and `--add-dir` as adding writable dirs, with no flag for read access;
  nothing documents `read-only` as confining reads to `--cd` (inferred from the flag semantics, not
  live-tested). The Claude fallback's `Read` is unaffected by cwd.
- Citations use the relative filename because the absolute path embeds the operator's home
  directory, and `docs/research/` is the one directory the repo's home-path scans
  (`git-hooks/pre-commit`, `scripts/run-gauntlet.sh`) skip.
- `check-verdict.py` mirrors `mh:deep-audit`'s copy, adapted to the 4-key contract: no
  `scope_ok`/`unexpected_files`, since this attacker never touches the repo.
- `additionalProperties: false` stops a stray field, not a hand-wavy `evidence` string, hence the
  separate `check-citations.py` pass.
- `checked[]` closes the vacuous-pass gap: `{"pass": true, "findings": []}` is schema-valid and
  indistinguishable from an attacker told (by injected source content or otherwise) to skip
  verification.
- The fallback is `general-purpose`, not `mh:plan-reviewer`, which hard-stops when handed a summary
  rather than a plan artifact (`agents/plan-reviewer.md`).
- The Agent tool has no per-invocation `disallowedTools` (that field exists only in agent
  frontmatter), so the fallback keeps `Bash` and has no sandbox; the `git status --porcelain`
  diff is the behavioral backstop.

## Phase 3: scoring

- Table shape copies `docs/research/plan-mode-nudge-audit-2026-08-05.md`, the only fully
  Rule-14-compliant scoring instance in this repo.
- The doctrine file's 35/20/15/15/15 split carries no stated rationale; this skill does not repeat
  that gap, so every non-primary weight carries a one-clause justification.
- Primary-source fidelity must be strictly the largest weight: a confident total built on shaky
  evidence is the failure this phase exists to prevent.
- Floor trigger (2) generalizes the doctrine file's per-criterion floor (no criterion below 85).
  40% is this skill's own number because its axes and scale differ; state it in the artifact.
- Anchoring each score band raises judge consistency, not established correctness
  (`docs/reference/rubric-anchoring-evidence.md`).
- `weighted-score.py` is the same script `mh:deep-audit` uses, so "no hand sum reaches the output"
  is one mechanism.
- The MATCH/PARTIAL/GAP/N-A vocabulary is picked for consistency going forward, not asserted as an
  existing convention.
- Entity-normalized matching: HTML entities (`&#8217;` and the like) in a raw-fetched file
  false-negative a real match into a wrong `GAP`.

## Phase 4: artifact

- `docs/research/` is public and still under path hygiene, but the repo's pre-commit and gauntlet
  home-path scans skip it, so this skill is the only backstop for its own scratchpad-path citations.
- Memory dir comes from `scripts/_lib/memory-dir.py`, never from the live cwd: a linked worktree's
  cwd names a store that does not exist.
- No `docs/reference/mattpocock-integration-map.md` row: that table tracks 1:1 routing to a named
  matt skill; this composes on `mattpocock-skills:research`'s principle but is not a routing of it.
