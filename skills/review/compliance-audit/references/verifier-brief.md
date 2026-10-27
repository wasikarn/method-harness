# Phase 2 — adversarial-completeness mandate + per-requirement verdict

Moved verbatim from `SKILL.md` Phase 2 (progressive disclosure). Read before writing the
verifier's brief — this decides which requirements get the adversarial mandate, and how a found
bypass maps onto CONFORMS / DEVIATED / MISSING.

**Adversarial-completeness mandate** for any requirement touching a security/gate/verifier-
perimeter surface — treat a requirement as touching one whenever its own text names auth, access
control, rate limiting, input validation, secrets, or an abuse/fraud gate; when genuinely unsure,
default to applying the mandate rather than hedging (a false positive costs one extra check, a
false negative costs a missed finding). Applying it means tracing the diff's actual comparison/
validation logic for that surface, not naming a plausible bypass category and stopping — naming
the mandate without tracing the code has missed real, open bypasses (an HMAC check running
against a framework-parsed body instead of raw bytes; a clock-skew guard whose comparison
silently passes when the claim it depends on is simply absent, not wrong). Not "confirm my new
tests are honest" but "enumerate bypass permutations in this family and try to find one still
open" — read the actual validation code line by line for this surface, don't recall a category
from memory and call it enumerated. An in-family bypass found → flag for remediation (note it in
the report; this version does not auto-fix). An out-of-family gap (new attack class entirely) →
log as a known-gap for the user's decision; do not silently widen scope.

**Per-requirement verdict.** Return one verdict per requirement: **CONFORMS** / **DEVIATED**
(state what changed, and whether the justification is *accepted*) / **MISSING** /
**UNVERIFIABLE** (the check genuinely can't be exercised here, e.g. it needs a live external
service — it never counts as a pass on its own; `accepted` stays `null`). When an
adversarial-completeness finding surfaces a bypass, it downgrades the verdict only if the bypass
falls within the scenario the requirement's own text names — e.g. a requirement to validate "the
incoming signature" that turns out to validate the wrong bytes is still about validating the
incoming signature, so DEVIATED is correct. A bypass that exploits a scenario the requirement's
text never named at all — e.g. a guard scoped to "exp too far in the future" doesn't cover a
token missing `exp` entirely — stays **CONFORMS**, with the bypass logged as an attached note,
not folded into the verdict: the requirement is met on its own terms even though a related gap
exists nearby. Without this distinction, a verifier that traces deep enough to find a real
bypass has nowhere to put it except downgrading an otherwise-conforming requirement, which hides
which items are the actual open ones.

**Final output contract.** End your message with exactly one JSON object matching
`references/verifier-output-schema.json`: `{"requirements": [{"id", "verdict", "note",
"accepted"}...], "gauntlet": {"command", "sha", "exit_code", "output_tail"}, "scope_ok",
"unexpected_files": [...]}`. `accepted` is `null` for CONFORMS/MISSING (acceptance isn't a
question for those) and a real boolean for DEVIATED — leave it `false` unless the plan or
requirement text itself sanctions this exact deviation, cited as a backticked command or
`path:line`; you report whether it is sanctioned, you don't decide acceptance. Do not compute or
include a `pass` field yourself — `scripts/check-verdict.py` computes it from this object. If you
cannot safely determine something (the pinned SHA won't check out, the gauntlet command is
ambiguous, or the gauntlet fails and fails identically at the base SHA in the same sandbox —
`references/sandbox-gauntlet.md`, from `SKILL.md` Phase 2's sandbox-contract bullet), return `NEEDS-DECISION <question>` instead of
guessing — never a hedged JSON object.
