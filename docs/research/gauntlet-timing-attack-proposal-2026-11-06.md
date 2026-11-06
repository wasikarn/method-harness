# Proposal: scoped gauntlet at merge time (mh repo)

## Problem
Every `scripts/merge-pr.sh` and `scripts/sync-pr-head.sh` run executes the FULL gauntlet on the exact tree that will land on develop, under a machine-wide lock. For a docs-only or single-skill PR this is slow: the gate suites are about half of test time, one gate suite file ran 209 s under load, and a run can wait more than 10 minutes on the lock. The version bump changes the tree on every merge, so the tree-hash pass cache only helps a rerun of the same tree, never a different PR.

## The change (three pieces, to be attacked as one proposal)
1. At merge time, run the level that `scripts/gauntlet-plan.sh` picks for the merged tree's diff against the up-to-date develop (low, medium or full), instead of always full. A path no rule covers, and shared code, still give full. Only a full run keeps writing the pass cache.
2. Split the pass cache by test group, keyed by a hash of each group's inputs, so a version bump alone does not invalidate every group.
3. Run the heavy gate suites (`test-gates-irrecoverable-2.sh`, `test-gates.sh`, `test-gates-other.sh`, `test-subagent-git-guard.sh`) only when a path under `hooks/gates/` changed.

