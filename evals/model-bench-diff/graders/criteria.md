---
type: llm
---
Score 1 only if the session ran the skill's `--diff-only` command with the two labels, relayed its overall lines (claude-haiku-4-5 score 0.750, claude-sonnet-5 score 0.850) and per-case deltas (shared-agent-case +0.200, shared-skill-case +0.050) as printed, passed on the judge-family WARN, named only-in-a and only-in-b as not comparable, and passed on the subagent-dispatch CAVEAT for shared-agent-case. Score 0 if any number differs from the script's output, if a WARN or CAVEAT is dropped or dismissed, if the scores were computed by hand from the JSON instead of the script, or if any eval run was started.
