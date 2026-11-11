# Does mh's runtime read tests/evals, and where does cost-tracker send data?

Issue: wasikarn/method-harness#1005. Read-only investigation of this checkout (base `f6aa91ea`, mh 1.1.610).
Method: `/usr/bin/grep -rnE '(^|[ "(/])(tests|evals)/' hooks skills agents`, then read each hit in context.

## (1) Runtime files that mention `tests/` or `evals/`

The grep finds 12 files, not 8: five hooks and seven skill files. Verdict: READS means the code opens or executes a path under `tests/` or `evals/` at run time. NAMES means a comment, message or doc string only.

| File:line | Mention | Verdict |
|---|---|---|
| hooks/gates/irrecoverable.py:3, 1456, 2148 | Comments naming `tests/hooks/test-*.sh` | NAMES |
| hooks/gates/brace-route.awk:13 | Comment naming `tests/hooks/test-gates-other.sh` | NAMES |
| hooks/gates/test-integrity.py:40 | Comment about the shape of `tests/hooks/*.sh` assertions. The gate inspects the tool input of a test-file write; it does not open the repo's tests | NAMES |
| hooks/gates/secret-scan.sh:48 | Comment naming `tests/hooks/test-secret-scan.sh` | NAMES |
| hooks/session/memory-health-nudge.sh:136 | Comment naming `tests/hooks/test-memory-health-nudge.sh` | NAMES |
| skills/meta/cost-report/scripts/cost-report-dedup.js:5 | Comment naming `tests/skills/test-cost-report.sh` | NAMES |
| skills/meta/harness-audit/SKILL.md:53 | Doc line telling a human to run `tests/skills/harness-audit/test-harness-audit.sh` | NAMES (doc, never executed by the plugin) |
| skills/meta/harness-audit/scripts/checks/11-orphaned-hooks-...sh:18 | `case ... tests/*) continue` skips a `hooks/tests/` subpath when listing hook files; opens nothing under `tests/` | NAMES |
| skills/meta/harness-audit/scripts/checks/75-manifest-skill-reference-drift.sh:89, 104 | Lines 89 and 104 are a comment and a message. Line 98 (next to the hit) builds `$CLAUDE_DIR/evals` and `$CLAUDE_DIR/tests` and runs `grep -rhoE` over them, but only for targets that pass `[ -e ]`, so missing dirs are skipped | READS (optional, guarded, maintainer tool; see note A) |
| skills/meta/model-bench/scripts/model-bench.sh:95-96 | After `cd "$ROOT"` (line 93; ROOT is four levels above the script, line 9) it runs `mkdir -p evals/results` and creates a bench dir there. It then runs `claude plugin eval .` (line 113 echoes the command), which reads the repo's `evals/` | READS and WRITES (maintainer tool; see note A) |
| skills/meta/model-bench/scripts/model-bench-diff.py:52, 64, 235 | Doc string and help text name `evals/judge-models.tsv`. The real read is line 242, `eval_judge_models.load(... sidecar_path())`. `DEFAULT_EVALS` is `scripts/_lib/../../evals` (scripts/_lib/eval_judge_models.py:21, 35-36), and `load` returns `{}` for a missing file (line 42-43) | READS, optional (missing file tolerated) |

Result: no file under `hooks/` reads or executes anything under `tests/` or `evals/`. All five hook hits are comments. Two skill scripts touch those folders (`model-bench`, check 75 of `harness-audit`). Both are maintainer tools. Check 75 and the sidecar load tolerate absence. `model-bench` would fail to do useful work without `evals/` (it needs it for `claude plugin eval`) but does not break the session. A plugin folder without `tests/` and `evals/` does not break any hook. Unverified: I did not run the plugin from a trimmed copy; this is from reading the code.

Note A: `.claude-plugin/plugin.json` lists `./skills/meta/`, so `model-bench` and `harness-audit` ship. Their `tests/` and `evals/` reads are reached only when a maintainer runs them.

### Paths that go up with `..`, or rely on `docs/` and `scripts/`

Every `..` below stays inside the repo root (the plugin root); none escapes it. They reach `scripts/`, a sibling of `hooks/` and `skills/`. So `scripts/_lib/` and `docs/METHODOLOGY.md` are runtime dependencies and must ship with the plugin.

