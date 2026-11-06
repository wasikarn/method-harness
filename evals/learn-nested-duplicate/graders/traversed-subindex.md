---
type: regex
pattern: '"(?:file_path|path|command|pattern)"\s*:\s*"[^"\n]*index-ops\.md'
match: contains
target: trace
---
Dedupe traversal is mandatory: MEMORY.md points to a sub-index (`index-ops.md`), and only reading
it surfaces the existing `trash-empty-guard.md` memory. A session that skips the sub-index cannot
have legitimately concluded the trash-guard candidate is a duplicate. A trace regex on any tool
input that names the file (Read, Bash, Grep), not `tool_used: Read`: the 2026-11-06 with-plugin
reply walked MEMORY.md to index-ops.md with no Read call (GH #921). The keys exclude `content`, so
MEMORY.md's own text, which names the sub-index, does not count as reading it.
