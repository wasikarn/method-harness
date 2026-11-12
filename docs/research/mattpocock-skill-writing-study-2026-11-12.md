# How mattpocock-skills are written (2026-11-12)

**Date:** 2026-11-12
**Source:** `mattpocock-skills` 1.3.2, read from the local plugin cache
(`~/.claude/plugins/cache/mattpocock/mattpocock-skills/1.3.2/`): all 38 `SKILL.md` files, their sibling files, and
the repo's own authoring docs (`AGENTS.md`, `SCOPE.md`, `.agents/`, `.out-of-scope/`, `docs/`).
**Why:** mh skills have a median body of 1,094 words; matt's is 548. The question was whether writing a skill short,
matt's way, makes it score better or cost less than the long form.
**How it was read:** two read-only subagents, one for the 20 `engineering/` skills and one for the other 18 plus the
repo rules. Sections 4 and 5 are their reports, edited only to remove tool wrappers. Every quoted string was then
searched for in the 1.3.2 cache by script (145 fragments); each one was found, allowing for line wraps and markdown
marks.

## 1. What to do when writing or shortening a skill

1. **Delegate in one line.** Name the skill and stop: `Call the Skill tool with "grilling"`. Do not restate what the
   callee does. Say whether the call is a session to run or a reference to consult.
2. **End each step on a "Done when".** One artifact or one checkable state per step, not a quality bar.
3. **Move formats, templates and examples to sibling files.** `SKILL.md` keeps the process. The pointer names the
   question the file answers and sits where it is used ("Use the format in ...", "Copy ... to the repo root").
4. **Few prohibitions, each with its reason.** Write a rule only for a failure seen in a real session (`SCOPE.md`).
5. **No failure handling unless it guards a real hazard.** Most matt skills say nothing about errors or retries.
6. **A user-invoked skill is a thin wrapper.** `grill-me` is one line; the reusable discipline lives in a
   model-invoked skill other skills can call. 23 of 38 set `disable-model-invocation: true`.
7. **Leading words in place of procedure.** Name the concept once (frontier, design tree, fog of war) and let the
   agent sequence the work.

Two rules for a rewrite of an existing skill, from the pilots below:

- **Move a contract, never drop it.** A command line, an exit-code rule, an output key or a file a script reads stays
  word for word, in `SKILL.md` or in a sibling file the step points at.
- **One skill per PR, measured before and after** on cases that check the end state, with the decision rule written
  before the run.

The full style guide is matt's own `writing-for-agents` skill (`skills/productivity/writing-for-agents/SKILL.md` and
`SKILL-MECHANICS.md` in the cache). Read that before this file's summaries.

## 2. What the measurements say (read before shortening for cost)

Shorter text did not make a skill cheaper or better in either pilot. Cost follows the number of steps the skill makes
the agent take, not the number of words.

| Pilot | Long | Short | Outcome | Cost per with-arm run | Turns |
|---|---|---|---|---|---|
| mh `deep-audit`, 2 cases, 3 runs per arm (this session) | 2,412 words | 1,266 words | 5/5 vs 6/6 (one long run timed out and is excluded) | 1.58 vs 1.84 USD | 8-10 vs 13-16 |
| siang `humanize`, 2 cases, 5 runs per arm (reported by the siang session; siang `evals/README.md`). A rerun on cases that session already knew, not a fresh blind result | 2,119 words | 799 words | Thai case 0.82 with skill (long form scored 0.96 and 0.78 earlier), English 1.00 | 0.26-0.29 vs 0.41 USD on the Thai case | 8 vs 11.4 |

A later siang run on a fresh blind pair (`humanize` 0.1.41, short form with the dropped instructions restored, 5 runs
per arm, reported by the siang session) scored 1.00 in both arms on both cases: no gain, and that pair cannot show
one, since an unedited fixture already scores 0.67. A with-arm run cost 0.305 USD on the Thai case (11.2 turns)
against 0.122 without the skill, and 0.178 against 0.112 on the English case. That compares skill with no skill, not
short with long.

In both, the short form cost more. In the mh pilot the extra turns are reads of the sibling files. For `humanize`
that cause is probable, not shown: the siang archive keeps no traces, and on the English case with-arm turns fell
(6.6 to 6.4). The `humanize` rewrite also shows why a contract is moved and never dropped: siang 0.1.40 lost three
instructions and inverted one guardrail in the cut, found by an audit afterwards and restored in 0.1.41. On the same seven
`deep-audit` cases, Claude with no plugin passed the end-state checks 35/35 at about 0.20 USD per run, so the skill's
text length is not what decides the result there. The mh pilot's decision rule, written before the run, returned
"no change": the short `deep-audit` in the appendix was not shipped.

So the reason to write short is the reader (a maintainer or an agent finds the contract faster), not the score or
the bill. matt's repo makes no score claim either: it has no automated eval (section 5, "How they test skills").

## 3. Size of each skill

Counted by script on 2026-11-12: `bodyW` is the words in `SKILL.md` after the frontmatter, `descW` the words in
`description`, `sibs`/`sibW` the other files in the skill's folder and their words (the `agents/openai.yaml` each
skill ships counts as one, so `sibs` 1 means no sibling document). The per-skill notes in sections 4 and 5 give a count
that includes the frontmatter, so they run 15 to 75 words higher (wayfinder 2,034 here, 2,080 there).

