---
status: accepted
---

# Operator-authorized Routine self-launch (narrow reversal of the no-model-self-launch invariant)

> **Status note (2026-10-22):** accepted; the `gate:tool:routine-trigger-guard` gate this ADR justifies ships. CI checks
> and `validate.yml` were removed 2026-10-03, so every premise below that relies on them is historical, and the
> "`status: proposed`" text below records the draft stage, not the current status.

`docs/adr/` restarted numbering below the legacy pre-rebuild set: `ADR 0006` (deleted, `git`-only —
see §1's `[R1 fix]` for the retrieval command), and `docs/research/adr-0009-bounded-review-fix-
auto-loop.md` / `docs/research/adr-0011-scheduled-recursive-improve-invocation.md` (both still
live). Cite all three by full path or retrieval command, never by a bare "ADR 0006" that could be
confused with a file under this directory. This ADR is the fourth attempt to touch the no-model-
self-launch invariant those three establish, and the third rejection's own revisit trigger names
exactly the condition that licenses trying again: *"a multi-reviewer adversarial pass before any
implementation, not a single drafting session's say-so"* (`adr-0011-scheduled-recursive-improve-
invocation.md`). This document is that draft; the adversarial pass it requires (§7) has not yet
run to a clean result, so `status: proposed` is not a formality here — nothing downstream of this
ADR may treat it as decided.

> **Wave 1 review, round 1 (2026-09-28): 5/5 REJECT, all evidence-cited, all verified live.** The
> single biggest finding, confirmed independently by all 5 reviewers: this document's earlier draft
> stated `develop` "now carries branch protection (Phase B)" in the present tense while the live
> GitHub API returned `protected: false` and a 404 on the protection endpoint — a real,
> unimplemented step in Phase B's own plan (B5), not a documentation typo. Applying real protection
> was the fix outside this ADR's own scope; it has now been done (verified via `gh api
> repos/wasikarn/matt-harness/branches/develop/protection`, 2026-09-28) and the repo's merge
> settings (`allow_squash_merge: false`, `delete_branch_on_merge: true`) were corrected to match
> what `docs/reference/branching-model.md` already claimed. Every other finding below is addressed
> inline, each marked `[R1 fix]`. This was round 1's fix pass; Wave 1 was re-run against this
> revision — see the round-2 block immediately below. That block, not this one, is authoritative
> on whether the pass is clean.

> **Wave 1 review, round 2 (2026-09-28): 5/5 REJECT — no `[R2 fix]` markers, because nothing below
> is fixed.** Round 1 fixed a live gap and a set of citation/framing defects. Round 2 found the
> credential-scoping premise §5 rests on does not exist as designed, plus several independent
> doctrine contradictions round 1 missed. Nothing in §1-§7 has been edited to address any of this;
> editing the prose without a real design would repeat the exact pattern that drew round 1's
> REJECTs. This block is a record, not a repair. `status: proposed` remains correct, and none of
> the findings below should be read as resolved until a future round explicitly says so.
>
> **The finding that invalidates §5's design, independently reached by 4 of 5 reviewers:** a
> Routine authenticates as the operator's own connected GitHub identity — `wasikarn`, this repo's
> sole collaborator and admin (`gh api repos/wasikarn/matt-harness/collaborators`) — not a
> separately-scoped credential. §5's fork-flow and scoped-PAT framing both address a threat model
> that does not match how Routines actually work: there is no per-Routine credential to scope in
> the first place. Compounding this: GitHub's merge endpoint requires `Contents:write`, the exact
> same permission needed just to push the branch — so any credential capable of doing the Routine's
> job can also call the merge endpoint once required checks pass (`required_approving_review_count`
> is 0). §5's stated reason for rejecting the scoped-PAT path (blaming `pull-requests:write`) is
> wrong; the real reason is that no scoping can separate "can push" from "can merge" on this
> platform. The fork-flow's prerequisite (a second, non-admin GitHub identity) is not just unmet —
> per Routines' own docs, the connected GitHub identity is account-wide, so satisfying it would mean
> reconnecting the operator's Claude account to a different GitHub identity for *every* cloud
> session, not scoping one Routine. §5 item 1's empirical test cannot currently be run on any viable
> path, and as specified it is vague enough to record a false negative (a 405 from failing branch
> protection reads identically to a real permission denial).
>
> **Other findings, independently evidence-cited, not previously named:**
> - The "Routines push only to `claude/`-prefixed branches" restriction §3/§4 rely on is a
>   prompt-level convention, not a mechanical platform control — any unprotected branch (everything
>   on this repo except `develop`) carrying only the operator's own commits accepts a Routine push
>   today.
> - The local `gh pr merge`/`gh api .../merge` ask-tier gate matches only the `Bash` tool; a
>   default-included MCP connector's own write tool (e.g. GitHub's `merge_pull_request`) is not
>   covered at all.
> - No threat model is stated for this being a **public repo**: a webhook-triggered Routine reacting
>   to an external fork PR runs with attacker-controlled content in context, the operator's own
>   admin identity, every connected connector included by default, and no approval step. The API
>   trigger's free-text field is a second injection path.
> - §1 claims the autonomous-loop drilldown's conclusion is "unchanged by this ADR," but that
>   drilldown explicitly declined the σ-band autonomous trigger §3 proposes building as a future
>   building block — a direct contradiction, not an omission.
> - §2's L4-machinery citation says the opposite of what it's cited for: the retired L4 design kept
>   a human-review gate before any push reached `origin`; this ADR's push-confirmation carve-out
>   (§3) removes exactly that gate. The `composer-not-creator.md` citation for the same bullet
>   doesn't mention launchd, cron, or self-start at all — the "platform-native, already-installed"
>   reasoning is unsupported by the doc it cites.
> - `docs/reference/operating-model.md:100` ("No autonomous loop: the model never starts work on its
>   own") directly contradicts this ADR and is not listed anywhere as superseded.
> - §2's "maker ≠ checker, retained unchanged" claim doesn't hold under inspection: `validate.yml`
>   runs on `pull_request` (not `pull_request_target`), so a Routine's own edited copy of that
>   workflow becomes its own required check, with no `CODEOWNERS` file and 0 required approvals
>   backing it up.
> - No value or benefit case is stated anywhere in this ADR — unlike this repo's own practice on
>   `ADR 0009`/`ADR 0011`, which required the operator to weigh a stated value case against the
>   invariant, not just hear that the operator wants it reversed. §6 (cost) is also left fully open,
>   and §7's acceptance criteria don't require a cost figure, a chosen trigger, or any of §5's items
>   2-6 before `accepted`.
> - §3's "none of these require an LLM to classify" claim is false for the eval-pass-rate candidate
>   trigger: 81 of this repo's eval cases use LLM graders (`type: llm`), so gating on that pass rate
>   reintroduces model judgment into the trigger, contradicting §2's own retained
>   no-model-confidence-as-trigger principle.
> - None of §3's four candidate trigger signals is a trigger type Routines natively support
>   (Schedule, API-POST, GitHub PR/Release events only) — bridging any of them in requires a new
>   Anthropic-issued bearer token stored as a repository secret, the exact kind of secret §6 already
>   says this repo deliberately doesn't carry. Half the "local-only" framing in §3 item 2 is also
>   inaccurate: `harness-audit` and the gauntlet already run on GitHub-hosted CI; only the
>   gate-verdict journal and `costs.jsonl` are genuinely local-only.
>
> **This round did not re-verify round 1's live fixes** beyond confirming branch protection and
> merge-settings are still live (they are) — round 2's reviewers independently re-checked those and
> found them holding.
>
> **Recommended next step, not yet actioned:** this is not a prose-fixable state. Two named revisit
> conditions, either of which would make a round 3 drafting pass worthwhile: (a) Claude Code's
> Routines platform gains a per-Routine scoped GitHub credential distinct from the account's own
> connected identity, or (b) the operator connects a second, non-admin GitHub identity to their
> Claude account, accepting that this changes every cloud session's GitHub identity, not only this
> Routine's. Absent either, the honest alternatives are: redesign around a scheduled-only,
> report-only mechanism with no push and no PR at all (removes §5 entirely, closes the public-repo
> injection vector, but is a different mechanism and still needs a stated value case); or proceed
> knowingly with the operator's own admin identity and no mechanical merge prevention — which is
> what `ADR 0006`/`ADR 0009`/`ADR 0011` each already rejected. Neither choice is this document's to
> make.

> **Operator-requested research + 2-round adversarial debate (2026-09-28): both sides converge on
> reject, superseding this block's two revisit conditions with three sharper, conjunctive ones.**
> Two fresh-context agents (FOR and AGAINST proceeding, each researching independently) wrote
> opening statements, then each read the other's opening and rebutted. Full transcripts are not
> reproduced here; this is the reconciled outcome, evidence-cited to what each side actually found.
>
> **The value case, checked directly for the first time.** FOR fetched
> `claude.com/blog/the-ai-native-sdlc-playbook` fresh and read the Stage 6 section end to end:
> every claimed benefit (faster triage, fewer missed 3am incidents, the three worked examples) is
> asserted with zero numbers. The only quantified evidence anywhere traces to a linked companion
> post (`claude.com/blog/ai-ci-cd-on-call`) — but that setting is Anthropic's own high-volume CI,
> run through Claude Tag in Slack with humans in the channel, and "a PR that the on-call can
> review, merge." **A human merges there.** That's Stage 6 with the exact control this ADR
> proposes removing — the upstream evidence doesn't support the reversal, it demonstrates the
> invariant the reversal would drop.
>
> **This repo's own CI has nothing to react to.** `gh run list --workflow validate.yml --limit
> 200` (2026-09-05 to 2026-09-28): 199 green, 1 red. `harness-audit-drift.yml`: 4 runs, all green.
> One red event in 23 days, handled by a human with no Routine involved. A σ-band trigger is
> mathematically undefined over a near-zero-variance series even if the missing control-band math
> (§3) were built today.
>
> **The identity finding is narrower than round 2 characterized it — a real correction, not just
> a restatement.** AGAINST fetched `code.claude.com/docs/en/routines` fresh: `git push` to a
> non-`claude/*` branch really is rejected if that branch is protected, has someone else's open
> PR, or carries commits from anyone but the operator — round 2's "prompt-level convention" framing
> was too pessimistic about push specifically. What stays open: PR/merge calls and connector write
> tools pass through via the GitHub proxy's REST fallback "with your real credentials
> substituted" — so push and merge still can't be separated, just not for the reason round 2
> originally gave. FOR's own proposed mitigation (a committed `Bash(git push*)` deny) was retracted
> in rebuttal once this surfaced: it would guard a path the platform already fences, while leaving
> the actual open path (API/connector writes) untouched.
>
> **Even the narrowest safe form has no value today.** Schedule-only + report-only + no connectors
> was the most defensible shape either side could construct. It still fails on two independent
> grounds that reinforce each other: an event trigger (e.g., a red `harness-audit-drift` run)
> needs a bearer-token repo secret this repo's own §6 already says it deliberately doesn't carry;
> a schedule trigger avoids that secret but then runs against a repo that's already green,
> diagnosing nothing. AGAINST's sharpest point: treating frequent red CI as the trigger for
> building this gets the causality backwards — frequent red runs in a repo with deterministic
> gates mean something is broken (a flaky test, gate drift), and the right response is fixing that,
> not automating a Routine to live with it.
>
> **Reopening bar, superseding this block's original two conditions — now three, conjunctive, not
> either/or:**
> 1. A concrete value case beyond ADR 0011's already-rejected "saves typing a command periodically."
> 2. A named, numeric red-CI-run threshold, met over a stated window, *after* flakiness/gate-drift
>    has been ruled out as the cause (not just "red runs happened").
> 3. A Routine's actual GitHub credential shown, empirically, to have no PR-open/merge/
>    connector-write capability — not merely a `git push` restriction, which the platform already
>    provides today.
>
> This closes the operator's explicit request to research further and have agents debate before
> deciding — the debate converged, unprompted, on the same "reject for now" both Wave-1 rounds
> already reached, but replaced this block's vaguer revisit conditions with ones an actual future
> reviewer can check against evidence rather than judgment.

> **`mh:deep-audit` on PRs #167-#170 (2026-09-28), baseline 6.8/10 (fail): 6 findings, all fixed
> in code/docs/memory, none fixable by editing this ADR's own earlier blocks — recorded here
> instead, per this document's own additive-only convention.**
>
> 1. **§5 item 6's gate shipped narrower than either §4/§5's own prose or the shipped 1.1.151
>    version described.** `CronCreate` was misclassified as a cloud-Routine trigger throughout —
>    the tool's own description says its jobs are session-only, in-memory, and die when the
>    session ends: it re-enqueues a prompt in the *same*, already-operator-attended session,
>    granting no new credential and starting no new session. It never belonged in this ADR's
>    threat model. Separately, the shipped gate asked on every `RemoteTrigger` call, including
>    pure reads (`list`/`get`/`list_runs`/`get_run_log`) that create or fire nothing. Both fixed in
>    `gate:tool:routine-trigger-guard` (now 1.1.153): matcher narrowed to `RemoteTrigger`'s
>    `create`/`update`/`run`/`create_webhook_trigger` actions only, `CronCreate` dropped entirely.
> 2. **§4's "nothing gates the model from creating or firing a Routine in the first place" and
>    §5's "None of items 2-6 ship with this ADR" are both now stale**, written before 1.1.151 shipped
>    the gate this paragraph names as unbuilt. Marked superseded here, not edited in place: item 6
>    has shipped, in the corrected/narrowed form above, independent of whether this ADR itself is
>    ever accepted — same as originally scoped.
> 3. **The round-2 block above cites `docs/reference/operating-model.md:100` for the "No autonomous
>    loop" quote; that quote is now at line 102** — an unrelated later edit (this gate's own table
>    row) shifted it by 2. Noted here rather than corrected in place, since line citations drift
>    again on any future edit to that file; re-verify at the cited line before trusting it, the
>    same rule this ADR asks of every other citation.
> 4. **For the record, not a new finding**: the 1.1.150 commit that added the round-2 block above
>    also edited two sentences inside the round-1 block's own text (the stale "Wave 1 has not yet
>    been re-run" forward-reference, corrected to point at round 2). That was a deliberate,
>    disclosed fix at the time, not a rewrite hidden after the fact — but it is a real, if narrow,
>    deviation from this document's stated convention that a dated block, once written, stays as a
>    historical record. No further instance of it has recurred since.

## 1. Decision and basis

**The operator has explicitly, directly instructed this reversal** — not a capability argument,
not a plausibility argument, not this document independently concluding the invariant should
move. `docs/research/autonomous-loop-doctrine-drilldown-2026-09-28.md` traced the full history of
why the invariant exists and found it structurally sound as of 2026 external research; that
conclusion is unchanged by this ADR. What changed is that the person who owns the decision said
to reverse it anyway, for reasons outside this repo's own evidence base (matching the article this
session originated from, "the AI-Native SDLC playbook"'s Stage 6 framing) — and `ADR 0006` already
states plainly that reopening this invariant **on a capability argument is still foreclosed**.
**[R1 fix] `ADR 0006` citation corrected**: it does not live under `docs/research/` — it was
deleted from `docs/adr/` entirely (`1acce027`, "remove all 14 ADR files, owner decision,
irreversible") and is retrievable only via
`git show 1acce027d9cb6080e57db6c354c210ea1e4ebfd9^:docs/adr/0006-ecc-aligned-operating-model.md`.
Verified this resolves and its actual line 64 reads: *"principle-bounded, not capability-bounded —
reopening them on a capability argument is still foreclosed"* — confirming the claim above is
accurate, not just the citation. Claude Code's Routines feature (§3) is named below only
as *mechanism* — what becomes possible once the operator's decision is implemented — never as the
*reason* for the decision. If this ADR is ever cited as "Routines exists, therefore reversed," that
citation is wrong; the correct citation is "the operator said so."

## 2. Superseded / retained

**Superseded, narrowly:** `ADR 0006`/`ADR 0009`/`ADR 0011`'s self-launch clause is superseded
*only* for the specific Routine path described in §3 below — a deterministically-triggered,
investigate-and-PR-only cloud session. Nothing else about those three decisions moves.

**Retained, explicitly, unchanged:**
- **Maker ≠ checker** (`docs/reference/operating-model.md` §2) — a Routine's own output is never
  self-graded; whatever review gate a PR normally goes through (`mattpocock-skills:code-review`,
  the gauntlet/harness-audit CI checks) applies to a Routine-opened PR identically to a
  human-opened one.
- **No model-confidence-as-trigger** — the same "two optimists agreeing" argument
  `docs/research/autonomous-loop-doctrine-drilldown-2026-09-28.md` Finding 4 documents (4
  independent same-day rejections of confidence/criticality-gated runtimes, 2026-07-01) applies
  with full force to any Routine trigger design. §3 names only deterministic triggers for exactly
  this reason.
- **No auto-merge** — a Routine may open a PR; it may never merge one. This is retained from
  Phase B's own design (`docs/reference/branching-model.md`), not newly invented here.
- **No push to `develop`** — Routines are mechanically restricted to `claude/`-prefixed branches
  and rejected on protected branches by the platform itself (not an mh-side control — see §4), and
  `develop` **now genuinely carries branch protection** — `[R1 fix]` this was previously stated as
  fact while still unapplied (Wave 1's central finding); applied and verified live 2026-09-28
  (`gh api repos/wasikarn/matt-harness/branches/develop/protection`: `enforce_admins: true`,
  the 3 CI checks required with `strict: true`, force-push/deletion disabled).
- **No custom launchd/cron self-start machinery** — composer-not-creator
  (`docs/reference/composer-not-creator.md`) still applies; a Routine is a platform-native,
  already-installed mechanism, not a bespoke one this repo builds and maintains. The retired L4
  autonomy-ladder machinery stays dead — this ADR does not resurrect it or anything shaped like it.
  **[R1 fix] citation corrected**: the earlier draft pointed at `docs/reference/repo-gotchas.md`,
  which doesn't reference this file at all — the design doc is `docs/research/
  l4-machinery-design.md` directly (confirmed present on disk).

## 3. Mechanism, stated honestly

**Trigger:** deterministic only, never a model-computed aggregate or self-report. Candidate
triggers, each already a real, already-emitted signal in this repo: `harness-audit`'s CRIT count
crossing zero, the gauntlet's own exit code, an eval suite's pass rate crossing a fixed threshold,
the gate-verdict journal's `ask`-count over a window. None of these require an LLM to classify
"is this significant" — matching the boundary condition two dedicated research passes checked
before this ADR was drafted (grader/scoring mechanisms; judgment/decision-making mechanisms, both
dispatched earlier in this same session, feeding directly into the approved plan this ADR
implements — **[R1 fix]**: the earlier draft cited these as saved `docs/research/*.md` files; no
such files exist, only the plan and this session's own transcript carry that research, so this is
an author-asserted claim, not an independently-citable one, until a proper research doc is written
and saved). The finding itself: the article's own gates are fully deterministic threshold
crossings or a *separate* adversarial agent's verdict, never the acting model's own confidence
report. That finding is what makes this mechanism section defensible at all — if the article's
gates had turned out to be self-report-gated, this ADR would not be written this way. **Follow-up
required before Wave 1 re-runs**: either write up that research as a real `docs/research/*.md`
file, or drop this specific framing and rest the deterministic-triggers design on §3's own stated
triggers alone (which don't need the article's own gates to be deterministic to be valid — they
already are).

**Two building blocks this repo does not have today, named plainly, not glossed over:**
1. **No rolling-baseline/control-band math exists anywhere in this repo.** A σ-band trigger (mean
   ± N standard deviations over a rolling window) is new subsystem work — a metrics-history store,
   a baseline computation, a drift/threshold check — not a wire-up of something already built.
2. **The metrics that would feed a trigger are local-only** (`~/.local/share/kbg/metrics/
   gate-decisions.jsonl`, `costs.jsonl`, and this repo's own gauntlet/audit exit codes, all on the
   operator's machine). A cloud Routine session cannot read them as they stand today. Either the
   trigger fires from a mechanism a cloud session *can* observe (a scheduled interval, a GitHub
   webhook on a release/PR event — both natively supported by Routines), or this repo's local
   metrics need their own export/sync design before a metrics-driven trigger is buildable at all.
   This ADR does not resolve which; it is a prerequisite for choosing a metrics-driven trigger,
   named so it isn't silently assumed solved.

**Output, unconditionally:** investigate → push to `claude/<slug>` → open a PR → **never merge**.
The PR is subject to the same required status checks on `develop` as any other PR (now genuinely
live — see §2's `[R1 fix]`). **[R1 fix] two claims corrected, not just softened:**
- *"Sits exactly where any other PR sits"* is false for §5's own recommended fork-based flow
  specifically: this repo's Actions settings require first-run approval for a first-time
  contributor's fork PR (`gh api repos/wasikarn/matt-harness/actions/permissions/fork-pr-
  contributor-approval` → `first_time_contributors`) — a fork-originated Routine PR does not run CI
  until a maintainer approves the run, an extra step a same-repo `claude/`-branch PR doesn't need.
  Not a flaw, but the ADR should describe the real flow, not a flow that treats fork and same-repo
  PRs as identical.
- *"...and to human review before anyone... merges it"* overstated what branch protection actually
  enforces here: `required_pull_request_reviews.required_approving_review_count` is **0**, a
  structural necessity for a single-maintainer repo (GitHub refuses to let a PR author approve
  their own PR, so any count ≥1 would make every PR permanently unmergeable — `~/.claude/CLAUDE.md`
  names `wasikarn` as the only account). This means **no approval is mechanically required to
  merge** — only the 3 status checks passing. "Human review before merge" is this repo's own
  operating custom, not something branch protection enforces. §5 (credential-scoping) is therefore
  the *only* thing standing between "checks passed" and "merged" for a credential with write
  access — not a backstop behind human review, the sole mechanism.

**Push-confirmation carve-out, named explicitly:** the global "confirm before every push" rule
(`~/.claude/CLAUDE.md`, `# Git`) is written for an interactive session with an operator present to
ask. A Routine session has no operator present by construction — confirmation is structurally
impossible, not merely inconvenient. This ADR carves out exactly one exception: a Routine session
may push unconfirmed, but *only* to a `claude/`-prefixed branch, never to `develop` or any other
branch. This carve-out is the ADR's own explicit grant, not a silent gap in the global rule.

> Correction (2026-09-29): the global rule this carve-out names changed on 2026-09-28. Push no
> longer requires confirmation by default (`~/.claude/CLAUDE.md`, `# Git`; only a known
> deploy-on-push branch is hard-blocked), so the carve-out has nothing left to grant. The
> `claude/`-prefix restriction still stands as this ADR's own scope limit.

## 4. Enforcement reality

**Stated plainly, not softened:** mh's own PreToolUse/Stop hooks (`hooks/gates/*.py`,
`hooks/hooks.json`) almost certainly do not run inside a cloud Routine session at all. Routines
are a Claude-hosted execution environment, not a local Claude Code CLI invocation with this
repo's plugin loaded the way an interactive session or a `claude --worktree` session is. Every
gate this repo has built — `gate:bash:irrecoverable`'s new `gh pr merge` ask-tier rule (Phase B),
`gate:agent:subagent-spawn-guard`, all of it — assumes a Claude Code session with mh's hooks
wired in. **None of it constrains a Routine.**

What *does* constrain a Routine is the platform's own restriction (Routines push only to
`claude/`-prefixed branches, rejected on protected branches) plus whatever the Routine's own
GitHub credential is scoped to do — which is §5's job, not this section's. Branch protection on
`develop` (`enforce_admins: true`, the 3 status checks required with `strict: true` — **[R1 fix]**
applied and live-verified 2026-09-28, not merely planned) blocks a direct push from *any*
credential, Routine or human, admin included short of editing the protection rule itself — but it
does not, and cannot, stop a sufficiently-scoped credential from calling the merge API on a PR that
already passed its checks (and, per §3's `[R1 fix]` above, passing checks is *all* that's
mechanically required to merge on this single-maintainer repo — there is no required-approval
backstop). That gap is exactly what §5 must close before this ADR could ever move past `proposed`.

**[R1 fix] A fourth gap, not previously named: nothing gates the model from creating or firing a
Routine in the first place.** `grep -rn "RemoteTrigger\|CronCreate" hooks/hooks.json hooks/gates/`
returns zero matches — no PreToolUse gate exists on either tool. This doesn't contradict
"deterministic triggers only" (§3) as a *design* — nothing about a Routine's trigger condition
becomes model-computed — but it does mean the *creation* of a Routine, today, is unconstrained by
mh: an interactive session could call `RemoteTrigger`/`CronCreate` with no ask-tier friction at
all, the same gap Phase B closed for `gh pr merge` but never extended to these two tools. This is
now item 6 in §5's mandatory-before-implementation list.

**[R1 fix] Named residual risk, not a gap this ADR closes**: `validate.yml` runs on `pull_request`
(not `pull_request_target`), so a same-repo `claude/`-branch PR's own edited copy of that file runs
for its own check. The repo's Actions settings (`default_workflow_permissions: read`,
`can_approve_pull_request_reviews: false`) cap what any workflow-issued token can do regardless of
what the PR's edited `permissions:` block asks for — this closes the specific "escalate to a
merge-capable token via a workflow edit" path a bypass reviewer raised. It does **not** close a
narrower one: a same-repo PR could edit `validate.yml` to silently weaken what `gauntlet`/
`harness-audit` actually check, making a required check pass falsely on genuinely bad content.
Nothing here detects that today; it's the same class of risk as §5's yet-to-be-built alerting
(item 4), not a new mechanism this ADR needs to invent.

## 5. Credential-scoping design (required before any implementation)

**No implementation may ship until this section's empirical test (item 1) has actually run and
passed.** Naming an intended scope is not evidence it holds — GitHub's actual API permission
semantics are the ground truth, not this document's expectation of them. **[R1 fix] resolving the
§5/§7 circularity 3 reviewers independently flagged**: item 1's disposable test is explicitly
authorized to run *while this ADR is still `status: proposed`* — it needs a throwaway credential
and a throwaway PR, neither of which requires the ADR itself to be accepted first. §7's acceptance
criteria now require this item's *recorded result* (§7 below) — acceptance was never meant to
happen with §5 still just a design on paper; the earlier draft simply failed to say so explicitly
in §7 itself, which is the actual defect, not the sequencing.

**Recommended default: fork-based flow.** The Routine authenticates as an identity that pushes to
its *own fork* of this repo and opens a PR back to `wasikarn/matt-harness`, the same shape any
external contributor without write access uses. This is structurally different from a scoped
token with write access to the main repo: a fork-based credential never holds write access to
`wasikarn/matt-harness` at all, so it cannot merge into it, full stop — not "is scoped not to,"
but "cannot, because it was never granted write access to this repository in the first place."
**[R1 fix] a real, currently-unmet prerequisite, named by 3 of 5 reviewers independently and not
previously stated in this ADR**: a fork-based flow requires a GitHub identity *distinct from the
operator's own account*. `~/.claude/CLAUDE.md`'s `# Git` section names exactly one account,
`wasikarn` — an account cannot fork its own repository into itself, and `wasikarn` is this repo's
owner/admin. **This recommendation is not viable until the operator creates and connects a second,
non-admin GitHub identity for the Routine to authenticate as.** Until that identity exists, item 1
below cannot even be attempted for the fork-flow path — only the scoped-PAT alternative (already
named as a rejected candidate pending its own empirical test) is currently testable at all.

**Why a fine-grained PAT scoped to `contents:write` + `pull-requests:write` is not (yet) a viable
alternative:** GitHub's fine-grained PAT permission model does not cleanly separate "can open/push
to a PR branch" from "can merge a PR" the way this design would want — `pull-requests:write`
covers PR-related actions more broadly than this ADR's threat model wants to grant. Until someone
verifies empirically, with a real token of that exact scope, that it genuinely cannot call the
merge endpoint, it stays a rejected candidate, not a pending one.

**Mandatory before `status: accepted`:**
1. Stand up the actual credential (fork-based, or the scoped-PAT alternative if someone later
   proves it safe) and, with a real token of that exact scope, attempt to call the merge endpoint
   against a disposable test PR. Record the result (denied with what error, or — if it
   unexpectedly succeeds — this ADR is not ready and that finding blocks acceptance outright).
2. A budget cap and rate limit on Routine invocations — none exists today in any form.
3. A kill switch: a documented, fast way for the operator to disable every scheduled/triggered
   Routine immediately (at minimum: `/schedule` list + delete, or revoking the Routine's
   credential — whichever is faster to execute under pressure).
4. Alerting on a fired Routine — the operator should learn a Routine ran without having to go
   looking for it.
5. An incident runbook — what to do if a Routine's PR is wrong, if its credential leaks, or if it
   fires more often than intended.
6. **[R1 fix, new item]** An ask-tier PreToolUse gate on `RemoteTrigger` and `CronCreate` (§4's
   `[R1 fix]`), matching the shape of Phase B's `gh pr merge` gate — closes the "nothing gates a
   model creating a Routine in the first place" gap for interactive sessions (same local-only
   caveat as every other mh gate in this ADR: it constrains a human's own session, not a Routine
   that already exists).

None of items 2-6 ship with this ADR. They are named here as what the eventual implementation
must include, not built now — Phase C is explicitly ADR-drafting and review-scheduling only.

## 6. Cost

Routines are recurring, paid, cloud-hosted sessions — a different cost shape from an interactive
session's usage. This repo has an existing, closely analogous precedent: the earlier decision to
skip `claude-code-action` automated PR review in CI specifically because it needs a paid Anthropic
API secret this repo doesn't carry (Phase B's B4/B5 notes, `docs/reference/codex-integration-map.md`).
**Left open, deliberately** — this is exactly the kind of criterion the adversarial review in §7
should weigh with real numbers (expected trigger frequency × per-invocation cost), not something
this drafting pass pre-decides by assertion.

## 7. Mandatory adversarial review (this repo's own established reversal protocol)

Matches `ADR 0009`'s precedent (5 fresh-context reviewers + 2 rounds of cross-ADR adversarial
review — the most scrutiny any single decision in this lineage has received) and satisfies
`ADR 0011`'s own revisit trigger verbatim.

**Wave 1 — 5 fresh-context reviewers, main-session-dispatched only** (inside Rule 13's per-wave cap: 5 when this was written, 10 since 2026-10-05),
each a distinct lens:
1. **Doctrine-fidelity** — does this ADR actually retain everything §2 claims it retains, checked
   against the live repo, not against this document's own assertions?
2. **Steelman-against** — the strongest case this ADR should not be accepted at all, argued in
   good faith.
3. **Implementation-feasibility** — is §3's mechanism (deterministic triggers, the two named
   missing building blocks) actually buildable as described, or does it hide a third missing
   piece?
4. **Bypass/incident** — concretely, how could a Routine (or its credential, or its trigger) be
   made to do something this ADR forbids, despite §4/§5's stated controls?
5. **Gate-sufficiency** — do Phase B's existing gates (branch protection, `gh pr merge` ask-tier)
   plus §5's credential design actually add up to "cannot merge its own PR," or is there a gap
   none of them individually cover?

**Waves 2-3 — cross-ADR adversarial passes** against `ADR 0006`/`ADR 0009`/`ADR 0011` specifically:
does this ADR's narrow supersession in §2 actually hold up against each of those three documents'
own stated reasoning, not just against a summary of them?

**Acceptance criteria:**
- No unresolved REJECT verdict from any wave.
- A REJECT must cite a specific file/behavior/line, not a general objection — an evidence
  standard, not a veto by assertion.
- **[R1 fix, closes the §5/§7 circularity 3 of 5 Wave-1 reviewers independently flagged]** §5
  item 1's empirical merge-endpoint test must have been run, with its actual result (denied — with
  what error — or unexpectedly succeeded) recorded in this ADR as a dated addendum, before
  acceptance. This does not require the *rest* of §5 (items 2-6, the runbook/alerting/gate
  machinery) to be built first — only that the one load-bearing empirical fact §4 rests the whole
  enforcement argument on has actually been checked, not merely designed.
- **Owner and timeout, so this cannot deadlock:** the operator is the named owner for breaking any
  stalemate a REJECT creates; a review wave that has not converged within a reasonable, explicitly
  time-boxed window escalates to the operator for a direct decision rather than looping
  indefinitely.
- Only once every wave's REJECTs are resolved *and* the operator gives explicit sign-off does
  `status: proposed` move to `status: accepted`.

**Explicitly out of scope even after acceptance:** building the actual Routine, its trigger
wiring, or the credential itself is a separate, later, independently-gated piece of work — this
ADR's acceptance authorizes starting that work, it does not constitute having done it.
