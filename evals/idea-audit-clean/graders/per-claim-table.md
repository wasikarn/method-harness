---
type: regex
pattern: '\|[^\n]*\|\s*[^\w\s|]{0,4}\s*\**\s*(MATCH|PARTIAL|GAP|N[-/]?A)\b[^\n]*\n(?:[^\n]*\n){0,12}?[^\n]*\|\s*[^\w\s|]{0,4}\s*\**\s*(MATCH|PARTIAL|GAP|N[-/]?A)\b'
match: contains
target: last_message
flags: i
---
The final message carries the skill's per-claim verdict table: at least two table rows whose
verdict cell opens with MATCH, PARTIAL, GAP or N-A (N/A, lower case and a leading emoji also count).
The prompt asks for the table in the message, since the skill otherwise writes it only to its
`docs/research/` artifact, whose path varies by topic and date, so a `focus` file grader cannot
target it. Known limit: any other table with two rows whose cell opens with N/A (a criteria table
with "n/a" reasons) also passes.