```text
cat skill bodyW descW heads steps neg must sibs sibW extraFM
engineering ask-matt 1935 16 9 4 5 0 2 713 disable-model-invocation
engineering code-review 1021 68 7 4 3 5 1 12 
engineering codebase-design 806 40 8 3 5 2 3 793 
engineering diagnosing-bugs 1403 19 14 18 4 4 2 206 
engineering domain-modeling 465 23 9 3 2 0 3 778 
engineering grill-with-docs 9 19 0 0 0 0 1 16 disable-model-invocation
engineering implement-spec 429 9 1 9 1 1 1 17 disable-model-invocation
engineering implement 83 13 0 0 0 0 1 14 disable-model-invocation
engineering improve-codebase-architecture 877 20 5 0 5 0 2 938 disable-model-invocation
engineering pr 546 6 8 0 1 0 2 98 metadata
engineering prototype 450 32 3 6 1 0 3 2153 
engineering research 94 39 0 3 0 0 1 8 
engineering retro 665 7 4 4 1 0 1 14 disable-model-invocation
engineering setup-matt-pocock-skills 1090 29 11 0 5 1 6 2055 disable-model-invocation
engineering tdd 549 20 5 0 3 1 3 499 
engineering to-spec 462 24 8 5 2 0 1 14 disable-model-invocation
engineering to-tickets 869 41 12 0 3 2 1 14 disable-model-invocation
engineering triage 962 21 10 8 3 3 3 1958 disable-model-invocation
engineering wayfinder 2034 39 17 11 15 2 1 14 disable-model-invocation
engineering wizard 621 47 6 0 6 2 2 1283 
in-progress chief-of-staff 597 11 5 0 5 2 1 20 disable-model-invocation
in-progress claude-handoff 190 16 0 0 1 1 1 14 argument-hint,disable-model-invocation
in-progress loop-me 383 14 4 0 2 0 1 15 disable-model-invocation,argument-hint
in-progress setup-ts-deep-modules 1077 26 11 7 5 3 2 505 disable-model-invocation
in-progress writing-beats 826 19 5 5 3 3 1 13 disable-model-invocation
in-progress writing-fragments 580 8 4 0 4 1 1 12 disable-model-invocation
in-progress writing-shape 1008 11 7 6 3 2 1 14 disable-model-invocation
misc git-guardrails-claude-code 257 40 8 0 1 0 2 81 
misc migrate-to-shoehorn 385 25 9 2 1 2 1 11 
misc scaffold-exercises 407 30 9 8 0 1 1 9 
misc setup-pre-commit 294 33 12 0 0 1 1 9 
productivity grill-me 6 9 0 0 0 0 1 13 disable-model-invocation
productivity grilling 303 25 0 0 4 0 1 13 
productivity handoff 114 14 0 0 1 0 1 13 argument-hint,disable-model-invocation
productivity teach 1496 11 12 0 5 1 5 1307 disable-model-invocation,argument-hint
productivity to-questionnaire 447 16 7 3 2 3 1 17 disable-model-invocation
productivity wait-what 44 9 0 0 1 0 1 16 disable-model-invocation
productivity writing-for-agents 1757 15 7 3 4 4 2 424 
n 38 median 547.5 mean 672 total 25541 descMedian 19.5
```

## 4. The 20 engineering skills

I read all 20 SKILL.md files, every sibling file, and the 20 `agents/openai.yaml` files, which are only a display name plus `allow_implicit_invocation`. The only files I skimmed were `template.sh`, `issue-tracker-gitlab.md` (first 25 lines each) and `README.md` (first 30 lines). All quotes are verbatim.

Word-count buckets: tiny is under 150 words, short is 150–600, medium is 600–1200, long is over 1200.

### Per skill

**grill-with-docs** (tiny, 35 words)
- (a) A pure alias: one line of body.
- (b) It has no rules of its own, so everything is delegated.
- (c) No sibling files.
- (d) Chains two skills: "Call the Skill tool twice, for "grilling" and "domain-modeling"."
- (e) It says nothing about what to grill, when to stop, or the output.

**implement** (tiny, 103 words)
- (a) A five-line checklist of imperatives.
- (b) Judgement, with two small gates: "Run typechecking regularly, single test files regularly, and the full test suite once at the end."
- (c) None.
- (d) Delegates twice: `tdd` "where possible, at pre-agreed seams", then `code-review` "Once done".
- (e) It gives no failure handling, no definition of "done", and no tracker commands. The ambiguous-ticket case is a single line: "ask".

**research** (tiny, 138 words)
- (a) A spawn instruction followed by a 3-item job spec.
- (b) The constraint is on sources, not process: "Follow every claim back to the source that owns it."
- (c) None.
- (d) It does not call other skills. It spawns a "background agent" with a fresh context.
- (e) It sets no file format and no length. The file location is "somewhere sensible and say where."

**implement-spec** (short, 445 words)
- (a) A short preamble defining terms in bold (frontier, integration branch, task graph), then 9 numbered steps.
- (b) The goal is the completion criterion: "the entire spec implemented on a single **integration branch**". Orchestration rules are hard, such as a fresh window per subagent and "Communication… should be sparse."
- (c) None.
- (d) Implementers "call the Skill tool with `tdd`". After all tickets it calls `code-review` on the integration branch.
- (e) Merge-conflict handling, subagent failure and retries, and the subagent prompt text are all absent. A missing tracker is deferred: "tell the user to run `/setup-matt-pocock-skills`."

**to-spec** (short, 493 words)
- (a) 3 steps plus an inline `<spec-template>`.
- (b) The one hard prohibition is up front: "Do NOT interview the user; just synthesize what you already know." A "user stories" list that is "LONG" and "extremely extensive" is demanded, which is as close as it gets to a completion criterion.
- (c) None. The template is inline, in XML-style tags.
- (d) It has no skill calls. It depends on the setup skill's config and says so: "tell the user to run `/setup-matt-pocock-skills`."
- (e) It says nothing on spec length, on updating an existing spec, or on the label if triage is not installed.

