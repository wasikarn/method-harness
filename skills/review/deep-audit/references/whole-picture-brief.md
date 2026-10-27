# deep-audit: step 6 whole-picture brief and failed dispatch

Moved from `SKILL.md` step 6 unchanged.

## Framing the brief

Frame the brief explicitly as a system-level challenge, not a repeat of step 3: name each
individual fix and what it was supposed to close, then ask directly for what a fix-by-fix
re-check structurally cannot see — interaction/emergent bugs between the fixes, whether each
fix's underlying design decision is sound and not just correctly implemented, and whether step
5's re-verification evidence actually exercises the fixes *together* or only individually. Tell
it explicitly not to re-litigate a finding step 3's checker already confirmed or refuted unless
new evidence surfaces.

## When the dispatch fails

If the dispatch itself fails to return a usable result (the agent errors, returns empty, is
denied by `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` when this skill is itself running inside an
already-dispatched subagent, or otherwise doesn't produce the finding/CLEAN format it defines),
this step did not run — say so plainly under Remaining risks in the Final output (item 6), the
same way step 3's hard-fail path is distinguished from a real pass. Never let a failed dispatch
read the same as "skipped by trigger" or "clean" in the final report.
