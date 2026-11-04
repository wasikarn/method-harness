---
status: accepted
---

# Gate scope: agent mistakes, not deliberately disguised commands

The Bash gates (`irrecoverable`, `subagent-git-guard`, `test-integrity`) stop an agent from running a
destructive or out-of-scope command by mistake. They read command text only, so a command built to
hide its meaning (an encoded name, a `${IFS}` splice, a brace-built word, a quote trick) can always be
written in one more shape than the gates read. Until now no document said which of those shapes are
in scope, so every review round could find a new one, and every finding was fixed.

## Context

Rounds 5 to 7 of the gate work (2026-11-02 to 2026-11-04) measured what that costs:

- 7 issues fixed (GH #833, #834, #835, #796, #838, #840, #839), and about 23 new issues filed
  (#846 to #871, nearly all gate gaps) by the same PRs' reviews.
- 8 to 15 fresh-context review rounds per PR; every round found another hand-built shape.
- Every PR was replayed against the full local pool of real Bash commands (about 54,000). No real
  command changed its allow/deny decision in any of them. None of the closed gaps had ever appeared in
  a real command.
- Each fix made the gates slower: #852 by 25 to 40% on long commands, #870 by 2 to 3x in the quote
  mask on large inputs. #872 alone added 452 lines to `subagent-git-guard.py`.
- GH #797 asked to loosen a route for an over-deny seen only in fuzz output. It was dropped
  mid-session for that reason.

## Decision

A gate gap qualifies for a fix only when one of these holds:

1. **A real command hits it.** A `scripts/gate-differential.sh --replay` run, a transcript, or a gate
   journal row shows the shape in ordinary use.
2. **An agent could write it by mistake** during ordinary work. Examples: a commit or PR body that
   quotes shell patterns (GH #844), a common wrapper or flag spelling, a script an agent generates.

A shape that only a deliberate attempt to hide a command would produce is out of scope. That covers
ANSI-C or octal encoded names, `${IFS}` or empty-variable splices, brace-built command words, case
arms or comments placed to fool the quote mask, and similar shapes. Such an issue gets the `parked`
label and no fix session.

Two rules follow:

- **Never loosen a gate for an over-deny seen only in fuzz output.** A replay cannot vouch for that
  kind of change, since it only shows that no real command benefits (GH #797).
- **Review rounds converge.** When a fresh-context review of a gate PR finds an out-of-scope shape,
  the builder files it `parked` and does not fix it in the same PR. Only an in-scope finding blocks
  the merge.

This decision only stops new work. Every disguised shape the gates already deny keeps its deny and its
test rows; nothing is removed.

## Amendment: gate freeze (2026-11-04)

Criterion 2 above still left room for a shape that an agent only *could* write. Review rounds kept
finding those, and each one still cost 8 to 28 review rounds plus a 1 to 2 hour replay. Of 70 open
issues triaged on 2026-11-04, 53 were gate gaps of this kind, and only one (#710) cites a real
command. So the gates are frozen. A change to `hooks/gates/` is allowed only for:

1. **A real false deny:** a real command from a transcript, the gate journal or a replay was wrongly
   denied or asked.
2. **A real miss:** an incident where a dangerous command an agent actually ran got through.
3. **The replay speed-up plan** (#895): work on how gates are tested and replayed, not on what they
   decide.

An agent-mistake shape without a real hit is filed `parked` and gets no fix session. PR #872 (GH
#842 to #844) was approved before the freeze and is the last gate PR under the old criterion 2.
Work outside the gates (scripts, skills, docs, the gauntlet) is not frozen.

**Risk accepted: agent mistakes.** The freeze drops criterion 2 as a reason to fix ahead of time. A
dangerous command an agent writes by mistake, in a shape the gates miss, is fixed only after it has
run (a real miss). That case can cost work: a lost stash, a hard reset, a deleted tree. Parked issues
close to ordinary mistakes (for example #867) stay unfixed until then. What still limits the damage:
the denies already shipped, the `permissions.deny` rules for `rm -rf` and force pushes, `trash` in
place of `rm`, and branch protection on `develop`. Uncommitted work in a subagent's checkout is the
exposed part. If one such miss happens, reopen its `parked` class and fix it as in-scope.

## Risk accepted: prompt injection

The realistic author of a disguised command is not a person at the keyboard. It is an agent that read
injected text (a web page, an issue, a PR, a file) telling it to run a command and to slip it past the
gates. This ADR accepts that risk for the shapes the gates do not already deny:

- **What stays exposed:** a prompt-injected agent that writes a disguised command the gates miss can
  run it. In a subagent that includes a destructive local command (file deletion, `git reset --hard`,
  `git stash`), or starting a `claude` session.
- **Why it is accepted:** the gates read text, and each round showed there is always one more shape.
  Closing gaps one shape at a time cannot reach zero, and it costs speed on every real command. The
  replays show that no real command has used a disguised shape so far. That says nothing about a
  future injection, which is why this section exists.
- **What still holds:** the denies already shipped, the `settings.json` deny rules, branch protection
  on `develop` (PR plus `mh/gauntlet`), and the operator's approval of every merge. None of these
  stops a disguised local destructive command in a subagent: the deny rules read text too.
- **The right control for this threat** is an OS-level sandbox (filesystem and network limits on the
  agent's shell), not more text rules. Adopting one is a separate decision.

## Consequences

- Known disguised bypasses stay open, listed under `parked`, as accepted above.
- Gate PRs get smaller and their reviews end. The gates stop slowing down for shapes no real command
  uses.
- **Revisit when:** a real command or an incident uses a disguised shape. Reopen the `parked` issues of
  that class and fix them as in-scope. Lift the freeze when the replay plan (#895) makes a gate PR
  cheap enough that review rounds, not replays, are the cost again.