**domain-modeling** (short, 493 words, plus 2 format files)
- (a) A reference and discipline: a file-layout tree, then 5 behaviour headings.
- (b) Judgement, with one hard gate for ADRs: "Only offer to create an ADR when all three are true". The glossary rule is firm: "a glossary and nothing else."
- (c) Templates and format rules go to `GLOSSARY-FORMAT.md` and `ADR-FORMAT.md`. The pointer is one clause: "Use the format in [GLOSSARY-FORMAT.md](./GLOSSARY-FORMAT.md)."
- (d) It is a leaf, called by others.
- (e) It never says how to end a session or when the model is "done". Files are created lazily instead.

**tdd** (short, 574 words, plus `tests.md` and `mocking.md`)
- (a) A reference whose self-description is "the reference that makes that loop produce tests worth keeping".
- (b) Hard rules: "No test is written at an unconfirmed seam." There is also a named anti-pattern list and a three-rule loop.
- (c) The pointer is bare: "See [tests.md](tests.md) for examples and [mocking.md](mocking.md) for mocking guidelines." The siblings are good/bad code examples only.
- (d) A consult-only call: "call the Skill tool with "codebase-design" for the vocabulary… a reference to consult, not a session to run." It explicitly defers refactoring to `code-review`.
- (e) It leaves out how to run tests, which framework to use, and what to do when a test cannot go red.

**pr** (short, 568 words, plus `CREDITS.md`)
- (a) A template in a fenced block, then a section-by-section guide.
- (b) Style rules and judgement: "Skip all preambles and keep prose brief." The visuals are optional: "Use your judgement and don't overwhelm the user."
- (c) `CREDITS.md` holds attribution only. Rather than depend on another skill, the content was copied: "copied in rather than pointed at".
- (d) None. It only reads `GLOSSARY.md`.
- (e) It gives no PR title rule and no `gh` commands. Evidence is ranked (screenshots "S-tier", tests "A-tier"), but what to do when none exists is not said.

**retro** (medium, 679 words)
- (a) 4 steps plus a "Reference" section.
- (b) Judgement through taxonomy: each category carries a "_Use when_" trigger line. Some categories also carry a firm rule: "Default to building the check over writing the rule."
- (c) None.
- (d) A style-guide call at step 1: "Call the Skill tool with `writing-for-agents` for the writing style guide."
- (e) It sets no output format beyond "in order of severity". It never says whether to edit files or only suggest.

**prototype** (short, 487 words, plus `LOGIC.md` and `UI.md`)
- (a) A router with shared rules: a "Pick a branch" section, then 6 numbered rules for both branches.
- (b) The shared hard rules are numbered, for example "Throwaway from day one, and clearly marked as such." The branch files carry an "Anti-patterns" list each.
- (c) Branch detail is pushed out, and each pointer carries the question it answers: `"Does this logic / state model feel right?" → [LOGIC.md](LOGIC.md)`. The branch files link back to the SKILL.md for the shared capture step.
- (d) No skill calls.
- (e) It gives an ambiguity default instead of failing: "default to whichever branch better matches the surrounding code… state the assumption."

**diagnosing-bugs** (long, 1427 words, plus `hitl-loop.template.sh`)
- (a) A six-phase pipeline with checkboxes.
- (b) Hard completion gates per phase. Phase 1 ends only when one command meets four ticked criteria, and "No red-capable command, no Phase 2."
- (c) Only the human-in-the-loop script goes to a sibling. The pointer is inline in a list item: "drive _them_ with `scripts/hitl-loop.template.sh`".
- (d) It calls no skills. It reads `GLOSSARY.md` and ADRs.
- (e) It does handle the "cannot build a loop" case with an explicit stop. Redaction is covered by a `<REDACTED>` rule.

**codebase-design** (medium, 851 words, plus `DEEPENING.md` and `DESIGN-IT-TWICE.md`)
- (a) A vocabulary reference, with "Rejected framings" listed.
- (b) Vocabulary is enforced: "Use these terms exactly: don't substitute "component," "service," "API," or "boundary.""
- (c) Process goes to siblings under a "Going deeper" heading. Each pointer is a topic phrase followed by the link: "**Exploring alternative interfaces**, see [DESIGN-IT-TWICE.md](DESIGN-IT-TWICE.md)".
- (d) It is the callee for `tdd` and `improve-codebase-architecture`. `DESIGN-IT-TWICE.md` spawns 3+ sub-agents, each with a different named constraint.
- (e) The skill has no process of its own. It never says when to stop designing.

**code-review** (medium, 1094 words)
- (a) A 5-step process plus a "Why two axes" rationale section.
- (b) Hard rules, with the reason given: "Do **not** merge or rerank findings, because the two axes are deliberately separate". Fail-fast ref checks come before the sub-agents. Word caps are set ("Under 400 words").
- (c) None. The smell baseline is inline, and the sub-agent prompts are written out verbatim in the skill.
- (d) It spawns two parallel sub-agents. It reads the setup skill's tracker config.
- (e) Fixing is left out. A missing spec is handled: skip that agent and note it.

**improve-codebase-architecture** (medium, 904 words, plus `HTML-REPORT.md`)
- (a) A 3-step process.
- (b) Mixed. There is one firm gate: "Do NOT propose interfaces yet." Exploration is explicitly loose: "Don't follow rigid heuristics."
- (c) The full HTML scaffold and tone rules go out, with a "See [HTML-REPORT.md]… for the full HTML scaffold, diagram patterns, and styling guidance" pointer.
- (d) Three call styles. It calls `codebase-design` for vocabulary, `grilling` once the user picks a candidate, and `domain-modeling` "as you go" for side effects.
- (e) The refactor itself is out of scope. Candidates are rated only as `Strong`, `Worth exploring` or `Speculative`.

