---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?performance-optimizer"'
min: 1
---
Display-only trigger: confirms the `mh:performance-optimizer` skill was actually loaded via the Skill tool in
this run, so an outcome grader is never scoring a run that answered without the skill. `arm`
is left unset since this is the plugin's own mechanism: excluded from scoring in both arms,
reported for visibility only.
