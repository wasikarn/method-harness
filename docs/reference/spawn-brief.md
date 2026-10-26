# Spawn brief

The shape every dispatched subagent prompt takes. Short on purpose; the constraints line is METHODOLOGY Rule 13.

```
# Task: <one line>
[role: builder|validator|fixer|re-validator|research|other]

## What
<the deliverable, in the dispatcher's own words; tracker text paraphrased, never pasted>

## FILES YOU OWN
<explicit paths; everything else is read-only>

## Done-when
<observable and pre-stated before starting: exit status plus a task-relevant assertion on the
output — a literal string, a count (tests run/failed/skipped), or a structured field, whichever
fits. Exit 0 alone is not evidence (a skipped suite exits 0). A file existing is not evidence
either — check the content that has to be there, not just presence, or a stale file passes free.
Exercise a negative control before trusting an absence claim (a check that fails on a known-bad
input); measure a stated number independently before writing it into Done-when as its own proof.>

Builder/fixer: before returning, re-read your diff once against Done-when's own assertions and fix
what's cheap to fix. This is a private pass, not the pass/fail decision, and you don't report having
done it — the fresh-context validator still independently re-verifies every claim, and its brief is
never narrowed on the strength of "already self-checked."

Validator/re-validator: return `{pass, findings[], checked[], scope_ok, unexpected_files[]}` and
nothing else (bar the `not_checked:` line below); `checked[]` holds ≥1 `{claim, evidence}` even on a clean pass — this is where
Rule 13's "one checkable fact" lands, and an empty `checked[]` is not verified, same as a missing
field. `scope_ok` fails on either an unexpected file or an owned file the diff never touches.
Scope the validator had no access to goes on one `not_checked:` prose line outside the JSON (the
`mh:plan-reviewer` `not_reviewed` pattern, which that agent keeps in its own output block), never inside the JSON object; where a brief demands JSON only (a schema-bound checker such as `mh:deep-audit`'s), name it in a `checked[]` claim instead. A Done-when assertion it could not
verify is never listed there: that is `pass: false` or `NEEDS-DECISION`.
Dispatching `mh:plan-reviewer` specifically: it has no calling skill of its own to embed this in
as a mandatory step, so the dispatcher must remember it here — pipe
`{"findings": [{"severity": ...}, ...], "top_blockers_count": <int>, "verdict": "..."}` through
`scripts/_lib/plan-verdict-check.py` (repo root) before trusting the verdict. It catches
`production-ready` alongside a real blocker. `findings` is the agent's full `findings:` list, each item projected to `{"severity": ...}` only
(the script rejects any other key, such as `lens` or `finding`);
`top_blockers_count` is the full Critical+High tally, never `len(top_blockers)`, whose display
list is capped at 10. The script does not check `not-ready`, which needs judgment.

Constraints: stage by explicit path only, never stash/reset/checkout/add -A; delete with `trash`;
return `NEEDS-DECISION <question>` instead of guessing; a ruling made within your own authority
(not escalated) states it inline in your final message as `Ruling: <what>—<why>—<cost if wrong>`
(no separate log — the orchestrator reads it from your return value); cite one checkable fact per
claim — illegible evidence is unverified, not absent; before returning, stop every background
job or wait loop you started (a finished validator once left an `until ... sleep` loop running);
in a repo that has `scripts/merge-pr.sh` (method-harness does), merge through `scripts/merge-pr.sh <PR>`,
not bare `gh pr merge`, and do not bump the version in the PR: the script cuts it at merge time, run
from the PR's checkout in the background (`branching-model.md`, "Merging").
```

When the brief goes to Codex (`/codex:rescue`), name the reasoning effort as an invocation flag,
`--effort <none|minimal|low|medium|high|xhigh>` (the set `codex@openai-codex` 1.0.6 validates;
`none` and `minimal` pass the plugin, but no model in the live catalog lists them, so pick from
`low` to `xhigh`), never as a line inside the task text: the rescue agent strips runtime flags from the prompt and a
prose `REASONING:` line reaches nothing. Omitting the flag runs the operator's configured default;
say so when you relay the result. Model and effort are the dispatcher's call, never the lane's.
Select both using `docs/reference/codex-integration-map.md`'s task/account-cost table. This
operator-authorized policy permits explicit `--model <selected-model> --effort <selected-effort>`
on rescue dispatches; bounded verification starts at Terra/medium, adversarial judgment at
Sol/medium. Escalate effort for a concrete reasoning need, not merely the word "audit".
The live Codex catalog also lists `max` and `ultra`, but this plugin rejects both.
Empty-diff handling: `docs/reference/codex-integration-map.md`, "Silent-refusal gotcha".

Dispatching a Claude subagent (`Agent`): default is no `model:` override, running the agent's own
frontmatter pin. Override only for **independence** (a verifier/reviewer pinned to the same model
as the live main session gets a different one — `agent-authoring-conventions.md` item 4) or
**stakes** (a Rule 1 one-way-door review escalates a sonnet-pinned reviewer to `opus`). The
`model` parameter takes only `sonnet`, `opus`, `haiku` or `fable`, and a same-family alias
resolves to the main session's exact model, so an opus-pinned verifier under an Opus main session
has no independent override here; use the Codex lane. Never override to `fable` (same reason
check 21 WARNs on a `fable` agent pin) and never downgrade a pin to save cost. Unlike Codex, the
Agent tool has no per-dispatch effort. A subagent runs its frontmatter `effort:` when it has one
(every mh agent does, check 54), unless `CLAUDE_CODE_EFFORT_LEVEL` is set, which outranks it;
`maxEffortLevel` or an org cap still clamps it. An agent without `effort:` (a built-in
`general-purpose` or `Explore`) takes an explicit session `--effort` or `/effort`, else its own
model's configured or default effort. To change an mh agent's effort, edit its frontmatter, not
the dispatch.

