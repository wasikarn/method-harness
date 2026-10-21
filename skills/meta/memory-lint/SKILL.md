---
name: memory-lint
description: "Lints the auto-memory store: dangling [[links]], orphans, index drift; --auto-archive trims. Use after editing memories or near the cap. Not for semantic or harness review."
model: inherit
effort: medium
---

# memory-lint

Deterministic bookkeeping check for the auto-memory store. Claude Code only warns when
`MEMORY.md` nears its 200-line / 25 KB load cap; nothing else resolves `[[wikilinks]]`, finds
orphans or notices index drift. Semantic review of memory content is out of scope.

## The loop

1. **Run the detector.** Exit code equals the finding count, so `0` proves a clean store.
   ```bash
   python3 "${CLAUDE_SKILL_DIR}/scripts/memory-lint.py"              # store derived from the git root: ~/.claude/projects/<root with / as ->/memory
   python3 "${CLAUDE_SKILL_DIR}/scripts/memory-lint.py" /path/to/memory
   python3 "${CLAUDE_SKILL_DIR}/scripts/memory-lint.py" --json         # findings array instead of the summary line
   ```
   Done when: the summary line (`memories: … | findings: N`) or `--json` array, and the exit code, are read, not assumed.
2. **Fix each finding at its cause.** Dangling link: correct the target to the real filename stem
   (the `did you mean` hint is a string-similarity guess; check it first); never delete the link.
   Stale pointer: remove the `MEMORY.md` line; never create a file to satisfy it. Unindexed: add a
   one-line pointer, or link it from an indexed memory. Orphan: link it from the memory it belongs
   with. Near or over budget: step 3.
   Done when: every finding has a named edit and no memory file was deleted.
3. **Trim only through action mode.** `--auto-archive --dry-run` first, read the plan, then
   `--auto-archive --yes`. Rubric, classes A–D and thresholds: `references/action-mode.md`.
   Done when: the dry-run plan was read before any apply.
4. **Re-run the detector.** Done when: exit code `0`, or every remaining finding is accepted with a
   written reason.

## Checks

| Check | Fires when |
|---|---|
| Dangling link | `[[target]]` (alias form `[[target\|alias]]` stripped) or same-store `](file.md)` resolves to no memory by filename stem or `name:` slug; code spans are masked first |
| Orphan | an indexed memory has no links in or out |
| Index drift | `MEMORY.md` points at a missing file, or a file has no pointer and is not `[[link]]`-reachable from an indexed one |
| Load budget | `MEMORY.md` at 80% or more of 200 lines / 25 KB; once over the cap, trailing entries never load |

## Authoring rules the checks assume

- **Link by filename stem**, never by `name:` slug; `name:` values drift from filenames.
- `[[ ]]` is memory-to-memory only. Name a skill, doctrine file or ADR in backticked prose.
- One fact per file with `name:` and `description:` frontmatter, body with `**Why:**` and
  `**How to apply:**`; dedupe before writing; archive under `_archive/`, never delete.

`hooks/session/memory-health-nudge.sh` runs the detector at session start unless the store is
unchanged since the last clean run; it is silent when clean.

## Failure modes

- **Apply without the plan.** `--auto-archive --yes` straight away moves entries you meant to keep.
- **Silencing instead of fixing.** Deleting a dangling link or stubbing a stale pointer clears the
  finding and loses the fact.
- **Trusting the hint.** A wrong `did you mean` accept links two unrelated memories.
