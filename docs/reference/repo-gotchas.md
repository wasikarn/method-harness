# Non-obvious gotchas: full bodies

`CLAUDE.md` keeps each rule as one line; the history and mechanics live here.

## Validation

`claude plugin validate . --strict` is the primary gate. `scripts/run-gauntlet.sh` runs three
layers in parallel: plugin-validate, lint (shell, Python, JSON, whole-tree home-path ban), and
every test under `tests/`. pre-push runs the gauntlet; pre-commit runs the fast subset (syntax,
shellcheck on staged `.sh`, JSON parse, the home-path ban, harness-audit CRIT only, and when a gate
is staged, `scripts/gate-canary.sh` against the index copy of `hooks/gates/`).

The gauntlet's timing rows ("finishes inside 4 s / 8 s") fail when several gauntlets share the
machine (GH #158: four parallel builders pushed load to 15-20 and failed seven pushes). pre-push
therefore takes a per-user lock (`scripts/_lib/gauntlet-lock.sh`, default
`~/.cache/mh/gauntlet.lock`) and waits its turn, up to 30 minutes, then runs anyway with a message
(it orders work; it is never a gate). A lock whose owner is gone is reclaimed; a child of the holder
skips the queue so a test that runs the hook cannot deadlock the gauntlet. Load from other apps and
non-mh sessions is not covered. Builders still build in parallel; only their pushes queue. If
`core.hooksPath` is an absolute path to the main checkout, a push from any worktree runs that
checkout's hook, so the lock applies only once that checkout has the new `git-hooks/pre-push`
(update it after this lands); a relative path uses each worktree's own hook.

Under `set -o pipefail`, never pipe a writer into a reader that may stop early: `echo "$out" | grep
-q PAT` fails on a match whenever grep exits before bash's line-by-line writes finish (SIGPIPE, rc
141). Under gauntlet load this flaked the wiring test and other rows, each run naming a different
file (2026-10-23). Write `grep -q PAT <<<"$out"` or `grep -q PAT <<<"$(cmd)"`.
`tests/scripts/test-pipefail-grep-q-lint.sh` checks every tracked shell file (a file without
`pipefail` may be sourced under it, as harness-audit's checks are) with
`tests/_lib/pipe_into_grep_q.py`, which reads shfmt's JSON syntax tree: a line regex and then a
hand-written lexer each missed sites in review (#578, #597, #598). **The gauntlet needs shfmt
>= 3.5** (macOS: `brew install shfmt`; Linux: `pip install shfmt-py`, or `apt install shfmt` on
Ubuntu 24.04+; 22.04's 3.4 is too old; cloud sessions get it from the SessionStart hook below, apt
3.8 on 24.04 or pip's shfmt-py when apt's is older) and refuses to start without it, as it does
without `trash`. shfmt 3.4 only has `-tojson`, whose operators are numbers, and once made every
file scan clean, so the scanner checks itself on `x | grep -q y` first and exits 2 when it cannot
read the tree. A file shfmt cannot read or parse is also an error, never a clean pass, and hits in
the other files are still listed.
A pipe's readers are the commands that can read the stdin it hands its right side: the command
there, each statement of a `{ }`/`( )` group, both sides of `&&`/`||`, a `time`d command, and any
`$(...)`/`<(...)` that expands with the pipe as stdin. Bash applies redirections left to right, a
simple command (incl. `local`/`declare`/`let`) expands its words before its redirections, and a
compound command (`for` list, `case` subject, `for ((...))`, `[[ ]]`, `(( ))`) after them. A `grep
-q` in `>(...)` reads the command's output, but its early exit kills that command with SIGPIPE (`seq
2000000 | tee >(grep -q 1) >/dev/null` gives 141 141), so on a pipe's right side it counts wherever
it sits, even inside a group or loop whose stdin is redirected. So `x | echo "$(grep -q y)" < f` and
`x | cat < <(grep -q y)` race, while `x | for f in $(grep -q y); do ...; done < f` and `x | cat < f
<<<"$(grep -q y)"` do not (bash: `echo P | for x in $(cat); do echo $x; done < f` prints f's
contents). In the conditions and bodies of `if`/`while`/`until`/`for`/`case`, only a grep that reads
stdin counts (no file operand and no `-r`, or `-`, `/dev/stdin`, `/dev/fd/0`, `/proc/self/fd/0`, or
one of those after `-f`), so `while read -r f; do grep -q p "$f"; done` is clean (a heuristic). A
statement whose stdin is redirected (`<`, `<<<`, `<&N` with a literal N other than 0) is no reader.
Wrappers (`command`, `builtin`, `exec`, `env` incl. `env -S`, `timeout`, `nice`, `stdbuf`, `sudo`,
`nohup`, with `NAME=VALUE` for env and sudo) are looked through; long options, grep's and the
wrappers', resolve as getopt_long does (`--qui` is `--quiet`, `--reg` is `--regexp`, `--sig` is
timeout's `--signal`), and the value of `-e`/`--regexp`-style options is not an option. It does not
catch a grep reached through a function or alias, nor other early-exit readers (`head`, `grep -m`, a
command that skips stdin): there, apply the rule by hand.
(GNU grep 3.11 writing to `>/dev/null` reads all of its input, so that form is safe.) A hit whose
line ends in the comment `# pipe-into-grep-q: deliberate` is exempt but reported, and the lint
allows one: its own race probe.
`scripts/gate-canary.sh` feeds gates through `< <(printf ...)` for the stdin-skipping reason, and
skips the `_*.sh` helpers the gates source.

## Git hooks

Hooks live in `git-hooks/`, not `.git/hooks/`. Wire once per clone with
`git config core.hooksPath git-hooks` and **keep that path relative**. An absolute
`core.hooksPath` dies silently the moment the directory is renamed: git does not warn when the
path no longer exists, it runs no hooks. Confirmed 2026-08-26 when renaming this clone left one
commit and one push running zero gates. Verify with `test -d "$(git config core.hooksPath)"`.
There is no CI (GitHub Actions removed 2026-10-03), so a broken `core.hooksPath` means the gauntlet
never runs at all and nothing server-side notices. Run the verify command above after any rename.
A cloud session's fresh clone starts with no `core.hooksPath`; the project SessionStart hook
(`.claude/hooks/session-start.sh`) sets it to `git-hooks` when it is unset, and leaves a value
already set alone.

## Repo and commit hygiene

- **Hardcoded home paths blocked.** This repo is public. Every committed file uses `$HOME` or
  `~`, never a literal `/Users/<name>`; the bare account name counts too (an author field, a
  `cache/<account>/` fragment in prose). pre-commit checks staged files; the gauntlet checks
  the whole tree. The frozen dirs (`docs/research/`, `docs/post-mortems/`, `docs/plans/`,
  `CHANGELOG.md`) are exempt from wording passes, never from hygiene: on 2026-08-26 a purge
  reported clean while 29 hits sat in exactly those dirs.
- **Never `rm -rf`.** Use `trash` (`trash-put` on Linux; neither installed means ask the user).
  `run-gauntlet.sh` needs the `trash` command itself, since the tests call it by that name, and
  stops without it: on Linux, `pip install trash-cli` provides `trash` alongside `trash-put`.
  Single-repo Claude Code cloud sessions (not Project threads or multi-repo sessions, which skip
  repo hooks) get it from the project SessionStart hook in `.claude/settings.json`
  (`.claude/hooks/session-start.sh`, apt `trash-cli` and `shfmt`, only when `CLAUDE_CODE_REMOTE=true`); it is
  for developing this repo and is not part of the shipped plugin's `hooks/` (which sessions read
  repo settings: code.claude.com/docs/en/settings, "Settings in cloud sessions").
  Enforced by `gate:bash:irrecoverable`. Validate the argument is non-empty before any `trash`
  call: an empty glob result once trashed the whole repo. A template `mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"`
  prints "" when TMPDIR names a missing directory (a plain `mktemp -d` falls back on macOS), and `set -u`
  does not catch an empty variable, so a test hands such a path to `track_trash` from
  `tests/_lib/harness.sh`, never to `trash` (`tests/scripts/test-trash-empty-guard-lint.sh`).
- **Never `--no-verify`.** Enforced by `gate:bash:irrecoverable`.
- **Stage by name.** Never `git add -A` or `git add .` outside a mid-merge state. Enforced by
  `gate:bash:irrecoverable`.

## Plugin lifecycle and install

- **`defaultEnabled: false`.** After install, add `"mh@wasikarn": true` to Claude Code
  `settings.json` and restart.
- **Same-version edits are no-ops.** Claude Code loads the plugin from
  `~/.claude/plugins/cache/<marketplace>/mh/<version>/` at startup; `claude plugin update`
  copies nothing unless `plugin.json`'s version changed. Bump both manifests before updating.
  This applies to third-party plugins too: `mattpocock-skills` once sat 3 commits behind
  upstream while `update` reported "already latest". Fix: uninstall, `trash` the cache dir,
  reinstall.
- **Re-verifying a same-session edit.** Have the agent `Read` the repo path; `Skill(<name>)`,
  `subagent_type`, or a slash command silently tests the stale cached version (confirmed
  2026-07-27: a false "fix confirmed" via `Skill(mh:tech-humanize)`).
- **Which mh copy runs after a restart.** `$MH_PLUGIN_ROOT` is a SessionStart snapshot, not proof.
  Read `mh_version` in this session's last row of `~/.local/share/kbg/metrics/costs.jsonl` that has
  one (a Codex row has none), or the version in the hook path Claude Code prints around a gate deny. `~/.claude/metrics/costs.jsonl` is a stale
  file with no `mh_version`. A wrong probe gave a wrong answer twice: the env var (2026-09-21) and the
  stale file (2026-09-30). In an mh checkout with modules on, the hooks module's status line and
  stale-skill toast say it too (`docs/reference/cost-ledger-module.md`, GH #442).
- **A brand-new skill or agent no longer fails checks 02 and 03.** The plugin cache is built from
  committed state, so a component added after the commit the cache was built from cannot be in it.
  Checks 02 (skill loadability) and 03 (agent loadability) report such a component as INFO when its
  file is absent from the base commit: `gitCommitSha` in `installed_plugins.json` for the audited
  cache, else `origin/develop`; override `HARNESS_AUDIT_BASE_REF`. This holds after the PR merges
  and until the release is installed. CRIT returns only for a component that is on that commit but
  missing from the cache, and whenever the audited dir is not its own git toplevel or the base does
  not resolve. No hand-copy into the cache dir, no `~/.claude` symlink.
- **The plugin runs every hook machine-wide.** A gate crash locks out every session that has
  `mh@wasikarn` enabled, not just sessions in this repo. A missing sibling `.py` or lib module
  must fail open with a diagnostic, never exit non-zero.

## Session environment quirks

- **Bare `grep` is shadowed, for ordinary invocations, by Claude Code's own shell-snapshot shim**,
  not an rtk alias (no `rtk` reference exists in the snapshot function; a few flags like
  `--null`/`-Z` fall through to real grep). Use `/usr/bin/grep` or `awk` for count and stat
  operations.
- **`/context` verifies what actually loaded.** Check the Memory files list before reasoning
  about whether a CLAUDE.md or rule file is in context.
- **Two user-level rules load every session:** `~/.claude/rules/{test-honesty,code-review-graph}.md`
  (dotfiles-owned). `test-honesty.md` fires on any `.py` read, not just tests.
- **Piping a payload into a gate by hand writes to the real journal.** A denying gate appends to
  `~/.local/share/kbg/metrics/gate-decisions.jsonl` unless `MH_GATE_JOURNAL_PATH` is set, and a
  made-up `session_id` (`s`, `t`, `test-session`) passes `gate-report`'s session filter, so it
  is counted in the totals (159 of 161 `subagent-verdict-check` denies were these; the report
  names non-UUID ids but does not drop them). Probe with
  `MH_GATE_JOURNAL_PATH=/dev/null` (or a scratch file when you want to read the row back), and
  use `scripts/gate-differential.sh` for old-vs-new comparisons, which already isolates it.
- **Background load runs go in a bash file, with explicit PIDs.** The Bash tool's shell is zsh:
  `wait $pids` does not word-split, and under `zsh -c` `kill $(jobs -p)` finds no jobs, so the
  workers outlive the run. Twice this left a flood behind (289 processes, load ~248, 2026-10-05;
  4 `yes` at 100% CPU for ~4 h, 2026-10-25) that failed every session's timing rows. Write the
  run as a file and start it with `bash <file>`, collect `pids+=($!)`, `kill "${pids[@]}"` in a
  `trap ... EXIT`, then confirm no worker is left and the load has dropped. `run-gauntlet.sh` now
  names long-running CPU-heavy processes of yours (`scripts/_lib/stray-procs.sh`, warn-only), but
  it can only catch a stray after the fact; killing one that a peer session owns is the operator's call.

## Research: check qmd before web search

The qmd-first rule lives in `CLAUDE.md`, not a skill, because a skill was the surface that two
namespace migrations silently deleted it from. Before primary-source research: search the local
`qmd` collections (`qmd status` lists them), then `context7` for library docs, then `WebSearch`.
Neither is bundled; skip straight to `WebSearch` when not configured.

**Verify technical claims before shipping them into agent or skill content.** Plausibility is
not verification. Three confidently wrong claims shipped and were caught only by a source check
(2026-08-05): a two-pointer "O(n) 3-sum" (it is O(n^2)), Drizzle nested `with` as "one query per
relation depth" (always one query), and a CWE-1333/CWE-400 pairing that contradicts MITRE's page.

## Changing a deny heuristic in a gate

Any change to how `hooks/gates/*.py` decides deny versus allow (a tokenizer step, a substitution
or redirect strip, a shell-syntax rule) needs a differential fuzz against current `develop` before
merge. Unit tests alone missed every bypass on the 2026-09-29 `irrecoverable.py` work (GH #184,
#185, #188, #189): three plans failed, PR #192 was closed after 3 validator rounds, and a
builder's self-check ("0 bypasses in 4032") was wrong each time.

- **Tool:** `scripts/gate-differential.sh OLD [NEW] GATE` (GH #411; OLD a gates dir or a git ref such as
  `origin/develop`, GATE `irrecoverable`, `subagent-git-guard` or `secret-scan`) replays the committed
  fixtures, `--replay N` real commands from this project's transcripts only (secret-scan reads
  Write/Edit text) and `--fuzz-seed S` mutations through both copies. It compares exit, stdout,
  stderr and journal rows and prints diff classes with counts and 3 redacted samples, never raw
  transcript text. Both sides journal to a temp file under a temp HOME: earlier hand-built replays
  that did not isolate it left 268k session-less rows in the real journal. The fuzz is a few fixed
  rewrites; the real-shell oracle and a validator's own generator below still apply.

- **Acceptance:** 0 commands that `develop` denies and the branch allows, apart from a category
  the PR names as intended. Over-denies are the safe direction and are reported, not blocking.
  A timeout counts as allow: a hook past its `hooks.json` timeout (8 s) lets the call through, so
  a command `develop` denies in time and the branch does not finish in time is a regression. Time
  padded shapes (thousands of statements, 20-150 KB) with the target early and late (GH #245: a
  new scan placed before the fast denies turned a 0.03 s deny into a timeout). Any exit other than
  0 or 2 from the `.py` is a finding too, even where the `.sh` wrapper fails it closed.
  **Measure every new regex piece's own worst case**, never assume it fits the existing charge:
  anchor regexes are quadratic (starts x length, GH #246), and a chain or wrapper loop that can read
  one token two ways goes exponential (GH #320, #339). GH #469: the guard's work budget (40M) is not
  a time bound, so a length cap decides first (`_MAX_CMD_CHARS` = 16000, `MH_SGG_MAX_CMD_CHARS` in
  tests; it fixes the pre-mask linear cost of a 20 MB command) and a 5 s SIGALRM deadline
  (`MH_SGG_DEADLINE_SECS`, under the 8 s hook timeout) denies wherever the scan is.
  Verify a scan change with a real-shell differential, not by reading the code (GH #274: 5 rounds
  each missed shapes the next found), and replay real transcript commands: a replay finds shapes
  the generated fuzz misses.
- **A broad new rule ships shadow first** (GH #337). Give its `deny()`/`ask()` call a `rule="<id>"` and
  list the id in `irrecoverable.py`'s `SHADOW_RULES`: a match then journals `would_deny`/`would_ask` with
  the id and the command, and the call goes through. `/mh:gate-report` lists the hits per rule with
  sample commands; delete the id to enforce once they hold no false positive. The list is source, not an
  env var, so a project `settings.json` cannot shadow an enforced rule. A structural deny (length cap,
  unparsable text, budget, depth) takes no id: returning from it would run the code it guards. A rule
  that denies commands from a replay of real transcripts ships shadow, not enforcing.
- **Oracle:** run the real shells (the system `/bin/sh`, bash 3.2, a current bash, dash, zsh, ksh)
  with argv-logging stubs, never one shell or argv0-based shell guessing: whether `{fd}>` is a
  redirect depends on the binary and version (GH #219).
- **Validator:** a fresh agent writes its own generator; the builder's generator is never reused.
- **A piece that still fails after one patch round is dropped.** PR #208's redirect fix took one
  patch (validator round 1) and merged; validator round 2 then found an sh/dash residue, and its
  fix (PR #218) was the piece dropped, with the residue tracked in GH #219. Shipping only the
  pieces that pass is how #208 merged after PR #192 failed.
- **When the shell is ambiguous, check both readings; any deny wins** (GH #219). Shipped for named-fd
  `{var}>f`: `_blank_redirections(s, named_fd)` is run as redirect (bash 4+/ksh), literal word (sh,
  bash 3.2, dash) and zsh (`{var}&>f` too), and every window is checked. Fuzz, 4000 cases against real
  shells: false-allows 84 to 0, false-denies 545 to 602 (a branch switch or restore with `{fd}>x` now
  denies; accepted, the safe direction). A check by argv0 stays unsound (`exec -a sh bash`).
- Attack strings live in files, never in Bash command text, and the gate only classifies them.
- **A word list one gate types by hand drifts from its sibling.** `subagent-git-guard.py`'s
  `_WRAPPER_WORDS` is a second copy of `irrecoverable.py`'s `PREFIX_WRAPPERS`; `rtk` reached the
  first list only after the guard let `rtk proxy git stash` through (deep-audit 4), and a glued
  `timeout=30` once broke the shared spawn regex. `tests/hooks/test-subagent-git-guard.sh` now fails
  when a `PREFIX_WRAPPERS` word is not a wrapper in the guard. A new copy of a list needs its own
  drift test, and a new word needs two awkward-shape cases per consumer: a glued `name=1`, and a
  multi-statement decoy (`<word> x && git stash && git status`), because a wider wrapper list can
  also hide the statements after it (the guard's walk ran across `;` to the last `git`).

Per-issue measurements (GH #245, #246, #248, #273, #274, #276, #307, #317, #318, #320, #322, #327,
#336, #339, #340, #344, #349, #375, #382, #469): [`gate-heuristic-history.md`](gate-heuristic-history.md).