**setup-matt-pocock-skills** (medium, 1126 words, plus 6 seed templates)
- (a) A 5-step wizard in the form of an interview, with a "Section A/B/C" structure.
- (b) Firm file-selection rules ("Never create `AGENTS.md` when `CLAUDE.md` already exists"). It also states "This is a prompt-driven skill, not a deterministic script."
- (c) The seed templates are in `issue-tracker-*.md`, `triage-labels.md` and `domain.md`. The pointer reads as a labelled list: "[issue-tracker-github.md](./issue-tracker-github.md): GitHub issue tracker".
- (d) It adapts to installed skills: Section B is skipped if `triage` is not installed.
- (e) The seed files hold the mapping tables ("Wayfinding operations") and a failure rule: if `gh repo view` cannot print the project, "stop and tell the user".

**to-tickets** (medium, 917 words)
- (a) A 5-step process with two inline templates, one for local files and one for a real tracker.
- (b) Hard rules and prohibitions: "Do NOT close or modify any parent issue." Slices must be "demoable or verifiable on its own". The user approval gate is explicit: "Iterate until the user approves the breakdown."
- (c) None. The wide-refactor exception is written inline as one dense paragraph.
- (d) It adapts to the tracker config and has no skill calls. It references `/setup-matt-pocock-skills`.
- (e) It never says how many tickets are too many.

**triage** (medium, 990 words, plus `AGENT-BRIEF.md` and `OUT-OF-SCOPE.md`)
- (a) A state machine with roles, plus a 5-step per-issue process.
- (b) Hard rules: every comment "**must** start with this disclaimer". "exactly one category role and one state role". A "Quick state override" clause lets the maintainer skip grilling.
- (c) A "Reference docs" list sits at the top, with a gloss on each file: "[AGENT-BRIEF.md](AGENT-BRIEF.md): how to write durable agent briefs".
- (d) A chain: `grilling` and `domain-modeling` at step 4. "call the Skill tool twice, for "grilling" and "domain-modeling"".
- (e) The briefs exclude file paths and line numbers because they go stale. The bad-brief example is shown, as are the cases where `.out-of-scope/` is not written to.

**wayfinder** (long, 2080 words)
- (a) A concept document with named terms (map, fog of war, frontier), two modes of invocation and a map template.
- (b) Hard rules: "never resolve more than one ticket per session, with the exception of research tickets." "Plan, don't do" sets the default. A HITL ticket can only resolve through a live exchange with the human.
- (c) None. The tracker-specific operations are pushed into the tracker docs, under "Wayfinding operations", and pointed to with a sentence: "Consult the tracker doc's "Wayfinding operations" section".
- (d) The richest: research tickets call `research`, prototype tickets call `prototype`, and grilling tickets call "twice, for "grilling" and "domain-modeling"".
- (e) No output format is set for the resolution comment beyond "post the answer". There is a stop condition for when the way is clear.

**ask-matt** (long, 1958 words, plus `PHASE-BOUNDARIES.md`)
- (a) A router. It frames "A **flow** is a path through the skills", then lists on-ramps, standalone skills and a precondition.
- (b) Firm guardrails for the router itself: "Before stating what a skill does or recommending a step be skipped, read that skill's SKILL.md".
- (c) The decision tree goes out to `PHASE-BOUNDARIES.md`: "Read [PHASE-BOUNDARIES.md] for the ordered tree: the five questions, the reasoning behind each branch".
- (d) It wraps. It names skills with slash-command syntax and describes the chains, but runs none.
- (e) It leaves out the criteria for choosing between `/to-spec` and going straight to `/implement`, except as branch questions. Skills it names (`/handoff`, `/grill-me`) are not in this directory.

**wizard** (medium, 673 words, plus `template.sh`)
- (a) A 4-step process with a "Done when:" line after steps 1 and 2.
- (b) Completion criteria are explicit per step. "Your job is only to scope the procedure and author its stages." The library above the marker is frozen: "never hand-edit it."
- (c) The library and UX live in `template.sh`, which the skill copies. The pointer sits in prose: "already solved by [template.sh](template.sh)".
- (d) None.
- (e) Running the wizard is explicitly forbidden: "Don't run it end-to-end yourself". It tells the author to say so when a step is unknown: "never invent steps that may not exist."

### Patterns across all 20

