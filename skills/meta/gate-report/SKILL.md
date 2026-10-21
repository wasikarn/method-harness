---
description: "Gate-report: ask/deny counts per gate from the gate-decisions journal, and mh skills unused in the last N sessions. Use for gate friction or stale skills."
name: gate-report
disable-model-invocation: true
model: inherit
effort: low
---

# Gate Report

Summarize `hooks/gates/_journal.py`'s log, `~/.local/share/kbg/metrics/gate-decisions.jsonl`:
every non-allow gate verdict (ask/deny/`allow-suppressed`) on this machine, by gate id and tool.

## Run

One Bash call; do not open the log or count rows by hand.

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/gate-report.py"
```

`MH_GATE_JOURNAL_PATH=<path>` points at another log (the same variable `_journal.py` reads). A
missing log prints `Gate journal not set up.` and exits 0; relay that line. Never invent numbers.

## Skill usage

mh skills with no recorded use in the last N sessions (default 100). Read-only and machine-local
(`~/.local/share/kbg/metrics/skill-usage.jsonl`).

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/skill-usage.py" [--sessions N]
```

It lists model-invocable skills, then manual-only ones (`disable-model-invocation: true`, used
only when typed), each with its last-use date. A missing log prints `Skill usage log not set up.`

- **Zero use is not broken.** A rare skill and a never-matching description look the same here.
  List them; a human decides keep, trim or fix.
- **N counts sessions that used an mh skill**; a session with no skill use leaves no row.
- **Typed uses are logged** (`source: typed`), so manual-only skills do show up.

## Read back

Quote the script's counts as printed.

- **Ask-count only, never wait-time.** Rows carry no resolution timestamp.
- **`allow-suppressed` isn't a block.** `secret-scan.py` logs it when a suppression marker
  (`gitleaks:allow` etc.) let a match through. Keep it out of an "interruptions" total, or say so.
- **`would_deny`/`would_ask` rows are not blocks.** They come from a gate's `SHADOW_RULES`, which
  journal and allow. The "Shadow rules" section shows each rule's count, sessions and up to 3
  sample commands. A rule is ready to enforce (delete its id from `SHADOW_RULES`) when its
  matches across several sessions are all real hits, with no false positive.
- **Session-less rows are left out** and reported as `Ignored N session-less row(s)`: they came
  from tests or direct gate runs. A large N means something writes to the real journal without
  `MH_GATE_JOURNAL_PATH`; say so.
- **A `session_id` is not proof of a live call.** Live ids are UUIDs; the `Non-UUID session id(s)`
  line names made-up ones (`test-session`, `s`, `t`) that still count. Quote it, and say when a
  gate's count is mostly made-up ids.
- **A high count isn't automatically a problem.** Check the gate's false-positive history before
  recommending a change.
