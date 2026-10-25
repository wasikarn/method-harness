# Irrecoverable-gate bypass sweep 2026-10-24

This is the adversarial review of `hooks/gates/irrecoverable.py` (wrapper `hooks/gates/irrecoverable.sh`)
that `docs/research/cloud-audit-2026-10-23.md` left undone: it checked only the gate's error paths and
said nothing about bypasses. The review looks for commands the gate should deny or ask on but lets
through, and for plain reads it asks on or denies.

The base is `develop` at `58a6f08` (after #555 and #558). The session ran in the cloud: Ubuntu, bash 5.2,
Python 3.13, gh 2.89, with `trash` installed from pip for the gauntlet. Every payload was piped as
`{"tool_name":"Bash","tool_input":{"command":...}}` into `bash hooks/gates/irrecoverable.sh`, as
`tests/_lib/gates-harness.sh`'s `bash_payload` builds it. A subagent case added `"agent_id"`. No
payload's command was run. Each claim about what a command does comes from that tool's documentation
(git-config(1), git-rm(1), git-worktree(1), coreutils `env`, `gh <cmd> --help` on gh 2.89).

## Contract and severity

The contract is the `gate:bash:irrecoverable` row and the error-path paragraph in
`docs/reference/operating-model.md` §1. A behaviour that row names as intended is not a finding. For
example, `gh api .../merge` asks even on a GET, and a plain `git branch -D <names>` is allowed.
Comments in the code and the tests are not the contract. Where one of them declares a non-goal, the
finding says so.

Severity:
- **CRITICAL**: a T3/T4 write passes silently. T3 means an irreversible change to shared or remote
  state, such as a forced or mirror push, a dropped database, or a GitHub delete. T4 means a credential,
  a disk, or repo history.
- **HIGH**: irreversible loss of local work passes silently, or the repo's hooks can be switched off.
- **MEDIUM**: an odd spelling of a denied action passes, or a read the repo itself prescribes is denied.
- **LOW**: an action reflog can undo passes, the gate over-asks on a read, or the doc has drifted.

## Method

1. Read the whole gate against the §1 row, rule by rule. For each rule, list the other ways git, gh,
   the shell or a SQL client can produce the same effect: config keys, aliases, plumbing, stdin,
   wrappers, flag spellings.
2. Probe each candidate with a small harness. It holds `EXPECT<TAB>command` rows and reports `MISS`
   when the gate's exit code or stdout `ask` differs from the expected decision. The rows are in
   batches of 10-60, about 250 in total. Read controls went into the same batches.
3. For each fix, use `scripts/gate-differential.sh origin/develop irrecoverable --fuzz-seed 7` (GH #411)
   to replay the committed fixture corpora (the #336, #375, #382 and #349 files that
   `tests/hooks/test-gates-other.sh` replays) plus 200 fuzz mutations. Every fix branch reports
   `diffs=0` over 475 cases. There are no transcripts in this container, so `--replay` had nothing to
   sample.
4. Write every fix's test rows first and confirm they fail against develop's gate.

## Findings

| # | Sev | path:line (develop 58a6f08) | Payload | Actual → expected | Issue | Fix |
|---|---|---|---|---|---|---|
| 1 | CRITICAL | `irrecoverable.py:43,59` (heredoc body stripped unless an interpreter reads it), `:2603-2609` (SQL rule reads `-c`/`-e` only) | `psql mydb <<'SQL'`⏎`DROP TABLE users;`⏎`SQL`; `echo 'DROP TABLE users' \| psql mydb`; `psql mydb <<< 'DROP TABLE users'`; `dropdb mydb`; `mysqladmin -f drop mydb`; `psql -c 'DROP/**/TABLE users'` | allow → deny | #559 | #569 |
| 2 | CRITICAL | `irrecoverable.py:2095-2109` (env unwrap skips `-S STRING` as a bare flag) | `env -S 'rm -rf build'`; `env --split-string='git push --force'`; `env -C /tmp rm -rf build`; subagent `env -S 'claude -p hi'` | allow → deny | #560 | #570 |
| 3 | CRITICAL | `irrecoverable.py:2312-2563` (git rules read flags only; only `core.hooksPath` config is read, `:1816`) | `git -c remote.origin.mirror=true push origin`; `git -c remote.origin.push=+HEAD:refs/heads/main push origin`; `git -c alias.p='push --force' p origin main`; `git -c alias.x='!rm -rf build' x`; `git -c clean.requireForce=false clean -dx`; `git -c gc.reflogExpire=now -c gc.reflogExpireUnreachable=now -c gc.pruneExpire=now gc`; `git config alias.p 'push --force'` | allow → deny | #561 | #571 |
| 4 | CRITICAL | `irrecoverable.py:223-231` (`PREFIX_WRAPPERS`, also the spawn anchor `:261-290`); `:221-222` already calls the list open-ended | `flock /tmp/l git push --force`; `caffeinate -i git push --force`; `xcrun git reset --hard`; `watch -n1 git reset --hard`; `strace -f rm -rf build`; `script -qc 'rm -rf build' /dev/null`; `parallel rm -rf ::: build`; subagent `npx @anthropic-ai/claude-code -p hi`, `npx claude -p hi` | allow → deny | #566 | not fixed: design choice, see below |
| 5 | CRITICAL | `irrecoverable.py:43,59` vs `_blank_redirections` `:988-1094` (here-string word blanked) and pipe windows | `bash <<< 'rm -rf build'`; `sh <<< "git reset --hard"`; `echo 'git push --force' \| bash`; `printf 'git reset --hard\n' \| bash -s` (while `bash <<EOF`⏎`rm -rf build`⏎`EOF` denies) | allow → deny | #567 | not fixed: `tests/hooks/test-gates-irrecoverable-2.sh:918` declares `cat <<EOF \| bash` a non-goal |
| 6 | CRITICAL | `irrecoverable.py:1984-1994` (`_GH_BUILTIN_WRITES`, `_GH_BUILTIN_FORCED`) | `gh gist delete 123`; `gh pr update-branch 3 --rebase` | allow → ask | #564 | #574 |
| 7 | CRITICAL / HIGH / MEDIUM / LOW | no rule (send-pack, rm); `:2536` (worktree `-f` only); `:2551`, `:2549` (branch / update-ref onto protected) | CRITICAL `git send-pack --force <url> main`; HIGH `git rm -rf src`, `git rm -f a.py`; MEDIUM `git worktree remove -ff ../wt`; LOW `git branch -f main HEAD~5`, `git update-ref refs/heads/main HEAD~5` | allow → deny | #563 | #573 |
| 8 | HIGH | `irrecoverable.py:2401` (`"git-hooks" not in scan`) | `git config core.hooksPath /dev/null git-hooks` (a value-pattern: git-config(1) replaces the matching `git-hooks` value with `/dev/null`); `git config --replace-all core.hooksPath /dev/null git-hooks`; `git config --comment git-hooks core.hooksPath /dev/null` | allow → deny | #562 | #572 |
| 9 | MEDIUM | `irrecoverable.py:2401` (same line) | `git config core.hooksPath`; `git config --get core.hooksPath`; `test -d "$(git config core.hooksPath)"`. The last is CLAUDE.md's own check, and §1 says "hooksPath *edits*". | deny → allow | #562 | #572 |
| 10 | LOW | `irrecoverable.py:2577` (`"merge" in gh_scan[1:]`), `:2581` (`"/merge" in t`) | `gh pr list --search merge`; `gh pr view merge`; `gh api repos/o/r/contents/lib/merge_sort.py`; `gh api 'repos/o/r/commits?path=src/merge.py'` | ask → allow | #565 | #575 |
| 11 | LOW | `docs/reference/operating-model.md:16` | The row omits rules the gate enforces: deny `mkfs` (`:2266`), `chmod` world-writable (`:2269`), `rm --no-preserve-root` (`:2303`), and ask on `source` and on an unassigned-variable program (`:2272-2276`, both shadow). It says "SQL `DROP`", but only `DROP TABLE/DATABASE/SCHEMA` and `TRUNCATE` are denied (`DROP INDEX`, `DROP VIEW` pass). | doc drift | #568 | #576 |

### Notes on the findings

- **#1.** This is the natural way to run SQL from an agent, so it is the most likely of these to happen
  for real. The fix keeps every non-interpreter heredoc body stripped. It also keeps the bodies that a
  SQL client's pipeline reads, and checks the text upstream of the client and its here-string. A client's
  output piped onward (`psql -c '\dt' | grep -i 'drop table'`) stays allowed. `mysql db < drop.sql` is
  still not covered, because the gate does not read files.
- **#3.** Each config key's effect is quoted from git-config(1) in the issue. The fix also checks a
  persisted `git config KEY VALUE` of the same keys, since `git config alias.p 'push --force'` followed
  by `git p` is the two-step form. A dry-run `clean -n` under `requireForce=false` stays allowed.
- **#4 and #5 are filed, not fixed.** For #4, every wrapper added to `PREFIX_WRAPPERS` widens the
  spawn-anchor regex walk, whose time budget is GH #245/#246. A fallback that scans each word of an
  unknown argv0 is a policy change. Either is a design call for the owner. #5 conflicts with a declared
  non-goal in the tests. Both issues carry a proposed shape.

## Out of the contract, not filed

These do the same kind of damage as a denied action but are not named in §1, and widening the row is
the owner's call:
- `rm -r build`. The row names `rm -rf`, and `rm -r` without `-f` deletes a directory just as finally.
- `python3 -c 'import shutil; shutil.rmtree(...)'` and `perl -e 'system("git reset --hard")'`. An
  interpreter's `-c`/`-e` body is never scanned. The code calls itself "habit-guard, not sandbox" at
  `:541`.
- `rsync -a --delete empty/ build/`, `psql -c 'DELETE FROM users'`, `DROP INDEX`/`DROP VIEW`
  (row 11), `mongosh --eval 'db.dropDatabase()'`, `redis-cli FLUSHALL`.
- `git checkout src/a.py` (one pathspec) and `git checkout --ours src/a.py`. With one non-flag word the
  gate cannot tell a path from a branch, and `tests/hooks/test-gates.sh:532` allows the branch switch
  on purpose.
- `gh pr review 3 --approve` and `gh repo create`. Neither is a T3/T4 write under the tiers above.

## Not confirmed

- `git -c core.hooksPath= commit` (an empty value) is allowed, because `_sets_hooks_path` (`:1816`)
  requires a non-empty value. Whether git then runs no hooks or the default `.git/hooks` was not checked.
  Checking it would mean running the payload.
- `git stash -q drop`: whether git's subcommand parser reads `drop` as the subcommand after a leading
  `-q` (the gate reads `args[0]`, `:2514`) was not established from the source, so it is left out.

## Checked, held

Each of these denied or asked as the contract says:
- rm via `sudo -i`, `nice -n5 ionice -c3`, `time { ...; }`, and `bash <<EOF`.
- `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT/KEY_n` and `--config-env` carrying `core.hooksPath`.
- `git -c core.hooksPath=/dev/null`.
- `push origin --delete main`, `push origin :refs/heads/main`, `push origin +main:main`, and
  `--force-with-lease --force`.
- `restore -WS .`, `checkout -q -- .`, `switch --discard-changes`, and `worktree remove --force --force`.
- `mysql -e 'drop   database prod'`.
- `gh repo delete`, `gh api -X DELETE`, a graphql `mutation`, `gh secret set`, `gh pr merge`,
  `gh api .../merge -X PUT`, `gh release upload --clobber`, and `gh api user/keys -f ...`.
- Subagent `claude -p hi`.

Each of these reads or harmless writes was allowed:
- `gh api -X GET search/issues -f q=...`, `gh api --method GET ... -f state=all`, and
  `gh api graphql -f query='query {...}'`.
- `gh pr view 7 --json title,mergeStateStatus`, `gh pr list --label merge-ready`,
  `gh run list --workflow merge.yml`, and `gh pr list --head feature/merge`.
- `git commit -m "note: rm -rf is denied"`, `grep -rn "push --force" docs/`, and a `cat <<'EOF' > notes.md`
  heredoc mentioning `git reset --hard`.
- `git push --force-with-lease`, a plain `git branch -D old-feature`, and `git checkout feat/x`.
- `dd ... of=rand.bin`, and the issue and PR comments mentioning "merge".
- `claude --version` from a subagent.

The gauntlet passed on the base: `bash scripts/run-gauntlet.sh` gave "all layers passed".

## Hook runs

Each fix branch passed pre-commit (the audit) and pre-push (the full gauntlet). Three pushes first
failed on rows the fixes do not touch:
- Twice on a `json.load MemoryError` row (`test-config-write-guard.sh`, `test-secret-scan.sh`), while a
  second worktree's test suite ran in parallel.
- Three times in a row on `test-secret-scan.sh`'s "199,999 suppressed lines ... (< 4 s)" timing row,
  at 4.13–4.31 s. It ran in 3.1–3.4 s alone.

Those pushes passed with `GAUNTLET_JOBS=2`, the gauntlet's own setting for timing rows on a loaded
machine (`scripts/run-gauntlet.sh:156`). That secret-scan row has little headroom on a 4-core cloud
container at the default 4 jobs.

## Merge order

The fix PRs bump 1.1.240 (#569) through 1.1.247 (#576), one version each, all off `58a6f08`. Whichever
merges first takes its version, and each later one needs a fresh bump above `origin/develop`
(`docs/reference/branching-model.md`). #571 and #572 both touch the `git config` branch of the rule loop
in different places. #574 and #575 both add rows next to the `gh pr merge` tests. Each pair may need a
small merge.