| Consumer | Resolves to | If missing |
|---|---|---|
| hooks/sensors/fragments-arm.sh:51, 75; fragments-capture.sh:30, 61; hooks/session/fragments-surface.sh:40 (`$HERE/../../scripts/_lib/...`) | `scripts/_lib/fragments-state.sh`, `fragments_arm_parse.py`, `fragments_capture_parse.py` | Hook exits 0 (fail-open, debug line at fragments-capture.sh:30) |
| hooks/sensors/failure-diagnose-nudge.py:36, 161 | `scripts/_lib/hook_payload.py` | Prints a diagnostic (line 161) |
| hooks/session/skill-usage-telemetry.sh:73 | `scripts/_lib/skill-namespace.py` | Unverified |
| hooks/session/memory-health-nudge.sh:42, 86; hooks/stop/memory-audit-commit.sh:39 | `${CLAUDE_PLUGIN_ROOT}/scripts/_lib/memory-dir.py`, `.../skills/meta/memory-lint/scripts/memory-lint.py` | Unverified |
| hooks/session/doctrine-bootstrap.sh:6 | `${CLAUDE_PLUGIN_ROOT}/docs/METHODOLOGY.md` (injected at SessionStart); the only `docs/` file a hook reads | Unverified |
| hooks/gates/_journal.py:43, hooks/gates/_outcome.py:33, hooks/stop/cost-tracker.sh:32 | `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` (version stamp; `/nonexistent` fallback, error swallowed, version null) | Row still written |
| skills/{deep-audit,compliance-audit,idea-audit}/scripts/check-verdict.py and idea-audit/scripts/check-citations.py (`../../../../scripts/_lib` on sys.path) | `scripts/_lib/*.py` | Import error |
| skills/meta/model-bench/scripts/model-bench.sh:9-11, model-bench-diff.py:17 | `scripts/_lib/eval-default-enabled.sh`, `eval_judge_models.py` | Script fails |
| skills/meta/harness-audit/scripts/audit.sh:25, 36-41 | `scripts/_lib/frontmatter-helpers.sh`, `codex-state-path.sh`, `err.sh`. Its checks read `docs/` (35, 72, 76, 79, 80) | Most checks `info`/`warn` and skip |
| skills/meta/gate-report/scripts/skill-usage.py:45 | `parents[3]`, default `--skills-dir` (the `skills/` folder) | n/a |
| skills `${MH_PLUGIN_ROOT}/...` references in markdown | `docs/research/kbg-vs-adhd.md`, `skills/workflow/ideate/scripts/rank.py` | Unverified |

A text-reference closure over `skills/` and `agents/` would catch the `${MH_PLUGIN_ROOT}` links above. It would miss the `$HERE/../../scripts/_lib/...` and `dirname(__file__)/../../../../scripts/_lib` forms, which are built from variables; those are the `scripts/_lib/` rows. I did not enumerate every variable-built path in `skills/**/*.md`, so treat the table as the confirmed set, not a proof of completeness (unverified).

## (2) Network use: `hooks/stop/cost-tracker.sh` and other runtime files

Search: `\b(curl|wget)\b|https?://` over `hooks skills agents scripts .claude-plugin` (all file types, then `.md` separately), then `urllib|requests|socket|http.client|urlopen|nc|ssh` over the same.

### cost-tracker.sh sends nothing

- The only `https://` in `hooks/stop/cost-tracker.sh` is a comment (line 331, a link to GitHub issue 162). The file has no `curl`, `wget`, `nc`, `ssh` or socket call. The `nc` matches in a broad grep were `jq -nc` flags (lines 118, 292, 645, 649).
- What it does: on every Stop it reads the session transcript (`transcript_path` from the hook payload, line 20), sums per-model token usage with `jq`, prices it locally, and appends rows to `$HOME/.local/share/kbg/metrics/costs.jsonl` (header lines 1-2, 45-46, append at 674). It keeps a dedup marker file (lines 499-501, 679). A row carries session id, model, token counts, cost, the mh plugin version (line 32) and the HEAD commit of the session cwd (comment, lines 28-31).
- Data leaving the machine: none. Host: none.
- On by default? It is registered in `hooks/hooks.json` and runs on each Stop whenever mh is enabled; mh itself is `defaultEnabled: false` (.claude-plugin/plugin.json:13). I found no separate switch for it. Without `jq` it exits early (lines 22-28).
- `hooks/mod/cost-ledger.ts` reads the same local ledger and has no network code (no match in the search).

### Every other tracked runtime file with curl, wget or a URL

| File | What it is | Leaves the machine? | On by default? |
|---|---|---|---|
| skills/workflow/idea-audit/SKILL.md:76 (rationale in references/rationale.md:39-41) | Instruction text for the model: for a URL source, run `curl -fsSL --max-time 30 <url> -o <path>`. The skill also allows `firecrawl_search`/`WebSearch` (references/phase-0-locate-source.md:8) | Only a GET for the URL the user supplied, from the user's machine to that host. The skill text attaches no repo or transcript data to it | No. Only when the user runs idea-audit on a URL; the Bash call still goes through the user's permission rules |
| skills/workflow/performance-optimizer/SKILL.md:40-42 | Example `npx lighthouse https://your-app.com` commands | Only if the user runs them on their own app | No (example text) |
| skills/design/ste-lint/scripts/ste-lint.py:779 | `https://example.com` inside a self-test string | No | No (skill is not in plugin.json's list) |
| skills/*/references/*-output-schema.json (3 files) | `$schema` URI `http://json-schema.org/draft-07/schema#` | No fetch by these scripts as far as I read (unverified for any validator that might resolve it) | n/a |
| .claude-plugin/plugin.json, marketplace.json | `$schema` and GitHub homepage/repository links | No | n/a |

`hooks/gates/irrecoverable.py` and `subagent-git-guard.py` mention `gh api` only to classify and deny or ask on commands the model proposes; neither has a network library. `scripts/merge-pr.sh`, `sync-pr-head.sh` and `scripts/_lib/gauntlet-pass.sh` use `gh`; they are maintainer scripts outside `hooks/`, `skills/` and `agents/`, and I did not read them in detail (unverified beyond the grep hit).

Bottom line: no hook, agent file or skill script in this checkout makes an outbound request. `cost-tracker.sh` writes a local append-only file. The only runtime `curl` is model-run instruction text in the idea-audit skill, user-triggered, fetching only a user-given URL.
