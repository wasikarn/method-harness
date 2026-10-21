# deep-audit: design rationale

Why each rule in `SKILL.md` exists. Not needed to run the skill; read it before changing a rule.

## Step 3: withholding the maker's claims

Handing the checker the maker's own per-file claims or rubric scores is the CoVe "joint" failure
mode: a same-session check that shares the generator's trace tends to inherit its blind spots
(`docs/research/adversarial-attacker-dispatch-patterns-2026-09-19.md` §1, CoVe's
factored-vs-joint ablation: "the verification questions might hallucinate similarly to the
original baseline response, which defeats the purpose").

## Step 3: primed items need CONFIRMED/DISPUTED entries

"Find what it missed" framing alone makes confirming a named item indistinguishable from never
having looked. A checker primed with 3 specific known findings has returned several new ones
while addressing none of the primed 3. One `findings[]` entry per primed item, `summary` starting
`CONFIRMED:` or `DISPUTED:`, fits the existing schema (`summary`/`evidence` are free text) and
turns "checked and cleared" and "never looked" into different, citable strings.

## Step 3: Codex sandbox wording

`codex exec --sandbox read-only` is sandboxed against model-generated shell commands
(`codex exec --help`'s own wording); with the brief's no-mutation line that is not an unqualified
"read-only, guaranteed", since neither layer alone covers every tool an environment might load.

## Step 3: why the fallback contract has six keys

`docs/reference/spawn-brief.md`'s generic `Validator/re-validator:` shape has four fields and is
intentionally left unchanged: it backs many unrelated Rule-13 validator dispatches. This skill's
`check-verdict.py` validates both paths against the unconditional 6-key contract, so a fallback
agent following the 4-field shape is rejected:
`echo '{"pass": true, "findings": [], "scope_ok": true, "unexpected_files": []}' | python3 scripts/check-verdict.py`
exits 1 on `missing=['checked', 'contract_version']`.

## Step 3: how check-verdict.py parses a raw message

A live run of the fallback path (2026-09-18) returned a schema-valid object followed by
unrequested prose after the closing code fence, so "strip a leading/trailing fence" does not
survive. The script therefore:

- checks for a literal `NEEDS-DECISION` first; it always wins over nearby JSON, so a hedged
  object quoted ahead of a real escalation cannot override it, and JSON-shaped prose after the
  escalation is not misread as a malformed verdict;
- otherwise scans every `{` in the text (narration can itself contain a brace, e.g. an echo of the
  return-contract line) and keeps every candidate that fully validates: exact key-set equality,
  `pass`/`scope_ok` as real booleans, `findings[]` items exactly `{summary, evidence}`,
  `checked[]` non-empty with items exactly `{claim, evidence}`, citation-shaped `evidence` (the
  regex idea-audit's `check-citations.py` uses), `unexpected_files[]` a list of strings;
- requires exactly one valid candidate: two distinct valid objects (a decoy example ahead of the
  real verdict) reject as ambiguous.

`checked[]` is required because `pass: true, findings: []` is schema-valid even when a checker
addressed none of its primed items.

## Step 3: hard-fail override

Without it, step 2's "insufficient evidence, left out of the total" allowance would let a
checker-less run still pass on its remaining dimensions.

## Step 6: why the trigger is not a bare fix count

A single fix can interact with code already in the file exactly the way two fixes interact: it can
silently disable an unrelated feature when it shares an early-exit path with pre-existing code,
and still pass its own point-by-point verification. A strict "2+ fixes" gate would skip exactly
that case. The 2-fix trigger can also hold only by coincidence: a finding can come from a peer
commit consuming the fixed function as a black box, unrelated to whether the two fixes share a
surface.
