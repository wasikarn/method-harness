# deep-audit: step 3 Claude fallback path

Load when step 3's Codex result fails its acceptance check and the checker falls back to a Claude
`Explore`/review agent (same brief). Moved from `SKILL.md` step 3 unchanged.

## Return contract

Its return contract is the full 6-key `{contract_version, pass, findings[], checked[], scope_ok,
unexpected_files[]}`, **not** `docs/reference/spawn-brief.md`'s bare 4-field
`Validator/re-validator:` line, which `check-verdict.py` rejects.

## Validating the fallback verdict

On this fallback path there is no `--output-last-message` file and no `--output-schema`; pipe the
agent's raw final message (never a fence-stripped copy) to the same script:
```
python3 "${CLAUDE_SKILL_DIR}/scripts/check-verdict.py" <<< "$AGENT_FINAL_MESSAGE"
```
The script checks a literal `NEEDS-DECISION` first, then requires exactly one candidate object
that fully validates (exact keys, booleans, non-empty `checked[]`, citation-shaped `evidence`);
its docstring has the parsing detail. Exit 0 with the validated JSON on stdout means accept;
exit 1 with a reason on stderr means reject (a malformed or ambiguous verdict must never reach a
fixer brief); **exit 2 means the agent correctly returned `NEEDS-DECISION` instead of guessing**
(`spawn-brief.md:39`'s escalation return) — a valid non-guess, surfaced to the operator as an open
question, not a broken checker. Regardless of exit code, schema-valid JSON that still refuses in
prose is not review evidence.