- **Delegation by one-line imperative.** grill-with-docs, implement, tdd, retro and implement-spec all use the same literal phrasing, "call the Skill tool with X" or "twice, for X and Y". Skills are named, not inlined.
- **Chain versus consult.** The same call has two explicit modes. `tdd` says codebase-design is "a reference to consult, not a session to run". improve-codebase-architecture calls the same skill "as you go".
- **Sibling files hold formats, templates and examples. SKILL.md holds the process.** domain-modeling, triage, prototype, codebase-design, improve-codebase-architecture and tdd all do this, usually with a pointer that names the question the file answers.
- **A tracker-agnostic dependency via one shared fallback line.** to-spec, to-tickets, code-review, implement-spec, triage and wayfinder all end up at "tell the user to run `/setup-matt-pocock-skills`".
- **Completion is stated as one named artifact or checkbox list, not as a quality bar.** diagnosing-bugs ("Phase 1 is done when…"), wizard ("Done when:"), implement-spec ("the entire spec implemented on a single integration branch") and to-tickets (user approval).
- **Staleness is designed out.** to-spec, to-tickets and triage's AGENT-BRIEF all ban file paths and line numbers. domain-modeling creates files lazily. setup-matt-pocock-skills edits an existing block in place.
- **Leaving out failure handling is the norm.** implement, research, grill-with-docs, to-spec and implement-spec say little about errors or retries. The exceptions are the narrow ones that guard a real hazard (diagnosing-bugs, code-review ref checks, setup's `gh repo view`).
- **The 11 skills with `disable-model-invocation: true` are the user-invoked ones.** These are ask-matt, grill-with-docs, triage, improve-codebase-architecture, setup, to-spec, to-tickets, implement, implement-spec, wayfinder and retro. The README says so, and every skill ships an `openai.yaml` with `allow_implicit_invocation: false`. Several of them are the tiny ones.

### Counter-examples (long or rule-heavy, and why)

- **wayfinder (2080 words):** it defines a durable multi-session artifact, the map. The vocabulary (fog, frontier, claim) and the one-ticket-per-session rule are needed because concurrent sessions edit the tracker. The tracker detail is still pushed out to config.
- **ask-matt (1958 words):** a router has to describe every route. Its depth is in the decision tree in `PHASE-BOUNDARIES.md`. It also carries its own safety rule against summarising skills from memory.
- **diagnosing-bugs (1427 words):** it is the most rule-heavy. Its core claim is stated as "This is the skill", and the other phases are called "mechanical". Inference: the extra checkboxes target a known failure, jumping to a hypothesis before a loop exists.
- **code-review (1094) and setup (1126):** these are long because the sub-agent prompts and the smell baseline (code-review) and the interview branches (setup) are written out in full.

## 5. The other 18 skills and the repo rules

**Sources.** Everything below is read from `~/.claude/plugins/cache/mattpocock/mattpocock-skills/1.3.2/`. Two caveats apply:
- `CLAUDE.md` is byte-identical to `AGENTS.md`.
- Some of the claims on authoring rules are inferred; I have marked them.

### Per-skill (a) shape, (b) constraint, (c) siblings, (d) calls, (e) unsaid

**grill-me** (productivity, user-invoked)
- Whole body: `Call the Skill tool with "grilling".`
- (a) Tiny router, one line. (b) It adds no constraints. (c) None. (d) Exact wording above. (e) Everything. The description is human-facing: "A relentless interview to sharpen a plan or design."

**grilling** (productivity, model-invoked)
- (a) Short prose protocol with one fenced round template. (b) The end is a state: "The session is done when the frontier is empty… nothing left silently assumed." It adds a gate: "Do not act on it until the user confirms." (c) None. (d) It does not call a skill; it dispatches a "sub-agent with a fresh context window" for facts. (e) It sets no question cap (see `.out-of-scope/question-limits.md`) and names no harness question tool. It uses leading words (design tree, frontier, rounds) in place of procedure.

**handoff** (productivity, user-invoked)
- (a) Tiny, five sentences. (b) Constraints are a few direct rules plus one negation-style rule. "Do not duplicate content already captured in other artifacts… Reference them by path or URL instead." (c) None. (d) "naming which skills the next agent should call the Skill tool for." (e) It gives no document template, no section list, and no length. It does specify where to save (OS temp dir, not the workspace).

**wait-what** (productivity, user-invoked)
- Whole body: "Wait, I don't understand where you've got to here. Re-pitch that: give me a little bit of context, talk in ASD-STE100 Simplified Technical English, and use the ubiquitous language from `GLOSSARY.md` (follow `GLOSSARY-MAP.md` to the right one if the repo has more than one)."
- (a) Tiny, one sentence, written in the user's voice. (b) Left to judgement. (c) None. The pointers are repo files, not skill siblings. (d) None. (e) Format and length.

**to-questionnaire** (productivity, user-invoked)
- (a) Three numbered steps plus a template block, short. (b) Each step ends in a bolded-style "Done when". Example: "Done when the file exists and every item the user named in step 2 is covered by a question." (c) None; the template is inline in an XML-style tag. (d) None. (e) It does not interview the user about the subject, only about the send ("Grill the send, not the subject"). It says nothing about the questionnaire's domain content.

**teach** (productivity, user-invoked)
- (a) Medium reference with no steps, built from a workspace file list and philosophy sections. (b) Mostly judgement, with a few hard rules. "Never trust your parametric knowledge." "Reuse is the default." Quiz answers must be equal in length. (c) Four `*-FORMAT.md` siblings (MISSION, RESOURCES, LEARNING-RECORD, GLOSSARY). Pointer wording: "Use the format in [MISSION-FORMAT.md](./MISSION-FORMAT.md)." Each format file holds a template plus a "Rules" list and "when to write" criteria. (d) None. (e) It sets no lesson count or syllabus. It names no completion state, because it is multi-session and stateful.

**writing-for-agents** (productivity, model-invoked)
- (a) Long reference with no steps, one section per lever. (b) The strongest criteria are "checkable and exhaustive". The skill teaches that "Every step ends on a completion criterion". It uses no hard rules on itself. (c) `SKILL-MECHANICS.md`, pushed behind a conditional: "When the document you're writing is a skill, read [`SKILL-MECHANICS.md`]… for frontmatter, invocation choice, and router skills." (d) None. (e) Examples of good output and any template. It is explicitly a vocabulary of failure modes: sprawl, sediment, no-ops, premature completion, negation.

**git-guardrails-claude-code** (misc)
- (a) Five numbered steps, short. (b) Step 5 is a smoke test with a concrete expected result: "Should exit with code 2 and print a BLOCKED message". (c) `scripts/block-dangerous-git.sh`, linked as "The bundled script is at: [scripts/block-dangerous-git.sh]". The script is copied, not inlined. (d) None. (e) Why the hook matters, and no rule against bypasses. The frozen file `frozen-misc-skills.md` cites a bypass bug that was closed unfixed.

**migrate-to-shoehorn** (misc)
- (a) Reference first (before/after code), then a checklist workflow. Medium-short. (b) Checkbox list ending "Run type check to verify". It also has one hard rule: "Test code only. Never use shoehorn in production code." (c) None. (d) None. (e) How to handle edge cases beyond the three patterns.

**scaffold-exercises** (misc)
- (a) A reference with naming rules and a lint summary, plus a five-step workflow. Short-medium. (b) The linter is the criterion: "Fix any errors - iterate until lint passes". (c) None. (d) None. (e) Rationale; it is a pure convention and lint dump, tied to one external CLI.

**setup-pre-commit** (misc)
- (a) Eight numbered steps, short-medium. (b) A step 7 checkbox "Verify", then a final commit step that doubles as a smoke test. "A good smoke test that everything works." (c) None. (d) None. (e) Behaviour when a package manager is not detected is covered only by "default to npm".

**chief-of-staff** (in-progress, user-invoked)
- (a) Persona and reference, medium-short, no steps. (b) Judgement plus bold directive rules. "All work should be done in subagents. Protect your context window." "Start every subagent with a fresh context window." (c) None. (d) Uses the term "context pointers" but calls no skill. (e) Completion, because it is a long-running session. It encodes the wiki discipline "Write history, not the present", with dated claims and cited commits. It is a user-invoked skill that does not appear in the in-progress README list.

**claude-handoff** (in-progress, user-invoked)
- (a) Tiny-short, one dense paragraph plus rules. (b) A concrete command is given: `claude --bg --name "<descriptive name>" -- "$(cat <summary file>)"`. It also says why: passing the file avoids shell backtick expansion. (c) None. (d) "naming which skills the next agent should call the Skill tool for." (e) Document template, the same as `handoff`. It is a near-copy of `handoff` that adds the launch step.

**loop-me** (in-progress, user-invoked)
- (a) Short reference with no steps. (b) The only gate is "A workflow spec is done when an implementer agent could build it without asking a single question." It also says "Mandate nothing structural". (c) None. (d) Names the grilling skill as a bare slash name in prose ("a stateful `/grilling` session"), not a Skill tool call. That breaks `invocation.md`'s operative-call rule, though grilling is model-invoked. (e) Output format of a workflow spec beyond the path `workflows/*.md`.

**setup-ts-deep-modules** (in-progress, user-invoked)
- (a) Seven numbered steps plus rationale and notes. Long. (b) Each step has an explicit "**Done when:**". Step 6 is the whole-skill criterion: "you have observed a pass, then a fail on the deep import, then a pass again". (c) `dependency-cruiser.config.cjs`, pointer: "Copy [`dependency-cruiser.config.cjs`](./dependency-cruiser.config.cjs) to the repo root". The config carries the rules; the skill only says which constant to edit. (d) "call the Skill tool with "codebase-design" and use its language throughout." (e) Layering rules are left as a commented stub.

**writing-beats** (in-progress, user-invoked)
- (a) Five steps in `<what-to-do>` plus `<supporting-info>` reference. Medium. (b) Hard rules in the writing rhythm: "Append one beat at a time. Never write ahead." and "Re-read the article file from disk before every write." Reachability test for each candidate beat. (c) None; the supporting reference sits in the same file in a second XML section. (d) None. (e) Article length. "The article ends when the journey is complete, not when the pile is empty."

**writing-fragments** (in-progress, user-invoked)
- (a) A short `<what-to-do>` block plus a reference with the file format. Medium-short. (b) Left to judgement, with a few concrete rules. "Never overwrite the file; only append." "Imposing phases, outlines, or article structure is out of scope here." (c) None. (d) None; "Run a grilling session" is plain prose. (e) Completion. It has no end state, because it is pure explore.

**writing-shape** (in-progress, user-invoked)
- (a) Six-step loop, plus Grounding and format-argument reference and an Out of scope list. Medium. (b) Ends when "The user decides when it's done." Hard rules: the raw file is read-only, and each block is appended immediately. (c) None. (d) None. (e) Platform formatting and frontmatter ("Out of scope").

### Repo-level authoring rules

- **Invocation.** Each skill is either user-invoked (`disable-model-invocation: true`, plus `policy.allow_implicit_invocation: false` in `agents/openai.yaml`) or model-invoked. The user-invoked description is human-facing, with trigger lists stripped. The model-invoked description keeps trigger phrasing. The test is "could the model usefully reach for this autonomously?" (`.agents/invocation.md`).
- **Calling skills.** Use an explicit Skill tool call (`Call the Skill tool with "grilling"`), one skill per call, with no deep `../other/FILE.md` links. A user-invoked skill can never be called by another skill. Where the precondition is a user-invoked skill, tell the user to run it instead. Pure router prose may keep `/name` labels.
- **Dependency pointers.** ADR 0001 says hard-dependency skills carry an explicit setup pointer, and soft-dependency skills use vague prose only.
- **Subagents.** `AGENTS.md`: every skill that dispatches a subagent says to start it with a fresh context window.
- **Style.** No em-dashes anywhere. Docs links are absolute, with no H1.
- **Buckets.** Promoted buckets are `engineering/` and `productivity/`. They need a top-level README entry, a plugin.json entry, a docs page (four sections), an `ask-matt` router update, and an `agents/openai.yaml`. `misc/` and `in-progress/` get none of these except that README rule.
- **Scope** (`SCOPE.md`): an idea needs an observed failure in a real session and must fit the philosophy. No config options, harness branches, or per-person tweaks. Size is irrelevant.
- **What gets rejected** (`.out-of-scope/`):
  - New skills ("if you can compose the behaviour from existing skills, it doesn't get a new skill").
  - `misc/` changes (frozen).
  - Question caps.
  - A native question tool for grilling.
  - Subagent-recursion guards (the harness's job).
  - Renames to dodge harness built-ins.
  - Trackers beyond GitHub, GitLab and local.
  - A verify mode for the setup skill.
  - Lazy-loading `writing-for-agents` in `retro`.
- **Docs writing.** `.agents/writing-docs.md` demands:
  - Explain why, not process.
  - Name no author.
  - Put branches in tables or lists, not paragraphs.
  - Use the AI Coding Dictionary's terms.
  - Install commands live only on the site.

### How they test skills

Nothing automated. `docs/productivity/writing-for-agents.md` states: "There is no automated eval. You check by running the document by hand." It also says to settle no-op disputes by running the document, not by debate. I found no eval files, A/B tests, or fixtures in the repo (grep over `docs`, `.agents`, `.github`, `scripts`). The only mechanical checks are the plugin version sync (`npm run check-plugin-version`) and `claude plugin validate . --strict`, per `AGENTS.md`. Per-skill verification is inside the skills themselves (see the patterns below). Observed-failure issues drive changes (`SCOPE.md`).

### Patterns across all 18

- **Wrapper skills.** `grill-me` and `wait-what` have one-line bodies. The reusable discipline sits in a model-invoked skill that other skills can call. `claude-handoff` repeats the `handoff` rules inline instead of calling it (inferred reason: user-invoked skills cannot call each other, per `invocation.md`).
- **Explicit done-conditions on setup skills.** `setup-ts-deep-modules` ("Done when:" per step plus the pass/fail/pass proof), `to-questionnaire` ("Done when" per step), `scaffold-exercises` (lint passes) and `setup-pre-commit` (verify checklist plus a commit that runs the hooks).
- **Reference skills have no steps.** `writing-for-agents`, `teach`, `chief-of-staff` and `loop-me` teach vocabulary and rules and leave sequence to the agent.
- **Leading words in place of procedure.** `grilling` (frontier, design tree), `loop-me` (push right, brief, checkpoint), `writing-beats` and `writing-shape` (grounded), `writing-fragments` (leading word), `teach` (storage strength, zone of proximal development).
- **Format files as siblings.** `teach` has four `*-FORMAT.md` files and `setup-ts-deep-modules` has its config. Both are pointed to at the point of use with a verb ("Use the format in…", "Copy… to the repo root").
- **Persistent-file discipline.** `writing-beats`, `writing-fragments`, `writing-shape` and `chief-of-staff` all say to re-read from disk before writing and to preserve user edits. `chief-of-staff` also dates claims and cites commits.
- **Context pointers over copying.** `handoff`, `claude-handoff` and `chief-of-staff` all say to reference artifacts by path or URL and not duplicate them. `chief-of-staff` calls them "context pointers".
- **Subagent hygiene.** `grilling` and `chief-of-staff` both say "fresh context window" for subagents.

## Appendix: the short `deep-audit` from the pilot (not shipped)

The 1,266-word body tested against the 2,412-word shipped one. Scoring rules and the checker dispatch brief moved to
`references/scoring.md` and `references/checker-dispatch.md`, which are not kept here. It is an example of the rewrite shape, not a
recommended replacement: same outcome, higher cost (section 2).

````markdown
---
name: deep-audit
description: "Deep-audit: post-implementation audit: verify every claim, score before/after, fix gaps, re-score. Use after an implementation pass. Not for plan conformance (/mh:compliance-audit) or first-pass review (/code-review)."
model: inherit
effort: xhigh
---

Audit everything this session implemented or changed as if someone else built it. Its output is
a set of **claims**, each true only once evidence outside the model's own memory says so.

## 1. Reconstruct scope from the tree

Scope is what git shows, since a compacted session remembers a retelling, not the work. Find the
session's first commit from the reflog or the session start time, then:

```bash
git log --oneline --since="<session start>"        # or <first-sha>^..HEAD
git diff <first-sha>^..HEAD --stat; git status --porcelain
```

Uncommitted-only work is the diff alone. Add files edited outside git (memory store, settings,
sibling repos) by name. When the session worked from a plan's file list, re-sweep every tracked
file with a fresh grep for the changed names and paths: the plan's list is a claim, not the set.
Trace the diff end to end, noting assumptions, implicit behaviour, and anything claimed but never run.

**Done when** every changed file is listed with the session's claim about it and your own note on it.

## 2. Score the baseline

Score each dimension 0–10 from evidence, on this fixed rubric so runs compare:

| dimension | weight | evidence that earns the score |
|---|---|---|
| Correctness | 3 | tests, checks, or a reproduced command exit code |
| Completeness | 2 | every item of the request traced to a file or an explicit "left out" |
| Claim accuracy | 2 | each claim in commits, docs, and replies re-run or re-read |
| Regression safety | 2 | gauntlet or equivalent green; sibling callers of changed code checked |
| Simplicity | 1 | no abstraction, file, or line without a caller or a reader |

Mark a dimension with no evidence **insufficient evidence**; a guessed score is worse than none
(Rule 14).

You write scores and reasons; `weighted-score.py` does the arithmetic, so a wrong hand sum never
reaches a verdict. Load `references/scoring.md` before scoring: evidence order, the command, the
pass rule, and what a non-zero exit means.

**Done when** `weighted-score.py` exited 0 and you hold its `total`, `pass`, `belowFloor`,
insufficient dimensions, and `sensitivity.verdictStable`, or it exited non-zero: a hard `fail`.

## 3. Hunt gaps with a fresh-context checker

The maker never grades its own work (`docs/reference/operating-model.md`). Load
`references/checker-dispatch.md` before writing the brief; it holds items 1–3's commands and
acceptance rules. When Codex fails acceptance, load `references/codex-fallback.md` before
dispatching the Claude `Explore`/review fallback.

1. Brief the checker with **only** step 1's scope list; withhold your per-file notes and step-2
   scores so it cannot inherit your blind spots.
2. Fingerprint, dispatch, validate with `check-verdict.py`, re-fingerprint; on drift re-run once.
3. Run the citation check (report-only).
4. Reconcile its findings with yours. A finding survives only with a concrete trigger; drop a
   speculative "consider X". Rank survivors by severity, impact, likelihood, confidence, and
   effort. Zero survivors is valid: only evidence separates "nothing worth fixing" from "under-audited".

**Hard-fail override:** if the fallback also fails to produce a valid result, or scope is still
unstable after the retry, the Final Verdict is **fail, reason "verification incomplete"**,
whatever step 2's total says. Say plainly this means the audit could not verify the work, not
that the work is wrong.

**Done when** you hold a ranked survivor list (possibly empty), the citation count, and one of: an
accepted verdict on stable scope, a `NEEDS-DECISION` escalation surfaced to the operator, or the
hard-fail override.

## 4. Confirm, then fix

Present the ranked findings and confirm with one **AskUserQuestion**:

- `Apply all fixes now` (findings low-risk and inside the session's scope)
- `Apply only some` (a finding is out of scope or needs its own decision); ask which
- `Skip fixes, report findings only` (review-only pass); 0 fixes also skips step 6 (it needs a
  landed fix to check): go straight to step 7 with the baseline as both scores

Skip the ask only when the same turn already said "audit and fix"; an earlier or implied
authorization is not that.

Each fix names its failure class (Rule 4: missing_context, bad_tool_contract, missing_guardrail,
weak_verification) and lands test-first where a test can express it: the new test is red on the
pre-fix code and green after; that red run is evidence. Every change carries a quality rationale; leave out a change that
only moves the score.

**Done when** each approved finding has a landed fix with failure class and red-then-green
evidence; each declined one is recorded.

## 5. Re-verify

- Re-run the tests and checks the fixes touch, plus the repo gate (`scripts/run-gauntlet.sh` or
  equivalent).
- Check each fix's own mechanism for a new regression before scoring its dimension resolved: a
  test that only documents the new behaviour hides one. Close a cheap self-inflicted regression now.
- When any fix touched 2+ files or a test, re-run step 3's checker once over the union of all
  fixes (Rule 13), not one dispatch per fix.
- A hook, gate, or plugin fix in the repo is a separate claim from the running copy (plugin
  cache version, restarted session); say which one the evidence covers.

**Done when** each fix has a command and exit code proving it, and the repo gate is green.

## 6. Whole-picture challenge

Trigger: step 4 fixed 2+ defects, OR exactly 1 defect whose change touched a function, early-exit
path, return value, or emitted string that other code, a test, or an out-of-scope consumer reads.
Count defects, not changes: a code change and the test that pins it are one fix. A test of the
very behaviour the fix changes is not a reader; step 5 re-runs it. Otherwise skip: step 3's
checker already covered a fully-local single fix.

When triggered, dispatch `mh:blind-spot-hunter` (`Agent` tool; reuse it, write no new agent)
against the **combined delta**: every file step 1 put in scope, unioned with every fix commit from
step 4. Load `references/whole-picture-brief.md` before dispatching: brief framing, the no-second-pass
stop, `CLEAN` and dormant results, and what to report when the dispatch fails. Its
findings go through step 4's **Confirm, then fix** gate (a fresh `AskUserQuestion`, same three
options), then step 5, before step 7.

**Done when** the step is one of: skipped by trigger, CLEAN, findings confirmed and re-verified,
or a failed dispatch; each reads differently in the report.

## 7. Re-score on the same rubric

Run `weighted-score.py` again on post-fix evidence. Report before, after, absolute delta, and
percentage, per dimension and overall; for a baseline at or near zero, give the absolute delta and
say the percentage is not meaningful. An improvement counts only when post-change evidence beats
the baseline. If the score did not move, say so and why.

**Done when** both score runs are in hand, side by side.

## Final output

Line one is the **Final Verdict**: pass or fail, with the reason and a confidence level. Copy the
total and the pass/fail call from `weighted-score.py`'s output; step 3's hard-fail override, when
it fires, wins over that call. When `sensitivity.verdictStable` is
`false`, append a fragility clause **after** the pass/fail word, e.g. "pass (7.3/10, confidence
high; fragile — range [6.9, 7.6] under ±20% weight perturbation)", so the grader contract
(`Final Verdict… (pass|fail)`) keeps matching. Then:

1. Baseline score (per dimension, weighted total)
2. Findings, each marked by source (step 3's checker, step 6's whole-picture pass when it ran, or your own)
3. Changes made, each with its failure class
4. Verification evidence (commands and exit codes), including "N of M citations exist"
5. Final score and before → after
6. Remaining risks, **insufficient evidence** dimensions, and the scope boundary: the audit
   covers the diff it was pointed at, not the neighbourhood around it
````
