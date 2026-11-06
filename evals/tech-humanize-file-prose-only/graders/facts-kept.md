---
type: regex
pattern: 'after each deploy[\s\S]*regions\.yaml[\s\S]*/warm'
match: contains
target: {source: file, path: README.md}
---
The rewrite keeps the file's real instructions: run it after each deploy, it reads `regions.yaml`,
and it hits `/warm`. Replaces the llm `criteria` grader (GH #921), which failed the correct
rewrite 3/3. Limit: an invented flag, region or timing goes unchecked (evals/README.md, "Not
covered by evals").
