---
type: regex
pattern: 'subagent[^\n]{0,300}(may|might|does|do)\s?n[o.]t[^\n]{0,40}(reflect|measur|come from)[^\n]{0,40}model|(may|might|does|do)\s?n[o.]t[^\n]{0,40}(reflect|measur|come from)[^\n]{0,40}model[^\n]{0,300}subagent|pinned subagent|subagent[\s\S]{0,120}(pinned|regardless of --model)'
match: contains
target: last_message
flags: i
---
The script's CAVEAT reaches the reader, verbatim or paraphrased: `shared-agent-case` dispatches a
subagent, so its delta may not reflect the subject model. The llm `criteria` grader passed a reply
with this caveat removed (3/3 haiku votes, 2026-11-06), so this regex carries the check.
