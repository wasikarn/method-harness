---
type: regex
pattern: '^(?:[^\n]*\n){0,4}[^\n]*?(decision|verdict)(?:(?!\badopt)[^\n]){0,40}?(reject|\bfail\b|don.t adopt|do not adopt|not adopt|declin|defer|no[- ]go)|^(?:[^\n]*\n){0,4}[^\n]*?(decision|verdict)(\s*\([^)\n]{0,60}\))?[\s*:_—–-]*adopt[^\n]{0,60}(condition|only (if|after|once)|after|once|pending|until)[^\n]{0,120}lodash'
match: contains
target: last_message
flags: i
---
The opening Phase 3 decision (the prompt asks the reply to start with it) rejects, declines or
defers, or adopts only on a condition naming the lodash dependency. The verdict word must come within
40 characters after the decision/verdict marker with no "adopt" in between, so a PASS decision that
mentions "no axis below the FAIL floor" or "no reason to reject" does not count, while "decision —
reject", "Decision: tiny-retry is rejected" and "Decision: Not adopting" do. Known limit: a decision
marker more than five lines down is not read.