A fixer brief carries the validator's `findings[]` verbatim and narrows FILES YOU OWN to the files
the findings name; a returned unit that may touch anything grows into a diff nobody reviewed.

Launch a wave's Agent calls together, before reading any of their results: dispatching one, waiting
on it, then dispatching the next serializes what Rule 13's per-wave cap assumes runs concurrently.

If a wave's launch fails partway — an Agent call itself errors rather than a subagent returning a
finding — do not read results from the launched subset as if the wave completed; note which leaves
never launched and either retry them or say so plainly in the report.

When two leaves' FILES YOU OWN sets aren't disjoint — one owns a path that is an ancestor or
descendant of the other's, or they name the same file — dispatch them sequentially instead of
trusting a glance across the wave.

## Isolated checkout dispatch (opt-in pilot, 2026-09-28)

A subagent normally shares its parent session's live worktree (`docs/reference/branching-model.md`,
"Concurrent sessions") — file-collision risk is handled by FILES YOU OWN discipline and sequential
dispatch, not filesystem isolation. For a **builder** dispatch that already trips Rule 13's
validator requirement (2+ files, or adds a test), the dispatcher may instead give it its own
worktree, reusing `skills/review/compliance-audit`'s existing disposable-worktree pattern
(`docs/reference/codex-integration-map.md`'s compliance-audit row) rather than inventing a new
mechanism — the difference is this pilot merges its result back; compliance-audit's verifier
worktree is always discarded.

1. **Create** (dispatcher, before launching the Agent call): commit any pending edits to files the
   builder needs — `git worktree add ... HEAD` branches from the last **commit**, not the live
   working tree, so an uncommitted edit is invisible to the builder unless committed first. Don't
   use `git stash` for this: a stash resets the working tree to HEAD before the worktree is
   created, so the edit is parked in `refs/stash`, not in the commit the builder branches from —
   the same failure this step exists to prevent, just reached through a different command. If
   committing isn't possible for this dispatch (e.g. a
   pre-commit gate would block a half-finished edit), the pilot doesn't apply here; use the
   shared-tree model instead. Then `git worktree add <path> -b subagent/<slug> HEAD` — a real
   branch, not `--detach` like compliance-audit's read-only verifier pin, because this one needs
   somewhere to commit onto. `<path>` under `.claude/worktrees/` (gitignored, matches the
   session-level convention). Record `<base-sha>` = `git -C <path> rev-parse HEAD` right after —
   steps 3 and 4 both use this value.
2. **Brief**: FILES YOU OWN names paths under `<path>`, given as absolute paths (Read/Write/Edit
   have no cwd concept) or with an explicit `cd <path> &&` prefix on every Bash git command. The
   subagent commits its own work there — `gate:bash:subagent-git-guard` only denies
   `stash`/`reset`/`clean`, `git add`/`git commit` inside the worktree are unaffected.
3. **Validate**: first `git -C <path> status --porcelain` must be empty — an untracked or
   uncommitted file in the worktree is invisible to the diff below and can make `worktree remove`
   refuse later (step 4); if not empty, that's a validator-reject (step 5), not a pass. The
   fresh-context validator then reads `git -C <path> diff <base-sha>..HEAD`, not the shared tree —
   `scope_ok`/`unexpected_files` are computed against that diff. Record the exact SHA validated
   (`git -C <path> rev-parse HEAD`) — step 4 merges that SHA, never the bare branch name, so a
   commit added to the branch after validation can't ride along unreviewed.
4. **Clean completion** (validator `pass: true`): dispatcher re-checks `git -C <path> rev-parse HEAD`
   still equals the SHA step 3 validated (reject and re-validate if it moved), then runs
   `git merge --no-ff <that-sha> -m "Merge subagent/<slug> @ <that-sha>"` from its own worktree —
   naming the branch in the message, since merging a bare SHA otherwise drops it from history.
   **If the merge fails:** check `git rev-parse -q --verify MERGE_HEAD` first — only a real
   conflict sets it, and only then does `git merge --abort` apply; a dirty-tree preflight refusal
   (the dispatcher's own tree wasn't clean) never sets MERGE_HEAD, so there's nothing to abort —
   commit the dispatcher's pending edits (not stash — step 1) and retry the merge instead. Either
   way, a failed merge falls
   through to step 5's "leave it, don't discard" handling; it is not a clean completion. Only on a
   merge that actually succeeds: `git worktree remove <path>` and `git branch -d subagent/<slug>`
   — if either refuses (e.g. an untracked file step 3 should have caught), treat it as a step 5
   case rather than forcing it.
5. **Validator reject**: follow Rule 13's normal loop first — dispatch a fixer *into the same
   worktree*, FILES YOU OWN narrowed to the findings per this doc's fixer-brief convention above;
   re-validate against the cumulative `git -C <path> diff <base-sha>..HEAD` (the original builder's
   files plus the fixer's), not just the fixer's own diff, or the builder's untouched files
   spuriously trip `unexpected_files`. Stop after 3 rounds same as any other builder/validator
   cycle. Only once that loop is exhausted, or the dispatch was cancelled/interrupted, or step 4's
   merge itself failed, does it become an operator decision: do not merge, leave the worktree in
   place, say so in the report — mirrors a retained clone on non-clean completion. Never
   `git worktree remove --force` or `trash` it without being asked; an unmerged worktree is
   someone's unlanded work, same as any other uncommitted state this repo already treats carefully.

Revisit whether this earns a dedicated helper (script or skill) only if it sees repeated real use —
`docs/research/oh-my-openagent-adoption-audit-2026-09-28.md`'s own adoption audit scored this the
one mechanism worth a pilot, not a default.
