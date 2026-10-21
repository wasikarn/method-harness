# Environment variables

Only variables a shipped script actually reads. Set user-scope knobs in `~/.claude/settings.json`
under `env`, never in a committed file.

| Variable | Read by | Purpose |
|---|---|---|
| `MH_PLUGIN_ROOT` | `agents/ideate-critic.md` (runs `skills/workflow/ideate/scripts/rank.py`), `skills/workflow/ideate/references/provenance.md` (doc reads) | Exported at SessionStart by `hooks/session/command-root-anchor.sh` from `CLAUDE_PLUGIN_ROOT`. One live script call goes through it: the ideate critic's `rank.py` step; an eval sandbox may not run the hook. Not a user knob. |
| `MH_COSTS_FILE` | `skills/meta/cost-report/scripts/cost-report-dedup.js` | Overrides the cost log path (default `~/.local/share/kbg/metrics/costs.jsonl`); tests and evals plant a fixture through it. |
| `MH_COST_TRACKER_SETTLE_S` | `hooks/stop/cost-tracker.sh` | Seconds the Stop hook waits for the transcript to stop growing before it reads it (default `1`, GH #329). Tests set `0` so fixtures written up front cost no wait. |
| `MH_GATE_JOURNAL_PATH` | `hooks/gates/_journal.py`, `skills/meta/gate-report/scripts/gate-report.py` (`scripts/_lib/gate-differential.py` sets it per side) | Overrides the gate-verdict journal path (default `~/.local/share/kbg/metrics/gate-decisions.jsonl`); `scripts/run-gauntlet.sh` and every standalone-runnable gate test suite set it to an isolated tmp path so local test runs don't pollute the operator's real journal. |
| `MH_SGG_MAX_CMD_CHARS` | `hooks/gates/subagent-git-guard.py` | Test-layer override of the gate's length cap (default `16000` characters, GH #469); `tests/hooks/test-subagent-git-guard.sh` raises it so its over-16000-character stress rows still run the scan. A value that is not a positive integer keeps the default. |
| `MH_SGG_DEADLINE_SECS` | `hooks/gates/subagent-git-guard.py` | Test-layer override of the gate's own wall-clock deadline (default `5` seconds, GH #469): past it the gate denies and exits 2. `tests/hooks/test-subagent-git-guard.sh` raises it so slow stress rows still run the scan. A value that is not a positive number keeps the default (0 would disarm the timer) and prints a stderr diagnostic; one over 7 is clamped to 7 (under the 8 s hook timeout). |
| `MH_CACHE_DIR` | `skills/meta/harness-audit/scripts/audit.sh`, check 35 | Overrides the mh plugin cache root the audit resolves loadability against; `--plugin-cache <path>` wins over it. |
| `HARNESS_AUDIT_BASE_REF` | `skills/meta/harness-audit/scripts/audit.sh` (`new_vs_base`, used by checks 02 and 03) | Git ref that checks 02 and 03 compare a skill or agent against: a `SKILL.md` or agent file absent from it reports INFO instead of CRIT, since the plugin cache cannot hold a component added after the commit it was built from. Unset, the base is the `gitCommitSha` `installed_plugins.json` records for the audited cache, else `origin/develop`. An unresolvable ref keeps CRIT. |
| `MH_CODEX_DATA_DIR` | `scripts/_lib/codex-state-path.sh`, check 71 | Overrides the paired `codex@openai-codex` plugin's per-plugin data root (default: `~/.claude/plugins/data/codex-openai-codex`) that check 71 reads the review-gate state from. Test-only: points the self-test at a throwaway directory instead of the real, shared one. |
| `MH_CODEX_CACHE_DIR` | check 72 | Overrides the paired `codex@openai-codex` plugin's cache dir (default: newest `~/.claude/plugins/cache/openai-codex/codex/<version>/`) that check 72 reads `VALID_REASONING_EFFORTS` from. Test-only. |
| `MH_FRAGMENTS_DEBUG` | `hooks/sensors/fragments-capture.sh` | Set to `1` to trace each decision point (why a capture did or didn't fire — not armed, window expired, no match, publish race) to stderr. Silent by default; a user knob for debugging the writing-fragments pointer-capture sensor, not read by any other script. |
| `MH_CODEX_QUOTA_STATE_FILE` | `hooks/sensors/codex-quota-sensor.py`, `codex-quota-advisory.py`, `codex-quota-advisory.sh` | Overrides the recorded Codex usage-limit state file (default `~/.cache/mh/codex-quota-state.json`); empty counts as unset. Tests point it at a throwaway path. |
| `MH_CODEX_QUOTA_TTL_SECONDS` | `hooks/sensors/codex-quota-advisory.py` | Seconds a recorded usage-limit failure stays live before the advisory drops it (default 24 h); a non-integer keeps the default. Tests set a small value. |
| `MH_MEMORY_LOCK_WAIT_MAX`, `MH_MEMORY_LOCK_POLL_INTERVAL`, `MH_MEMORY_LOCK_STALE_METADATA_SEC` | `hooks/stop/memory-audit-commit.sh` | Memory-store commit lock: max wait in seconds (default `10`), poll interval (default `0.2`), and the age after which unreadable lock metadata counts as stale (default `300`). Test-layer knobs. |
| `GAUNTLET_JOBS` | `scripts/run-gauntlet.sh` | Test files run in parallel (default `4`, or `1` when `CI` is set). |
| `GAUNTLET_SHARD` | `scripts/run-gauntlet.sh` | `i/N`: run only shard `i` of `N` (GH #400); anything else fails. Unset before child tests run. |
| `GAUNTLET_LOCK_DIR`, `GAUNTLET_LOCK_WAIT_SECS`, `GAUNTLET_LOCK_POLL`, `GAUNTLET_LOCK_MAX_AGE`, `GAUNTLET_LOCK_NOPID_SECS` | `scripts/_lib/gauntlet-lock.sh` | Machine-wide gauntlet queue: lock dir (default `~/.cache/mh/gauntlet.lock`), max wait before running unlocked (`1800` s), poll (`5` s plus jitter), age past which a lock is stale (`3600` s), age a pid-less lock dir must reach to count as a crash leftover (`60` s). |
| `MH_GAUNTLET_LOCK_OWNER` | `scripts/_lib/gauntlet-lock.sh` | Exported by the lock holder with its pid, so a child (a test that runs the pre-push hook) skips the queue instead of deadlocking. Not a user knob. |
| `MERGE_PR_LOAD_MAX` | `scripts/merge-pr.sh` | Load average below which the script merges (default `4`); `tests/scripts/test-merge-pr.sh` sets `4` explicitly. |
| `MERGE_PR_LOAD_WAIT_SECS` | `scripts/merge-pr.sh` | Seconds the script waits for load to drop before it fails with the load figure (default `900`); the test sets `0`. |
| `MERGE_PR_ALLOW_SAME_VERSION` | `scripts/merge-pr.sh` | Set to `1` to skip only the refusal of a head whose manifest version equals `origin/develop`'s, for a PR that needs no bump. A lower version still refuses; the test sets it to cover both cases. |

Native Claude Code variables this plugin relies on but does not own: `CLAUDE_PLUGIN_ROOT`
(every hook command), `CLAUDE_SKILL_DIR` (set while a skill body runs; `harness-audit`,
`memory-lint`, and `cost-report` invoke their bundled scripts through it, so it works in an eval
sandbox where no SessionStart hook ran), `CLAUDE_ENV_FILE` (command-root-anchor writes the export there),
`CLAUDE_CODE_EFFORT_LEVEL` (`model-bench.sh` sets it per `@effort` arm and it reaches the eval
child; per model-config it outranks every frontmatter `effort:` pin, not yet probed inside an
eval child; a bare arm inherits the invoking shell's value), `CLAUDE_CODE_ENABLE_TODO_TOOLS`
(Claude Code gives `TaskUpdate` by default only to Claude 3.x, Opus 4 to 4.7, Sonnet 4 to 4.6
and Haiku 4.5, plus every model in background and cloud sessions; on Opus 4.8+, Sonnet 5 or
Fable elsewhere, `gate:task:complete-separation` has nothing to match unless this is `1` or the
tools are named in `--allowedTools`/`--tools`; tools-reference, "Task tool availability"),
`CLAUDE_CODE_SESSION_ID` (`learn`'s `find-transcript.sh` finds this session's transcript by it;
the failure nudge falls back to it when the payload has no `session_id`),
`CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PROJECT_DIR_NAME` (`scripts/_lib/memory-dir.py` resolves the
memory store from them; `gate-differential.sh` reads transcripts under `CLAUDE_CONFIG_DIR`),
`SLASH_COMMAND_TOOL_CHAR_BUDGET` (check 43's description budget), `CODEX_HOME`
(`codex-resolve-model.py` reads the catalog there), `CI` (`run-gauntlet.sh`'s default job count),
`CLAUDE_PLUGIN_DATA` — observed as `~/.claude/plugins/data/<plugin>-<marketplace>/`, consistent
across every installed plugin on this machine; not documented by Claude Code, and mh doesn't
read it directly (check 71 hardcodes the resolved default instead, since `audit.sh` runs as a
bare `bash` invocation with the env var unset outside an actual plugin-hook context).
