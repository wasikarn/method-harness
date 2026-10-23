# Cloud audit 2026-10-23

Repo-wide audit of `develop` at `364e58f4`, run from a cloud session (Ubuntu, bash 5.2.21, Python
3.13, `awk` = mawk 1.3.4, GNU coreutils, running as root, no `trash`, no mh plugin cache, no
`~/.claude`). Report only: no code was changed. Every finding below was reproduced in that
session; anything not reproduced was dropped.

## Scope note

Priority 1 asked for an adversarial bypass sweep of `irrecoverable.py`. That sweep was **not done**
in this session. The gate's error paths were checked (see "checked, clean"), but no crafted bypass
payloads were tried against its rules. No CRITICAL or HIGH finding below means only that none was
found in what was checked. It does not mean the gate is free of bypasses.

## Findings

| # | Severity | path:line | Defect | Reproduction |
|---|---|---|---|---|
| 1 | MEDIUM | `docs/reference/operating-model.md:43`; `hooks/gates/irrecoverable.py:1375`, `:1585` | §1 says "input it cannot tokenize asks (`could not safely tokenize`)". Both sites call `deny()`, which exits 2 (`irrecoverable.py:502-511`). Either the doc or the gate is wrong. The message text ("confirm with user first") reads like an ask was intended. | `{"tool_name":"Bash","tool_input":{"command":"git log --oneline \"unterminated"}}` piped to `bash hooks/gates/irrecoverable.sh` gives `rc=2`, stderr `[mh:gate] BLOCKED: could not safely tokenize command ...`. Expected per doc: exit 0 with `permissionDecision: ask`. |
| 2 | MEDIUM | `tests/hooks/test-gates-other.sh:404` | The GH #309 drift check passes all ~19.5k shapes as one `bash -c` argument. On Linux this exceeds `MAX_ARG_STRLEN` (128 KiB), so `posix_spawn` raises `E2BIG`. The embedded Python dies, and the row fails with every count as `?`. The awk-routing half of the check never runs on Linux. This one row makes the pre-push gauntlet fail on every Linux machine. `tests/_lib/gates-harness.sh:25-31` already documents this kernel cap for `bash_payload`. | `bash tests/hooks/test-gates-other.sh` gives `❌ GH #309: brace-route.awk missed ? of ? ...`. Running the heredoc alone gives `OSError: [Errno 7] Argument list too long: '/usr/bin/bash'`. With the same script feeding bash on stdin instead, the result is `11702 11702 0 19530 0`: under mawk, no shape is missed and `_bracex` agrees with bash on all 19,530. So the gate is fine; only the test is broken. |
| 3 | LOW | `hooks/gates/irrecoverable.sh:15` | `tr -d "\"'$_bs\\"` ends in one unescaped backslash. GNU `tr` warns about this on stderr for every Bash call that reaches the line, which is every Bash call. On a deny, the warning comes before the `[mh:gate] BLOCKED:` reason that Claude is shown. It also makes the missing-`_run.py` test's stderr noisy. | `jq -nc '{tool_name:"Bash",tool_input:{command:"ls"}}' \| bash hooks/gates/irrecoverable.sh` gives `rc=0` and stderr `tr: warning: an unescaped backslash at end of string is not portable`. Expected: no stderr. |
| 4 | LOW | `tests/hooks/test-subagent-git-guard.sh:1504` (pattern in 38 files under `tests/`) | Test state is reset with `trash <marker> 2>/dev/null \|\| true`. `scripts/run-gauntlet.sh` never checks that `trash` exists. Without it the reset silently fails and state carries over to the next row. In `fp_run`, a stale `PYSTUB_MARK` makes the next row read `fp_py=yes`. A row expecting "reaches python3" can then pass without the gate ever reaching python. A row expecting "no python" fails for the wrong reason, as seen here. | In this session (no `trash`), `bash tests/hooks/test-subagent-git-guard.sh` gives `❌ GH #326 numbers, literals, spaces ... (python yes)`. The marker left by the previous row was never removed. The same cause fails rows in `test-memory-health-nudge.sh` (cache not reset), `test-hook-payload.sh` (stale `__pycache__`), `test-gauntlet-log-preservation.sh`, and the two missing-`_run.py` rows of `test-gates-irrecoverable-2.sh:1290`. In those two rows `_run.py` was never removed, so the gate denied by rule rather than by the missing sibling. |
| 5 | LOW | `docs/reference/operating-model.md:43-51` | §1 lists each gate's missing-sibling behavior. It names `irrecoverable.py` (deny), the four subagent-scoped gates, `routine-trigger-guard`, and `secret-scan.py` (allow). It omits `test-integrity`, `config-write-guard`, and `codex-setup-guard`, which also allow. The code is consistent with the principle in §1, but the list is incomplete. | Copy `hooks/gates/` to a scratch dir, remove `<gate>.py`, and pipe a matching payload into `<gate>.sh`. All three give `rc=0` and stderr `[mh:gate] internal error: sibling script <gate>.py missing or unreadable -- allowing ...`. |
| 6 | LOW | `skills/meta/harness-audit/scripts/checks/02-symlink-integrity-skills.sh:43` vs `checks/03-symlink-integrity-hooks-recurse-hooks-li.sh:14` | With no plugin cache, agent loadability reports one WARN ("expected on a clean CI checkout"), but skill loadability reports a CRIT for every skill. CLAUDE.md's "0 CRIT required" therefore cannot be met on any clean checkout, a cloud session included. | `bash skills/meta/harness-audit/scripts/audit.sh` gives `Critical: 12` (F1–F12: `skill '<name>' not loadable ...`) and `W1: no plugin cache ... agent loadability unverified`. |

