---
type: regex
pattern: '^[^#\n][^\n]*—'
match: not_contains
flags: m
target: {source: file, path: README.md}
---
Cue #14 in the prose: no line outside a `#` line carries an em dash. The fixture plants one in the
prose paragraph; the code block's `# warm every region — ...` comment is exempt, and
`code-block-intact.md` keeps it byte-identical. Replaces the llm `criteria` grader (GH #921), which
failed the correct rewrite 3/3. Limit: a prose line that itself starts with `#` (a heading) is not
checked.
