---
type: regex
pattern: '(?:CRITICAL|HIGH)\b[^\n]*\n(?:[^\n]*\n){0,2}[^\n]*billing\.py:\d+|billing\.py:\d+[\s\S]{0,400}(?:CRITICAL|HIGH)'
flags: i
match: contains
target: last_message
---
The swallowed `except Exception: pass` in `app/billing.py` must be reported at its line, sized CRITICAL or HIGH: `mark_paid` marks the order paid after a failed charge.
The severity may come first, in the heading (`### 1. CRITICAL: ...`), with `**Location:** .../billing.py:5-9` on the next line, as in the 2026-11-06 run (GH #921).
