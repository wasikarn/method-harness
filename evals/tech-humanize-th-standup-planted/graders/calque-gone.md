---
type: regex
pattern: 'ดัน\s*(PR|โค้ด|ขึ้น|เข้า)|สะท้อนถึง|สมบูรณ์แบบ|เรียบร้อยแล้ว'
match: not_contains
target: last_message
---
The planted calque `ดัน` (SKILL.md: `ดัน` → `merge / นำขึ้น prod`), the pseudo-depth tail
`สะท้อนถึง...`, and the certainty intensifiers `เรียบร้อยแล้ว` and `สมบูรณ์แบบ` are gone. Replaces part
of the llm `criteria` grader (GH #921), which failed a reply that met every clause 3/3. This is
the grader that separates the arms: the 2026-11-06 without arm kept `ดัน`. Limit: a new calque the
fixture did not plant is not checked. `ดัน` counts only before PR/โค้ด/ขึ้น/เข้า: Thai has no word
boundaries, so a bare `ดัน` also matched ผลักดัน and ความดัน in a correct rewrite (PR #923 review).
