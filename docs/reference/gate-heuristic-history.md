# Gate deny-heuristic history

Per-issue measurement notes behind `repo-gotchas.md` § Changing a deny heuristic in a gate, moved
out of it so the procedure stays short. Each number is dated by its issue and was measured on
one machine (M3 Pro unless stated); rerun before citing it.

## subagent-git-guard: narrow ambiguity pieces (GH #340, #349)

GH #340: `_AMBIG_NARROW_AFTER` had no `switch` piece, so a narrow ambiguity shape holding `git switch`
raised KeyError (exit 1, an "internal error" deny). A sub word with no piece now counts as a hit, and a
test checks the keys against `_AMBIG_GIT_SUB_RE`. A narrow piece is the only check that sees a
substitution body, and its view reads `$'-f'` as `$-f` (no blank before the dash): a flag piece for
switch let 14 fuzzed `$'-f'` commands through, so switch takes any form, like clean and restore.
GH #349: the same `$-f` reading hid a quoted flag from push, reset, checkout, branch, stash and rm, so
the check now also reads a fourth view with `$'..'` decoded and `$".."` read as `".."` (only when the
command holds one). Its fuzz also found three pieces narrower than the main parser: reset now takes
`--h`/`--har`, push a `+refspec`, and checkout a `.` that ends at `` ` `` or `)`. Fuzz, 4000 cases:
false-allows 473 to 48, false-denies 66 to 111 (a `stash list ... drop` or a bare trailing `checkout --`
in these shapes now denies). The 48 left are `checkout ./` and `branch -d -f`, which the main parser
allows too.

## subagent-git-guard: substitution scan (GH #274)

GH #274: `subagent-git-guard.py` also scans the raw command for `$(...)` / backtick bodies
(`_substitution_bodies`, one linear pass) because the quote mask hides them. That pass reads a
case pattern's `)`, `#` comments, `${x:-)}`, backslash escapes in backticks, `$'..'`, an
apostrophe inside `"..."`, and heredocs. Every body copy and heredoc lookup charges the same
budget. Its quote tracker must follow the shell's rules exactly: it once let an apostrophe inside
`"..."` open a fake single-quote span that hid every later substitution. A heredoc it cannot
read (odd delimiter, no terminator, `X)` where bash and a lenient reading disagree) is DENIED
(`_Unparsed`), never scanned as code, because prose fed to the tracker as code desyncs it.
Verify with a real-shell differential (sh/bash/zsh against a shim `git`), not by reading the
code: 5 rounds each missed shapes the next found. The 27 real-shell cases that survived are
committed (`tests/hooks/fixtures/subagent-git-guard-substitution-cases.txt`, replayed by
`test-subagent-git-guard.sh`). Known residue: an `eval`/`sh -c` of a command's OUTPUT (data
flow, undecidable), `bash -c 'sh -c ...'` (two shell levels, never covered), a quoted heredoc
nested under a wrapper inside a quoted substitution (denied, a false positive), and a
redirection before `git` (`<f git stash`, `$(<<a git stash)`), which `develop` also allows.
Differential against `develop` (2026-10-01, #274/#280): a replay of 109,500 distinct Bash
commands from local transcripts gave 0 newly denied, 0 exits other than 0/2 and a worst case of
1.0 s. 20 commands were denied by `develop` and allowed by the branch: all are heredoc body text
(commit messages, PR bodies, scripts) that `develop` denied for lack of heredoc parsing; with
the bodies stripped `develop` allows every one. That is the named intended category. One shape
inside it is a real change: `eval "$(cat <<'EOF' ... EOF)"` runs the body, so `develop` denied it
only by accident and the branch allows it (data flow, undecidable). A replay finds shapes real
commands already have: it caught a `"${x}"` counter bug, a too-broad terminator rule and a
budget over-deny that the generated fuzz missed.

## subagent-git-guard: anchor budget, length cap and deadline (GH #246, #248, #273, #276, #307, #317, #318, #339, #469)

Anchor regexes are quadratic (command starts x length): `subagent-git-guard.py` charges that
bound to a shared budget and denies past it (GH #246: 30 KB of `env ; ` before a `git stash`
timed out into allow). Only 3 of 2,581 replayed real commands (20-28 KB scripts) hit it.
GH #248 added a third, lazy-walk pass (`*?` finds the FIRST target after a wrapper, where the
greedy walk lands on the last), `{` + blank as a command start (GH #318: also a glued `{` that
starts a word, since zsh runs `{git stash;}`; GH #317: the anchor scans read a backslash before
an ordinary character as dropped, `g\it stash`, padding the word's front so offsets hold), and `xargs` in the spawn
anchor's wrapper list only. Each pass charges the budget, so the guard's budget rose to 60M; a padded
benign command of ~3,000 blank lines (spawn scan) or ~2,100-2,200 `{ ` units (both gates) is now refused.
GH #276: the lazy pass can land on a wrapper argument spelled `git` (`sudo -u git env git stash`),
so it keeps scanning forward for later `git` words in the same statement, one linear walk (a
lookahead from every `git` re-read `git -C ` runs and took 11 s). Lazy pass only, so an unquoted
`git log x git stash` now denies; deny-biased, accepted.
Starts x length is not the whole cost: the guard's chain prefix (eval/builtin/command/exec/rtk)
re-reads a chain run from every walk position, so each run also charges its length squared per
start (deep-audit 5: `command ` x 8000 after one `;` took 9 s). GH #273 added one leading chain run (eval/builtin/rtk, only when a wrapper word follows), so a
start such as `eval sudo ` now walks to the end of the string like a bare `sudo ` start does; the starts x length
charge covers that, not the per-run one. Slowest allowed shape (`eval sudo ` + 1000 args + `;` x 70, then `ls`):
5.1 s on the branch at the old 60M budget, 0.09 s on `develop` (M3 Pro). The guard's budget was lowered to 45M
(worst measured then 4.2 s for this shape, which GH #307 later showed was not the slowest); it flaked `test-subagent-git-guard.sh` on a loaded runner. GH #469: The GH #307 shape (`eval command sudo ` + 1000 args + `;` x 70) is refused, not allowed, and took 6.9-7.0 s to reach that refusal at 45M (a `git stash` tail: 5.6-5.8 s); the cost steps one heavy scan at a time (30M 2.9 s, 35M and 40M 4.3 s, 45M 7.0 s). The budget is now 40M, but it is not a time bound: a sweep of 84 padded shapes at 40M (load 2.5-3.9) took up to 7.4 s refused and 7.1 s ALLOWED (`eval command sudo ` + 400 args + `;` x 70), since the charge does not track wall time and a timed-out hook allows. So a hard length cap decides first, before the quote mask runs: `_MAX_CMD_CHARS` = 16000 characters, lifted for tests with `MH_SGG_MAX_CMD_CHARS`. The cap fixes the pre-mask linear cost (a 20 MB command of quoted words plus `; git stash` timed out at 8.0 s into allow; it is now denied in under 1 s) but is NOT a time bound for shapes under it, and two sizes were tried and measured wrong: cost follows `;` count x length, so `eval sudo ` + 75 args + `;` x 99 (15956 chars) takes 2.9 s while the same family with 24 args x 270 (15947 chars) takes 6.5 s at load 3.5 and 9.8 s at load 9.4, past the timeout (28000 took 6.6 s for the 75-arg family). 8 of 3190 real subagent commands of 3 KB or more are over 16000 (longest 29.7 KB); the deny message says to write the script to a file. So the gate also arms its own wall-clock deadline: a SIGALRM at 5 s (`MH_SGG_DEADLINE_SECS`, under the 8 s hook timeout, armed after the stdin parse) whose handler prints the deny, journals it and `os._exit(2)`s wherever the scan is, which bounds every shape directly and denies a little more often under load (the safe direction). Cost: a command under the length cap whose scan would have taken 5-8 s is now denied (the 24-arg `eval sudo` shape, 6.5 s, is one; the 57 KB `eval command sudo` shape is over the cap and denied by length). Every deny path writes its message through `_err` (a closed stderr is swallowed) and leaves with `os._exit(2)`: a failed print used to exit 120, which is not a deny. Known residual: the timer starts in Python, after the shell wrapper has read and prefiltered the payload, so a payload with a huge field other than `command` can still run into the 8 s timeout (130 MB of `description` plus a slow command reached the deadline deny at 7.7 s). The time is in the wrapper, not the parse: at 400 MB the wrapper plus Python took 17.5 s and Python alone 2.3 s (130 MB: 3.4 s and 0.76 s), so arming the timer before `json.load` was tried and dropped, it covers too little. No real payload is near that size (30 MB: 5.5 s), and a model-written command cannot reach it. Of the 60 longest real Bash commands in local transcripts, one (12.7 KB) flips from allowed to refused between 45M and 40M. `eval` takes
assignments (`eval A=1 env git stash` runs git) and `doas` is a wrapper word, both GH #273 follow-ups. A chain/wrapper loop was
exponential (`sudo eval ` x 250 never finished), so keep it to one leading run, limited to the non-wrapper words (eval, builtin, rtk) and ended by a
lookahead for a wrapper word: a run that also took `command`/`exec` doubled every split (deep-audit
checker, `command ` x 700 + `eval "git stash"` took 8 s). A new regex piece needs its own
worst case measured, not assumed to fit the existing charge.
GH #339: the lookahead's step also takes exec's `-a NAME` and rtk runs after a command/exec word
(`eval command rtk proxy nohup git stash`), and `_SHELL_PASS`'s exec takes `-c`/`-l`/`-a NAME`
(`eval exec -a x git stash`). Each flag reads one way only: a flag holding an `a` takes the next word,
one without takes none. Letting `-a` read both ways was exponential (`eval exec ` + `-a ` x 30 took
16 s). The spawn anchor takes one leading run of `builtin`, only when a wrapper word follows
(`builtin command claude --agent x`); a run that could read `builtin ` two ways took 15 s at 24 words.
A `builtin ...` timing row must name `claude` or `git`: the `.sh` fast path never starts python for `ls`.
A chain run with `exec -a x` units now charges the budget, so `eval ` + `exec -a x ` x 500 (5 KB) is
refused as too dense, as `command rtk proxy ` x 200 already was.

## irrecoverable.py: GH #336 rules and views

GH #336 added `mkfs`, `chmod-world` (777 / a+rwx with -R or on / or ~), `rm-no-preserve-root` and two
views, each a second reading of the whole command checked by every rule: `ifs-split` ($IFS read as a
blank) and `var-verb` (`$NAME` read back where the command assigns NAME a plain value). A view runs
after the command passed, up to 20 KB, and a structural deny inside one only ends that view. Two exceptions (GH #309): `brace-view` is read up to the main gate's 150 KB cap, and `_deny_ambiguous` returns inside it (a guard-position brace such as `{,git} reset --hard` would otherwise end the view before any rule ran). GH #661: rm's own rules (`rm-rf`, `rm-recursive`, `rm-no-preserve-root`) enforce inside `brace-view` (`_VIEW_ENFORCED`), since no token reading keeps a word such as `--{r,} b` whole; every other rule there stays shadow. GH #690: bash expands braces before `$IFS` splitting and command substitution, so `brace-view` also reads its expanded text with the `ifs-split` and `subst-literal` rewrites applied (`r{m,m}${IFS}-rf b`, `rm $(echo --{r,f}) b`), under the same enforcement. Replay of
55,000 real commands with every new rule shadowed: 0 verdict diffs against develop; 0 hits for the
first four, 1 for `var-verb` (a real `git -C $R checkout -- <file>`, a discard develop misses, GH #375), 63
`opaque-var-verb` asks and 98 `source-file` asks. Those three ship shadow. Residue: zsh does not split
$IFS (bash and dash do); `. file` with no candidate word never reaches python; `mk$(true)fs` matches,
`${X}` as argv0 does not read as mkfs.

## shlex cuts one shell word into several tokens (GH #375, #382)

With `punctuation_chars` and no
`whitespace_split`, a character outside its wordchars ends the token: `$PWD` is `$`, `PWD`, and `a:b`,
`a@b.c` and a Thai path split too. A check that takes "the next token" as one word misreads it: the git
global walk took `PWD` in `git -C $PWD reset --hard` for the subcommand. `_tokens` now returns a token
cut from the one before it, with no blank between, as `_Glued` (an equal `str`), and the git block
re-reads its global flags as joined words in a window of its own; the token reading stays, so a deny in
either wins. Replay of 115,308 real commands (main and agent): 3 newly denied, two
that run `reset --hard` / `checkout --` and one `git -C $PCR add .` (git-add-all, not data loss).
GH #382: every other walk had the same fault (sudo/doas/env/timeout/nice values, a `X=$Y` prefix, a
wrapper's dash words, docker's container, `$HOME/bin/git` as argv0), and `_split_ops("")` dropped an
empty word, so `git -C "" reset` read `reset` as -C's value. Each statement is now also read as shell
words (`_readings`: glued runs joined, `""` kept), queued and checked after every token window, so a
develop deny keeps its message. The token reading still drops `""`: keeping it there would allow
`"" rm -rf x`, which develop denies. Git ignores an empty argument in its rules (git rejects it).
A joined word holds more text, so in a word window a substitution word only stands for the names
its literal text allows (`_candidates`: `g$(..)t` may be git, `x:$(date)` names nothing); before
that, prose read as shell (python heredocs, a PR body) denied 8 replayed commands as `git restore`.
`scripts/gate-differential.sh` against develop (2026-10-04, after #405/#409): 20,000 and 40,000
replayed commands plus fixtures and fuzz; every exit change is a fixture or fuzz row, and the real
commands gained only 2 shadow asks (`PATH=/a:/b command -v $t`: opaque-var-verb;
`X=$F bash -c '. x.sh'`: source-file), each what develop already says without the split prefix.

## Wrapper words written as paths, quotes and a second parse (GH #320, #322, #344, #327)

GH #320: each word may also be written as a path (`/usr/bin/env git stash`), so every copy takes a
directory prefix, and the drift test checks `/usr/bin/<word>` too. The prefix is one plain word that
never starts with `-` and holds no `=`, `<` or `>`. The git word's `\S*/` was tried first and was
exponential: a token such as `-/command` or `2>/x/env` then reads two ways (flag or path command,
redirection or path wrapper), and the chain loops try every split (`eval command ` + `-/command ` x 40
ran past 15 s, and a timed-out hook allows).
GH #322: `irrecoverable.py`'s spawn anchor got the guard's #317 and #318 fixes (`cl\aude -p x`,
`{claude -p x;}`). It reads raw text, so a glued `{` inside quotes after a blank now denies too
(`git commit -m "fix {claude -p x;}"`), the same over-deny develop already makes for `"fix; claude -p x"`.
Its glued `{` alternative carries `(?!\s)` so it never matches the same `{` as `{` + blank: with both,
every `{ env ` unit was walked twice (2.4 s against 1.2 s at 2000 units).
GH #344: a shell removes the quotes inside a word (`"git" stash`, `g'i't stash`, `git "stash"`,
`"claude" -p x`). Both gates join a word made only of command-word characters (`[\w./-]`, an escaped
one too) and quoted runs of them back to its letters (`_QWORD_RE` / `_SPAWN_QWORD_RE`, one pattern, a
drift test). The guard joins only where its quote mask shows the word outside every quote, so a
message stays masked. A `$'..'`/`$".."` piece reads differently per shell (`$'list'` is `$list` in
dash, `$"show"` is `$show` in dash and zsh), which matters for the `stash list|show` carve-out, so the
guard runs up to three readings. The spawn anchor also scans the unjoined text when a join changed it
(`claude -p"x"` is `-px`). Its residue, a second parse level (`eval \"git\" stash`, `eval "git " stash`,
an escaped quote inside a `bash -c "..."` body), is GH #327's fix below.
GH #327: eval and `sh -c` hand their argument text to a second parse, so a pair that is a literal
backslash after the first parse is an escape in the second (`eval g\\\it stash`, `bash -c "g\\it stash"`).
The guard's `_read_words` does the first parse's quote removal (one word after `-c`, every word to the
statement end after eval, joined with blanks) and checks the result as one more body; the raw quoted body
is still checked, so any deny wins. `$'..'` is decoded the bash way and `$".."` read as `".."`; a `$(..)` or
backtick span is copied as it is. Fuzz, 4000 cases, two seeds: false-allows 641 and 552 to 0, no new
false-deny. A known over-deny: `eval sudo echo "git stash"` now reads as `sudo echo git stash`, which the
wrapper walk denies like the plain text (a GH #273 control changed from allow to deny). The copied spans
made every substitution body scan twice, so the substitution pass now checks each body string once; that
also fixed a develop timeout: `eval ` + 2 million backticks + a late `"$(git stash)"` took 8.3 s (allow),
now 3 s. The second-parse body joins the substitution pass only when a `$` or backtick came out of a quote
or an escape (`` eval echo '`git' 'stash`' ``), since a copied span is one the raw scan already read. Residue, which `develop` also allows: a substitution that expands to nothing
before the word (`eval $(true) g\\\it stash`, like `$(true) git stash`) and a third parse level.

## irrecoverable.py: one strict force-push exception (spec v3, 2026-10-30)

The operator asked to allow a force push unless its destination is protected (main, master, develop,
production, staging, `release/*`), a lease push to a protected branch included. Two earlier designs parsed
the shell to find the push's destinations, and a fresh validator broke each round with a new shell-parse gap
(value-taking options, xargs, a split at the first `:`, a redirect before `-f`, `--repo=`, `<<<`, an
assignment before xargs). This one parses nothing: `_FORCE_PUSH_OK` is a `re.fullmatch` of the raw command
(outer blanks trimmed) against `git( -C P)? push( O)* R( S)+`, single blanks, an alphabet with no shell
meaning, a fixed option list, a remote name (no URL) and explicit `src:dst` refspecs. The path, remote,
lease ref, src and dst never start with `-`, so an option can't fill the remote slot (`push -f --mirror
HEAD:feat` is git's `--mirror` and a repository `HEAD:feat`). An explicit `src:dst` ignores
`remote.<r>.push`, `push.default` and branch merge config, and mirror config refuses it (measured, git 2.56).
A dst or `--force-with-lease=<ref>` is protected after dropping `refs/heads/` or `heads/`, any case. The
flag skips only git-push-force, the ambiguity check's push arm and a `-c remote.<r>.push=+...` pair; mirror,
send-pack, delete-protected and every other rule still run. Tightened: a lease (`--force-with-lease[=..]`,
`--force-if-includes`) now counts as forced, so the strict shape is its only allow (four develop allow rows
to `origin develop` flip to deny). Accepted over-deny: anything chained, piped, redirected, quoted, wrapped,
with `-o`, or to a URL remote.