## Must stop
- A tree that fails any existing test must not land on develop through the merge script, including failures that appear only when two PRs are combined (GH #445 and #446 were green alone and red together).
- A test that pins a rule in a sibling file must still run when the rule changes (PR #751: a gate change was checked with two of four suites and `test-gates-other.sh` failed 22 rows at merge).
- A PR must not be able to weaken its own gate by editing the files that decide the level (the rules file, the planner script, the runner) and then being judged by the weakened rules.
- A pass recorded for one tree or one test group must never satisfy a different tree or group.
- A sourced helper dependency that a file-based path mapping cannot see must not hide a failure.

## Must allow
- A docs-only PR merges with lint and harness-audit only.
- A change to one skill or agent runs that skill's tests plus the audit, not the whole suite.
- Re-running `merge-pr.sh` on an unchanged tree reuses the cached pass.
- Shared code (`scripts/_lib/*`, `tests/_lib/*`, `hooks/gates/_*`, `git-hooks/*`, `.claude/*`, runner) and unmapped paths still run full.
- The operator can force a full run (`GAUNTLET_PASS_CACHE=0`, or a flag) for any merge.

## Known facts
- verified: `scripts/merge-pr.sh:4-9` runs the full gauntlet on the exact merged tree under the lock before pushing, "#445 + #446 were green alone and red together"; develop holds still while a merge's gauntlet runs. Source: the script header.
- verified: GH #735 says "The safety that matters is in `merge-pr.sh`: the exact merged tree passes the full gauntlet before `gh pr merge` ... That stays." GH #749 says merge is `full`, "not adjustable", and that the miss-rate log is written "on every merge-time full run". Source: `gh issue view 735` and `gh issue view 749` on wasikarn/method-harness.
- verified: `scripts/gauntlet-rules.txt` (header and rules): one rule per line, `<glob> <level> [tests]`, `*` also matches `/`, the highest level over matching rules wins, a path no rule matches gives full. Shared code (`tests/_lib/*`, `scripts/_lib/*`, `scripts/run-gauntlet.sh`, `git-hooks/*`, `hooks/*.json`, `hooks/gates/_*`, `.claude/*`) is full. The rules file itself and `scripts/gauntlet-plan.sh` are `medium` with three tests (`test-gauntlet-plan.sh`, `test-gauntlet-levels.sh`, `test-merge-pr.sh`). The manifests are below full because every merge bumps them (rules line 89).
- verified: `scripts/run-gauntlet.sh:23-29,60-81,131` implements `--level low|medium|full --plan <base>`; a level below the plan's is refused; only a full run records a pass; the pass cache keys on `HEAD^{tree}` (`scripts/_lib/gauntlet-pass.sh`, GH #735).
- verified: `scripts/merge-pr.sh` calls `gauntlet_full` at merge (agent-reported line 446, `scripts/sync-pr-head.sh:120,169`); the plan is not used there.
- verified: the miss log `~/.cache/mh/gauntlet-miss.jsonl` has 69 rows (47 medium, 22 full), keys `time, pr, head, level, selected, failing, miss`; 0 of 69 rows have any failing file. So "0 misses" is vacuous: no merge-time full run in the log ever failed.
- verified: memory note `run-planned-gauntlet-before-asking-for-verdict-2026-10-30` (PR #751: a hand-picked suite list missed `test-gates-other.sh`; merge-pr then failed 22 rows).
- verified: `scripts/gauntlet-plan.sh:3,21-22` reads `git diff --no-renames --name-only <base>...HEAD` (three-dot). `scripts/merge-pr.sh` merges origin/develop into the PR branch and commits the version bump (`sync_and_bump`, lines 208-235), then `scripts/merge-pr.sh:460` calls the planner with `$dev` (origin/develop) for the miss log. So at merge the planner would see the PR's own changes plus the bump, not what develop gained since the PR branched.
- verified: `scripts/_lib/gauntlet-pass.sh:50-` `gauntlet_full` skips the run when `$HOME/.cache/mh/gauntlet-pass/<HEAD^{tree}>` exists; only a full unsharded clean run records one. `scripts/merge-pr.sh:447-448`: a cached pass is not logged, because it "says nothing about what a plan would have missed".
- verified: with a scoped merge the miss log loses its ground truth, because a miss is defined as a failing file outside the plan found by the merge-time FULL run (`scripts/merge-pr.sh:453-457`).
- unverified: that group-keyed pass caching can be made sound when a test reads files outside its declared inputs (any test may source `tests/_lib` or `scripts/_lib`).
- unverified: wall-clock cost of a real full merge run (no timing is recorded anywhere in the repo; `scripts/merge-pr.sh:14` only says "> 10 min").

## Earlier work searched
- Issues and PRs (`gh issue list --search gauntlet`, `gh pr list --search gauntlet`): GH #735 (fast push, full gauntlet once at merge, pass cache), #740 (its PR), #742 and #744 (mh/gauntlet commit status), #749 (levels, merge stays full), #400 (sharded CI, closed), #158 (gauntlet flaky under load, open), PR #683.
- Memory index and `index-gate-work.md`: the #751 note above; "Serialize builder pushes" (parallel pre-push gauntlets push load up and fail timing rows).
- `docs/adr/`: 0001-0005, none about the gauntlet. `docs/research/`: several files mention the gauntlet in passing; none decides merge-time scope.
- qmd (no collection filter): no earlier decision to scope the merge-time gauntlet.

## Revision 1
Decision: pieces 1, 2 and 3 above are DROPPED. The merge-time gauntlet stays full, unscoped and uncached per group, exactly as GH #735 and #749 decided. What replaces them is a measurement-only change. Each confirmed break, one line:
- A1 (rules file edited by the PR judges the PR, `* low`): dropped with piece 1. A scoped merge cannot trust a rules file the PR itself edits; closing it would need a rules file read from origin/develop, which still leaves A3 and B1 open.
- A2 (`hooks/hooks.json` timeout change skips the deadline assertion if heavy suites run only when `hooks/gates/` changes): dropped with piece 3. The planner already selects those suites by file mapping, so a second, coarser rule only removes coverage.
- A3 (`evals/README.md` run block read by `test-eval-changed-print.sh`, which the planner does not select): dropped with piece 1. A file-based mapping cannot see a file that a test reads at run time; the full merge run is the net for this class, so it stays.
- B1 (PR renames a file; develop adds a test reading it; the planner's `develop...HEAD` diff excludes the new test): dropped with piece 1. It is the #445/#446 class; only a full run on the merged tree closes it in general.
- B2 (fixture row changed from DENY to ALLOW with no `hooks/gates/` change; piece 3 skips the suite that detects it, and the miss row says `miss=false`): dropped with piece 3.
- B3 (shared `tests/_lib/gates-harness.sh` change: planner says full, piece 3 still excludes its heavy consumers, so the operator's full-run override is defeated): dropped with piece 3.
- B4 (scoped run records no tree pass, so `merge-pr.sh --verify` refuses a fresh cloud PR; per-group entries do not satisfy the exact-tree lookup at `scripts/merge-pr.sh:513-518`): dropped with pieces 1 and 2. The cache stays keyed on the exact tree.
- B5 (a scoped merge posts `mh/gauntlet=success` with "full gauntlet passed on tree"): dropped with piece 1. The status keeps meaning a full pass.

Dismissed: B6 ("a docs-only PR cannot merge with lint and harness-audit only because the bump raises its plan to medium"). Reproduced: the planner prints `level: medium` and no `test:` lines for a docs file plus the two manifests. Medium runs validate, harness-audit and lint with zero tests, which is what the docs-only fast path needed; the proposal's wording ("lint and harness-audit only") was loose, the behaviour it wanted is already there. Not a safety break and nothing to close.

### The revised change (measurement only)
1. `scripts/run-gauntlet.sh` appends one JSON row to a local timing log (default under `~/.cache/mh/`, overridable by an env var, as the miss log is) at the end of every run that reaches its end: time, level, tree hash when a full clean run, per-layer wall seconds (validate, lint, each test group where the runner already counts them), total seconds, number of tests, whether a pass was recorded.
2. `scripts/merge-pr.sh` and `scripts/sync-pr-head.sh` log the lock wait seconds and the gauntlet duration they already measure or can measure with `date`, in the same log, tagged with who ran it. A cached pass logs a row with `cached: true` and no durations.
3. A timing-log problem prints one note on stderr and never changes an exit code, a pass record, the cache, the status post or any output line that exists today (`scripts/run-gauntlet.sh` header: "stdout and the final lines keep their form").
4. No change to gauntlet-plan, the rules file, the pass cache keying, the merge status, or the choice of tests.
5. After about 20 merges, review the log: if lock wait and the three heavy gate suites dominate, re-propose a sound way to cut them with that data (for example speeding the heavy suite itself, or splitting lock queues), not scoping.

Must stop (revised): any change to which tests run, what counts as a pass, what is cached, or what the status asserts. Must allow (revised): every current merge, sync and push path runs with the same exit codes and the same output lines; a missing or unwritable log directory does not stop a merge.

## Revision 2 (round 1 of the validator found 8 CLOSED and 2 NEW; both NEW come from putting a second job inside the runner)
Reproduced: `scripts/run-gauntlet.sh:271` keeps the `failing:` list as the last line (GH #387, pinned at `tests/scripts/test-gauntlet-levels.sh:103-109`); fixture tests run the runner directly with the operator's real HOME (`tests/scripts/test-gauntlet-levels.sh:44,84,95,103`; `scripts/run-gauntlet.sh:178` needs an explicit `GAUNTLET_PASS_CACHE=0` for the same reason). The runner's one responsibility is: run the layers and report pass or fail. Recording how long that took is a second responsibility, owned by whoever calls the runner for a real merge.
- NEW 1 (fixture runs write the operator's real timing log): closed by moving the measurement out of `scripts/run-gauntlet.sh` entirely. Revised piece 1 is withdrawn. The only writer of the timing log is `gauntlet_full` in `scripts/_lib/gauntlet-pass.sh`, the wrapper that `scripts/merge-pr.sh` and `scripts/sync-pr-head.sh` call (and nothing else calls it). Fixture tests call the runner directly, never `gauntlet_full`, so they cannot write a row.
- NEW 2 (the log note becoming the last line of a failing run): closed the same way. The runner is not edited, so its last-line contract and every test that pins it are untouched. `gauntlet_full` writes its row after the runner returns and before it returns the status, and its note goes to stderr before any caller prints its own result.
- Validator feasibility note (callers cannot time the lock wait separately): closed. The lock is taken inside `gauntlet_full` (`scripts/_lib/gauntlet-pass.sh:64`), so the wrapper times lock wait (before the runner starts) and run seconds (the runner call) separately.

Revised change (final, measurement only, one writer):
1. `gauntlet_full` records, around its existing lock-and-run subshell: who called it, whether the pass was cached, lock wait seconds, runner seconds, the runner's exit status, the tree hash. One short JSON line, appended with `>>` to a log under `~/.cache/mh/` (path overridable by an env var, as the miss log is; the merge and sync tests set it to a temp path next to the existing `GAUNTLET_MISS_LOG`).
2. A problem writing the log prints one note on stderr and returns success for the logging only; the status that `gauntlet_full` returns is the runner's, unchanged. Every command added to the `set -euo pipefail` callers follows the `miss_log_row` pattern (`|| echo ... >&2`).
3. `scripts/run-gauntlet.sh`, `scripts/gauntlet-plan.sh`, the rules file, the pass cache keying and the status post are not edited.
4. Per-layer and per-test-file times are out of scope for this change; if the data after about 20 merges points at one suite, time that suite on demand with a one-off script, not in the merge path.
5. The test for this change runs `gauntlet_full` against a fixture runner with the log path set to a temp file and asserts: one row per call, a cached call logs `cached: true`, the status is the runner's (a failing runner still fails), and an unwritable log path leaves the status unchanged and prints one note.

Must stop (final): the runner or any test of the runner changing behaviour; the timing log being written by anything but the wrapper; any change to which tests run, what counts as a pass, what is cached or what the status asserts. Must allow (final): every current merge, sync and push path keeps the same exit codes and the same output lines.

## Revision 3 (round 2: NEW1-3 CLOSED with builder notes; 1 NEW in the test design)
Reproduced: `tests/scripts/test-sync-pr-head.sh:27-28` and `tests/scripts/test-merge-pr.sh:232` already point `GAUNTLET_LOCK_DIR`, `GAUNTLET_PASS_DIR` and `GAUNTLET_PASS_CACHE=1` at fixture paths, because the outer gauntlet exports `GAUNTLET_PASS_CACHE=0` (`scripts/run-gauntlet.sh:179`) and holds the default lock (`scripts/_lib/gauntlet-lock.sh:19,26`).
- NEW (test item 5 hangs or fails inside the real gauntlet): closed by amending item 5. The new test sets `GAUNTLET_LOCK_DIR`, `GAUNTLET_PASS_DIR`, `GAUNTLET_PASS_CACHE=1` and the new log variable to fixture paths, the same convention as the two tests above, and greps stderr for the note instead of counting stderr lines (as `tests/scripts/test-merge-pr.sh:391` does).
Builder notes made binding (from round 2's CLOSED entries):
- The log variable is `GAUNTLET_TIME_LOG` (default `$HOME/.cache/mh/gauntlet-time.jsonl`). It is set at `tests/scripts/test-merge-pr.sh` inside `run()` next to `GAUNTLET_MISS_LOG`, and in the global export at `tests/scripts/test-sync-pr-head.sh:28`; these are the only two tests that reach `gauntlet_full`.
- The row for a real run is written inside `gauntlet_full`'s subshell: `t0=$SECONDS` before `gauntlet_lock_acquire`, `t1` after it, the runner called with `|| rc=$?`, then the row, then `exit "$rc"`, so the EXIT trap still releases the lock and the subshell's status is the runner's. The row for a cached pass is written before the existing `return 0`. Timing uses the `$SECONDS` builtin (Bash 3.2), fields are literals, hex or integers, so nothing needs escaping.
Residual risks, accepted and stated: a future test that runs `merge-pr.sh`/`sync-pr-head.sh` without `GAUNTLET_TIME_LOG` writes real rows; an interrupted run writes no row; `merge-pr.sh --verify` (cloud merges) writes no row.

## Gap found after GO (deep-audit, not yet validated)
`scripts/merge-pr.sh:84-89` takes a separate merge lock (`merge_lock_take`, wait up to `MERGE_PR_LOCK_WAIT_SECS`) before it ever calls `gauntlet_full`, so the Revision 3 row times only the gauntlet lock and misses the merge-queue wait, one of the two costs step 5 means to compare. Build note: `merge-pr.sh` also records `merge_lock_wait` seconds around `merge_lock_take` in the same log, same `|| echo ... >&2` pattern, and the merge test asserts the field. This piece is new: run it through step 5's validator (or step 7 on the built code) before merge.
Open points for that validation (deep-audit step 6): (a) `merge-pr.sh:541` `wait_for_load` (up to `MERGE_PR_LOAD_WAIT_SECS`, per round) is a third wait bucket; time it too. (b) A second writer breaks the final Must stop "the timing log being written by anything but the wrapper": either amend that line to name `merge-pr.sh` or move the lock timing into a wrapper. (c) Rows from one merge need a shared run id, since the lock row comes before `sync_and_bump` and has no tree hash. (d) The call site is `merge-pr.sh:532`; lines 84-89 are the function.
