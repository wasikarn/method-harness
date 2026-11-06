---
type: regex
pattern: 'dependenc[^\n]{0,200}(SOURCE-PITCH\.md:\d|package\.json[^\n]{0,60}(:\d|\blines?\b|block|snippet|typed|embedded|lists|shows|\{\}))|package\.json[^\n]{0,120}(lists|declares|shows|has) no (runtime )?dependenc|"dependencies"\s*:\s*\{\}'
match: contains
target: last_message
flags: i
---
The "zero runtime dependencies" claim is weighed against the package.json block embedded in
SOURCE-PITCH.md (cited by line, quoted, or described as listing no dependencies), whether the report
then counts the block as consistent or as the author's own unverified text, not just repeated back.
A regex, not an llm rubric: the one-word haiku judge passed a reply that only repeated the claim
(2026-11-06, GH #920). `companies-unverified.md` checks the other half.
