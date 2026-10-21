# Cost baseline

What mh puts into a model's context, and what each context-injecting hook costs in wall time.
Measured 2026-10-21 on base `80155f58` (mh 1.1.216), Claude Code 2.1.306, codex-cli 0.163.0.
Re-measure with the method below and diff the tables; do not edit old numbers in place.

Tokens are `bytes / 4`, an estimate, not a tokenizer count.

## Per session (paid on every session start)

| Item | Bytes | ~Tokens | Source |
|---|---:|---:|---|
| Doctrine (`hooks/session/doctrine-bootstrap.sh` stdout: `docs/METHODOLOGY.md` 3742 B in `<doctrine>` tags) | 3765 | 941 | SessionStart, no matcher |
| Skill listing, 8 model-visible skills (`- mh:<name>: <description>` lines) | 1586 | 397 | SKILL.md frontmatter |
| Agent listing, 10 agents (`- mh:<name>: <description>` lines; the per-agent tools suffix Claude Code adds is not counted) | 2064 | 516 | agents/*.md frontmatter |
| **Total** | **7415** | **~1854** | |

Not in context (0 B; 897 B of listing lines for the five together): `ste-lint` is deliberately
unshipped (outside every `plugin.json` `skills` entry; `MANIFEST_EXPECTED_EXCLUDED` in the
audit); `gate-report`, `model-bench`, `compliance-audit`
and `post-mortem` carry `disable-model-invocation: true`.

## Per compaction

| Item | Bytes | Note |
|---|---:|---|
| Doctrine again | 3765 (measured with `"source":"compact"`) | `doctrine-bootstrap.sh` has no matcher, so it re-runs on `compact`; `command-root-anchor` and `memory-health-nudge` also re-run and printed 0 B |
| `fragments-surface.sh --reinject` | 0 here; when fragment files exist, roughly 400-650 B of fixed text (estimate from the printf source, not emitted bytes) + one line per file | matcher `compact` |

## Per event (conditional)

| Hook | Trigger | Bytes when it fires |
|---|---|---:|
| `sensors/failure-diagnose-nudge` | a Bash call fails, including one a PreToolUse gate denied before it ran; once per distinct command per session (and per subagent) | 431 |
| `session/memory-health-nudge` | memory-lint reports `findings: [1-9]`, or the store's auto-commit failed | ~200 B fixed + the lint output (estimate from source) |
| `session/fragments-surface` (startup/resume/clear) | fragment files recorded for this project | roughly 400-650 B fixed + one line per file (estimate from source) |
| `sensors/codex-quota-advisory` | a Codex CLI call is about to run and a usage-limit failure was recorded within the TTL (24 h) | 388 with a 30 B recorded message (measured), so ~358 + message |

Not context: the `hooks/mod/cost-ledger.ts` module writes ledger rows and may show a status line or
toast; Stop hooks write files only.

## Hook wall time

Median of 3 runs, ms. Each figure includes ~30 ms of probe overhead (the no-op row), so net hook
time is roughly the figure minus 30.

| Hook | ms |
|---|---:|
| no-op script (probe overhead) | 31 |
| `session/command-root-anchor.sh` | 31 |
| `session/doctrine-bootstrap.sh` | 32 |
| `session/memory-health-nudge.sh` | 114 |
| `session/fragments-surface.sh` | 98 |
| `session/fragments-surface.sh --reinject` | 98 |
| `sensors/fragments-arm.sh` (UserPromptSubmit, every prompt) | 38 |
| `sensors/failure-diagnose-nudge.sh` (firing) | 62 |
| `sensors/codex-quota-sensor.sh` | 62 |

SessionStart sum, net of overhead: ~155 ms (summed serially; Claude Code may run them in parallel).

## Method

1. Hook output: pipe a JSON payload into `bash "$CLAUDE_PLUGIN_ROOT/<hook>"` with
   `CLAUDE_PLUGIN_ROOT` set to the checkout and cwd at its root; count stdout bytes, or
   `hookSpecificOutput.additionalContext` bytes when stdout is JSON. Use a fresh `session_id` per
   run, or the failure nudge's per-command dedupe reads as 0 B. Payloads:
   - SessionStart: `{"session_id":"<fresh>","hook_event_name":"SessionStart","source":"startup","cwd":"<root>","transcript_path":"/nonexistent"}` (`"source":"compact"` plus `--reinject` for the compaction row)
   - UserPromptSubmit: `{"session_id":"<fresh>","hook_event_name":"UserPromptSubmit","prompt":"fix the bug","cwd":"<root>"}`
   - PostToolUseFailure: `{"session_id":"<fresh>","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"false"},"error":"exit 1","cwd":"<root>"}`
2. Listings: parse each `SKILL.md` and `agents/*.md` frontmatter; take `name` and the one-line
   `description` with surrounding quotes stripped; count UTF-8 bytes of `- mh:<name>: <description>\n`.
   Count only skills under a `plugin.json` `skills` entry and without
   `disable-model-invocation: true`.
3. Timing: wall time per call from Python `time.time()` around the pipe, three runs, median,
   with a no-op script through the same path as the overhead row.
4. Conditional rows: the worktree probe had no fragment files, memory-lint found nothing in the
   shared store (a linked worktree resolves to the main checkout's store), and no quota failure
   was recorded. The codex advisory was measured by writing
   `{"recorded_at": <now>, "message": "You have hit your usage limit."}` to a temp file, pointing
   `MH_CODEX_QUOTA_STATE_FILE` at it, and sending a PreToolUse Bash payload whose command is
   `codex exec --sandbox read-only hi`. The rest are estimates from each script's fixed text.
