---
name: post-mortem
description: "Writes the canonical record of a fixed bug, after its diagnosis; not for an in-progress incident."
argument-hint: "[bug-id|jira-key|summary]"
disable-model-invocation: true
disable-model-invocation-reason: writes a canonical doc (and optional tracker post) — user decides to record
model: inherit
effort: high
---

# Post-Mortem

Draft the engineering record of a fixed bug: the document that answers "what happened and why"
for a reader who was not there. It follows `mattpocock-skills:diagnosing-bugs`, whose Phases 2, 5 and 6
outputs (minimised repro, regression test, confirmed hypothesis in the commit / PR message) are this
skill's input.

Three rules hold through every step:

- **Four inputs or no draft.** Reproducible trigger, known mechanism, identified patch, passing
  validation. A draft with "we think the cause is" is an investigation, not a post-mortem.
- **Blameless, concrete, unhedged.** "The check was missing", never "Alice forgot". Function
  names, paths, and SHAs are welcome; "appears to", "may have", "we believe", "probably",
  "likely" are not. What is unknown is marked unknown, not smoothed over.
- **Mechanism over symptom.** The symptom is what was seen; the mechanism is why. Keep them apart.

## 1. Verify inputs

Scan the conversation first: a diagnosis run in the same session usually established most of the
four. Then ask for whatever is still missing, one question per input:

- **Reproducible trigger**: exact steps, environment, inputs. Can someone else make it happen?
- **Known mechanism**: which code path, invariant, race, or assumption broke, in one paragraph.
- **Identified patch**: fixing commit SHA(s) and branch.
- **Passing validation**: regression test name and status (CI, local, both). No regression test
  is a flagged gap, not a blocker. The record cites validation someone ran; running the tests
  to manufacture this input is not this skill's job.

Done when: all four are in hand, or the reply is a request for the missing ones and nothing
else. Capture the bug identifier as the slug (`JIRA-12345`, `gh-456`, or a short kebab summary).

## 2. Gather evidence

Fetch only what the conversation did not already give:

1. The fix: `git show <sha>` for diff summary, author, date. A previous incomplete fix, if any,
   with why it fell short.
2. The regression test: file, name, and the assertion that fails pre-fix.
3. CI on the fix commit: `gh run list --commit <sha>` or `gh pr checks <pr>`.
4. Related issues: `gh issue list --search <keyword>`; for Jira, the `jira-acli:acli` skill,
   never a raw `acli` or MCP call. Skip with a note when the tool is absent.
5. Impact: support tickets, SLO breaches, error-rate spikes tied to the bug.

Done when: every template section has a source or an explicit "None." / "Unknown".

## 3. Draft

Load `references/template.md` and fill all 11 sections in order. A section with no content
reads "None."; a section still under investigation reads "Unknown — tracked in <issue>". Nothing
is invented to make the story cleaner.

Done when: 11 numbered headings, each with content, "None.", or a tracked unknown.

## 4. Review the draft against the facts

Run each check and render the result as a visible checklist in the reply, one line per check,
before the draft, each line naming the check by its bold label and its result, not the
phrases it hunts. A check folded into prose gets skipped under compression.

1. **Banned phrases** (the list in the rules above) gone, each replaced with a fact or an
   explicit unknown.
2. **Blame** gone: a person's name plus forgot / missed / approved becomes the system gap.
3. **Every identifier exists**: `git show <sha>`, `grep -r <function>`. Existence is not
   accuracy: a claim about what the identifier does or covers is verified by reading the full
   code path, since a later guard can narrow or void an equivalence the first line suggests.
4. **Absence claims** ("never happened before", "no server emits X") name what was checked, or
   shrink to the claim the check supports.
5. **Closure claims** ("already addressed") grep every occurrence of the term in the affected
   files and state the count checked.
6. **Links** (PR numbers, issue keys) resolve.
7. **Section 4 connects 3 to 2.** If it cannot, the mechanism is not understood; go back to
   step 1.
8. **Section 11 is anchored** to something written before the fix was known, or says it is a
   reconstruction.

Done when: the checklist shows eight results and the draft reflects every fix.

## 5. Present and archive

Present the post-mortem in one markdown block, then decide where it lives. When the user
already named the destination (in the invocation or this turn), use it; otherwise recommend
one from the facts (public bug and in-repo issue tracking point to repo markdown; a ticket-bound
bug points to its tracker; a process escape points to the wiki) and confirm with one
**AskUserQuestion**, the recommendation tagged `(Recommended)` and the runner-up named with
the fact that would flip the pick:

- **Repo markdown**: write `docs/post-mortems/<slug>.md`, then ask yes/no before committing
  it (stage by path).
- **GitHub comment**: `gh issue comment` / `gh pr comment` after the user says "post it".
- **Jira comment**: a bespoke document, not one of `jira-acli:jira-content`'s four templated
  shapes. Convert with `jira-acli:acli`'s `md2adf.py <file>.md > note.json`, then
  `acli jira workitem comment create --key <KEY> --body-file note.json`, after "post it" —
  never a raw `--body` or MCP call, which garbles the ADF payload. Without `jira-acli`, hand the
  text to the user.
- **Wiki / Confluence** or **print-only**: hand the text to the user.

Then: update a runbook or ADR when Section 7 shows a systemic gap; create Section 10's
follow-ups (`gh issue create`, or `jira-acli:jira-content` for a Jira Task/Bug) or say they
still need creating; write a `project` memory entry when the escape reason is a gap the next
session would hit again. Tag the record with the incident severity when there was one.

Done when: the record is delivered, its location is stated, and each follow-up has a ticket
or an explicit "needs creation".

Doctrine ties: Section 8 takes Rule 4's four failure classes; Section 9 is Rule 4's failing-test
proof.

## Failure modes

- **Drafting around a missing input.** The gap gets a plausible paragraph instead of a
  question; the record then teaches the wrong mechanism.
- **Verifying existence, not claims.** `git show` proves the SHA exists, not that it fixes what
  Section 5 says.
- **Hindsight in Section 11.** The belief written after the fix is cleaner than the one held
  before it; an unanchored trace says so.
- **Follow-ups owned by a team.** Unowned items rot; each needs one person and a completion
  criterion someone can check.