## Checked, clean

- `hooks/gates/irrecoverable.sh` error paths. A missing `irrecoverable.py` gives exit 2 with `[mh:gate] internal error ... failing closed`. A missing `_run.py` gives exit 2. A Python rc other than 0 or 2 is mapped to 2. A missing `python3` allows with an announcement (lines 45-48). All of this matches operating-model §1.
- A malformed payload reaching `irrecoverable.py` (`tool_input` not a dict) fails closed with exit 2 (lines 33-37).
- Missing-sibling behavior of `subagent-git-guard`, `task-complete-separation`, `subagent-spawn-guard`, `subagent-verdict-gate`, `routine-trigger-guard`, and `secret-scan`: each allows with a stderr note, as §1 says.
- `brace-route.awk` under mawk (the default `awk` on Debian and Ubuntu): it routes all 11,702 enumerated expanding shapes to Python (finding 2's rerun).
- `tests/_lib/gates-harness.sh` `test_allow`: an ASK payload does **not** pass an allow row. `rc=$(...; echo $?)` also captures stdout, so the JSON makes `rc` non-`"0"`. The comment's claim of "empty stdout" holds, though only by accident.
- Hardcoded home paths: no `/Users/<name>` or `/home/<name>/` in `hooks/`, `scripts/`, or `skills/meta/harness-audit/scripts/`.
- `irrecoverable.py` `_gh_api_write`, `_gh_builtin_write`, and the `_check_window` dispatch were read against the §1 table row and match its description. They were not probed with payloads (see the scope note).
- Test suites run: `test-gates.sh` passed 565/565. `test-gates-irrecoverable-2.sh` passed 640/642, and both failures are finding 4. `test-gates-other.sh` passed 621/622, and the failure is finding 2.

## Not runnable here

- `scripts/run-gauntlet.sh` exits 1. Its failures are covered by findings 2 and 4, plus `tests/skills/test-ste-lint.sh` ("unreadable directory expected exit 2, got 1"). That one is environmental: root can read a `chmod 000` directory. `tests/scripts/test-run-gauntlet-wiring.sh` failed inside the gauntlet but passes standalone. It was not investigated further.
- `skills/meta/harness-audit/scripts/audit.sh` exits 12 for lack of a plugin cache (finding 6).
