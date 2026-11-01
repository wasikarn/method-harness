#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal \$ in test payload strings is intentional
# Gate unit tests: simulates PreToolUse JSON payloads and asserts allow/deny/ask.
# Each test_deny call expects exit 2; test_allow expects exit 0 + empty stdout;
# test_ask expects exit 0 + a permissionDecision: ask JSON on stdout.
# Run standalone: bash tests/hooks/test-gates-irrecoverable-2.sh
# Part 2 of 3 of the gate tests (see test-gates.sh); helpers in tests/_lib/gates-harness.sh.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/_lib/gates-harness.sh"

echo "=== irrecoverable gate (part 2) ==="
# --- git -c core.hooksPath= : the --no-verify-equivalent hook bypass ---
test_deny  "$IRRECOVERABLE" "git -c core.hooksPath= (hook bypass, space form)" \
  "$(bash_payload 'git -c core.hooksPath=/tmp/evil commit -m x')"
test_deny  "$IRRECOVERABLE" "git -ccore.hooksPath= (hook bypass, joined form)" \
  "$(bash_payload 'git -ccore.hooksPath=/tmp/evil commit -m x')"
test_deny  "$IRRECOVERABLE" "git config core.hooksPath <other> (persistent hook bypass)" \
  "$(bash_payload 'git config core.hooksPath /dev/null')"
test_deny  "$IRRECOVERABLE" "git config --unset core.hooksPath (persistent hook bypass)" \
  "$(bash_payload 'git config --unset core.hooksPath')"
test_allow "$IRRECOVERABLE" "git config core.hooksPath git-hooks (documented wiring)" \
  "$(bash_payload 'git config core.hooksPath git-hooks')"
# GH #562: "git-hooks" anywhere passed the allowlist (a value-pattern replaces the git-hooks value), and a read denied.
test_deny  "$IRRECOVERABLE" "GH #562: value-pattern git-hooks replaces the documented value" \
  "$(bash_payload 'git config core.hooksPath /dev/null git-hooks')"
test_deny  "$IRRECOVERABLE" "GH #562: --comment git-hooks" "$(bash_payload 'git config --comment git-hooks core.hooksPath /dev/null')"
test_allow "$IRRECOVERABLE" "GH #562: git config core.hooksPath (a read)" "$(bash_payload 'git config core.hooksPath')"
test_allow "$IRRECOVERABLE" "GH #562: CLAUDE.md's own check" "$(bash_payload 'test -d "$(git config core.hooksPath)"')"
test_allow "$IRRECOVERABLE" "GH #562: git config --get core.hooksPath" "$(bash_payload 'git config --get core.hooksPath')"
test_allow "$IRRECOVERABLE" "git -c user.name= (benign -c config, must not over-block)" \
  "$(bash_payload 'git -c user.name=x commit -m y')"
# 2026-09-20 audit: the -c branch did an exact-case startswith("core.hooksPath=")
# check while the sibling `git config` branch two lines below already lowercased --
# git itself treats the key case-insensitively, so a differently-cased key bypassed
# this gate while still working as a real hook-path override.
test_deny  "$IRRECOVERABLE" "git -c core.HOOKSPATH= (case-insensitive hookspath bypass, was silently ALLOWed)" \
  "$(bash_payload 'git -c core.HOOKSPATH=/tmp/evil commit -m x')"
test_deny  "$IRRECOVERABLE" "git -cCore.HooksPath= (joined form, mixed case, was silently ALLOWed)" \
  "$(bash_payload 'git -cCore.HooksPath=/tmp/evil commit -m x')"
# 2026-09-21 deep-audit: real git honors --config-env=KEY=VAR / --config-env KEY=VAR
# exactly like -c KEY=<value of VAR>, but only -c was checked.
test_deny  "$IRRECOVERABLE" "git --config-env=core.hooksPath=VAR (joined form, hook bypass, was silently ALLOWed)" \
  "$(bash_payload 'git --config-env=core.hooksPath=EVIL commit -m x')"
test_deny  "$IRRECOVERABLE" "git --config-env core.hookspath=VAR (split form, lowercase key, was silently ALLOWed)" \
  "$(bash_payload 'git --config-env core.hookspath=EVIL commit -m x')"
test_allow "$IRRECOVERABLE" "git --config-env=user.name=X (benign key, must not over-block)" \
  "$(bash_payload 'git --config-env=user.name=X commit -m x')"
# 2026-09-21 deep-audit: a bare NAME=value assignment prefix made argv0 "FOO=bar",
# so every token-dispatched deny (rm, git push --force, ...) fell through.
test_deny  "$IRRECOVERABLE" "FOO=bar rm -rf (assignment prefix, was silently ALLOWed)" \
  "$(bash_payload 'FOO=bar rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "FOO=bar git push --force (assignment prefix, was silently ALLOWed)" \
  "$(bash_payload 'FOO=bar git push --force origin main')"
test_deny  "$IRRECOVERABLE" "GIT_CONFIG_PARAMETERS=core.hooksPath=... git commit (env-var hook bypass, was silently ALLOWed)" \
  "$(bash_payload 'GIT_CONFIG_PARAMETERS="'"'"'core.hooksPath=/dev/null'"'"'" git commit -m x')"
test_deny  "$IRRECOVERABLE" "env GIT_CONFIG_PARAMETERS=core.hooksPath=... git commit (same via env wrapper)" \
  "$(bash_payload 'env GIT_CONFIG_PARAMETERS="'"'"'core.hooksPath=/dev/null'"'"'" git commit -m x')"
test_allow "$IRRECOVERABLE" "FOO=bar ls (assignment prefix on a benign command)" \
  "$(bash_payload 'FOO=bar ls')"
# --- actionable refusals: a "confirm with user first" deny names a next step a headless run can take ---
_NODECIDE='if nobody can confirm, skip this step, keep going on the rest'
test_deny_says "$IRRECOVERABLE" "refusal: reset --hard keeps the confirm text" "$(bash_payload 'git reset --hard')" "confirm with user first"
test_deny_says "$IRRECOVERABLE" "refusal: reset --hard has the no-one-to-confirm tail" "$(bash_payload 'git reset --hard')" "$_NODECIDE"
test_deny_says "$IRRECOVERABLE" "refusal: tail says list it for the user" "$(bash_payload 'git clean -fd')" "list it for the user in your final report"
test_deny_says "$IRRECOVERABLE" "refusal: dropdb has the tail" "$(bash_payload 'dropdb prod')" "$_NODECIDE"
test_deny_says "$IRRECOVERABLE" "refusal: tokenizer deny has the tail" "$(bash_payload 'rm -rf "x')" "$_NODECIDE"
test_deny_says "$IRRECOVERABLE" "refusal: tokenizer deny says split the command" "$(bash_payload 'rm -rf "x')" "split it into simpler separate commands"
# hints name steps this gate allows, and never git stash (subagent-git-guard denies it; the stash is shared).
# A step the subagent guard denies is marked "in the main session" in the hint (checked below).
# --binary: a plain diff writes only "Binary files differ" for a binary file; --no-textconv/--no-ext-diff/--no-color:
# a diff driver or forced color would write text git apply cannot use
_SAVE='or commit first, or save a patch with `git diff --binary --no-textconv --no-ext-diff --no-color HEAD > x.patch`'
test_deny_says "$IRRECOVERABLE" "refusal: reset --hard hint" "$(bash_payload 'git reset --hard')" 'in the main session, move HEAD with `git reset --keep <ref>`' '`git stash'
test_deny_says "$IRRECOVERABLE" "refusal: reset --hard names commit/patch" "$(bash_payload 'git reset --hard')" "$_SAVE"
test_deny_says "$IRRECOVERABLE" "refusal: restore hint" "$(bash_payload 'git restore f')" "$_SAVE" '`git stash'
test_deny_says "$IRRECOVERABLE" "refusal: checkout -- hint" "$(bash_payload 'git checkout -- f')" "$_SAVE" '`git stash'
test_deny_says "$IRRECOVERABLE" "refusal: switch --force hint" "$(bash_payload 'git switch -f main')" 'or commit first, then a plain `git switch`' '`git stash'
test_deny_says "$IRRECOVERABLE" "refusal: commit --amend hint" "$(bash_payload 'git commit --amend -m x')" "make a new commit"
test_deny_says "$IRRECOVERABLE" "refusal: clean -f hint" "$(bash_payload 'git clean -f')" 'in the main session, preview with `git clean -n`; then move the files aside with `mv`' '`git stash'
test_deny_says "$IRRECOVERABLE" "refusal: push --mirror hint" "$(bash_payload 'git push --mirror origin')" "push named refs"
test_deny_says "$IRRECOVERABLE" "refusal: stash drop hint" "$(bash_payload 'git stash drop')" "leave the stash in place" '`git stash'
test_deny_says "$IRRECOVERABLE" "refusal: worktree remove --force hint" "$(bash_payload 'git worktree remove --force ../wt')" "then a plain \`git worktree remove" '`git stash'
test_deny_says "$IRRECOVERABLE" "refusal: rm -f hint" "$(bash_payload 'git rm -f f.txt')" "then plain \`git rm"
test_deny_says "$IRRECOVERABLE" "refusal: chmod 777 hint" "$(bash_payload 'chmod -R 777 /')" "narrowest mode"
test_deny_says "$IRRECOVERABLE" "refusal: find -exec chmod 777 hint" "$(bash_payload 'find . -exec chmod 777 {} +')" "narrowest mode"
# a git -c / git config deny names the override, not the verb's hint: tail only
test_deny_says "$IRRECOVERABLE" "refusal: alias definition gets the tail only" "$(bash_payload "git config alias.x 'reset --hard'")" "$_NODECIDE" 'reset --keep'
test_deny_says "$IRRECOVERABLE" "refusal: -c alias run gets the tail only" "$(bash_payload "git -c alias.x='!git reset --hard' x")" "$_NODECIDE" 'reset --keep'
test_deny_says "$IRRECOVERABLE" "refusal: -c risk key gets the tail only" "$(bash_payload 'git -c clean.requireForce=false clean')" "$_NODECIDE" 'git clean -n'
# each alternative a hint names must itself pass the gate
for _alt in 'git reset --keep HEAD~1' 'git commit -m x' 'git add f.txt' 'git diff --binary --no-textconv --no-ext-diff --no-color HEAD > x.patch' 'git clean -n' \
  'mv f.txt aside/' 'git push origin feat/x' 'git worktree remove ../wt' 'git rm f.txt' \
  'chmod 755 f.sh' 'chmod u+x f.sh' 'git switch main'; do
  test_allow "$IRRECOVERABLE" "refusal hint alternative: $_alt" "$(bash_payload "$_alt")"
done
# a subagent reads the same hints: every alternative not marked "in the main session" must pass its guard too
for _alt in 'git commit -m x' 'git add f.txt' 'git diff --binary --no-textconv --no-ext-diff --no-color HEAD > x.patch' \
  'mv f.txt aside/' 'git push origin feat/x' 'git worktree remove ../wt' 'git rm f.txt' \
  'chmod 755 f.sh' 'chmod u+x f.sh' 'git switch main'; do
  test_allow "$SUBAGENT_GIT_GUARD" "refusal hint alternative, subagent: $_alt" "$(bash_agent_payload "$_alt" fork)"
done
# the two marked main-session-only really are denied to a subagent (drop the mark if the guard ever allows them)
for _alt in 'git reset --keep HEAD~1' 'git clean -n'; do
  test_deny "$SUBAGENT_GIT_GUARD" "refusal hint alternative, subagent denied: $_alt" "$(bash_agent_payload "$_alt" fork)"
done
# --- git branch force-delete: discards unmerged commits ---
test_deny  "$IRRECOVERABLE" "git branch -D (force-delete short flag)" \
  "$(bash_payload 'git branch -D main')"
test_deny  "$IRRECOVERABLE" "git branch --delete --force (long-flag force-delete)" \
  "$(bash_payload 'git branch --delete --force develop')"
test_deny  "$IRRECOVERABLE" "git branch -fD (bundled force-delete flags)" \
  "$(bash_payload 'git branch -fD master')"
# Operator policy 2026-09-30: a force-delete is allowed unless it may hit main/master/develop.
test_allow "$IRRECOVERABLE" "git branch -D on a feature branch is allowed" \
  "$(bash_payload 'git branch -D claude/gate-restore-S-197-2026-09-29')"
test_allow "$IRRECOVERABLE" "git branch -D on several feature branches is allowed" \
  "$(bash_payload 'git branch -D feat/a fix-b')"
test_allow "$IRRECOVERABLE" "git branch --delete --force on a feature branch is allowed" \
  "$(bash_payload 'git branch --delete --force featurex')"
test_allow "$IRRECOVERABLE" "a name that only contains main is not protected" \
  "$(bash_payload 'git branch -D maintenance feat/main-fix')"
test_deny  "$IRRECOVERABLE" "git branch -D with a protected name among others" \
  "$(bash_payload 'git branch -D feat/a develop')"
test_deny  "$IRRECOVERABLE" "git branch -D Main (case-insensitive filesystem)" \
  "$(bash_payload 'git branch -D Main')"
test_deny  "$IRRECOVERABLE" "git branch -D refs/heads/master" \
  "$(bash_payload 'git branch -D refs/heads/master')"
test_deny  "$IRRECOVERABLE" "git branch -D with a quoted protected name" \
  "$(bash_payload 'git branch -D "ma"in')"
test_deny  "$IRRECOVERABLE" "git branch -D -- main (name after --)" \
  "$(bash_payload 'git branch -D -- main')"
test_deny  "$IRRECOVERABLE" "git branch -D with a substituted name" \
  "$(bash_payload 'git branch -D $(git branch --show-current)')"
test_deny  "$IRRECOVERABLE" "git branch -D with a variable name" \
  "$(bash_payload 'git branch -D $b')"
test_deny  "$IRRECOVERABLE" "git branch -D with a glob" \
  "$(bash_payload 'git branch -D ma*')"
test_deny  "$IRRECOVERABLE" "git branch -D @{-1} (the previous branch, may be main)" \
  "$(bash_payload 'git branch -D @{-1}')"
test_deny  "$IRRECOVERABLE" "git branch -D with a quoted ; before main (splits the window)" \
  "$(bash_payload "git branch -D f1 ';' main")"
test_deny  "$IRRECOVERABLE" "git branch -D with an escaped & before develop" \
  "$(bash_payload 'git branch -D f1 \& develop')"
test_deny  "$IRRECOVERABLE" "git branch -D ma{i,}n (mid-word brace expansion)" \
  "$(bash_payload 'git branch -D ma{i,}n')"
test_deny  "$IRRECOVERABLE" "xargs appends main to git branch -D" \
  "$(bash_payload 'echo main | xargs git branch -D f1')"
test_deny  "$IRRECOVERABLE" "xargs -I replaces the name with main" \
  "$(bash_payload 'echo main | xargs -I X git branch -D X')"
test_deny  "$IRRECOVERABLE" "git branch -D chained after another command keeps the deny" \
  "$(bash_payload 'git fetch && git branch -D f1')"
test_allow "$IRRECOVERABLE" "git -C path branch -D feature is allowed" \
  "$(bash_payload 'git -C /tmp/r branch -D feat/a')"
test_allow "$IRRECOVERABLE" "git branch -rD origin/feature is allowed" \
  "$(bash_payload 'git branch -rD origin/feat-a')"
# Deep-audit 2026-10-01: @ inside a name is a valid refname and literal to the shell there. # is not:
# zsh extendedglob turns "ma#in" into a glob that can match a "main" entry in the cwd.
test_allow "$IRRECOVERABLE" "git branch -D with @ inside a name is allowed" \
  "$(bash_payload 'git branch -D feature@v2')"
test_deny  "$IRRECOVERABLE" "git branch -D ma#in (a zsh extendedglob for main) keeps the deny" \
  "$(bash_payload 'git branch -D ma#in')"
test_deny  "$IRRECOVERABLE" "git branch -D name@{1} keeps the deny" \
  "$(bash_payload 'git branch -D feat@{1}')"
test_deny  "$IRRECOVERABLE" "git branch -D f1 #main (a word-leading # is a comment) keeps the deny" \
  "$(bash_payload 'git branch -D f1 #main')"
test_deny  "$IRRECOVERABLE" "git branch -D maſter (U+017F folds to master on APFS)" \
  "$(bash_payload 'git branch -D maſter')"
test_deny  "$IRRECOVERABLE" "git branch -D maﬆer (U+FB06 folds to st)" \
  "$(bash_payload 'git branch -D maﬆer')"
test_deny  "$IRRECOVERABLE" "git branch -D with no name" \
  "$(bash_payload 'git branch -D')"
test_deny  "$IRRECOVERABLE" "git -C repo branch -D develop" \
  "$(bash_payload 'git -C /tmp/r branch -D develop')"
test_allow "$IRRECOVERABLE" "git branch newbranch (create, must not over-block)" \
  "$(bash_payload 'git branch newbranch')"
test_allow "$IRRECOVERABLE" "git branch featureD (name containing D, must not over-block)" \
  "$(bash_payload 'git branch featureD')"
# 2026-09-20 audit: git accepts an unambiguous prefix of any long flag
# (--no-veri for --no-verify, etc). Every exact-string `== "--force"`-style
# check below was bypassed live by git's own long-option abbreviation feature.
# push --force is deliberately NOT tested here: git rejects a shortened
# --forc as ambiguous with --force-with-lease/--force-if-includes, so that
# call site is confirmed non-exploitable and was left untouched by the fix.
test_deny  "$IRRECOVERABLE" "git commit --no-veri (abbreviated --no-verify, was silently ALLOWed)" \
  "$(bash_payload 'git commit --no-veri -m msg')"
test_deny  "$IRRECOVERABLE" "git reset --ha (abbreviated --hard, was silently ALLOWed)" \
  "$(bash_payload 'git reset --ha HEAD~1')"
test_deny  "$IRRECOVERABLE" "git commit --amen (abbreviated --amend, was silently ALLOWed)" \
  "$(bash_payload 'git commit --amen')"
test_deny  "$IRRECOVERABLE" "git clean --forc (abbreviated --force, was silently ALLOWed)" \
  "$(bash_payload 'git clean --forc')"
test_deny  "$IRRECOVERABLE" "git branch --del --forc (abbreviated delete+force, was silently ALLOWed)" \
  "$(bash_payload 'git branch --del --forc main')"
test_deny  "$IRRECOVERABLE" "git switch --discard-ch (abbreviated --discard-changes, was silently ALLOWed)" \
  "$(bash_payload 'git switch --discard-ch main')"
test_deny  "$IRRECOVERABLE" "git add --al (abbreviated --all, was silently ALLOWed)" \
  "$(bash_payload 'git add --al')"
# deep-audit fix-round 3, 2026-09-20: the len()>3 guard excluded 2-char-
# after-"--" tokens from ever being checked, regardless of whether real git
# accepts them unambiguously -- live-confirmed `git reset --h` and
# `git clean --f` both ran for real and destroyed data.
test_deny  "$IRRECOVERABLE" "git reset --h (1-char abbreviated --hard, was silently ALLOWed)" \
  "$(bash_payload 'git reset --h')"
test_deny  "$IRRECOVERABLE" "git clean --f (1-char abbreviated --force, was silently ALLOWed)" \
  "$(bash_payload 'git clean --f')"
# Spec v3 (PR #745): a lease is forced, and with no src:dst it is denied. This row
# was an allow control below until leases started counting as forced.
test_deny  "$IRRECOVERABLE" "git push --force-with-lease origin develop denied (spec v3: a lease is forced; no src:dst)" \
  "$(bash_payload 'git push --force-with-lease origin develop')"
# Dangerous-direction control: the abbreviation helper must not itself start
# denying git's own already-documented noisy neighbors (an ambiguous prefix
# these long forms don't uniquely resolve to, or a flag never named in the
# specific per-call-site long_forms list).
test_allow "$IRRECOVERABLE" "git push -u origin HEAD:feat still allowed (-u is not a --force prefix)" \
  "$(bash_payload 'git push -u origin HEAD:feat')"
test_allow "$IRRECOVERABLE" "git diff --find-renames still allowed (unrelated long flag, not a --force/--hard/--amend prefix)" \
  "$(bash_payload 'git diff --find-renames')"
# --- fail-closed internal-error backstop: a payload that makes the
# Python raise (command is a JSON array, not a string) must still exit 2, never fall open.
test_deny_failclosed "$IRRECOVERABLE" "non-string command payload triggers the fail-closed backstop (exit 2, not fail-open)" \
  '{"tool_name":"Bash","tool_input":{"command":["rm","-rf","/x"]}}'

# --- GH #140: unbounded shlex tokenize cost on an oversized raw command string.
_len_pad=$(python3 -c "print('A' * 700000)")

_rc=$(bash_payload "git push --force origin $_len_pad" | timeout 2 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (<2s): oversized single-token dangerous command still denies (GH #140 length cap)"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (<2s) but got exit $_rc: oversized dangerous command (GH #140 length cap)" >&2
  fail=$((fail + 1))
fi

# Direction-pinning: the SAME oversized padding on a BENIGN tail (git status matches no deny
# pattern at all) must ALSO deny fast.
_rc=$(bash_payload "git status $_len_pad" | timeout 2 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (<2s): oversized BENIGN-tail command still denies -- pins the cap, not a pattern match (GH #140)"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (<2s) but got exit $_rc: oversized benign-tail command (GH #140 length cap)" >&2
  fail=$((fail + 1))
fi

# Negative control: a realistic, modestly-sized legitimate command.
test_allow "$IRRECOVERABLE" "realistic longer commit message, well under the GH #140 length cap -> still allows" \
  "$(bash_payload 'git commit -m "Implement feature X with detailed rationale covering edge cases and rollback plan for the release"')"

# 2026-09-29 deep-audit (Codex checker + a wrapper x verb sweep): a denied command hidden by a
# SPELLING its rule did not know. Every case below was already open before the gate chain (0 flips
# against the pre-chain gate), none is a regression. (a) command position after a shell keyword
# (do/then/else/elif/if/while/until/!), a wrapper missing from PREFIX_WRAPPERS (exec, timeout,
# ...), and the |& pipe; the same commands split over lines were already denied. (b) the short or
# bundled form of a flag the rule only checked long: commit -n is --no-verify, branch -d -f is -D,
# add -Af is add -A.
for _c in \
  'for d in a b; do rm -rf /tmp/x; done' \
  'while true; do git reset --hard; done' \
  'until false; do rm -rf /tmp/x; done' \
  'if true; then git add -A; fi' \
  'if false; then :; else rm -rf /tmp/x; fi' \
  'if false; then :; elif true; then rm -rf /tmp/x; fi' \
  'if false; then :; elif rm -rf /tmp/x; then :; fi' \
  'if rm -rf /tmp/x; then echo ok; fi' \
  'while git reset --hard; do :; done' \
  'until rm -rf /tmp/x; do :; done' \
  'while ! rm -rf /tmp/x; do :; done' \
  'coproc rm -rf /tmp/x' \
  'for d in a; do FOO=1 rm -rf "$d"; done' \
  'for d in a; do timeout 5 rm -rf "$d"; done' \
  '! rm -rf /tmp/x' \
  'exec rm -rf /tmp/x' \
  'true |& rm -rf /tmp/x' \
  'timeout 5 rm -rf /tmp/x' \
  'timeout -s KILL 5 rm -rf /tmp/x' \
  'timeout -k 2 -s KILL 5 rm -rf /tmp/x' \
  'timeout --signal KILL 5 rm -rf /tmp/x' \
  'gtimeout 5 rm -rf /tmp/x' \
  'setsid rm -rf /tmp/x' \
  'stdbuf -oL rm -rf /tmp/x' \
  'stdbuf -i 0 -e 0 -o 0 rm -rf /tmp/x' \
  'ionice -c3 rm -rf /tmp/x' \
  'ionice -c 3 -n 4 rm -rf /tmp/x' \
  'for d in a; do git commit -n -m x; done' \
  'git commit -n -m x' \
  'git commit -nm x' \
  'git commit -anm x' \
  'git commit -m x -n' \
  'git branch -d -f main' \
  'git branch -df develop' \
  'git branch -fd master' \
  'git branch -d --force main' \
  'git branch --delete -f develop' \
  'git branch -r -d -f origin/main' \
  'git add -Af' \
  'git add -fA' \
  'git add -vA' ; do
  test_deny "$IRRECOVERABLE" "spelling variant still denied: $_c" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" "subagent spawns claude through the exec wrapper (spawn guard shares the wrapper list)" \
  "$(bash_agent_payload 'exec claude -p "x"' fork)"
test_deny  "$IRRECOVERABLE" "subagent spawns claude through timeout (spawn guard shares the wrapper list)" \
  "$(bash_agent_payload 'timeout 60 claude -p "x"' fork)"
# Controls: none of the fixes may deny an ordinary command that only LOOKS similar. The keyword
# strip applies at command position only, so a keyword used as an argument or inside a quoted
# message is data, and -n only counts on `commit` (push -n is --dry-run).
for _c in \
  'for d in a b; do echo "$d"; done' \
  'for f in a.txt b.txt; do git add "$f"; done' \
  'if true; then echo hi; fi' \
  'while read l; do echo "$l"; done < list.txt' \
  '! git diff --quiet' \
  'echo do rm -rf x' \
  'echo then git add -A' \
  'git log --grep do' \
  'true |& cat' \
  'timeout 5 ls' \
  'timeout -s KILL 5 make test' \
  'exec ls' \
  'setsid ls' \
  'stdbuf -oL ls' \
  'ionice -c3 ls' \
  'git commit -m msg' \
  'git commit -am msg' \
  'git commit -mnew' \
  'git commit -Fnotes.txt' \
  'git commit -tnotes.txt -m x' \
  'git commit -uno -m x' \
  'git commit -m "fix n handling, then rm -rf notes"' \
  'git push -n' \
  'git branch -d merged-branch' \
  'git branch --delete merged-branch' \
  'git add file.py' \
  'git add -u' \
  'git add -p' \
  'git add -n file.py' \
  'git add -f ignored.txt' ; do
  test_allow "$IRRECOVERABLE" "spelling-variant control still allowed: $_c" "$(bash_payload "$_c")"
done

# Round 2 of the same audit (whole-picture pass over the round-1 fix). (a) Regression the round-1
# wrapper names introduced: a token that only STARTS with a wrapper word ("timeout=30", "exec-bot")
# dead-ended the spawn anchor's regex, so `env timeout=30 claude -p x` stopped denying. (b) The spawn
# anchor did not see loop keywords: `for i in 1; do claude -p x; done`. (c) shlex fuses glued
# punctuation into ONE token (");", "&&(", ")|", ")|&") that is not in OPERATORS, so the command after
# it stayed an argument and no rule dispatched on it: `(cd a && make); rm -rf build`.
test_deny  "$IRRECOVERABLE" "subagent: env timeout=30 claude -p (wrapper-word prefix token must not defeat the spawn anchor)" \
  "$(bash_agent_payload 'env timeout=30 claude -p "x"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: sudo -u exec-bot claude -p (same anchor dead end)" \
  "$(bash_agent_payload 'sudo -u exec-bot claude -p "x"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: claude -p inside a for/do loop" \
  "$(bash_agent_payload 'for i in 1; do claude -p "x"; done' fork)"
test_deny  "$IRRECOVERABLE" "subagent: claude -p after then" \
  "$(bash_agent_payload 'if true; then claude -p "x"; fi' fork)"
test_deny  "$IRRECOVERABLE" "subagent: claude -p after !" \
  "$(bash_agent_payload '! claude -p "x"' fork)"
test_allow "$IRRECOVERABLE" "subagent control: env timeout=30 with a harmless command" \
  "$(bash_agent_payload 'env timeout=30 echo hi' fork)"
test_allow "$IRRECOVERABLE" "subagent control: a for/do loop with no spawn" \
  "$(bash_agent_payload 'for i in 1; do echo "$i"; done' fork)"
for _c in \
  '(cd a && :); rm -rf x' \
  'cd a&&(git push --force)' \
  'true;(git commit -n -m x)' \
  '(true)|rm -rf x' \
  '(true)|&rm -rf x' \
  'bash -c "(true);rm -rf x"' ; do
  test_deny "$IRRECOVERABLE" "glued punctuation still separates commands: $_c" "$(bash_payload "$_c")"
done
for _c in \
  '(cd sub && make); ls' \
  '(echo a); echo b' \
  'cd a&&(ls)' \
  'env timeout=30 ls' ; do
  test_allow "$IRRECOVERABLE" "glued-punctuation control still allowed: $_c" "$(bash_payload "$_c")"
done

# 2026-09-29 deep-audit 4: `builtin` runs the builtin after it, so `builtin eval rm -rf x` and
# `builtin command git add -A` reached the real command with no wrapper unwrapped (the wrapper x verb
# sweep of the third audit never listed it). It is unwrapped in the rule loop only and is NOT in
# PREFIX_WRAPPERS: as a shared wrapper word it made the spawn anchor's greedy walk cross `&&` and land
# on the last `claude`, so `builtin cd /tmp && claude -p x && claude --version` stopped denying.
# The allow controls carry a candidate token (git/rm) so they reach irrecoverable.py, not the .sh prefilter.
for _c in \
  'builtin eval rm -rf x' \
  'builtin command git add -A' \
  'builtin eval git commit -n -m x' \
  'builtin command git push --force origin main' ; do
  test_deny "$IRRECOVERABLE" "builtin wrapper unwrapped: $_c" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" "subagent: builtin cd && claude -p && claude --version (no greedy walk past the first spawn)" \
  "$(bash_agent_payload 'builtin cd /tmp && claude -p "x" && claude --version' fork)"
test_deny  "$IRRECOVERABLE" "subagent: env builtin=30 claude -p (glued word must not defeat the spawn anchor)" \
  "$(bash_agent_payload 'env builtin=30 claude -p "x"' fork)"
for _c in \
  'builtin echo git status' \
  'builtin cd /tmp && git status' \
  'builtin command git status' \
  'builtin eval echo rm x' \
  'env builtin=30 git status' ; do
  test_allow "$IRRECOVERABLE" "builtin control still allowed: $_c" "$(bash_payload "$_c")"
done
# GH #245: the same greedy walk after an old wrapper (time, timeout, env, ...) crossed the separators
# to the LAST `claude`, and finditer resumed after it, so the earlier spawn was never scanned.
for _c in \
  'time ls; claude -p "x"; claude --version' \
  'timeout 5 ls && claude --bg "x" && claude --help' \
  'env A=1 make || claude --agent x; claude --version' ; do
  test_deny "$IRRECOVERABLE" "subagent: spawn behind an old-wrapper statement still anchored: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
# The eval / sh -c body scan calls the same spawn check (_scan_body). A caller left on an old
# signature raised TypeError, and irrecoverable.sh turned that exit 1 into a fail-closed deny, so
# test_deny could not see the crash: these rows run the .py directly and require its own exit 2.
for _c in \
  'eval claude -p x' \
  'ls; eval claude -p x' \
  'bash -c "claude --bg x"' ; do
  _rc=$(bash_agent_payload "$_c" fork | python3 "$ROOT/hooks/gates/irrecoverable.py" 2>/dev/null; echo $?)
  if [[ "$_rc" == "2" ]]; then
    echo "  ✅ DENY (.py, no crash): $_c"; pass=$((pass + 1))
  else
    echo "  ❌ .py exit $_rc, expected its own deny (2): $_c" >&2; fail=$((fail + 1))
  fi
done
test_allow "$IRRECOVERABLE" "subagent: old-wrapper walk control, no spawn flag: time ls; claude --version; claude --help" \
  "$(bash_agent_payload 'time ls; claude --version; claude --help' fork)"
# GH #320: a wrapper written as a path (`/usr/bin/env claude -p x`) runs the same program. The rule
# loop already compares basenames; the spawn anchor matched the bare word only.
for _c in \
  '/usr/bin/env claude -p "x"' \
  '/usr/bin/nice claude -p "x"' \
  '/opt/homebrew/bin/timeout 5 claude -p "x"' \
  '/usr/bin/env /usr/bin/nice claude --print "x"' \
  '/opt/homebrew/bin/rtk proxy claude -p "x"' \
  'true; /usr/bin/time claude --bg "x"' \
  '/usr/bin/env ls; claude -p "x"; claude --version' ; do
  test_deny "$IRRECOVERABLE" "subagent: spawn behind a wrapper written as a path: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  '/usr/bin/env claude --version' \
  'echo /usr/bin/env claude -p x' \
  '/usr/bin/envy claude -p x' ; do
  test_allow "$IRRECOVERABLE" "subagent: wrapper-path control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
# GH #322: the spawn anchor reads the raw command, so it missed what subagent-git-guard.py learned
# in #317 and #318. A shell drops a backslash before an ordinary character (`cl\aude -p x`,
# `claude --pri\nt x`), and zsh runs a brace group glued to its `{` (`{claude -p x;}`). Each deny
# row runs claude with a spawn flag in sh, bash 3.2, bash 5, dash, zsh and ksh (logging claude stub;
# the glued-brace rows in zsh only); the controls run none.
for _c in \
  'cl\aude -p hello' \
  '\c\l\a\u\d\e -p hello' \
  'e\nv claude -p hello' \
  'ti\me claude -p hello' \
  's\udo claude -p hello' \
  'claude -\p hello' \
  'claude --pri\nt hello' \
  'claude --a\gent x' \
  'claude --b\g x' \
  "bash -c 'cl\\aude -p hello'" \
  'bash -c "cl\aude -p hello"' \
  "eval 'cl\\aude -p hello'" \
  'true; cl\aude --bg x' \
  '{ cl\aude -p hello; }' \
  'echo $(cl\aude -p x)' \
  '/usr/bin/e\nv claude -p hello' \
  '{claude -p hello;}' \
  '{claude -p hello; }' \
  '(){claude -p hello;}' \
  'f(){claude -p x;}; f' \
  '{{claude -p x;};}' \
  'true; {claude -p x;}' \
  'true&&{claude -p x;}' \
  '({claude -p x;})' \
  '{env claude -p x;}' \
  '{cl\aude -p x;}' \
  'echo $({claude -p x;})' \
  'if true; then {claude -p x;}; fi' ; do
  test_deny "$IRRECOVERABLE" "subagent: GH #322 spawn denied (escaped letter / zsh glued brace): $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'cl\\aude -p hello' \
  'cl\\\aude -p hello' \
  'echo cl\aude -p hello' \
  'x{claude -p hello;}' \
  '${claude -p x;}' \
  '{true;}{claude -p x;}' \
  '{claude --version;}' \
  'cl\aude --version' \
  'claude -\v' \
  '\{claude -p x;}' \
  'claude --pri\\nt' ; do
  test_allow "$IRRECOVERABLE" "subagent: GH #322 control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
# Every glued `{` is now a command start that walks a wrapper chain; padded shapes must still be
# decided in bounded time (worst measured about 1 s; `timeout 5` turns a regression into rc 124).
for _u in '{env ' '{ env ' '{sudo -u x ' 'e\nv ' ; do
  _c="$(python3 -c 'import sys; print(sys.argv[1] * 2000 + "claude -p x")' "$_u")"
  _rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
  if [[ "$_rc" == "2" ]]; then
    echo "  ✅ DENY (bounded time): GH #322 padded '$_u' x 2000 before claude -p"; pass=$((pass + 1))
  else
    echo "  ❌ DENY EXPECTED (bounded time) but got exit $_rc (124 = timed out): GH #322 padded '$_u' x 2000" >&2; fail=$((fail + 1))
  fi
done
# GH #344: a shell removes the quotes inside a word, so a quoted or partly quoted claude, wrapper or
# flag still runs claude. Each deny row runs claude with a spawn flag in sh, bash 3.2, bash 5, dash, zsh
# and ksh (logging claude stub; $'..' rows in all but dash, the glued-brace row in zsh only); the
# controls run none.
for _c in \
  '"claude" -p x' \
  "cl'a'ude -p x" \
  'cl""aude -p x' \
  "'claude' --print x" \
  'sudo "claude" -p x' \
  '"env" claude -p x' \
  '"sudo" -u x claude -p x' \
  'true; "claude" --bg x' \
  'echo $("claude" -p x)' \
  "bash -c '\"claude\" -p x'" \
  '{ "claude" -p x; }' \
  '{"claude" -p x;}' \
  "claude '-'p x" \
  'claude --"print" x' \
  "\$'claude' -p x" \
  '"cl"\aude -p x' \
  'claude -p"x"' ; do
  test_deny "$IRRECOVERABLE" "subagent: GH #344 spawn denied (quoted word): $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'echo "claude" -p x' \
  '"claude -p x"' \
  '"claudex" -p x' \
  '"A=1" claude -p x' \
  '"claude" --version' \
  'git commit -m "use claude -p"' \
  "echo 'a \"claude\" -p'" ; do
  test_allow "$IRRECOVERABLE" "subagent: GH #344 control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
_c="$(python3 -c 'print("\"e\"nv " * 4000 + "claude -p x")')"
_rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): GH #344 '\"e\"nv ' x 4000 before claude -p"; pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $_rc (124 = timed out): GH #344 '\"e\"nv ' x 4000" >&2; fail=$((fail + 1))
fi
# GH #339: `builtin` before a wrapper runs the wrapper (`builtin command claude --agent x`). It is not a
# wrapper word (it made the greedy walk cross `&&`, see _UNWRAP_ONLY), so the anchor takes one leading
# run of it, only when a wrapper word follows. Each deny row runs claude with a spawn flag in sh, bash 3.2,
# bash 5 and zsh (logging claude stub); the controls run none.
for _c in \
  'builtin command claude --agent x' \
  'builtin exec -a x claude --print x' \
  'builtin builtin command claude -p x' \
  'true; builtin exec claude -p x' \
  'builtin -- command claude -p x' \
  'builtin cd /tmp && claude -p x && claude --version' \
  'builtin command true && claude -p x && claude --version' \
  '{ builtin exec -a x claude -p x; }' ; do
  test_deny "$IRRECOVERABLE" "subagent: GH #339 spawn denied (builtin before a wrapper): $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'builtin command claude --version' \
  'builtin echo claude -p x' \
  'builtin claude -p x' \
  'echo builtin command claude -p x' \
  'builtin cd /tmp && claude --version' ; do
  test_allow "$IRRECOVERABLE" "subagent: GH #339 control, no spawn: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _u in 'builtin ' 'builtin command ' ; do
  _c="$(python3 -c 'import sys; print(sys.argv[1] * 3000 + "command claude -p x")' "$_u")"
  _rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
  if [[ "$_rc" == "2" ]]; then
    echo "  ✅ DENY (bounded time): GH #339 padded '$_u' x 3000 before claude -p"; pass=$((pass + 1))
  else
    echo "  ❌ DENY EXPECTED (bounded time) but got exit $_rc (124 = timed out): GH #339 padded '$_u' x 3000" >&2; fail=$((fail + 1))
  fi
done
# `claude --version`, not `ls`: the .sh fast path skips python for a command with no claude/git in it.
_c="$(python3 -c 'print("builtin " * 3000 + "claude --version")')"
_rc=$(bash_agent_payload "$_c" fork | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_rc" == "0" ]]; then
  echo "  ✅ GH #339 padded 'builtin ' x 3000 allow shape finishes in bounded time (rc $_rc)"; pass=$((pass + 1))
else
  echo "  ❌ GH #339 padded 'builtin ' x 3000 allow shape: expected rc 0, got $_rc (124 = timed out)" >&2; fail=$((fail + 1))
fi

echo ""
echo "=== gh merge ask-tier gate (Phase B, 2026-09-28: local defense-in-depth for the PR-review flow) ==="
# GH #564: two built-in T3 writes the lists missed.
test_ask   "$IRRECOVERABLE" "GH #564: gh gist delete" "$(bash_payload 'gh gist delete 123')"
test_ask   "$IRRECOVERABLE" "GH #564: gh pr update-branch --rebase" "$(bash_payload 'gh pr update-branch 3 --rebase')"
test_allow "$IRRECOVERABLE" "GH #564 control: gh pr update-branch (merge commit)" "$(bash_payload 'gh pr update-branch 3')"
test_allow "$IRRECOVERABLE" "GH #564 control: gh gist view" "$(bash_payload 'gh gist view 1')"
test_ask   "$IRRECOVERABLE" "gh pr merge <number>"                "$(bash_payload 'gh pr merge 5')"
# GH #565: "merge" as a search word, a branch name or a file path is a read, not the merge verb or endpoint.
test_allow "$IRRECOVERABLE" "GH #565: gh pr list --search merge" "$(bash_payload 'gh pr list --search merge')"
test_allow "$IRRECOVERABLE" "GH #565: gh api contents/.../merge_sort.py" "$(bash_payload 'gh api repos/o/r/contents/lib/merge_sort.py')"
test_allow "$IRRECOVERABLE" "GH #565: gh api commits?path=src/merge.py" "$(bash_payload "gh api 'repos/o/r/commits?path=src/merge.py'")"
test_ask   "$IRRECOVERABLE" "GH #565: gh pr -R o/r merge still asks" "$(bash_payload 'gh pr -R o/r merge 3')"
test_ask   "$IRRECOVERABLE" "GH #565: gh api .../pulls/3/merge still asks" "$(bash_payload 'gh api repos/o/r/pulls/3/merge')"
# GH #621: a boolean flag does not take the next word, so a -h after it is help (runs nothing).
test_allow "$IRRECOVERABLE" "GH #621: gh pr update-branch --rebase -h (help)" "$(bash_payload 'gh pr update-branch 3 --rebase -h')"
test_allow "$IRRECOVERABLE" "GH #621: gh release upload --clobber -h (help)" "$(bash_payload 'gh release upload v1 f --clobber -h')"
test_allow "$IRRECOVERABLE" "GH #621: gh pr merge 1 --squash --help (help)" "$(bash_payload 'gh pr merge 1 --squash --help')"
test_ask   "$IRRECOVERABLE" "GH #621 control: gh api -H -h (-h is -H's value)" "$(bash_payload 'gh api -H -h repos/o/r/pulls/1/merge')"
test_ask   "$IRRECOVERABLE" "GH #621 control: gh extension exec x --force -h (exec hands -h on)" "$(bash_payload 'gh extension exec x --force -h')"
test_ask   "$IRRECOVERABLE" "GH #621 control: gh pr merge 1 --body -h (-h is --body's value)" "$(bash_payload 'gh pr merge 1 --body -h')"
# GH #621: a mid-word # reaches the gate as HASH_LIT; the endpoint check reads it as #.
test_ask   "$IRRECOVERABLE" "GH #621: gh api .../pulls/3/merge#x asks" "$(bash_payload 'gh api repos/o/r/pulls/3/merge#x')"
test_ask   "$IRRECOVERABLE" "GH #621: gh api '.../pulls/3/merge#x' asks" "$(bash_payload "gh api 'repos/o/r/pulls/3/merge#x'")"
test_allow "$IRRECOVERABLE" "GH #621 control: gh api .../contents/merge_x#y.py" "$(bash_payload 'gh api repos/o/r/contents/merge_x#y.py')"
test_ask   "$IRRECOVERABLE" "gh pr merge with --squash flag"       "$(bash_payload 'gh pr merge --squash 5')"
test_ask   "$IRRECOVERABLE" "gh pr merge with a brace word asks once (two window copies)" "$(bash_payload 'gh pr merge feat{1}')"
test_ask   "$IRRECOVERABLE" "gh pr merge with a \$() argument asks once (compacted copy)" "$(bash_payload 'gh pr merge $(true) 12')"
test_ask   "$IRRECOVERABLE" "gh api .../merge (PUT)"              "$(bash_payload 'gh api repos/wasikarn/method-harness/pulls/5/merge -X PUT')"
test_allow "$IRRECOVERABLE" "gh pr view (not a merge)"             "$(bash_payload 'gh pr view 5')"
test_allow "$IRRECOVERABLE" "gh pr list (not a merge)"             "$(bash_payload 'gh pr list')"
test_allow "$IRRECOVERABLE" "gh pr create (not a merge)"           "$(bash_payload 'gh pr create --title x --body y')"
test_allow "$IRRECOVERABLE" "gh api on an unrelated endpoint"      "$(bash_payload 'gh api repos/wasikarn/method-harness/pulls/5')"

echo ""
echo "=== gh api write ask (2026-10-23: replaces settings.json's blanket Bash(gh api *) ask, so reads stop prompting) ==="
test_ask   "$IRRECOVERABLE" "gh api -X DELETE a ruleset"            "$(bash_payload 'gh api -X DELETE repos/o/r/rulesets/5')"
test_ask   "$IRRECOVERABLE" "gh api --method put (lower case) contents" "$(bash_payload 'gh api --method put repos/o/r/contents/f -f message=x')"
test_ask   "$IRRECOVERABLE" "gh api -XPATCH visibility"             "$(bash_payload 'gh api -XPATCH repos/o/r -f visibility=public')"
test_ask   "$IRRECOVERABLE" "gh api bundled -iXPUT branch protection" "$(bash_payload 'gh api -iXPUT repos/o/r/branches/main/protection')"
test_ask   "$IRRECOVERABLE" "gh api -X=PUT"                         "$(bash_payload 'gh api -X=PUT repos/o/r/topics')"
test_ask   "$IRRECOVERABLE" "gh api --method=POST dispatches"       "$(bash_payload 'gh api --method=POST repos/o/r/dispatches')"
test_ask   "$IRRECOVERABLE" "gh api -f with no method is a POST (deploy key)" "$(bash_payload 'gh api repos/o/r/keys -f key=ssh-ed25519')"
test_ask   "$IRRECOVERABLE" "gh api -F with no method is a POST (release)" "$(bash_payload 'gh api -F tag_name=v1 repos/o/r/releases')"
test_ask   "$IRRECOVERABLE" "gh api --input body is a POST (webhook)" "$(bash_payload 'gh api repos/o/r/hooks --input body.json')"
test_ask   "$IRRECOVERABLE" "gh api graphql mutation"               "$(bash_payload "gh api graphql -f query='mutation { deleteBranchProtectionRule(input: {}) { clientMutationId } }'")"
test_ask   "$IRRECOVERABLE" "gh api graphql query read from a file (unseen)" "$(bash_payload 'gh api graphql -F query=@q.graphql')"
test_ask   "$IRRECOVERABLE" "gh api last -X wins: GET then DELETE"  "$(bash_payload 'gh api -X GET -X DELETE repos/o/r')"
test_ask   "$IRRECOVERABLE" "gh api method from a variable (unseen)" "$(bash_payload 'gh api -X "$M" repos/o/r')"
test_ask   "$IRRECOVERABLE" "rtk proxy gh api -X DELETE"            "$(bash_payload 'rtk proxy gh api -X DELETE repos/o/r/git/refs/heads/x')"
test_ask   "$IRRECOVERABLE" "gh <alias or extension> could wrap gh api" "$(bash_payload 'gh nuke repos/o/r')"
test_ask   "$IRRECOVERABLE" "xargs gh api -X DELETE (xargs supplies the endpoint)" "$(bash_payload 'echo repos/o/r | xargs gh api -X DELETE')"
test_ask   "$IRRECOVERABLE" "xargs -n 1 gh pr merge (xargs value flag before gh)" "$(bash_payload 'echo 5 | xargs -n 1 gh pr merge')"
test_ask   "$IRRECOVERABLE" "gh api graphql query from \$(...) (unseen)" "$(bash_payload 'gh api graphql -f query="$(cat q.graphql)"')"
test_ask   "$IRRECOVERABLE" "gh api graphql query from a variable (unseen)" "$(bash_payload 'gh api graphql -f query="$Q"')"
test_ask   "$IRRECOVERABLE" "gh api X-HTTP-Method-Override header" "$(bash_payload "gh api -H 'X-HTTP-Method-Override: DELETE' repos/o/r")"
test_allow "$IRRECOVERABLE" "xargs grep gh src (gh is a pattern, not the command)" "$(bash_payload 'echo a | xargs grep -l gh src')"
test_allow "$IRRECOVERABLE" "gh api graphql shorthand read query" "$(bash_payload "gh api graphql -f query='{ viewer { login } }'")"

echo ""
echo "=== gh built-in write ask (2026-10-23: T3/T4 writes gh runs without gh api) ==="
test_ask   "$IRRECOVERABLE" "gh repo delete"                       "$(bash_payload 'gh repo delete o/r --yes')"
test_ask   "$IRRECOVERABLE" "gh repo edit --visibility"            "$(bash_payload 'gh repo edit o/r --visibility public --accept-visibility-change-consequences')"
test_ask   "$IRRECOVERABLE" "gh repo archive"                      "$(bash_payload 'gh repo archive o/r -y')"
test_ask   "$IRRECOVERABLE" "gh repo deploy-key add"               "$(bash_payload 'gh repo deploy-key add key.pub -w')"
test_ask   "$IRRECOVERABLE" "gh secret set with -R before the verb" "$(bash_payload 'gh secret -R o/r set TOKEN --body x')"
test_ask   "$IRRECOVERABLE" "gh variable delete"                   "$(bash_payload 'gh variable delete FOO')"
test_ask   "$IRRECOVERABLE" "gh release delete"                    "$(bash_payload 'gh release delete v1.0 -y')"
test_ask   "$IRRECOVERABLE" "gh ssh-key add"                       "$(bash_payload 'gh ssh-key add k.pub')"
test_ask   "$IRRECOVERABLE" "gh extension install (third-party code)" "$(bash_payload 'gh extension install someone/gh-x')"
test_ask   "$IRRECOVERABLE" "gh alias set (a hidden gh api)"       "$(bash_payload "gh alias set nuke 'api -X DELETE repos/o/r'")"
test_ask   "$IRRECOVERABLE" "gh workflow run"                      "$(bash_payload 'gh workflow run deploy.yml')"
test_ask   "$IRRECOVERABLE" "gh issue delete"                      "$(bash_payload 'gh issue delete 5 --yes')"
test_ask   "$IRRECOVERABLE" "xargs gh secret delete"               "$(bash_payload 'echo X | xargs gh secret delete')"
test_ask   "$IRRECOVERABLE" "gh secret -e <env> before the verb (cobra takes the env as the flag's value)" "$(bash_payload 'gh secret -e prod set FOO --body x')"
test_ask   "$IRRECOVERABLE" "gh variable --env <env> before the verb" "$(bash_payload 'gh variable --env prod set FOO --body x')"
test_ask   "$IRRECOVERABLE" "gh secret --env=<env> before the verb" "$(bash_payload 'gh secret --env=prod delete FOO')"
test_ask   "$IRRECOVERABLE" "gh repo deploy-key with -R between the words" "$(bash_payload 'gh repo deploy-key -R o/r add key.pub')"
test_ask   "$IRRECOVERABLE" "BSD xargs -J % gh api (value flag before gh)" "$(bash_payload 'echo r | xargs -J % gh api -X DELETE repos/o/%')"
test_ask   "$IRRECOVERABLE" "GNU xargs --max-args 1 gh pr merge"   "$(bash_payload 'echo 5 | xargs --max-args 1 gh pr merge')"
test_ask   "$IRRECOVERABLE" "gh -X DELETE api (flag before the group)" "$(bash_payload 'gh -X DELETE api repos/o/r')"
test_ask   "$IRRECOVERABLE" "gh extension exec runs extension code" "$(bash_payload 'gh extension exec label')"
test_ask   "$IRRECOVERABLE" "gh release upload --clobber deletes the old asset" "$(bash_payload 'gh release upload v1.0 a.zip --clobber')"
test_ask   "$IRRECOVERABLE" "gh repo sync --force hard-resets the branch" "$(bash_payload 'gh repo sync o/r --force')"
test_ask   "$IRRECOVERABLE" "BSD xargs bundled -tJ % gh api"       "$(bash_payload 'echo r | xargs -tJ % gh api -X DELETE repos/o/%')"
test_ask   "$IRRECOVERABLE" "gh -R o/r <alias> (gh expands an alias after a flag)" "$(bash_payload 'gh -R o/r nuke')"
test_ask   "$IRRECOVERABLE" "gh --repo=o/r <alias>"                "$(bash_payload 'gh --repo=o/r nuke')"
test_ask   "$IRRECOVERABLE" "gh variable remove (cobra alias of delete)" "$(bash_payload 'gh variable remove FOO')"
test_ask   "$IRRECOVERABLE" "gh \$(...) as the group (built at run time)" "$(bash_payload 'gh $(echo secret) set FOO')"
test_ask   "$IRRECOVERABLE" "gh secret \$(...) as the verb"         "$(bash_payload 'gh secret $(echo set) FOO')"
test_ask   "$IRRECOVERABLE" "gh -c x cs delete (codespace alias after a flag)" "$(bash_payload 'gh -c x cs delete')"
test_ask   "$IRRECOVERABLE" "gh --pin v1 ext install (extension alias after a flag)" "$(bash_payload 'gh --pin v1 ext install o/gh-x')"
test_ask   "$IRRECOVERABLE" "gh - secret set (cobra drops a bare dash)" "$(bash_payload 'gh - secret set FOO')"
test_allow "$IRRECOVERABLE" "gh cs list (alias group, read)"       "$(bash_payload 'gh cs list')"
test_allow "$IRRECOVERABLE" "gh pr view \$(...) (a run-time argument, not a verb)" "$(bash_payload 'gh pr view $(git branch --show-current)')"
test_allow "$IRRECOVERABLE" "gh -R o/r pr view (a built-in after a flag)" "$(bash_payload 'gh -R o/r pr view 5')"
test_allow "$IRRECOVERABLE" "gh release upload without --clobber (T2)" "$(bash_payload 'gh release upload v1.0 a.zip')"
test_allow "$IRRECOVERABLE" "gh repo sync without --force (fast-forward)" "$(bash_payload 'gh repo sync o/r')"
test_allow "$IRRECOVERABLE" "gh api graphql read with a field aliased mutation" "$(bash_payload "gh api graphql -f query='query { viewer { mutation: login } }'")"
# 2026-10-23 deep-audit LOW over-asks: help only prints, a false bool flag is off, words after -- are not
# flags, and a GraphQL comment is ignored before an alias colon.
test_allow "$IRRECOVERABLE" "gh --help repo delete (prints help)"   "$(bash_payload 'gh --help repo delete')"
test_allow "$IRRECOVERABLE" "gh repo delete o/r --help (prints help)" "$(bash_payload 'gh repo delete o/r --help')"
test_allow "$IRRECOVERABLE" "gh secret set -h (prints help)"        "$(bash_payload 'gh secret set -h')"
test_allow "$IRRECOVERABLE" "gh release upload --clobber=false"     "$(bash_payload 'gh release upload v1 a.zip --clobber=false')"
test_allow "$IRRECOVERABLE" "gh repo sync --force=0"                "$(bash_payload 'gh repo sync o/r --force=0')"
test_allow "$IRRECOVERABLE" "gh release upload -- --clobber (a file named --clobber)" "$(bash_payload 'gh release upload v1 a.zip -- --clobber')"
test_allow "$IRRECOVERABLE" "gh api graphql read, comment before the alias colon" "$(bash_payload "gh api graphql -f query='query { viewer { mutation # c
: login } }'")"
test_allow "$IRRECOVERABLE" "gh api graphql read starting with a comment line" "$(bash_payload "gh api graphql -f query='# who am I
query { viewer { login } }'")"
test_ask   "$IRRECOVERABLE" "gh api graphql comment line hiding nothing: still a mutation" "$(bash_payload "gh api graphql -f query='# query
mutation { deleteRef(input: {}) { clientMutationId } }'")"
test_ask   "$IRRECOVERABLE" "gh release upload --clobber=true"      "$(bash_payload 'gh release upload v1 a.zip --clobber=true')"
test_ask   "$IRRECOVERABLE" "gh repo delete o/r -- --help (help after -- is an argument)" "$(bash_payload 'gh repo delete o/r -- --help')"
test_ask   "$IRRECOVERABLE" "gh extension exec x --help (exec hands --help to the extension)" "$(bash_payload 'gh extension exec x --help')"
test_ask   "$IRRECOVERABLE" "gh nuke --help (an alias or extension may not treat --help as help)" "$(bash_payload 'gh nuke --help')"
test_ask   "$IRRECOVERABLE" "gh api graphql mutation after a comment line" "$(bash_payload "gh api graphql -f query='# c
mutation { deleteRef(input: {}) { clientMutationId } }'")"
test_ask_says "$IRRECOVERABLE" "ask names the write: gh secret -e prod set" "$(bash_payload 'gh secret -e prod set FOO')" "gh secret set is a T3/T4 write"
test_ask_says "$IRRECOVERABLE" "ask names the forced flag"           "$(bash_payload 'gh release upload v1 a.zip --clobber')" "gh release upload --clobber is a T3/T4 write"
test_ask_says "$IRRECOVERABLE" "ask names gh api writes"             "$(bash_payload 'gh -X DELETE api repos/o/r')" "gh api would write"
test_ask_says "$IRRECOVERABLE" "ask names an unknown subcommand"     "$(bash_payload 'gh -R o/r nuke')" "gh nuke is not a built-in"
test_allow "$IRRECOVERABLE" "gh repo view"                      "$(bash_payload 'gh repo view o/r')"
test_allow "$IRRECOVERABLE" "gh repo view of a repo named delete"  "$(bash_payload 'gh repo view o/delete')"
test_allow "$IRRECOVERABLE" "gh secret list"                       "$(bash_payload 'gh secret list -R o/r')"
test_allow "$IRRECOVERABLE" "gh release view"                      "$(bash_payload 'gh release view v1.0')"
test_allow "$IRRECOVERABLE" "gh workflow list"                     "$(bash_payload 'gh workflow list')"
test_allow "$IRRECOVERABLE" "gh issue create (T2)"                 "$(bash_payload 'gh issue create --title x --body y')"
test_allow "$IRRECOVERABLE" "gh extension list"                    "$(bash_payload 'gh extension list')"
test_allow "$IRRECOVERABLE" "gh api plain GET"                      "$(bash_payload 'gh api repos/o/r/issues --paginate -q .[].title')"
test_allow "$IRRECOVERABLE" "gh api -X GET with -f fields is a query" "$(bash_payload 'gh api -X GET search/issues -f q=bug')"
test_allow "$IRRECOVERABLE" "gh api --method head"                  "$(bash_payload 'gh api --method head repos/o/r')"
test_allow "$IRRECOVERABLE" "gh api last -X wins: DELETE then GET"  "$(bash_payload 'gh api -X DELETE -X GET repos/o/r')"
test_allow "$IRRECOVERABLE" "gh api -H value is not a method"       "$(bash_payload "gh api -H 'X-Note: -XPUT' repos/o/r")"
test_allow "$IRRECOVERABLE" "gh api graphql read query"             "$(bash_payload "gh api graphql -f query='query { viewer { login } }'")"
test_allow "$IRRECOVERABLE" "gh api issue comment (T2 allowlist)"   "$(bash_payload 'gh api repos/o/r/issues/5/comments -f body=hi')"
test_allow "$IRRECOVERABLE" "gh api PR review-comment reply (T2 allowlist)" "$(bash_payload 'gh api repos/o/r/pulls/5/comments/9/replies -f body=done')"
test_allow "$IRRECOVERABLE" "gh api issue labels (T2 allowlist)"    "$(bash_payload "gh api repos/o/r/issues/5/labels -f 'labels[]=bug'")"
test_allow "$IRRECOVERABLE" "gh issue list (built-in)"              "$(bash_payload 'gh issue list')"
test_allow "$IRRECOVERABLE" "gh --version"                          "$(bash_payload 'gh --version')"

echo ""
echo "=== task-complete-separation gate (maker≠checker: subagent cannot self-complete) ==="
# Maker self-completion is the one thing the harness forbids — a subagent (agent_type present)
# calling TaskUpdate(completed) is blocked at exit 2.
test_deny  "$TASK_COMPLETE" "subagent marks completed (maker self-grade)" \
  "$(taskupdate_payload completed mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "main session marks completed (no agent_type)" \
  "$(taskupdate_payload completed '')"
test_allow "$TASK_COMPLETE" "subagent sets in_progress (not completion)" \
  "$(taskupdate_payload in_progress mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "subagent sets pending (not completion)" \
  "$(taskupdate_payload pending mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "subagent subject/desc update (no status field)" \
  "$(taskupdate_payload '' mh:build-error-resolver)"
test_allow "$TASK_COMPLETE" "malformed stdin (fail-safe allow)" \
  '{not valid json'
# Security-review finding (2026-08-31): agent_type is also present for a top-level `claude
# --agent <name>` MAIN session (not a subagent) — keying on it over-blocks that legitimate case.
test_allow "$TASK_COMPLETE" "--agent main session (agent_type set, no agent_id) may still complete" \
  "$(taskupdate_payload completed some-agent-name '')"
# GH #155: same truthiness-vs-presence gap GH #154 fixed in subagent-spawn-guard.py --
# the gate's own stated intent is to key on PRESENCE of agent_id, not a
# non-empty/non-null value. A real payload capture (2026-09-07) never observed an
# empty/null agent_id in practice -- these are hardening tests for a theoretical gap.
test_deny "$TASK_COMPLETE" "GH #155 gap: agent_id present but an empty string still denied" \
  "$(taskupdate_payload_forced_id completed mh:build-error-resolver '')"
test_deny "$TASK_COMPLETE" "GH #155 gap: agent_id present but JSON null still denied" \
  "$(taskupdate_payload_forced_id completed mh:build-error-resolver '__NULL__')"
# JSON depth: an extra key nested past the decoder's limit raises RecursionError. The main-session
# payload would otherwise be allowed, so only the fail-closed depth branch can deny it.
test_deny_deep "$TASK_COMPLETE" "JSON depth 1e6, main-session TaskUpdate(completed): fails closed" \
  "$(taskupdate_payload completed '' | deepen 1000000)"
test_allow "$TASK_COMPLETE" "JSON depth 500, main-session TaskUpdate(completed): still parses and allows" \
  "$(taskupdate_payload completed '' | deepen 500)"
GATE_RUNNER=memerr test_deny_deep "$TASK_COMPLETE" "json.load MemoryError, main-session TaskUpdate(completed): fails closed" \
  "$(taskupdate_payload completed '')"

echo ""
echo "=== nested-spawn deny (irrecoverable.py: a subagent may not spawn a nested claude session via Bash) ==="
# Security-review finding: a subagent retains Bash access, so `claude -p` from Bash spawns a
# nested session that never routes through the Agent tool.
test_deny  "$IRRECOVERABLE" "subagent runs 'claude -p' via Bash (the nested-spawn evasion)" \
  "$(bash_agent_payload 'claude -p "do something"' fork)"
test_deny  "$IRRECOVERABLE" "subagent runs 'claude --agent X --print' via Bash" \
  "$(bash_agent_payload 'claude --agent reviewer --print "check this"' fork)"
test_deny  "$IRRECOVERABLE" "subagent hides the spawn after a semicolon" \
  "$(bash_agent_payload 'echo hi; claude -p "sneaky"' fork)"
test_allow "$IRRECOVERABLE" "subagent runs an unrelated claude invocation (no spawn flag)" \
  "$(bash_agent_payload 'claude --version' fork)"
test_allow "$IRRECOVERABLE" "subagent runs an unrelated Bash command" \
  "$(bash_agent_payload 'ls -la' fork)"
test_allow "$IRRECOVERABLE" "main session runs 'claude -p' via Bash (no agent_id — always allowed)" \
  "$(bash_agent_payload 'claude -p "do something"' '')"
test_allow "$IRRECOVERABLE" "malformed stdin on the Bash leg (fail-safe allow)" \
  '{not valid json'
# H4 (harness gap-audit, 2026-09-20): the ABOVE case allows only because it
# has no destructive token, so the bash fast-path exits before python3 ever
# runs -- it never actually reached the python-side malformed-payload deny
# branch (lines 27-31). A malformed payload that DOES carry a destructive
# substring passes the fast path, then must fail closed once python3's
# json.load() chokes on the truncation -- the two branches must not be
# conflated (one's a pre-python allow, the other's a post-python deny).
test_deny "$IRRECOVERABLE" "truncated JSON carrying a destructive substring reaches python and fails closed (H4, was untested)" \
  '{"tool_input": {"command": "rm -rf /"'

# C1 (harness gap-audit, 2026-09-20): _nested_spawn's outer loop over every
# anchor match times an unbounded inner token scan is O(anchors x
# remaining-length) -- live-reproduced before the fix: 6,000 "claude ("
# anchors in a 48,000-char command (well under _CMD_LEN_CAP's 150,000) took
# 22s, far past this gate's own 8s hooks.json PreToolUse timeout, and Claude
# Code's own hooks reference confirms a timed-out PreToolUse command hook
# lets the tool call continue -- so a slow enough payload silently bypassed
# this whole check. `timeout 5` wraps the assertion itself: a regression
# back to the unbounded scan would make this whole test time out (rc 124),
# not just fail the deny assertion.
dos_payload="$(python3 -c 'print("claude (" * 6000)')"
dos_rc=$(echo "$(bash_agent_payload "$dos_payload" fork)" | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$dos_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): 6,000-anchor nested-spawn scan denies well under the 8s PreToolUse timeout, not a silent bypass"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $dos_rc (124 = timed out, budget regressed): 6,000-anchor nested-spawn scan" >&2
  fail=$((fail + 1))
fi

# C1b (harness gap-audit, 2026-09-20): both _nested_spawn call sites (line
# ~302 top-level command, line ~621 bash -c/eval unwrapped body) gate on
# `"agent_id" in d` -- presence, not truthiness. An empty-string or JSON-null
# agent_id is still a subagent call and must still deny, not fall through as
# if agent_id were absent (main session).
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but empty string still denies a top-level nested spawn" \
  "$(bash_agent_payload_forced_id 'claude -p "sneaky"' '')"
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but JSON null still denies a top-level nested spawn" \
  "$(bash_agent_payload_forced_id 'claude -p "sneaky"' '__NULL__')"
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but empty string still denies a bash -c-wrapped nested spawn" \
  "$(bash_agent_payload_forced_id 'bash -c "claude -p sneaky"' '')"
test_deny  "$IRRECOVERABLE" "C1b: agent_id present but JSON null still denies a bash -c-wrapped nested spawn" \
  "$(bash_agent_payload_forced_id 'bash -c "claude -p sneaky"' '__NULL__')"

test_deny  "$IRRECOVERABLE" "subagent spawns via command substitution" \
  "$(bash_agent_payload 'echo $(claude -p "evil")' fork)"
test_deny  "$IRRECOVERABLE" "subagent spawns with an env-var prefix before claude" \
  "$(bash_agent_payload 'CLAUDE_API_KEY=x claude -p "do something"' fork)"
# Deep-audit fresh adversarial pass, 2026-08-31: the un-anchored regex denied these three real,
# harmless commands because they merely CONTAIN the substring "claude -p" as prose/data, not as
# an invocation.
test_allow "$IRRECOVERABLE" "subagent commits a message mentioning the flag (prose, not invocation)" \
  "$(bash_agent_payload 'git commit -m "mention claude -p in docs"' fork)"
test_allow "$IRRECOVERABLE" "subagent echoes the pattern as a string, not a real invocation" \
  "$(bash_agent_payload 'echo "claude -p"' fork)"
test_allow "$IRRECOVERABLE" "subagent greps for the pattern (auditing this gate itself)" \
  "$(bash_agent_payload 'grep -r "claude -p" docs/' fork)"
# 2026-09-20 audit: _SPAWN_ANCHOR_RE required "claude" immediately after the
# separator/VAR=val chain, with no allowance for a wrapper word -- env/sudo/
# nohup/nice/time/command prefixes, chained or repeated, all bypassed it live.
test_deny  "$IRRECOVERABLE" "subagent: env-wrapped claude -p (wrapper-prefix bypass, was silently ALLOWed)" \
  "$(bash_agent_payload 'env claude -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: chained sudo env claude -p (multi-level wrapper bypass, was silently ALLOWed)" \
  "$(bash_agent_payload 'sudo env claude -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: backslash-escaped \\claude -p (was silently ALLOWed)" \
  "$(bash_agent_payload '\claude -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "subagent: env with its own -u flag and a VAR=val before claude -p (was silently ALLOWed)" \
  "$(bash_agent_payload 'env -u X FOO=bar claude -p "evil"' fork)"
# compliance-audit fix-round 2, 2026-09-20: a first fix bounded the wrapper
# chain at depth<=3 to dodge a catastrophic-backtracking shape; an
# independent verifier chained 13 wrappers and got past that cap live.
long_chain="$(python3 -c 'print("env sudo nohup nice time command " * 13 + "claude -p \"evil\"")')"
test_deny  "$IRRECOVERABLE" "subagent: 13-deep wrapper chain past the old depth<=3 bound (was silently ALLOWed)" \
  "$(bash_agent_payload "$long_chain" fork)"
test_allow "$IRRECOVERABLE" "main session: env-wrapped claude -p (no agent_id — always allowed)" \
  "$(bash_agent_payload 'env claude -p "evil"' '')"
# A flat [^|;&]* scan treated any &/;/| as end-of-invocation even inside a quoted prompt, so a
# spawn flag after a quoted separator evaded detection.
test_deny  "$IRRECOVERABLE" "spawn hidden behind an ampersand inside a quoted prompt" \
  "$(bash_agent_payload 'claude "fix A & B" -p' fork)"
test_deny  "$IRRECOVERABLE" "spawn hidden behind a semicolon inside a quoted prompt" \
  "$(bash_agent_payload 'claude "note; then" --print x' fork)"
test_deny  "$IRRECOVERABLE" "spawn hidden behind a pipe inside a single-quoted prompt" \
  "$(bash_agent_payload "claude 'use A | B' --agent x" fork)"
# Cross-segment separation must survive the quote-aware rewrite: a LATER, unrelated command's
# flag must never get credited to an earlier claude invocation that itself carries no spawn
# flag.
test_allow "$IRRECOVERABLE" "unrelated later command's flag does not leak back to claude" \
  "$(bash_agent_payload 'claude --version ; othertool -p' fork)"
# GH #152: the anchor matched "claude" as a mid-token substring (a path segment
# like /tmp/claude-501/... contains a word-bounded "claude"), and the forward
# flag scan did not stop at a newline, so an unrelated later line's flag got
# credited to that false match.
test_allow "$IRRECOVERABLE" "GH #152 exact repro: scratchpad-shaped path plus a later mkdir -p on its own line" \
  "$(bash_agent_payload $'BASE=/private/tmp/claude-501/foo\nmkdir -p "$BASE/work"' fork)"
# Newline-as-separator control, independent of the mid-token anchor fix: a real
# (flag-free) claude mention followed by an unrelated command's -p on the next
# line must not leak back either -- the same property already covered above
# for a ";" separator must also hold for "\n".
test_allow "$IRRECOVERABLE" "unrelated later LINE's flag does not leak back to claude (newline, not semicolon)" \
  "$(bash_agent_payload $'claude --version\nothertool -p' fork)"
# Dangerous-direction control: a false substring match on an earlier line must
# not blind the scan to a REAL spawn on a later line.
test_deny  "$IRRECOVERABLE" "GH #152 control: false path-substring on line 1 does not mask a real spawn on line 2" \
  "$(bash_agent_payload $'BASE=/private/tmp/claude-501/foo\nclaude -p "evil"' fork)"
# Deep-audit adversarial pass, 2026-09-07: the newline-stops-scan rule the GH #152 fix added has
# no concept of $(...) nesting depth. Real bash executes `claude $(\nprintf x\n) -p evil` as ONE
# command (the newline inside the substitution is not a top-level separator), but the scanner's
# flat token walk treated that embedded newline as scan-stopping regardless of nesting, so the
# flag scan never reached `-p` after the substitution closed.
test_deny  "$IRRECOVERABLE" "spawn flag after a command substitution containing an embedded newline must still be caught" \
  "$(bash_agent_payload $'claude $(\nprintf x\n) -p "evil"' fork)"
# code-review round on the GH #152 fix (before it shipped) caught two
# dangerous-direction regressions the fix itself would have introduced --
# both fixed, both locked in here so neither regresses again.
test_deny  "$IRRECOVERABLE" "GH #152 review catch: a shell metacharacter (not just \\s;&|)) right after claude must still anchor" \
  "$(bash_agent_payload 'claude>out.log -p "evil"' fork)"
test_deny  "$IRRECOVERABLE" "GH #152 review catch: a backslash-continued line is still one statement, spawn on the continuation line still caught" \
  "$(bash_agent_payload $'bash <<EOF\nclaude \\\\\n  -p "evil"\nEOF' fork)"
# Deep-audit 2026-09-07 paren-depth fix control (advisor-flagged gap): a
# BALANCED $(...) group between an unrelated claude mention and the real
# top-level separator must still let that separator stop the scan once the
# group closes depth back to 0 -- the same GH #152 leak-back property, now
# proven with parens in the mix rather than only newline/semicolon.
test_allow "$IRRECOVERABLE" "GH #152-class control: balanced \$(...) between claude and the real separator does not leak a later command's flag back" \
  "$(bash_agent_payload 'claude --version $(date) ; othertool -p' fork)"
# A stray unmatched ")" before the real separator must clamp at depth 0, not
# go negative -- going negative would require an unrelated later "(" to
# numerically return to 0, incorrectly swallowing everything in between
# (including a real separator) into the scan.
test_allow "$IRRECOVERABLE" "paren-depth clamp control: a stray unmatched ')' before the real separator does not swallow a later command's flag" \
  "$(bash_agent_payload 'claude --version) ; othertool -p' fork)"
# Codex-validator round on the paren-depth fix itself, deep-audit 2026-09-07:
# a backslash-escaped "(" is a literal argument character to claude, NOT a
# real subshell opener -- the depth tracker must not count it, or the real
# ";" right after gets swallowed and an unrelated later command's -p leaks
# back (reproduced live pre-fix: this exact payload was denied).
test_allow "$IRRECOVERABLE" "escaped literal paren control: a backslash-escaped '\\(' is not a real subshell opener, does not leak a later command's flag back" \
  "$(bash_agent_payload 'claude --version \( ; othertool -p' fork)"
# Same property, double backslash before a real newline: an EVEN count of
# backslashes right before a real newline is not a continuation in real bash
# (the pair is one escaped backslash, then the newline is unescaped and
# ends the statement) -- but this file deliberately still treats it as one,
# same safe-direction precedent as the single-backslash case, so a spawn on
# the "continuation" line must still be caught, not narrowed away.
test_deny "$IRRECOVERABLE" "double-backslash-before-newline control: even backslash count still treated as continuation (safe-direction precedent), spawn on the next line still caught" \
  "$(bash_agent_payload $'claude \\\\\n  -p "evil"' fork)"
# Round-2 codex-validator catch on the FIRST attempt at the escaped-paren fix
# (a fixed "backslash + one of these chars" rule with no parity check): an
# EVEN backslash count before a backtick leaves the backtick unescaped and
# LIVE in real bash (the pair is one literal backslash; the backtick opens a
# real command substitution) -- treating it as escaped/inert was a false
# ALLOW, a genuine bypass, reproduced live pre-fix (bash-stub trace showed
# claude actually receiving -p as an argument). Parity tracking (an odd-
# length run escapes the next char, an even-length run doesn't) fixes this.
test_deny "$IRRECOVERABLE" "backslash-parity control: an EVEN backslash count before a backtick leaves it live -- real command substitution still caught, not treated as escaped" \
  "$(bash_agent_payload 'claude \\`printf x; printf y` -p evil' fork)"
# Mirror case, ALLOW direction: an even backslash count before a semicolon
# also leaves the semicolon a real, live separator in real bash (same
# pairing rule) -- must still stop the scan normally, not get swallowed as
# an escaped/inert semicolon.
test_allow "$IRRECOVERABLE" "backslash-parity control: an EVEN backslash count before ';' leaves it a real separator -- later command's flag does not leak back" \
  "$(bash_agent_payload 'claude --version \\; othertool -p' fork)"

# Heredoc-body stripping regression coverage.
test_allow "$IRRECOVERABLE" "heredoc-authored commit message mentioning feat(claude): and --bg in unrelated prose lines no longer false-blocks (GH #121 exact repro)" \
  "$(bash_agent_payload $'git commit -m "$(cat <<\'EOF\'\nfeat(claude): document the nested-spawn gate heredoc fix\nunrelated later line just happens to mention --bg here\nEOF\n)"' fork)"
# Dangerous-direction control: a heredoc body that DOES feed an interpreter is executable code,
# not inert data, so a real nested `claude -p` spawn hidden inside one must still be caught.
test_deny  "$IRRECOVERABLE" "nested claude spawn hidden inside an interpreter-fed heredoc body still blocked (bash <<EOF ... claude -p ... EOF, GH #121 dangerous-direction control)" \
  "$(bash_agent_payload $'bash <<EOF\nclaude -p "evil"\nEOF' fork)"

# --- bash -c / eval one-level unwrap ---
test_deny  "$IRRECOVERABLE" "bash -c with rm -rf inside" \
  "$(bash_payload 'bash -c "rm -rf build"')"
test_deny  "$IRRECOVERABLE" "sh -c with git push --force inside" \
  "$(bash_payload "sh -c 'git push --force origin main'")"
test_deny  "$IRRECOVERABLE" "bash -lc (bundled) with rm -rf inside" \
  "$(bash_payload 'bash -lc "cd x && rm -rf y"')"
test_deny  "$IRRECOVERABLE" "eval with rm -rf inside" \
  "$(bash_payload 'eval "rm -rf build"')"
test_allow "$IRRECOVERABLE" "bash -c with a harmless body" \
  "$(bash_payload 'bash -c "ls -la && git status"')"
test_allow "$IRRECOVERABLE" "bash -c body mentioning rm -rf as data" \
  "$(bash_payload 'bash -c "echo rm -rf is dangerous"')"
# deep-audit 2026-09-06: the unwrap ran before the prefix-wrapper unwrap, never
# blanked a single-quoted body, and the nested-spawn deny never saw inside it.
test_deny  "$IRRECOVERABLE" "sudo bash -c with rm -rf inside (wrapper before shell)" \
  "$(bash_payload "sudo bash -c 'rm -rf x'")"
test_deny  "$IRRECOVERABLE" "env bash -c with git reset --hard inside" \
  "$(bash_payload "env bash -c 'git reset --hard'")"
test_deny  "$IRRECOVERABLE" "bash -c single-quoted body with a spliced argv0" \
  "$(bash_payload "bash -c 'gi\$(true)t push --force origin main'")"
test_deny  "$IRRECOVERABLE" "bash -c single-quoted body hiding the deny inside a substitution" \
  "$(bash_payload "bash -c 'echo \$(git push --force origin main)'")"
test_deny  "$IRRECOVERABLE" "bash -c single-quoted body with a bare-PH slot shift (stash \$(true) drop)" \
  "$(bash_payload "bash -c 'git stash \$(true) drop'")"
test_deny  "$IRRECOVERABLE" "subagent: bash -c hiding a nested claude -p spawn" \
  "$(bash_agent_payload "bash -c 'claude -p hi'" fork)"
test_deny  "$IRRECOVERABLE" "subagent: eval hiding a nested claude --bg spawn" \
  "$(bash_agent_payload "eval 'claude --bg'" fork)"
test_allow "$IRRECOVERABLE" "main session: bash -c claude -p (no agent_id, not a nested spawn)" \
  "$(bash_payload "bash -c 'claude -p hi'")"
test_allow "$IRRECOVERABLE" "sudo bash -c with a harmless body" \
  "$(bash_payload "sudo bash -c 'ls -la'")"
# GH #560: env -S / --split-string runs its string as the command, like a sh -c body; -C takes a value.
test_deny  "$IRRECOVERABLE" "GH #560: env -S hiding rm -rf" "$(bash_payload "env -S 'rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #560: env --split-string= hiding push --force" \
  "$(bash_payload "env --split-string='git push --force'")"
test_deny  "$IRRECOVERABLE" "GH #560: env -S with the flag after the string" "$(bash_payload "env -S 'git push' --force")"
test_deny  "$IRRECOVERABLE" "GH #560: env -C DIR before rm -rf" "$(bash_payload 'env -C /tmp rm -rf build')"
test_deny  "$IRRECOVERABLE" "GH #560: subagent: env -S hiding claude -p" "$(bash_agent_payload "env -S 'claude -p hi'" fork)"
test_allow "$IRRECOVERABLE" "GH #560 control: env -S with a harmless string" "$(bash_payload "env -S 'ls -la'")"
test_allow "$IRRECOVERABLE" "GH #560 control: env -C DIR ls" "$(bash_payload 'env -C /tmp ls')"
# GH #560 review: getopt reads -S bundled after env's other short flags (`-iS`, `-vS`), and a value
# letter inside a cluster (`-iu FOO`, `-iC /tmp`) takes the next word.
test_deny  "$IRRECOVERABLE" "GH #560: env -iS hiding rm -rf" "$(bash_payload "env -iS 'rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #560: env -vS hiding rm -rf" "$(bash_payload "env -vS 'rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #560: env -i0vS'...' attached hiding rm -rf" "$(bash_payload "env -i0vS'rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #560: env -iu FOO -S hiding rm -rf" "$(bash_payload "env -iu FOO -S 'rm -rf x'")"
test_deny  "$IRRECOVERABLE" "GH #560: env -iC DIR before rm -rf" "$(bash_payload 'env -iC /tmp rm -rf build')"
test_deny  "$IRRECOVERABLE" "GH #560: env --split-string BODY (space) hiding rm -rf" \
  "$(bash_payload "env --split-string 'rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #560: env --split= (abbreviated long option) hiding rm -rf" \
  "$(bash_payload "env --split='rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #560: subagent: env -iS hiding claude -p" "$(bash_agent_payload "env -iS 'claude -p hi'" fork)"
test_allow "$IRRECOVERABLE" "GH #560 control: env -iS with a harmless string" "$(bash_payload "env -iS 'ls -la'")"
test_allow "$IRRECOVERABLE" "GH #560 control: env -i ls" "$(bash_payload 'env -i ls')"
test_allow "$IRRECOVERABLE" "GH #560 control: env -0 (print the environment)" "$(bash_payload 'env -0')"
test_allow "$IRRECOVERABLE" "GH #560 control: env -iu FOO ls" "$(bash_payload 'env -iu FOO ls -la')"
test_deny  "$IRRECOVERABLE" "GH #560: a chain of 50 env -iS words before rm -rf" \
  "$(bash_payload "$(printf 'env -iS %.0s' $(seq 50))rm -rf x")"
# GH #560 regression (after #570): GNU env keeps reading its own options from the split words
# (`env -S -i echo hi` runs echo), so a body that starts with an option is not the command.
for _c in "env -S -i rm -rf build" "env -S -v git push --force" "env -S -u FOO rm -rf x" \
  "env -S -0 git clean -fdx" "env --split-string -i rm -rf x" "env -S -i git reset --hard" \
  "env -S '-i rm -rf build'" "env -S '-i git push --force'" "env -S -C /tmp rm -rf x" \
  "env -S '-u FOO -S \"-i rm -rf x\"'"; do
  test_deny "$IRRECOVERABLE" "GH #560: options inside the -S string: $_c" "$(bash_payload "$_c")"
done
# GH #560 round 2: env ends the -S string at a word starting with `#` and at `\c`, then reads on
# from the words after the -S argument (`env -S '-i #' echo RAN` runs echo).
for _c in "env -S '-i #' rm -rf x" "env -S '-i #' git push --force" "env -S '-u FOO #' rm -rf x" \
  "env -S '-i -S \"-i #\"' rm -rf x" "env -S '-i \\c' rm -rf x" "env -S '-i #comment -v' rm -rf x"; do
  test_deny "$IRRECOVERABLE" "GH #560: -S string ended by # or \\c: $_c" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "GH #560 control: env -S '-i #' ls" "$(bash_payload "env -S '-i #' ls -la")"
test_allow "$IRRECOVERABLE" "GH #560 control: env -S '-i a#b' (mid-word # is no comment)" "$(bash_payload "env -S '-i ls a#b'")"
# GH #560 round 3: env's -S splitting has more corners than the gate models (quoted or escaped `#`,
# `\_`, a quote inside a comment, an empty nested -S, `--unset NAME`), so a command with -S is also
# read the way the gate read it before #570, and either reading denies. One row-set per class.
_r3_cmds=(
  "env -S '-u \"#\"' rm -rf x" "env -S '-u \\#' git push --force" "env -S \"-u '#x'\" rm -rf x"
  "env -S '-i # don'\\''t' rm -rf x" "env -S '-i # it'\\''s' git push --force"
  "env -S '-i \\_ -v' git reset --hard" "env -S '-v \\_' rm -rf x"
  "env -S '-S#' rm -rf x" "env -S '-S\\_' rm -rf x" "env -S '-S #c' git clean -fdx"
  "env -S '--unset FOO' rm -rf x" "env -S '--unset FOO' git push --force"
)
for _c in "${_r3_cmds[@]}"; do
  test_deny "$IRRECOVERABLE" "GH #560: -S corner, both readings checked: $_c" "$(bash_payload "$_c")"
done
for _c in "env -i FOO=1 ls" "env -S -i ls -la" "env -S '-i #' ls -la" "env -C /tmp make" "env -S 'ls -la'" \
  "env -iS 'ls -la'" "env -S '-u \"#\"' ls"; do
  test_allow "$IRRECOVERABLE" "GH #560 round 3 control: $_c" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" "GH #560: subagent: env -S '-i claude -p hi'" "$(bash_agent_payload "env -S '-i claude -p hi'" fork)"
test_deny  "$IRRECOVERABLE" "GH #560: rm read through two -S levels, under the nesting limit" \
  "$(bash_payload "env -iS env -iS rm -rf x")"
for _c in "env -i FOO=1 ls" "env -C /tmp make" "env -S 'ls -la'" "env -u HOME -S 'echo hi'" "env -S '-u FOO echo C'" \
  "env -S -i ls -la"; do
  test_allow "$IRRECOVERABLE" "GH #560 control: $_c" "$(bash_payload "$_c")"
done
_env_S_dos_cmd="$(python3 -c 'print("env " + "-S -S " * 11000 + " ".join(["-S\x27-i -S\x27"] * 8000) + " ls")')"
_timed_case 'GH #560: 22000 -S words and 8000 option-only -S strings are read in bounded time' 2 "$_env_S_dos_cmd"
_env_iS_dos_cmd="$(python3 -c 'print("env -iS ls; " * 10000 + "env -" + "i" * 20000 + "S ls")')"
_timed_case 'GH #560: 10000 env -iS commands and a 20 KB cluster are read in bounded time' 0 "$_env_iS_dos_cmd"
# GH #621: --chdir and --unset (and getopt_long's unambiguous prefixes) take the next word; a -S string
# is split the way GNU env splits it (`\_` ends a word, a word starting with `#` ends the string) and its
# words, options first or not, go back into env's option loop.
for _c in "env --chdir /tmp rm -rf x" "env --ch /tmp rm -rf x" "env --chd /tmp rm -rf x" \
  "env --chdir /tmp git push --force" "env --unset FOO rm -rf x" "env --un FOO rm -rf x" "env --uns FOO rm -rf x" \
  "env -S '--unset FOO rm -rf x'" "env -S 'rm\\_-rf\\_x'" "env -S 'git\\_push\\_--force'" \
  "env -S '\"-i\" rm -rf x'" "env -S \"'-i' rm -rf x\"" "env -S '#x' rm -rf x" "env -S '#x' git push --force" \
  "env -S '\\_-i rm -rf x'" "env -S '\\_#x' rm -rf x" "env -iS '\\_\\_-i\\_rm -rf x'"; do
  test_deny "$IRRECOVERABLE" "GH #621: env long option value / GNU -S split: $_c" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" "GH #621: subagent: env -S 'claude\\_-p\\_hi'" "$(bash_agent_payload "env -S 'claude\\_-p\\_hi'" fork)"
test_deny  "$IRRECOVERABLE" "GH #621: subagent: env -S '#x' claude -p hi" "$(bash_agent_payload "env -S '#x' claude -p hi" fork)"
test_deny  "$IRRECOVERABLE" "GH #621: subagent: env --ch /tmp claude -p hi" "$(bash_agent_payload 'env --ch /tmp claude -p hi' fork)"
for _c in "env -i FOO=1 ls" "env --chdir /tmp make" "env --ch /tmp make" "env --unset HOME ls" "env -S 'ls -la'" \
  "env -S '-i #' ls -la" "env -S 'echo\\_hi'" "env -S '#x' ls -la" "env -S '\"-i\" ls'"; do
  test_allow "$IRRECOVERABLE" "GH #621 control: $_c" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "GH #621 control: subagent: env -S 'claude\\_--version'" "$(bash_agent_payload "env -S 'claude\\_--version'" fork)"
# GH #567: a shell reading stdin gets its commands from a heredoc piped in, a here-string, or an echo/printf.
test_deny  "$IRRECOVERABLE" "GH #567: bash <<< rm -rf" "$(bash_payload "bash <<< 'rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #567: echo into bash" "$(bash_payload "echo 'git push --force' | bash")"
test_deny  "$IRRECOVERABLE" "GH #567: printf into bash -s" "$(bash_payload "printf 'git reset --hard\n' | bash -s")"
test_deny  "$IRRECOVERABLE" "GH #567: heredoc piped into bash" "$(bash_payload "$(printf 'cat <<EOF | bash\nrm -rf build\nEOF')")"
test_allow "$IRRECOVERABLE" "GH #567 control: echo into tee" "$(bash_payload "echo 'rm -rf build' | tee notes.txt")"
test_allow "$IRRECOVERABLE" "GH #567 control: echo into bash script.sh (stdin is data)" "$(bash_payload 'echo hi | bash x.sh')"
test_allow "$IRRECOVERABLE" "GH #567 control: heredoc piped into grep bash" "$(bash_payload "$(printf "cat <<'EOF' | grep bash\nrm -rf build\nEOF")")"
# Non-goal: eval "$(cat <<EOF)" and fish <<EOF. A << lookalike the shell does not read as a heredoc: GH #668.
# GH #668: a << the shell does not read as a redirection (quoted, commented, escaped, in an arithmetic
# or parameter frame, an array) or a delimiter read wrongly no longer hides the lines after it.
for _c in $'echo "<<EOF"\nrm -rf build\nEOF' $'echo \'<<EOF\'\nrm -rf build\nEOF' \
  $'echo "a\n<<EOF"\nrm -rf build\nEOF' $'echo x # <<EOF\nrm -rf build\nEOF' $'echo \\<<EOF\nrm -rf build\nEOF' \
  $'echo $(( 1 << X ))\nrm -rf build\nX' $'echo ${x:-<< X }\nrm -rf build\nX' $'echo "${x:-"<<X"}"\nrm -rf build\nX' \
  $'a=( << X )\nrm -rf build\nX' $'cat <<\\EOF\nx\nEOF\nrm -rf build\n\\EOF' $'cat <<EOF;\nx\nEOF\nrm -rf build\nEOF;' \
  $'cat <<EOF\r\nx\nEOF\r\nrm -rf build\nEOF' $'cat <<EOF "a\n"; rm -rf build #\nEOF\n#"' \
  $'cat <<EOF \\\n; rm -rf build\nEOF\necho ok' $'cat <<EOF\n$(rm -rf build)\nEOF' $'cat <<EOF\nEO\\\nF\nrm -rf build\nEOF' \
  $'bash <<\'EOF\'\ncat <<X\nEOF\nrm -rf build\nX' $'echo "$(case a in a) echo "<<X";; esac)"\nrm -rf build\nX' \
  $'echo "$(cat <<X)"\nrm -rf build\nX' $'echo $(case a in a) echo;; esac); psql db <<\'SQL\'\nDROP TABLE t;\nSQL'; do
  _l=${_c//$'\r'/\\r}; test_deny "$IRRECOVERABLE" "GH #668: ${_l//$'\n'/ | }" "$(bash_payload "$_c")"
done
# Real heredocs whose body only mentions a destructive verb stay data.
for _c in $'cat <<\'EOF\'\nit\'s\nEOF\necho "<<X"\nls\nX' $'echo "$(cat <<\'EOF\'\ndon\'t\nEOF\n)"\necho "<<X"\nls\nX' \
  $'echo ${x}; cat <<\'EOF\'\nrm -rf build\nEOF' $'echo $((1)); cat <<\'EOF\'\nrm -rf build\nEOF' \
  $'git commit -m "$(cat <<\'EOF\'\nfix: don\'t rm -rf build\nEOF\n)"' $'git commit -F- <<\'EOF\'\nfix: no rm -rf build\nEOF' \
  $'gh pr create --title t --body "$(cat <<\'EOF\'\nWe don\'t run rm -rf build or git push --force.\nEOF\n)"' \
  $'cat > notes.md <<\'EOF\'\nnever rm -rf build\nEOF'; do
  test_allow "$IRRECOVERABLE" "GH #668 control: $(printf '%s' "$_c" | head -1)" "$(bash_payload "$_c")"
done
# GH #668 round 2: inside $( bash ends a heredoc at a line that starts with the delimiter (EOF), EOF ),
# EOF); ...) and runs the next line, where the gate waited for an exact EOF line.
for _c in $'out=$(cat <<EOF\nmsg\nEOF)\nrm -rf build\nEOF' $'out=$(cat <<EOF\nmsg\nEOF )\nrm -rf build\nEOF' \
  $'out=$(cat <<EOF\nmsg\nEOF);\nrm -rf build\nEOF' $'out=$(cat <<EOF\nmsg\nEOF) && :\nrm -rf build\nEOF' \
  $'out=$(cat <<\'EOF\'\nmsg\nEOF)\nrm -rf build\nEOF' $'out=$(cat <<-EOF\nmsg\n\tEOF)\nrm -rf build\nEOF' \
  $'bash <<\'EOF\'\npsql db <<SQL\nDROP TABLE t;\nSQL\nEOF'; do
  test_deny "$IRRECOVERABLE" "GH #668 round 2: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
# An interpreter-fed body is skipped like any body (kept as code), so a later quoted body stays data; and
# a plain ${NAME}, an escaped backtick or an escaped \$( in an unquoted body does not expand.
for _c in $'python3 - <<\'EOF\'\nprint("x")\nEOF\ncat > notes.md <<\'EOF\'\nWe don\'t run rm -rf build {ever}.\nEOF' \
  $'cat > notes.md <<EOF\nrm -rf build ran at ${TS}\nEOF' $'cat > notes.md <<EOF\nrm -rf build, not \\`ls\\`\nEOF' \
  $'cat > notes.md <<EOF\nrm -rf build, not \\$(date)\nEOF'; do
  test_allow "$IRRECOVERABLE" "GH #668 round 2 control: $(printf '%s' "$_c" | head -2 | tail -1)" "$(bash_payload "$_c")"
done
# GH #668 round 3: a data body the gate keeps as text once unsure is read by the tokenizer as shell text,
# but bash reads it as data, so an odd quote in it paired with a quote past the delimiter and hid the line.
# The last one is balanced for _quote_mask (a backtick opens a frame in "..") but not for the tokenizer.
# Out of scope: the same desync in an interpreter-fed (code) body, GH #681.
for _c in $'cat <<EOF\n$(echo) it\'s\nEOF\nrm -rf build\necho \'' $'cat <<EOF\n`echo` it\'s\nEOF\nrm -rf build\necho \'' \
  $'cat <<EOF\n$(echo) "\nEOF\nrm -rf build\necho "' $'cat <<EOF\nline \\\nit\'s\nEOF\nrm -rf build\necho \'' \
  $'cat > f <<EOF\nx="` echo \' " \' `"\nEOF\nrm -rf build\necho \'' \
  $'cat <(cat <<EOF\nin\nEOF) ; git push --force origin main\nEOF' $'cat >(cat <<EOF\nout\nEOF) ; git push --force origin main\nEOF' \
  $'x=${ cat <<EOF\nfunsub\nEOF }\ngit push --force origin main\nEOF\n}'; do
  test_deny "$IRRECOVERABLE" "GH #668 round 3: $(printf '%s' "$_c" | head -2 | tail -1)" "$(bash_payload "$_c")"
done
# Only inside $( or backticks does bash end a body at a line that starts with the delimiter (EOF)). Each
# control ends in a $ so it reaches python past the wrapper's fast path.
for _c in $'python3 - <<\'EOF\'\nprint("it\'s")\n# don\'t\nEOF' $'python3 - <<\'EOF\'\ns = """a "b" it\'s"""\nprint(s)\nEOF' \
  $'cat > f.sh <<EOF\necho "built at $(date)" \'ok\'\nEOF' $'bash <<\'EOF\'\necho "a"; echo \'b\'\nEOF' \
  $'python3 - <<\'E\'\nError = ValueError("it\'s")\nprint(Error)\nE' $'cat > f <<EOF\nv="$(echo \'x\')"\nEOF' \
  $'python3 - <<\'EOF\'\ns = """\nEOF marker\n"""\nprint("it\'s")\nEOF' $'cat > notes.md <<\'E\'\nExceptions aren\'t rare\nE' \
  $'python3 - <<\'E\'\nx = 1\nExc = 2\nprint(x)\nE\ncat > n.md <<\'X\'\nit\'s\nX' \
  $'diff <(cat <<\'EOF\'\nwe never rm -rf build\nEOF\n) f'; do
  test_allow "$IRRECOVERABLE" "GH #668 round 3 control: $(printf '%s' "$_c" | head -2 | tail -1)" "$(bash_payload "$_c"$'\necho "$PWD"')"
done
# GH #681 (python/node shape): a quoted heredoc a python/node stage reads as its script (operand `-` or none, or
# piped from cat) is scanned like a -c body and stripped as data, so its quotes never pair past the delimiter.
for _c in $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run([\'git\',\'push\',\'--force\'])\nEOF' \
  $'python3 <<\'EOF\'\nimport subprocess\nsubprocess.run([\'git\',\'push\',\'--force\'])\nEOF' \
  $'cat <<\'EOF\' | python3 -\nimport subprocess\nsubprocess.run([\'git\',\'push\',\'--force\'])\nEOF' \
  $'node - <<\'EOF\'\nrequire(\'child_process\').execSync(\'git push --force\')\nEOF' \
  $'cat <<\'EOF\' | node -\nrequire(\'child_process\').execSync(\'git push --force\')\nEOF' \
  $'python3 - <<\'EOF\'\nprint("it\'s")\nx = \'\nEOF\nrm -rf build\n#\'' \
  $'python3 -c \'import os,sys;os.system(sys.stdin.read())\' <<\'EOF\'\nrm -rf x\nEOF' \
  $'node -e "require(\'child_process\').execSync(require(\'fs\').readFileSync(0,\'utf8\'))" <<\'EOF\'\nrm -rf x\nEOF' \
  $'python3 run.py <<\'EOF\'\nrm -rf x\nEOF' $'python3 -V; bash <<\'EOF\'\nrm -rf x\nEOF' \
  $'python3 <<EOF\n$(rm -rf x)\nEOF' $'bash -s <<\'EOF\'\nrm -rf x\nEOF' $'bash <<\'EOF\'\ngit push --force\nEOF' \
  $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run([\'git\', \'push\', \'--force\', \'-m\', "it\'s"])\nEOF' \
  $'python3 - <<\'EOF\'\nfrom os import system\nsystem("git push --force")\nEOF' \
  $'node - <<\'EOF\'\nconst { spawnSync } = require("node:child_process")\nspawnSync("git", ["push", "--force"])\nEOF'; do
  test_deny "$IRRECOVERABLE" "GH #681 python/node heredoc: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
for _c in $'python3 - <<\'EOF\'\nx=\'\'\'it\'s\'\'\'\nprint(x)\nEOF' $'python3 <<\'EOF\'\n# don\'t\nprint("rm -rf build")\nEOF' \
  $'node - <<\'EOF\'\nconsole.log("it\'s")\nEOF' $'cat <<\'EOF\' | python3 -\nprint("it\'s")\nEOF' \
  $'python3 - <<\'EOF\'\nprint("never git push --force")\nEOF' \
  $'python3 - <<\'EOF\'\nimport subprocess\nprint("Don\'t use it", \'"\')\nsubprocess.run([\'ls\'])\nEOF' \
  $'python3 - <<\'EOF\'\nopen("x.md", "w").write("run `git restore f` to undo")\nEOF' \
  $'python3 - <<\'EOF\'\nopen("x.md", "w").write("a subagent may spawn work; git push --force is denied")\nEOF'; do
  test_allow "$IRRECOVERABLE" "GH #681 control: ${_c//$'\n'/ | }" "$(bash_payload "$_c"$'\ngit status')"
done
# trash of a whole tree (/, ~, ., *, an empty word, $HOME, $PWD) denies; any other operand, a variable too, is allowed.
for _c in 'trash ~' 'trash ""' 'trash .' 'trash *' 'trash /' 'trash ~/' 'trash ./' 'trash ..' 'trash ../..' \
  'trash $HOME' 'trash ${HOME}' 'trash "$HOME"' 'trash $PWD' 'trash $(pwd)' "trash $HOME" "trash $HOME/" \
  'trash-put /' 'gio trash ~' 'sudo trash ~/' 'trash -v .' 'trash build/x .' \
  'trash ~/*' 'trash /*' 'trash "$PWD/"' 'trash $HOME/' 'trash "$HOME"/*' 'trash ~/.' 'trash ../' 'trash .*' \
  'trash "$HOME/"' 'trash $HOME/*' 'trash $(pwd)/' 'trash "$(pwd)"/'; do
  test_deny "$IRRECOVERABLE" "trash whole tree: $_c" "$(bash_payload "$_c")"
done
for _c in 'trash "$X"' 'trash "${X:?}"' 'trash $TMPDIR/x' 'trash build/out.txt' 'trash ./build' 'trash "$HOME/tmp/x"' \
  'trash $(pwd)/build' 'echo trash ~' 'gio info ~' 'trash' 'trash ~/foo' 'trash .gitignore' 'trash "$(pwd)/build"'; do
  test_allow "$IRRECOVERABLE" "trash control: $_c" "$(bash_payload "$_c")"
done
_huge_cmd="$(python3 -c 'print("cat <<EOF\n" + "x" * 2100000 + "\nEOF")')"
_timed_case 'GH #668: a 2.1 MB command denies on length before the heredoc scan' 2 "$_huge_cmd"
# GH #668 round 4: shapes the scan does not model turn it unsure, so nothing more is stripped: a \ in the
# delimiter inside backticks (bash unescapes \\ first), a $(( frame still open at the line end, an opener
# in an array subscript (a left shift), a delimiter with a $ (quotes removed, never expanded), unfound.
_n4=0
for _c in $'x=`cat <<E\\\\OF\nmsg\nEOF\nrm -rf build\nE\\OF\n`' $'x=`cat <<E\\\\OF\nmsg\nEOF\ngit push --force origin main\nE\\OF\n`' \
  $'x=$((cat <<EOF\nmsg\nEOF\n) )\ncat <<\'X\'\nit\'s\nX\nrm -rf build\necho \'' \
  $'a[1<<2]=3\nrm -rf build\n2]=3' $'a[1<<X ]=5\nrm -rf build\nX' \
  $'cat <<"$X"\nit\'s data\n$X\nrm -rf build\necho don\'t' $'cat <<"$X"\nit\'s data\nrm -rf build\necho don\'t'; do
  _n4=$((_n4 + 1)); test_deny "$IRRECOVERABLE" "GH #668 round 4 case $_n4: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
# Quadratic before: a $(( per line left a frame open and grew the stack (800k chars took 9 s, past the hook
# timeout that allows); a command over _CMD_LEN_CAP now skips the scan. The second guards the depth latch.
_quad_cmd="$(python3 -c 'print("x=$((cat <<EOF\nit'"'"'s\nEOF\n) )\n" * 28571 + "rm -rf build")')"
_timed_case 'GH #668 round 4: 800 KB of $(( heredoc lines denies in bounded time' 2 "$_quad_cmd"
_deep_cmd="$(python3 -c 'print("\"$(\n" * 37000)')"
_timed_case 'GH #668 round 4: 37000 nested "$( lines (148 KB) deny in bounded time' 2 "$_deep_cmd"
# GH #685: a $(...) on line 1 then a line that opens a quote after <<EOF was allowed; bash runs line 1, then
# fails on line 2. The controls drop the trailing ' (the verb's own deny) or the <<EOF (no tokenize).
for _v in 'rm -rf build|rm -rf detected' 'git push --force origin main|git push --force overwrites'; do
  test_deny_says "$IRRECOVERABLE" "GH #685: echo \$(${_v%|*}) | <<EOF'" "$(bash_payload "echo \$(${_v%|*})"$'\n'"<<EOF'")" \
    'heredoc the gate reads unsure has no closing delimiter'
  test_deny_says "$IRRECOVERABLE" "GH #685 control: echo \$(${_v%|*}) | <<EOF" "$(bash_payload "echo \$(${_v%|*})"$'\n<<EOF')" \
    "${_v#*|}"
  test_deny_says "$IRRECOVERABLE" "GH #685 control: echo \$(${_v%|*}) | '" "$(bash_payload "echo \$(${_v%|*})"$'\n'"'")" \
    'could not safely tokenize'
done
test_allow "$TASK_COMPLETE" "non-TaskUpdate tool with agent_type (out of scope)" \
  "$(python3 -c 'import json; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"ls"},"agent_type":"mh:build-error-resolver"}))')"

echo ""

echo "=== v1.0.0 gate edits (worktree allowed, git add -A merge carve-out, --worktree spawn, stash list) ==="
# Payload with an explicit cwd (irrecoverable.py checks MERGE_HEAD there).
bash_cwd_payload() { python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$2"; }
test_allow "$IRRECOVERABLE" "git worktree add -b x ../y is ALLOWED (single-branch worktree doctrine block removed)" \
  "$(bash_payload 'git worktree add -b x ../y')"
test_allow "$IRRECOVERABLE" "git -C . worktree add -b feature (was denied by the removed worktree block)" \
  "$(bash_payload 'git -C . worktree add -b feature /tmp/wt-feature')"
MERGE_FIX=$(mktemp -d "${TMPDIR:-/tmp}/kbg-merge-fixture.XXXXXX")
NOMERGE_FIX=$(mktemp -d "${TMPDIR:-/tmp}/kbg-nomerge-fixture.XXXXXX")
( cd "$MERGE_FIX" && git init -q -b develop . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && echo a > f && git add f && git -c user.email=t@t -c user.name=t commit -q -m a \
  && git checkout -q -b side && echo b > f && git -c user.email=t@t -c user.name=t commit -q -am b \
  && git checkout -q develop && echo c > f && git -c user.email=t@t -c user.name=t commit -q -am c \
  && git -c user.email=t@t -c user.name=t merge -q side >/dev/null 2>&1; true )
( cd "$NOMERGE_FIX" && git init -q -b develop . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
if git -C "$MERGE_FIX" rev-parse -q --verify MERGE_HEAD >/dev/null; then
  test_allow "$IRRECOVERABLE" "git add -A ALLOWED while MERGE_HEAD exists in the payload cwd (mid-merge carve-out)" \
    "$(bash_cwd_payload 'git add -A' "$MERGE_FIX")"
  test_allow "$IRRECOVERABLE" "git add . ALLOWED mid-merge" \
    "$(bash_cwd_payload 'git add .' "$MERGE_FIX")"
else
  echo "  ❌ merge fixture failed to reach a conflicted state" >&2; fail=$((fail + 1))
fi
test_deny "$IRRECOVERABLE" "git add -A DENIED in a repo with no MERGE_HEAD" \
  "$(bash_cwd_payload 'git add -A' "$NOMERGE_FIX")"
test_deny "$IRRECOVERABLE" "git add --all DENIED with no cwd in the payload (falls back to process cwd, not mid-merge)" \
  "$(bash_payload 'git add --all')"

# M7 (harness gap-audit, 2026-09-20): a bad cwd makes _mid_merge()'s own
# subprocess.run raise (FileNotFoundError), caught by its except -- the deny
# that follows must be distinguishable from a genuine "not mid-merge" deny.
mid_merge_err=$(bash_cwd_payload 'git add -A' "/nonexistent/kbg-mid-merge-probe-$$" | bash "$IRRECOVERABLE" 2>&1 1>/dev/null)
mid_merge_rc=$(bash_cwd_payload 'git add -A' "/nonexistent/kbg-mid-merge-probe-$$" | bash "$IRRECOVERABLE" >/dev/null 2>/dev/null; echo $?)
if [[ "$mid_merge_rc" == "2" ]] && /usr/bin/grep -q "mid-merge check itself failed" <<<"$mid_merge_err"; then
  echo "  ✅ DENY + diagnostic: git add -A with an unreachable cwd denies AND names that the mid-merge check itself failed"
  pass=$((pass + 1))
else
  echo "  ❌ DENY+diagnostic EXPECTED but got exit $mid_merge_rc, stderr: $mid_merge_err" >&2
  fail=$((fail + 1))
fi

tmp_delete "$MERGE_FIX" "$NOMERGE_FIX"
test_deny "$IRRECOVERABLE" "subagent: claude -p hi via Bash denied" \
  "$(bash_agent_payload 'claude -p hi' fork)"
test_deny "$IRRECOVERABLE" "subagent: claude --worktree x denied (new flag in the ported nested-spawn deny)" \
  "$(bash_agent_payload 'claude --worktree x' fork)"
test_deny "$IRRECOVERABLE" "subagent: claude --bg denied" \
  "$(bash_agent_payload 'claude --bg "run it"' fork)"
# GH #157: a backslash-escaped quote outside a quoted span is a literal
# character in real bash, never a string opener -- the tokenizer must not
# let it swallow the real ";" and credit othertool's -p back to claude.
# Bypass hunt F1: the escaped quote is a prompt word (`claude \"` starts a session with the prompt `"`),
# so the leak-back rows carry --version, which keeps them about the -p scan.
test_allow "$IRRECOVERABLE" "#157: escaped double quote before a real ; is literal, othertool's -p stays with othertool" \
  "$(bash_agent_payload 'claude --version \" ; othertool -p "x"' fork)"
test_allow "$IRRECOVERABLE" "#157: escaped single quote before a real ; is literal" \
  "$(bash_agent_payload "claude --version \\' ; othertool -p 'x'" fork)"
test_allow "$IRRECOVERABLE" "#157 control: escaped quote then claude with no flag" \
  "$(bash_agent_payload 'echo \" ; claude' fork)"
test_allow "$IRRECOVERABLE" "#157 control: claude --version with a lone escaped quote and no flag" \
  "$(bash_agent_payload 'claude --version \"' fork)"
test_deny  "$IRRECOVERABLE" "#157 / bypass hunt F1: claude with a lone escaped quote takes it as the prompt" \
  "$(bash_agent_payload 'claude \"' fork)"
test_deny  "$IRRECOVERABLE" "#157 control: real -p after a literal escaped quote still denied" \
  "$(bash_agent_payload 'claude \"x\" -p y' fork)"
test_deny  "$IRRECOVERABLE" "#157 control: real double-quoted span containing ; still swallows it, -p denied" \
  "$(bash_agent_payload 'claude "a ; b" -p y' fork)"
test_deny  "$IRRECOVERABLE" "#157 control: single-quoted escaped quote is a real span, -p denied" \
  "$(bash_agent_payload "claude '\\\"' -p y" fork)"
test_deny  "$IRRECOVERABLE" "#157 control: even backslash run before a quote leaves the quote live, ; swallowed, -p denied" \
  "$(bash_agent_payload 'claude \\"a ; b" -p y' fork)"
test_allow "$IRRECOVERABLE" "main session: claude --worktree x allowed (no agent_id)" \
  "$(bash_agent_payload 'claude --worktree x' '')"
test_allow "$SUBAGENT_GIT_GUARD" "subagent: git stash list allowed (read-only carve-out)" \
  "$(bash_agent_payload 'git stash list' fork)"
test_allow "$SUBAGENT_GIT_GUARD" "subagent: git stash show -p allowed (read-only carve-out)" \
  "$(bash_agent_payload 'git stash show -p' fork)"
test_deny "$SUBAGENT_GIT_GUARD" "subagent: git stash (bare) still denied" \
  "$(bash_agent_payload 'git stash' fork)"
test_deny "$SUBAGENT_GIT_GUARD" "subagent: git stash pop still denied" \
  "$(bash_agent_payload 'git stash pop' fork)"
test_deny "$SUBAGENT_GIT_GUARD" "subagent: git stash listing (not the list verb) still denied" \
  "$(bash_agent_payload 'git stash listing' fork)"

echo ""
echo "=== subagent-spawn-guard (GH #151: a dispatched subagent may not call the Agent tool itself) ==="
test_deny "$SUBAGENT_SPAWN_GUARD" "subagent (general-purpose) calling Agent to spawn its own reviewer" \
  "$(agent_payload 'general-purpose' 'agent-1' 'general-purpose')"
test_deny "$SUBAGENT_SPAWN_GUARD" "subagent (fork) calling Agent with a DIFFERENT subagent_type still denied (closes the same-type-switch evasion from the 2026-08-31 fork-recursive-spawn incident -- the gate never inspects subagent_type)" \
  "$(agent_payload 'general-purpose' 'agent-2' 'fork')"
test_deny "$SUBAGENT_SPAWN_GUARD" "subagent with no agent_type recorded (agent_id alone is the signal) still denied" \
  "$(agent_payload 'mh:silent-failure-hunter' 'agent-3' '')"
test_allow "$SUBAGENT_SPAWN_GUARD" "main session calling Agent (no agent_id) allowed" \
  "$(agent_payload 'general-purpose' '' '')"
test_allow "$SUBAGENT_SPAWN_GUARD" "subagent calling a non-Agent tool (Bash) is out of scope for this gate" \
  "$(bash_agent_payload 'ls -la' fork)"
# GH #154: the gate's own stated intent is to key on PRESENCE of agent_id, not
# a non-empty/non-null value -- these three exercise cases the old bash
# fast-path (raw-text substring match) and old python truthiness check
# (`if not agent_id`) both mishandled as "no agent_id" when the key was in
# fact present. A real payload capture (2026-09-07, matt-harness issue #154)
# never observed an empty/null/escaped agent_id in practice -- these are
# hardening tests for a theoretical gap the gate's own contract should still
# hold against, not evidence the gap is live-exploitable.
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #154 gap 2: agent_id present but an empty string still denied" \
  "$(agent_payload_forced_id 'general-purpose' '')"
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #154 gap 2: agent_id present but JSON null still denied" \
  "$(agent_payload_forced_id 'general-purpose' '__NULL__')"
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #154 gap 1: agent_id key JSON-escaped (\\u005f for the underscore) still denied, not fast-pathed past on raw-text match" \
  "$(agent_payload_escaped_id_key)"
# The .sh gate has no bash-level fast path (removed for GH #154) -- every
# payload always reaches python3, so these exercise the json.load()/
# isinstance() fail-safe branches directly.
test_allow "$SUBAGENT_SPAWN_GUARD" "malformed stdin (fail-safe allow)" \
  '{"agent_id": invalid'
test_allow "$SUBAGENT_SPAWN_GUARD" "valid JSON but non-object payload (fail-safe allow)" \
  '["agent_id"]'
# GH #156: a 5000-digit UNQUOTED int literal used to raise ValueError inside
# json.load() itself (CPython 3.11+'s int-string digit limit), caught by the
# same broad `except Exception: allow` as ordinary malformed JSON -- a
# well-formed-but-huge-int payload bypassed this gate's actual logic instead
# of being parsed and denied normally.
test_deny "$SUBAGENT_SPAWN_GUARD" "GH #156: 5000-digit unquoted agent_id parses and denies, doesn't fail-open past the int-digit limit" \
  "$(printf '{"tool_name":"Agent","tool_input":{"prompt":"x","description":"y","subagent_type":"general-purpose"},"agent_id":%s}' "$(python3 -c "print('9'*5000)")")"
# JSON depth: an extra key nested past the decoder's limit raises RecursionError, which the old
# broad except allowed. The main-session row would otherwise be allowed, so only the depth branch denies it.
test_deny_deep "$SUBAGENT_SPAWN_GUARD" "JSON depth 1e6, main-session Agent: fails closed" \
  "$(agent_payload 'general-purpose' '' '' | deepen 1000000)"
test_deny_deep "$SUBAGENT_SPAWN_GUARD" "JSON depth 1e6, subagent Agent: fails closed" \
  "$(agent_payload 'general-purpose' 'agent-1' '' | deepen 1000000)"
test_allow "$SUBAGENT_SPAWN_GUARD" "JSON depth 500, main-session Agent: still parses and allows" \
  "$(agent_payload 'general-purpose' '' '' | deepen 500)"
GATE_RUNNER=memerr test_deny_deep "$SUBAGENT_SPAWN_GUARD" "json.load MemoryError, main-session Agent: fails closed" \
  "$(agent_payload 'general-purpose' '' '')"

echo ""
echo "=== routine-trigger-guard (ADR 0004 §4/§5 item 6: nothing gated RemoteTrigger before this) ==="
# mh:deep-audit (2026-09-28) found the original version action-blind (asked on
# read-only actions too) and CronCreate misclassified as a Routine trigger --
# both fixed; these cases cover the corrected, narrower scope.
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=create asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'create')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=update asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'update')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=run asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'run')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=create_webhook_trigger asks for confirmation" \
  "$(routine_trigger_payload 'RemoteTrigger' 'create_webhook_trigger')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger with no action key at all fails toward asking" \
  "$(routine_trigger_payload 'RemoteTrigger')"
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger with an unrecognized future action fails toward asking" \
  "$(routine_trigger_payload 'RemoteTrigger' 'some_future_action')"
# mh:blind-spot-hunter (2026-09-28): a non-string action (list/dict) crashed the gate's
# `action in READ_ONLY_ACTIONS` membership check with an unhandled TypeError, and Claude Code
# treats that non-zero, non-2 exit as non-blocking -- the call went through with no ask.
test_ask "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger with a non-string (list) action fails toward asking, not a crash-through-allow" \
  "$(python3 -c 'import json; print(json.dumps({"tool_name": "RemoteTrigger", "tool_input": {"action": ["create"]}}))')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=list is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'list')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=get is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'get')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=list_runs is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'list_runs')"
test_allow "$ROUTINE_TRIGGER_GUARD" "RemoteTrigger action=get_run_log is a pure read, allowed" \
  "$(routine_trigger_payload 'RemoteTrigger' 'get_run_log')"
test_allow "$ROUTINE_TRIGGER_GUARD" "CronCreate is out of scope (session-only, no new credential), allowed" \
  "$(routine_trigger_payload 'CronCreate' 'create')"
test_allow "$ROUTINE_TRIGGER_GUARD" "unrelated tool (Bash) is out of scope for this gate" \
  "$(bash_payload 'ls -la')"
test_allow "$ROUTINE_TRIGGER_GUARD" "malformed stdin (fail-safe allow)" \
  '{"tool_name": invalid'
test_allow "$ROUTINE_TRIGGER_GUARD" "valid JSON but non-object payload (fail-safe allow)" \
  '["RemoteTrigger"]'
# JSON depth: action=list would be allowed, so only the depth branch can ask on it.
test_ask "$ROUTINE_TRIGGER_GUARD" "JSON depth 1e6, RemoteTrigger action=list: asks (cannot be checked)" \
  "$(routine_trigger_payload 'RemoteTrigger' 'list' | deepen 1000000)"
test_allow "$ROUTINE_TRIGGER_GUARD" "JSON depth 500, RemoteTrigger action=list: still parses and allows" \
  "$(routine_trigger_payload 'RemoteTrigger' 'list' | deepen 500)"
GATE_RUNNER=memerr test_ask "$ROUTINE_TRIGGER_GUARD" "json.load MemoryError, RemoteTrigger action=list: asks (cannot be checked)" \
  "$(routine_trigger_payload 'RemoteTrigger' 'list')"

# Missing-sibling .py (corrupted/partial plugin install), mirroring the
# irrecoverable.py case below but expecting this gate's own documented
# allow-on-missing-sibling posture, not a deny (mh:deep-audit, 2026-09-28:
# this path was documented in operating-model.md but had no regression test).
MISSPY_RTG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kbg-misspy-rtg.XXXXXX")
cp "$ROUTINE_TRIGGER_GUARD" "$MISSPY_RTG_DIR/routine-trigger-guard.sh"
_errf=$(mktemp "${TMPDIR:-/tmp}/kbg-misspy-rtg-err.XXXXXX")
_out=$(routine_trigger_payload 'RemoteTrigger' 'create' | bash "$MISSPY_RTG_DIR/routine-trigger-guard.sh" 2>"$_errf")
_rc=$?
_ok=1
if [ "$_rc" -eq 0 ] && [ -z "$_out" ] && grep -q '\[mh:gate\]' "$_errf"; then
  _ok=0
fi
if [ "$_ok" -eq 0 ]; then
  echo "  ✅ ALLOW: missing sibling routine-trigger-guard.py -> fails open (exit 0) with [mh:gate] message"
  pass=$((pass + 1))
else
  echo "  ❌ missing sibling routine-trigger-guard.py: expected exit 0 + empty stdout + [mh:gate] message, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2
  fail=$((fail + 1))
fi
rm -f "$_errf"
tmp_delete "$MISSPY_RTG_DIR"

echo "=== GNU tr stays quiet (cloud audit 2026-10-23: an unescaped trailing backslash in tr -d warned on every Bash call) ==="
_trdir=$(mktemp -d "${TMPDIR:-/tmp}/kbg-gnutr.XXXXXX")
if command -v gtr >/dev/null 2>&1; then ln -s "$(command -v gtr)" "$_trdir/tr"; fi
_trerr=$(bash_payload 'ls' | PATH="$_trdir:$PATH" bash "$IRRECOVERABLE" 2>&1 >/dev/null)
if [ -z "$_trerr" ]; then
  echo "  ✅ no stderr from the gate on a plain command (tr: $(PATH="$_trdir:$PATH" command -v tr))"
  pass=$((pass + 1))
else
  echo "  ❌ the gate wrote to stderr on a plain command: $_trerr" >&2
  fail=$((fail + 1))
fi
tmp_delete "$_trdir"

echo "=== same damage, other git verbs (2026-10-23 bypass sweep after the cloud audit) ==="
for c in 'git push --mirror' 'git push origin --mirror' 'git push --prune origin' \
         'git push origin :main' 'git push origin :refs/heads/develop' 'git push origin --delete main' 'git push -d origin master' \
         'git read-tree -u --reset HEAD' 'git read-tree --reset -u HEAD' \
         'git checkout-index -f -a' 'git checkout-index --force --all' 'git checkout-index -fa' \
         'git worktree remove --force wt' 'git worktree remove -f wt' \
         'git reflog expire --expire=now --all' 'git reflog expire --expire-unreachable=all --all' 'git reflog expire --expire now --all' \
         'git reflog delete HEAD@{1}' 'git gc --prune=now' 'git gc --prune=all' 'git prune --expire=now' 'git prune --expire now' \
         'git update-ref -d refs/heads/main' 'git update-ref --delete refs/heads/develop' \
         'git branch -M x main' 'git branch -m --force x master' 'git branch -C x develop' \
         'git $(echo push) --mirror'; do
  test_deny "$IRRECOVERABLE" "$c" "$(bash_payload "$c")"
done
for c in 'git push origin --delete feat' 'git push origin :feat' 'git push origin main' 'git read-tree HEAD' \
         'git checkout-index -a' 'git worktree remove wt' 'git reflog expire --all' 'git reflog show' 'git gc' 'git gc --prune=2.weeks.ago' \
         'git prune' 'git prune --dry-run' 'git prune -n --expire=now' 'git update-ref -d refs/heads/feat' 'git branch -M old new' 'git branch -m main' 'git worktree list'; do
  test_allow "$IRRECOVERABLE" "$c" "$(bash_payload "$c")"
done

echo "=== fast-path (bash pre-filter that skips python3 on commands that cannot match, added 2026-08-14) ==="
# Irrecoverable gained a bash fast-path so a benign command skips the python3 cold-start.
test_deny  "$IRRECOVERABLE" "r\"\"m -rf (quote-concatenation -> fast-path quote-strip)" \
  "$(bash_payload 'r""m -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "r\\m -rf (backslash-concatenation -> fast-path strip)" \
  "$(bash_payload 'r\m -rf /tmp/x')"
# A backslash-newline continuation splitting the argv0 ITSELF (not just a flag) turns the \n
# escape into a space at the fast-path's own sed step, so "git"/"rm" never survives as one
# substring and the fast path exits 0 before python3.
test_deny  "$IRRECOVERABLE" "gi + backslash-newline + t (argv0 split, was a fast-path bypass)" \
  "$(bash_payload $'gi\\\nt push --force origin develop')"
test_deny  "$IRRECOVERABLE" "r + backslash-newline + m (argv0 split, was a fast-path bypass)" \
  "$(bash_payload $'r\\\nm -rf /tmp/x')"
# The fast path's sed turns a JSON \n or \t escape into a space. A command holding a literal
# backslash then t (JSON: two backslashes then t) was misread as that escape, so the argv0 lost
# its letter and python3 never ran. The shell reads backslash-t as a plain t (fuzz sweep 2026-10-01).
test_deny  "$IRRECOVERABLE" "gi + literal backslash-t (argv0 split, was a fast-path bypass)" \
  "$(bash_payload 'gi\t push --force origin develop')"
test_deny  "$IRRECOVERABLE" "fi + literal backslash-n + d (find argv0 split, was a fast-path bypass)" \
  "$(bash_payload 'fi\nd /tmp/x -delete')"
test_deny  "$IRRECOVERABLE" "control: a real tab between git and its argument still denies" \
  "$(bash_payload $'git\tpush --force origin develop')"
test_allow "$IRRECOVERABLE" "control: literal backslash-t in an unrelated command stays allowed" \
  "$(bash_payload 'printf "a\tb"')"
# GH #309: the argv0 brace rows (r{m,m}, fi{nd,nd}) sit with the other brace-view rows below.
test_allow "$IRRECOVERABLE" "GH #309 control: a brace group and a brace list with no verb stay allowed" \
  "$(bash_payload '{ echo a; }; ls x{a,b}')"
# "gh" was added to the fast-path candidate list alongside the ask-tier gh
# merge rule (Phase B) -- without this, "gh pr merge" would fast-path
# straight to allow, never reaching python3's ask() at all.
test_ask "$IRRECOVERABLE" "gh pr merge reaches python3 through the fast path (not swallowed by it)" \
  "$(bash_payload 'gh pr merge 5')"

echo ""
echo "=== python3-missing fail-open (#93: every deny gate must exit 0 with ONE stderr note, never rc=127 or a silent block) ==="
# A PATH stub dir with the gates' shell dependencies (cat/sed/tr/grep/awk + bash; awk since GH #309) but NO python3.
NOPY_BIN=$(mktemp -d "${TMPDIR:-/tmp}/kbg-nopy.XXXXXX")
for _t in bash cat sed tr grep awk; do
  _src=$(PATH="/usr/bin:/bin" command -v "$_t" || command -v "$_t")
  ln -s "$_src" "$NOPY_BIN/$_t"
done

# Test_nopython_allow <gate> <desc> <payload> [extra env VAR=VAL...]
test_nopython_allow() {
  local gate="$1" desc="$2" payload="$3"; shift 3
  local rc errf
  errf=$(mktemp "${TMPDIR:-/tmp}/kbg-nopy-err.XXXXXX")
  rc=$(echo "$payload" | env "$@" PATH="$NOPY_BIN" bash "$gate" 2>"$errf"; echo $?)
  if [[ "$rc" == "0" ]] && grep -q 'python3 not found' "$errf"; then
    echo "  ✅ NO-PYTHON ALLOW: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ NO-PYTHON ALLOW expected (rc=0 + note) but got rc=$rc, stderr: $(cat "$errf")" >&2
    fail=$((fail + 1))
  fi
  rm -f "$errf"
}

# Test_documented_fastpath_allow <gate> <desc> <payload> [extra env VAR=VAL...] Inverse of
# test_nopython_allow above (same NOPY_BIN instrument, opposite expectation): asserts rc=0
# WITHOUT the "python3 not found" note, i.e.
test_documented_fastpath_allow() {
  local gate="$1" desc="$2" payload="$3"; shift 3
  local rc errf
  errf=$(mktemp "${TMPDIR:-/tmp}/kbg-nopy-err.XXXXXX")
  rc=$(echo "$payload" | env "$@" PATH="$NOPY_BIN" bash "$gate" 2>"$errf"; echo $?)
  if [[ "$rc" == "0" ]] && ! grep -q 'python3 not found' "$errf"; then
    echo "  ✅ DOCUMENTED FAST-PATH ALLOW (GH #134, non-live): $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ documented fast-path allow expected (rc=0, no portability note) but got rc=$rc, stderr: $(cat "$errf")" >&2
    fail=$((fail + 1))
  fi
  rm -f "$errf"
}


# GH #771: without python3 a recursive rm or a find delete denies on a text check (names trash);
# everything else keeps #93's announced allow. Ruling: the text check over-denies "git rm -r" and
# "echo rm -rf" (any rm word with an -r flag), the safe direction on a machine that cannot parse.
test_nopython_deny() {
  local gate="$1" desc="$2" payload="$3"
  local rc errf
  errf=$(mktemp "${TMPDIR:-/tmp}/kbg-nopy-err.XXXXXX")
  rc=$(echo "$payload" | PATH="$NOPY_BIN" bash "$gate" 2>"$errf"; echo $?)
  if [[ "$rc" == "2" ]] && grep -q 'trash' "$errf"; then
    echo "  ✅ NO-PYTHON DENY: $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ NO-PYTHON DENY expected (rc=2 + trash hint) but got rc=$rc, stderr: $(cat "$errf")" >&2
    fail=$((fail + 1))
  fi
  rm -f "$errf"
}
for _c in 'rm -rf /tmp/x' 'rm -r x' 'rm -R x' 'rm --recursive x' 'rm -f -r x' 'rm x -fr' '/bin/rm -rf x' \
  'ls; rm -rf x' 'find . -delete' 'find . -name y -delete' 'find . -exec rm {} +' 'find . -exec /bin/rm -f {} ;' \
  'git rm -r dir' 'echo rm -rf x' \
  'rm --rec x' 'rm --recursiv x' "rm 'a|b' -r" "rm 'a;b' -rf" "rm \"a|b\" -r" "find . -name 'a|b' -delete" \
  "find . -regex '.*\\(a\\|b\\)' -delete" "find . -name 'x;y' -exec rm {} +" 'find . -exec command rm {} \;' \
  'find . -exec env rm {} \;' 'find . -exec sudo -u x rm {} \;' "rm '-rf' x" \
  "rm \"it's;x\" -rf y; echo 'z'" "rm 'it\"s;x' -rf y; echo \"z\""; do
  test_nopython_deny "$IRRECOVERABLE" "irrecoverable: $_c" "$(bash_payload "$_c")"
done
# An apostrophe in the description pairs with one inside a double-quoted argument (review of 9a65476b).
for _c in "rm \"it's;x\" -rf y" "find . -name \"it's;x\" -delete"; do
  test_nopython_deny "$IRRECOVERABLE" "irrecoverable: $_c, description don't" \
    "$(printf '{"tool_name": "Bash", "tool_input": {"command": %s, "description": "don'"'"'t"}}' "$(printf '%s' "$_c" | jq -Rsa .)")"
done
for _c in 'rm -f x' 'rm x' 'git status' 'find . -name y' 'find . -exec cat {} +' 'rmdir x' 'ls -r rmx' 'rm --force x' "rm 'a|b'" 'find . -exec cat {} \;'; do
  test_nopython_allow "$IRRECOVERABLE" "irrecoverable: $_c keeps the #93 allow" "$(bash_payload "$_c")"
done
# Backtick/$(...) fast-path bypass: a command substitution vanishes in real bash ("gi`true`t" IS
# "git" once bash evaluates it) but survives as literal characters through the fast path's
# normalization, so neither "git" nor any other tracked argv0 forms a contiguous substring and
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: backtick-split argv0 (gi\`true\`t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi`true`t push --force origin develop')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$(...)-split argv0 (gi\$(true)t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi$(true)t push --force origin develop')"
# Same class, two more splicing spellings found alongside the backtick/$(...) fix: ${x} with x
# unset expands to nothing ("gi${x}t" IS "git"), and $'...' ANSI-C quoting resolves escapes
# ("gi$'\x74'" IS "git").
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \${x}-split argv0 (gi\${x}t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi${x}t push --force origin develop')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$'...'-split argv0 (gi\$'\x74' push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload "gi\$'\\x74' push --force origin develop")"
# Fresh-context review finding (2026-09-03): $@ and $* are a 5th zero-width splicer the 4-marker
# enumeration above never covered.
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$@-split argv0 (gi\$@t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi$@t push --force origin develop')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: \$*-split argv0 (gi\$*t push --force) still reaches the guard, not fast-path-exited" \
  "$(bash_payload 'gi$*t push --force origin develop')"
# GH #336: mkfs, chmod and source are candidate words, so they reach python.
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: mkfs.ext4 reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'mkfs.ext4 /dev/sda1')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: mke2fs reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'mke2fs /dev/sda1')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: chmod -R 777 reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'chmod -R 777 /')"
test_nopython_allow "$IRRECOVERABLE" "irrecoverable: source reaches the guard, not fast-path-exited (GH #336)" \
  "$(bash_payload 'source ./setup.sh')"
# A $ that arrives JSON-\uXXXX-escaped instead of as a literal byte is invisible to the raw
# _has_subst scan above.
test_documented_fastpath_allow "$IRRECOVERABLE" "irrecoverable: JSON \\u0024-escaped \$ around a \${x} splice (gi\\u0024{x}t push --force) -- raw scan blind, documented non-live gap" \
  '{"tool_name":"Bash","tool_input":{"command":"gi\u0024{x}t push --force origin develop"}}'
test_nopython_allow "$TASK_COMPLETE" "task-complete-separation: subagent completion passes with note" \
  "$(taskupdate_payload 'completed' 'refactor-cleaner')"
test_nopython_allow "$SUBAGENT_SPAWN_GUARD" "subagent-spawn-guard: subagent calling Agent passes with note" \
  "$(agent_payload 'general-purpose' 'agent-1' 'general-purpose')"
test_nopython_allow "$ROUTINE_TRIGGER_GUARD" "routine-trigger-guard: RemoteTrigger passes with note" \
  "$(routine_trigger_payload 'RemoteTrigger')"

# Trash-fallback deny message (#93): with python3 present but NO trash CLI on PATH, the rm -rf
# deny must still fire (rc=2) and the message must route to the user instead of prescribing a
# binary the machine doesn't have.
TRASHLESS_BIN=$(mktemp -d "${TMPDIR:-/tmp}/kbg-notrash.XXXXXX")
# Dirname: GH #146 extracted irrecoverable.sh's embedded python3 -c block to a sibling
# irrecoverable.py, resolved via "$(dirname "$0")".
for _t in bash cat sed tr grep python3 dirname; do
  _src=$(PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" command -v "$_t" || command -v "$_t")
  ln -s "$_src" "$TRASHLESS_BIN/$_t"
done
_errf=$(mktemp "${TMPDIR:-/tmp}/kbg-notrash-err.XXXXXX")
_rc=$(bash_payload 'rm -rf /tmp/x' | env PATH="$TRASHLESS_BIN" bash "$IRRECOVERABLE" 2>"$_errf"; echo $?)
if [[ "$_rc" == "2" ]] && grep -q 'no trash CLI' "$_errf" && grep -q 'ask the user' "$_errf"; then
  echo "  ✅ DENY: rm -rf without a trash CLI still denies, message routes to the user (#93)"
  pass=$((pass + 1))
else
  echo "  ❌ rm -rf trashless deny expected (rc=2 + user-routing message) but got rc=$_rc, stderr: $(cat "$_errf")" >&2
  fail=$((fail + 1))
fi
rm -f "$_errf"

echo ""
echo "=== missing sibling .py (corrupted/partial plugin install; follow-up to #146) ==="
# Extracted this gate's embedded python3 -c block into a sibling irrecoverable.py, resolved via
# "$(dirname "$0")/irrecoverable.py".
MISSPY_IRR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kbg-misspy-irr.XXXXXX")
cp "$IRRECOVERABLE" "$MISSPY_IRR_DIR/irrecoverable.sh"
_errf=$(mktemp "${TMPDIR:-/tmp}/kbg-misspy-irr-err.XXXXXX")
_out=$(bash_payload 'rm -rf /tmp/x' | bash "$MISSPY_IRR_DIR/irrecoverable.sh" 2>"$_errf")
_rc=$?
_ok=1
if [ "$_rc" -eq 2 ] && [ -z "$_out" ] && grep -q '\[mh:gate\]' "$_errf" \
   && ! grep -qi "can't open file\|Traceback" "$_errf"; then
  _ok=0
fi
if [ "$_ok" -eq 0 ]; then
  echo "  ✅ DENY: missing sibling irrecoverable.py -> fails closed (exit 2) with [mh:gate] message, no raw traceback"
  pass=$((pass + 1))
else
  echo "  ❌ missing sibling irrecoverable.py: expected exit 2 + [mh:gate] message + no traceback, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2
  fail=$((fail + 1))
fi
rm -f "$_errf"
# Both gates run their .py through the _run.py import stub: with every sibling present but the stub,
# irrecoverable fails closed (exit 2) and subagent-git-guard fails open (exit 0), each with its own message.
MISSRUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kbg-missrun.XXXXXX")
cp "$ROOT"/hooks/gates/*.sh "$ROOT"/hooks/gates/*.py "$MISSRUN_DIR"/
[ -e "$MISSRUN_DIR/_run.py" ] && tmp_delete "$MISSRUN_DIR/_run.py"
_errf="$MISSRUN_DIR/err"
_out=$(bash_payload 'rm -rf /tmp/x' | bash "$MISSRUN_DIR/irrecoverable.sh" 2>"$_errf"); _rc=$?
if [ "$_rc" -eq 2 ] && [ -z "$_out" ] && /usr/bin/grep -q '\[mh:gate\].*_run.py missing' "$_errf"; then
  echo "  ✅ DENY: missing _run.py stub -> irrecoverable fails closed (exit 2) with [mh:gate] message"; pass=$((pass + 1))
else
  echo "  ❌ missing _run.py: irrecoverable expected exit 2 + [mh:gate] _run.py message, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2; fail=$((fail + 1))
fi
_out=$(bash_agent_payload 'git stash' fork | bash "$MISSRUN_DIR/subagent-git-guard.sh" 2>"$_errf"); _rc=$?
if [ "$_rc" -eq 0 ] && [ -z "$_out" ] && /usr/bin/grep -q '\[mh:gate\].*_run.py missing' "$_errf"; then
  echo "  ✅ ALLOW: missing _run.py stub -> subagent-git-guard fails open (exit 0) with [mh:gate] message"; pass=$((pass + 1))
else
  echo "  ❌ missing _run.py: subagent-git-guard expected exit 0 + [mh:gate] _run.py message, got rc=$_rc stdout='$_out' stderr: $(cat "$_errf")" >&2; fail=$((fail + 1))
fi
tmp_delete "$MISSRUN_DIR"

# GH #184/#185/#194/#195/#196: fail closed when the command is syntactically ambiguous (nested or
# mixed substitutions, a quoted ")" inside "$(", a "case" inside "$(", brace tokens, eval of a
# substitution) AND names an irrecoverable verb. Raw-text check, so it holds where blanking mis-closes.
# GH #219 (named-fd "{var}>") is not a raw-text rule here: the tokenizer reads it both ways instead (see _blank_redirections).
test_deny "$IRRECOVERABLE" 'GH #184: a quoted ")" inside $() must not hide rm -rf' \
  "$(bash_payload 'echo $(echo ")"; rm -rf /nonexistent-x)')"
test_deny "$IRRECOVERABLE" 'GH #185: backtick nested inside $() must not hide rm -rf' \
  "$(bash_payload 'echo $(echo `rm -rf /nonexistent-x`)')"
test_deny "$IRRECOVERABLE" 'GH #194: brace-hidden flag, git reset {--hard,}' \
  "$(bash_payload 'git reset {--hard,}')"
test_deny "$IRRECOVERABLE" 'GH #194: brace-hidden flag, rm {-rf,} X' \
  "$(bash_payload 'rm {-rf,} /nonexistent-x')"
test_deny "$IRRECOVERABLE" 'GH #194: a flag after a git @{n} revision, git reset HEAD@{1} --hard' \
  "$(bash_payload 'git reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #194: git push origin HEAD@{0} --force' \
  "$(bash_payload 'git push origin HEAD@{0} --force')"
test_deny "$IRRECOVERABLE" 'GH #194: a flag after a git ~{n} revision, git reset HEAD~{1} --hard' \
  "$(bash_payload 'git reset HEAD~{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #194: a flag after a git ^{commit} revision' \
  "$(bash_payload 'git reset HEAD^{commit} --hard')"
test_deny "$IRRECOVERABLE" 'GH #195: a case-pattern ")" inside $() must not hide rm -rf' \
  "$(bash_payload 'echo $(case a in a) rm -rf /nonexistent-x;; esac)')"
test_deny "$IRRECOVERABLE" 'GH #195: case inside $() then a real git reset --hard' \
  "$(bash_payload "echo \$(case a in 'a') true;; esac); git reset --hard")"
test_deny "$IRRECOVERABLE" 'GH #196: eval of a $() that builds rm -rf' \
  "$(bash_payload 'eval "$(echo rm -rf /nonexistent-x)"')"
test_deny "$IRRECOVERABLE" 'GH #196: escaped backtick nested in backticks' \
  "$(bash_payload 'echo `echo \`rm -rf /nonexistent-x\``')"
test_allow "$IRRECOVERABLE" 'ambiguity control: git log with @{1} and no destructive verb' \
  "$(bash_payload 'git log HEAD@{1}')"
test_allow "$IRRECOVERABLE" 'ambiguity control: git diff @{u}' \
  "$(bash_payload 'git diff @{u} --stat')"
test_allow "$IRRECOVERABLE" 'ambiguity control: brace list with no destructive verb' \
  "$(bash_payload 'mkdir -p /tmp/{a,b}')"
test_allow "$IRRECOVERABLE" 'ambiguity control: awk program braces, no destructive verb' \
  "$(bash_payload "awk '{print \$1}' /etc/hosts")"
test_allow "$IRRECOVERABLE" 'ambiguity control: plain $() and backticks with no destructive verb' \
  "$(bash_payload 'echo $(pwd) `date`')"
test_allow "$IRRECOVERABLE" 'ambiguity control: a plain rm of one file, no ambiguity' \
  "$(bash_payload 'rm /tmp/nonexistent-x')"
test_allow "$IRRECOVERABLE" 'ambiguity control: a branch switch with an ordinary $() argument' \
  "$(bash_payload 'git checkout "$(git branch --show-current)"')"
# Deep-audit 2026-09-30 (F1): the verb check must see a git global flag before the sub, and a
# path-qualified rm/git, or every ambiguous shape above is bypassed by respelling the verb.
test_deny "$IRRECOVERABLE" 'audit-0930 F1: git -C . reset {--hard,}' \
  "$(bash_payload 'git -C . reset {--hard,}')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: git --no-pager push origin HEAD@{0} --force' \
  "$(bash_payload 'git --no-pager push origin HEAD@{0} --force')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: git -C "a b" -c x.y=z reset HEAD@{1} --hard' \
  "$(bash_payload 'git -C "a b" -c x.y=z reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: /usr/bin/git reset HEAD~{1} --hard' \
  "$(bash_payload '/usr/bin/git reset HEAD~{1} --hard')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: /bin/rm {-rf,} X' \
  "$(bash_payload '/bin/rm {-rf,} /nonexistent-x')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: case inside $() hiding /bin/rm -rf' \
  "$(bash_payload 'echo $(case a in a) /bin/rm -rf /nonexistent-x;; esac)')"
test_deny "$IRRECOVERABLE" 'audit-0930 F1: eval of a $() that builds /bin/rm -rf' \
  "$(bash_payload 'eval "$(echo /bin/rm -rf /nonexistent-x)"')"
test_allow "$IRRECOVERABLE" 'audit-0930 F1 control: git -C . log HEAD@{1} has no destructive verb' \
  "$(bash_payload 'git -C . log HEAD@{1}')"
test_allow "$IRRECOVERABLE" 'audit-0930 F1 control: x.git and --git before a verb word are not git' \
  "$(bash_payload 'echo {a,b} x.git reset --git push')"
# Deep-audit 2026-09-30 (F2): one shape's narrow verb list must not hide another shape's broad one.
test_deny "$IRRECOVERABLE" 'audit-0930 F2: an escaped backtick must not mask a brace-hidden rm flag' \
  "$(bash_payload 'echo \` ; rm {-rf,} /nonexistent-x')"
test_deny "$IRRECOVERABLE" 'audit-0930 F2: a nested substitution must not mask a brace-hidden push flag' \
  "$(bash_payload 'echo $(echo `date`); git push {-f,} origin main')"
# GH #254: a "{" or "}" inside a word is literal in bash, but the tokenizer split the word there and
# started a new window, so the flag after it was never seen by its command's rule.
test_deny "$IRRECOVERABLE" 'GH #254: git reset feat{1} --hard' \
  "$(bash_payload 'git reset feat{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #254: git branch old{1} -D' \
  "$(bash_payload 'git branch old{1} -D')"
test_deny "$IRRECOVERABLE" 'GH #254: git push origin x{1} -f' \
  "$(bash_payload 'git push origin x{1} -f')"
test_deny "$IRRECOVERABLE" 'GH #254: dd if=a{1} of=/dev/disk9' \
  "$(bash_payload 'dd if=a{1} of=/dev/disk9')"
test_deny "$IRRECOVERABLE" 'GH #254: find with a word ending in } before -delete' \
  "$(bash_payload "find . -name '*.log' ! -name keep} -delete")"
test_deny "$IRRECOVERABLE" 'GH #254/#255: a bundled -fu after HEAD@{0}' \
  "$(bash_payload 'git push origin HEAD@{0} -fu')"
test_deny "$IRRECOVERABLE" 'GH #254/#255: an abbreviated --har after HEAD@{1}' \
  "$(bash_payload 'git reset HEAD@{1} --har')"
test_allow "$IRRECOVERABLE" 'GH #254 control: git stash show stash@{1}' \
  "$(bash_payload 'git stash show stash@{1}')"
test_allow "$IRRECOVERABLE" 'GH #254 control: git checkout feat{1} is a branch switch' \
  "$(bash_payload 'git checkout feat{1}')"
test_allow "$IRRECOVERABLE" 'GH #254 control: a { } group with a harmless body' \
  "$(bash_payload '{ echo a; echo b; } > /tmp/nonexistent-x')"
# GH #255: the value-taking git globals are one list (GIT_VALUE_GLOBALS) shared by the parser and the
# ambiguity verb walk; the walk takes escaped values, line continuations and 32 globals; the verb is
# also looked for with quotes and backslashes dropped.
test_deny "$IRRECOVERABLE" 'GH #255: git --namespace x reset --hard' \
  "$(bash_payload 'git --namespace x reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: git --namespace x clean -fd' \
  "$(bash_payload 'git --namespace x clean -fd')"
test_deny "$IRRECOVERABLE" 'GH #255: git --attr-source HEAD push --force' \
  "$(bash_payload 'git --attr-source HEAD push --force origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: git --namespace=x reset --hard' \
  "$(bash_payload 'git --namespace=x reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: nine -C globals before a brace-hidden push flag' \
  "$(bash_payload 'git -C . -C . -C . -C . -C . -C . -C . -C . -C . push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: an escaped-space -C value before reset --hard after @{1}' \
  "$(bash_payload 'git -C My\ Project reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: a line continuation between -C value and reset' \
  "$(bash_payload $'git -C /repo \\\n  reset HEAD@{1} --hard')"
test_deny "$IRRECOVERABLE" 'GH #255: an abbreviated --forc after HEAD@{0}' \
  "$(bash_payload 'git push origin HEAD@{0} --forc')"
# Deep-audit 2026-10-01: the ambiguity verb regex is length-bounded (~400 chars of globals), so the
# parser, which resolves the git sub at any length, also denies a destructive sub next to a brace token.
_many_c=$(printf -- '-C . %.0s' $(seq 100))  # lost in the d42e54cb split; the two tests below ran with no globals
_many_cfg=$(printf -- '-c a=b %.0s' $(seq 70))
test_deny "$IRRECOVERABLE" 'deep-audit 2026-10-01: 100 -C globals before a brace-hidden push flag' \
  "$(bash_payload "git ${_many_c}push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'deep-audit 2026-10-01: 70 -c globals before a brace-hidden reset flag' \
  "$(bash_payload "git ${_many_cfg}reset {--hard,}")"
test_allow "$IRRECOVERABLE" 'deep-audit 2026-10-01 control: 100 -C globals, a brace, a read-only sub' \
  "$(bash_payload "git ${_many_c}log {a,b}")"
test_deny "$IRRECOVERABLE" 'GH #255: a double-quoted git verb before a brace-hidden flag' \
  "$(bash_payload '"git" push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: a single-quoted git verb before a brace-hidden flag' \
  "$(bash_payload "'git' push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: a backslash inside rm before a brace-hidden flag' \
  "$(bash_payload 'r\m {-rf,} X')"
test_deny "$IRRECOVERABLE" 'GH #255: a quoted verb with a quoted spaced -C value' \
  "$(bash_payload '"git" -C "a b" reset {--hard,} HEAD')"
test_deny "$IRRECOVERABLE" 'GH #255: -c user.name with a quoted space before a brace-hidden flag' \
  "$(bash_payload "git -c user.name='A B' push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: 40 -C globals before a brace-hidden push flag' \
  "$(bash_payload "git $(printf '%.0s-C . ' $(seq 40))push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: a quoted ; inside a -C value before a brace-hidden push flag' \
  "$(bash_payload "git -C 'a;b' push {--force,} origin main")"
test_deny "$IRRECOVERABLE" 'GH #255: a quoted | inside a --namespace value before a brace-hidden flag' \
  "$(bash_payload 'git --namespace "a|b" push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: an escaped ; inside a -C value before a brace-hidden flag' \
  "$(bash_payload 'git -C a\;b push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: a substitution with && inside a quoted -C value' \
  "$(bash_payload 'git -C "$(cd /x && pwd)" push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: -xdf bundle after HEAD@{1}' \
  "$(bash_payload 'git reset HEAD@{1} -xdf')"
test_deny "$IRRECOVERABLE" 'GH #255: an unquoted $( ) with && inside a --namespace value' \
  "$(bash_payload 'git --namespace $(a && b) push {--force,} origin main')"
test_deny "$IRRECOVERABLE" 'GH #255: an unquoted backtick span with ; inside a -C value' \
  "$(bash_payload 'git -C `a;b` push {--force,} origin main')"
test_allow "$IRRECOVERABLE" 'GH #255 control: a quoted ; -C value with a harmless status' \
  "$(bash_payload "git -C 'a;b' status {a,b}")"
test_allow "$IRRECOVERABLE" 'GH #255 control: 40 repeated -C then a brace token runs in bounded time' \
  "$(bash_payload "git $(printf '%.0s-C ' $(seq 40))foo {a,b}")"
test_allow "$IRRECOVERABLE" 'GH #255 control: ls -lrt after HEAD@{1} with a find substitution' \
  "$(bash_payload 'ls -lrt HEAD@{1} $(find . -name x)')"
test_allow "$IRRECOVERABLE" 'GH #255 control: git --namespace x status' \
  "$(bash_payload 'git --namespace x status')"
test_allow "$IRRECOVERABLE" 'GH #255 control: git push origin HEAD@{0} has no flag' \
  "$(bash_payload 'git push origin HEAD@{0}')"
test_allow "$IRRECOVERABLE" 'GH #255 control: echo "git" hello' \
  "$(bash_payload 'echo "git" hello')"

# GH #246: the nested-spawn anchor scan is quadratic on padded input, and a hook past its 8 s timeout
# allows. 48 KB of `env ; ` in front of a hidden `claude -p` took 10 s. A shared work budget now
# denies a command too dense to scan, fast; a subagent only. Tails hold `claude`: irrecoverable.sh
# skips python for a command with no candidate word, so a plain `ls` tail never reaches this scan.
_pad() { python3 -c 'import sys; sys.stdout.write(sys.argv[1] * int(sys.argv[2]))' "$1" "$2"; }
_PAD_ENV=$(_pad 'env ; ' 8000; printf x); _PAD_ENV=${_PAD_ENV%x}  # $(...) strips trailing blanks and newlines
_PAD_NL=$(_pad $'\n' 6000; printf x); _PAD_NL=${_PAD_NL%x}
_t0=$(date +%s)
test_deny "$IRRECOVERABLE" 'GH #246: a spawn hidden behind 48 KB of padding is denied, not timed out into allow' \
  "$(bash_agent_payload "${_PAD_ENV}time ls; claude -p a; claude --version" fork)"
test_deny "$IRRECOVERABLE" 'GH #246: a padded benign command is refused by the work budget, fast' \
  "$(bash_agent_payload "${_PAD_ENV}claude --version" fork)"
test_deny "$IRRECOVERABLE" 'GH #246: 6000 bare newlines before a benign command is refused by the work budget' \
  "$(bash_agent_payload "${_PAD_NL}claude --version" fork)"
test_deny "$IRRECOVERABLE" 'GH #246: padding inside a bash -c body counts against the same budget' \
  "$(bash_agent_payload "bash -c '${_PAD_ENV}claude --version'; bash -c '${_PAD_ENV}claude --version'" fork)"
_el=$(( $(date +%s) - _t0 ))
if [ "$_el" -lt 8 ]; then echo "  ✅ GH #246: every padded shape decided inside the 8 s hook timeout (${_el}s)"; pass=$((pass + 1))
else echo "  ❌ GH #246: padded shapes took ${_el}s, past the hook timeout" >&2; fail=$((fail + 1)); fi
test_allow "$IRRECOVERABLE" 'GH #246 control: the main session is never scanned, padding is allowed' \
  "$(bash_agent_payload "${_PAD_ENV}claude --version" '')"
test_allow "$IRRECOVERABLE" 'GH #246 control: a long ordinary subagent command (20 KB) is still allowed' \
  "$(bash_agent_payload "echo $(_pad x 20000); claude --version" fork)"
test_allow "$IRRECOVERABLE" 'GH #246 control: a 400-line ordinary subagent script is still allowed' \
  "$(bash_agent_payload "$(_pad $'echo hello world\n' 400)claude --version" fork)"

# GH #248: three shapes that reached their target on develop too: a wrapped FIRST statement (the
# greedy walk lands on the last claude), a brace group, and `xargs claude` (xargs was no wrapper here).
for _c in \
  'time claude -p x; claude --version' \
  'env A=1 claude --bg x; claude --help' \
  'timeout 5 claude --agent x && claude --version' \
  '{ claude -p x; }' \
  '{ claude --bg x; } 2>&1' \
  'true; { claude -p x; }' \
  'xargs claude -p x' \
  'xargs -n1 claude --print x' \
  'echo a | xargs -I{} claude -p {}' \
  'nice -n 5 xargs claude -p x' \
  'bash -c "{ claude -p x; }"' \
  'bash -c "time claude -p x; claude --version"' ; do
  test_deny "$IRRECOVERABLE" "GH #248: spawn reached through a wrapped first statement, brace group or xargs: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'time claude --version; claude --help' \
  '{ claude --version; }' \
  'xargs claude --version' \
  'xargs ls' \
  'echo {a,b} claude' \
  'git commit -m "mention claude in docs"' ; do
  test_allow "$IRRECOVERABLE" "GH #248 control: benign claude use still allowed: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #248 control: the main session is never scanned' \
  "$(bash_agent_payload '{ claude -p x; }' '')"
# Deep-audit 5: repo-gotchas asks two awkward shapes of every new wrapper word, here xargs: a glued
# `name=1` (an assignment, not the wrapper) and a decoy whose walk could hide the statements after it.
for _c in \
  'xargs=1 claude -p x' \
  'xargs x && claude -p y && claude --version' ; do
  test_deny "$IRRECOVERABLE" "xargs wrapper awkward shape still denied: $_c" "$(bash_agent_payload "$_c" fork)"
done

# GH #275 follow-up (deep-audit): _AMBIG_FLAG_RE's `[uvnqxfdDrR]*[fdDrR][uvnqxfdDrR]*\b` retried every split
# of a long `-fff...` token (quadratic: 60 KB took 11 s, past the 8 s hook timeout, and a timed-out hook
# allows). `timeout 5` wraps the run, so a regression reads as rc 124, not a slow pass.
_flag_dos_cmd="$(python3 -c 'print("git @{1} -" + "f" * 60000 + "c; git reset --hard")')"
_flag_dos_rc=$(bash_payload "$_flag_dos_cmd" | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_flag_dos_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): a 60 KB non-matching flag token after git @{1} is scanned in bounded time; --hard carries the deny"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $_flag_dos_rc (124 = timed out, quadratic flag scan): 60 KB flag token after git @{1}" >&2
  fail=$((fail + 1))
fi
test_deny  "$IRRECOVERABLE" 'GH #275 control: a short bundled flag after git @{1} denies with no --hard in sight' \
  "$(bash_payload 'git reset HEAD@{1} -xdf; git stash')"
test_allow "$IRRECOVERABLE" 'GH #275 control: a non-bundle flag after git @{1} next to a broad verb is allowed' \
  "$(bash_payload 'git stash show stash@{1} -p')"
# Deep-audit step 6: the narrow-verb push piece `\s-[A-Za-z]*f\b` backed off across a whole long token from
# every git/push anchor in reach (13 s at 140 KB). The escaped backtick selects the narrow regex.
_push_dos_cmd="$(python3 -c 'print("\\`" + "git " * 100 + "push " * 40 + "-" + "f" * 140000 + "c" + "; psql -c \"DROP TABLE users\"")')"
_push_dos_rc=$(bash_payload "$_push_dos_cmd" | timeout 5 bash "$IRRECOVERABLE" 2>/dev/null; echo $?)
if [[ "$_push_dos_rc" == "2" ]]; then
  echo "  ✅ DENY (bounded time): a 140 KB flag token behind 100 git and 40 push anchors is scanned in bounded time"
  pass=$((pass + 1))
else
  echo "  ❌ DENY EXPECTED (bounded time) but got exit $_push_dos_rc (124 = timed out, quadratic push-flag scan)" >&2
  fail=$((fail + 1))
fi
test_deny  "$IRRECOVERABLE" 'GH #275 control: a short push -f next to an escaped backtick still denies' \
  "$(bash_payload 'echo \` ; git push origin main -f')"

# GH #284: the narrow push piece needed `f` to be the LAST letter of the flag, so a bundle like -fu missed it
# (defense-in-depth: the main parser already denies these). Check the regex itself, since the hook never reaches it.
_narrow_rc=$(python3 - "$ROOT/hooks/gates/irrecoverable.py" <<'PY'
import re, sys
# The module runs the gate at import, so exec only the regex definitions (from _AMBIG_UNIT to _ambiguous).
src = open(sys.argv[1]).read()
block = src[src.index("_AMBIG_UNIT = "):src.index("def _ambiguous(")]
ns = {"re": re, "_FORCE_PUSH_OK": False}; exec(block, ns)  # the strict-force-push flag is set at the top of the module
r = ns["_AMBIG_NARROW_VERB_RE"]
hit = all(r.search(c) for c in ("git push origin main -fu", "git push -uf origin main", "git push origin main -f"))
miss = not any(r.search(c) for c in ("git push -u origin main", "git push origin main -u"))
print(0 if hit and miss else 1)
PY
)
if [[ "$_narrow_rc" == "0" ]]; then
  echo "  ✅ GH #284: narrow push piece matches bundled -fu/-uf, ignores -u"
  pass=$((pass + 1))
else
  echo "  ❌ GH #284: narrow push piece misses a bundled force flag or over-matches -u" >&2
  fail=$((fail + 1))
fi

# GH #340: _AMBIG_GIT_SUB_RE names `switch` but _AMBIG_NARROW_AFTER had no `switch` key, so a narrow-shape
# command (escaped backtick, backtick plus $()) with a git switch raised KeyError: exit 1, which the .sh
# turned into an "internal error" deny. test_deny rejects a crash deny, so these rows need the real rule.
# The narrow piece for switch is "any switch" (like clean/restore): a flag piece missed $'-f' in a substitution
# body, which the main parser never sees, so a plain branch switch in these rare shapes stays denied.
test_deny  "$IRRECOVERABLE" 'GH #340: git switch <branch> next to an escaped backtick denies by rule, not crash' \
  "$(bash_payload 'echo \` ; git switch main')"
test_deny  "$IRRECOVERABLE" 'GH #340: git switch -c next to a backtick plus $() denies by rule, not crash' \
  "$(bash_payload 'x=$(echo `pwd`); git switch -c feat')"
test_deny  "$IRRECOVERABLE" 'GH #340: git switch --discard-changes next to an escaped backtick denies' \
  "$(bash_payload 'echo \` ; git switch --discard-changes main')"
test_deny  "$IRRECOVERABLE" "GH #340: git switch \$'-f' in a backtick body inside \$() denies" \
  "$(bash_payload "echo \$(echo \`git switch \$'-f' main\`)")"
test_deny  "$IRRECOVERABLE" "GH #340: eval of \$() holding git switch \$'-f' denies" \
  "$(bash_payload "eval \"\$(echo git switch \$'-f' main)\"")"
test_allow "$IRRECOVERABLE" 'GH #340 control: git status next to an escaped backtick is allowed' \
  "$(bash_payload 'echo \` ; git status')"
_switch_dos_cmd="$(python3 -c 'print("\\`" + "git status " * 100 + "-" + "q" * 140000 + " switch")')"
_timed_case 'GH #340: a switch after 100 git anchors and a 140 KB token is found in bounded time' 2 "$_switch_dos_cmd"
# Every sub word the ambiguity check finds needs a narrow piece; one with no piece counts as a hit (deny).
_narrow_keys_rc=$(python3 - "$ROOT/hooks/gates/irrecoverable.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = src[src.index("_AMBIG_UNIT = "):src.index("def _ambiguous(")]
ns = {"re": re}; exec(block, ns)
subs = set(re.findall(r"\w+", ns["_AMBIG_GIT_SUB_RE"].pattern.split("(", 2)[2].split(")")[0]))
r = ns["_AMBIG_NARROW_VERB_RE"]
ok = subs == set(ns["_AMBIG_NARROW_AFTER"]) and bool(r.search("git switch main"))
ns["_AMBIG_NARROW_AFTER"].pop("switch")
ok = ok and bool(r.search("git switch main"))  # a sub with no narrow piece fails closed
print(0 if ok else 1)
PY
)
if [[ "$_narrow_keys_rc" == "0" ]]; then
  echo "  ✅ GH #340: every ambiguity sub word has a narrow piece, and a missing piece counts as a hit"
  pass=$((pass + 1))
else
  echo "  ❌ GH #340: an ambiguity sub word has no narrow piece, or a missing piece does not fail closed" >&2
  fail=$((fail + 1))
fi

# Bypass hunt 2026-10-23 (docs/research/bypass-hunt-2026-10-23.md) F1/F2: with no TTY (the Bash tool
# has none) `claude <prompt>` and `<input> | claude` run headless, the same as -p; -w is --worktree's
# short form and --background is --bg's long form. Only the flag list was checked.
for _c in \
  "claude 'fix the failing test'" \
  'claude hi' \
  'echo hi | claude' \
  'claude --model sonnet hi' \
  'claude -w x' \
  'claude -w' \
  'claude --background hi' \
  'env claude hi' \
  'bash -c "claude hi"' \
  'echo hi | xargs claude' \
  'echo hi |& claude' \
  'claude < prompt.txt' \
  'claude <<< hi' \
  $'claude <<EOF\nhi\nEOF' \
  'claude -- hi' \
  'claude ultrareview' \
  'claude $(cat prompt.txt)' \
  'x=$(claude hi)' \
  "out=\"\$(claude 'review this')\"" ; do
  test_deny "$IRRECOVERABLE" "bypass hunt F1/F2: subagent claude with a prompt, piped input or a short/long flag alias: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'claude' \
  'claude --version' \
  'claude -v' \
  'claude --help' \
  'claude -h' \
  'claude hi --help' \
  'claude --version | head -1' \
  'claude mcp list' \
  'claude mcp serve' \
  'claude doctor' \
  'claude plugin list' \
  'ls || claude --version' \
  "echo 'claude hi'" \
  "rg -n 'claude hi' docs" \
  'git commit -m "feat(claude): document the gate"' \
  'git commit -m "a; claude handles it"' \
  'git commit -m "pipe it | claude"' \
  'echo "$(claude --version)"' \
  'x=$(claude)' ; do
  test_allow "$IRRECOVERABLE" "bypass hunt F1/F2 control: subagent claude that starts no session: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
# Fresh-context review of the F1 fix: a prompt or stdin hidden behind a quote in a comment or a $'..'
# string, a version word in a comment, a pipe into a group; and wrapped commands whose ARGUMENT is
# `claude`, which the anchor's wrapper walk reached (`time rg claude src/` read `src/` as a prompt).
for _c in \
  $'# it\'s a test\nclaude "hi"' \
  "echo \$'it\\'s'; claude \"hi\"" \
  'claude "summarize this" # -v' \
  'claude "x" $(true -v )' \
  'echo "do x" | { claude; }' \
  'echo "do x" | (claude)' \
  'echo hi | sudo -u bob claude' \
  'timeout 30 claude hi' \
  'echo hi | xargs -n1 claude' \
  'echo ${#arr[@]}; claude hi' \
  'HOME=/tmp claude "hi"' \
  'echo hi | FOO=a/b claude' \
  'env PATH=/usr/bin:$PATH claude "hi"' \
  'env -C /tmp claude "hi"' \
  'cat f | env -C /tmp claude' \
  'sudo -p pw: claude "hi"' \
  'echo {#,a}; claude "hi"' ; do
  test_deny "$IRRECOVERABLE" "bypass hunt F1 review: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  'time rg claude src/' \
  'timeout 30 grep -rn claude hooks/' \
  'env LC_ALL=C grep -c claude README.md' \
  'sudo grep -r claude /etc' \
  'git ls-files | xargs grep -l claude' \
  'nice -n 5 rg --files-with-matches claude' \
  $'# it\'s fine\nclaude --version' ; do
  test_allow "$IRRECOVERABLE" "bypass hunt F1 review control: claude is an argument, or prints its version: $_c" \
    "$(bash_agent_payload "$_c" fork)"
done
for _c in 'claude hi' 'echo hi | claude' 'claude -w x' ; do
  test_allow "$IRRECOVERABLE" "bypass hunt F1/F2 control: the main session may start one: $_c" \
    "$(bash_agent_payload "$_c" '')"
done

# GH #559 review: the SQL client is the command a pipe stage runs (its argv0 past wrappers), not the
# word "psql" anywhere in the pipeline or on a heredoc's line; and a bash -c / eval body is checked too.
test_allow "$IRRECOVERABLE" "GH #559 review: grep -v psql downstream of a grep for drop table" \
  "$(bash_payload "grep -rn 'drop table' . | grep -v psql")"
test_allow "$IRRECOVERABLE" "GH #559 review: grep psql downstream of a grep for DROP TABLE" \
  "$(bash_payload "grep -rn 'DROP TABLE' migrations/ | grep psql")"
test_allow "$IRRECOVERABLE" "GH #559 review: grep for psql upstream of a grep for drop table" \
  "$(bash_payload "grep -rn psql docs/ | grep -i 'drop table'")"
test_deny  "$IRRECOVERABLE" "GH #559 review: DROP TABLE echoed into sudo -u postgres psql" \
  "$(bash_payload "echo 'DROP TABLE users' | sudo -u postgres psql mydb")"
test_deny  "$IRRECOVERABLE" "GH #559 review: DROP TABLE echoed into sudo -iu postgres psql (a clustered value flag)" \
  "$(bash_payload "echo 'DROP TABLE users' | sudo -iu postgres psql mydb")"
test_deny  "$IRRECOVERABLE" "GH #559 review: DROP TABLE echoed into env PGHOST=db /usr/bin/psql" \
  "$(bash_payload "echo 'DROP TABLE users' | env PGHOST=db /usr/bin/psql mydb")"
test_allow "$IRRECOVERABLE" "GH #559 review control: a SELECT echoed into psql" \
  "$(bash_payload "echo 'SELECT * FROM users' | psql mydb")"
test_allow "$IRRECOVERABLE" "GH #559 review: a gh body heredoc whose title mentions psql" \
  "$(bash_payload "$(printf "gh issue create --title 'SQL DROP piped to psql passes' --body \"\$(cat <<'EOF'\npsql mydb <<< 'DROP TABLE users' passes\nEOF\n)\"")")"
test_deny  "$IRRECOVERABLE" "GH #559 review: a heredoc psql reads inside \$()" \
  "$(bash_payload "$(printf "out=\$(psql mydb <<'SQL'\nDROP TABLE users;\nSQL\n)")")"
test_deny  "$IRRECOVERABLE" "GH #559 review: a heredoc cat pipes into psql inside \$()" \
  "$(bash_payload "$(printf "out=\$(cat <<'SQL' | psql mydb\nDROP TABLE users;\nSQL\n)")")"
test_deny  "$IRRECOVERABLE" "GH #559 review: DROP TABLE echoed into psql inside bash -c" \
  "$(bash_payload "bash -c \"echo 'DROP TABLE t' | psql db\"")"
test_deny  "$IRRECOVERABLE" "GH #559 review: DROP TABLE echoed into psql inside eval" \
  "$(bash_payload "eval \"echo 'DROP TABLE t' | psql\"")"
test_deny  "$IRRECOVERABLE" "GH #559 review: a here-string psql reads inside sh -c" \
  "$(bash_payload "sh -c \"psql db <<< 'DROP TABLE t'\"")"
test_allow "$IRRECOVERABLE" "GH #559 review control: a SELECT echoed into psql inside bash -c" \
  "$(bash_payload "bash -c \"echo 'SELECT 1' | psql db\"")"
test_allow "$IRRECOVERABLE" "GH #559 review control: grep -v psql inside bash -c" \
  "$(bash_payload "bash -c \"grep -rn 'drop table' . | grep -v psql\"")"
# GH #559 review round 2.
test_deny  "$IRRECOVERABLE" "GH #559 review 2: DROP TABLE echoed into docker exec -i pg psql" \
  "$(bash_payload "echo 'DROP TABLE t' | docker exec -i pg psql -U postgres")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: a heredoc docker exec -i pg psql reads" \
  "$(bash_payload "$(printf "docker exec -i pg psql <<'SQL'\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: DROP TABLE echoed into docker exec -u postgres pg psql" \
  "$(bash_payload "echo 'DROP TABLE t' | docker exec -i -u postgres pg psql")"
test_allow "$IRRECOVERABLE" "GH #559 review 2 control: a SELECT echoed into docker exec psql" \
  "$(bash_payload "echo 'SELECT 1' | docker exec -i pg psql -U postgres")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: an apostrophe in a comment line before echo DROP | psql" \
  "$(bash_payload "$(printf "# don't do this\necho 'DROP TABLE t' | psql db")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: a pipeline into psql continued after a trailing |" \
  "$(bash_payload "$(printf "echo 'DROP TABLE t' |\n  psql db")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: a pipeline into psql continued with a backslash-newline" \
  "$(bash_payload "$(printf "echo 'DROP TABLE t' | \\\\\n  psql db")")"
test_allow "$IRRECOVERABLE" "GH #559 review 2: a heredoc into psql whose -- comment mentions DROP TABLE" \
  "$(bash_payload "$(printf "psql db <<'SQL'\n-- removed the DROP TABLE step\nSELECT 1;\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #559 review 2: a heredoc into psql with LIKE 'truncate the cache'" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nSELECT * FROM logs WHERE msg LIKE 'truncate the cache';\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #559 review 2: git diff | grep -v 'DROP TABLE' | psql (a grep pattern is not SQL)" \
  "$(bash_payload "git diff | grep -v 'DROP TABLE' | psql db")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: DROP TABLE after a string literal in a heredoc into psql" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nSELECT 'it''s';\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: DROP TABLE after a backslash string in a heredoc into psql" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nSELECT 'a\\\\';\nDROP TABLE t; -- '\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: a quote inside a block comment does not hide DROP TABLE" \
  "$(bash_payload "$(printf "psql db <<'SQL'\n/* don't */ DROP TABLE t; -- '\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: DROP TABLE echoed through cat into psql" \
  "$(bash_payload "echo 'DROP TABLE t' | cat | psql db")"
test_deny  "$IRRECOVERABLE" "GH #559 review 2: TRUNCATE of a quoted table name in a heredoc into psql" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nTRUNCATE \"users\";\nSQL")")"
# GH #559 review round 3.
test_deny  "$IRRECOVERABLE" "GH #559 review 3: a heredoc psql -h db-node reads (node in a host name)" \
  "$(bash_payload "$(printf "psql -h db-node db <<'SQL'\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: a heredoc psql reads after cd into a python path" \
  "$(bash_payload "$(printf "cd /srv/python/app && psql db <<'SQL'\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3 control: a heredoc sudo bash reads after a cd is still code" \
  "$(bash_payload "$(printf "cd /srv/app && sudo -u app bash <<'EOF'\nrm -rf ~\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3 control: a heredoc ssh host bash reads is still code" \
  "$(bash_payload "$(printf "ssh host bash <<'EOF'\nrm -rf ~\nEOF")")"
test_allow "$IRRECOVERABLE" "GH #559 review 3: rtk proxy -v psql with a SELECT heredoc" \
  "$(bash_payload "$(printf "rtk proxy -v psql db <<'SQL'\nSELECT 1;\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #559 review 3: a heredoc piped into rtk run -q grep psql" \
  "$(bash_payload "$(printf "cat <<'E' | rtk run -q grep psql\nhello\nE")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: rtk proxy -v psql with a DROP heredoc" \
  "$(bash_payload "$(printf "rtk proxy -v psql db <<'SQL'\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: a dollar-quoted apostrophe before DROP TABLE" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nSELECT \$\$it's\$\$; DROP TABLE t; -- '\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: a backslash-escaped quote before DROP TABLE into mysql" \
  "$(bash_payload $'echo "SELECT \'\\\\\'\'; DROP TABLE t; -- \'" | mysql db')"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: MySQL 1--1 is no comment before DROP TABLE" \
  "$(bash_payload "echo 'SELECT 1--1; DROP TABLE t;' | mysql db")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: a MySQL /*! */ executable comment holding DROP TABLE" \
  "$(bash_payload "echo '/*! DROP TABLE t */' | mysql db")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: a MySQL # comment with an apostrophe before DROP TABLE" \
  "$(bash_payload "$(printf "mysql db <<'SQL'\nSELECT 1 # don't\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 3: the second heredoc on a line is the one psql reads" \
  "$(bash_payload "$(printf "cat <<'A' >/dev/null; psql db <<'B'\nx\nA\nDROP TABLE t;\nB")")"
test_allow "$IRRECOVERABLE" "GH #559 review 3 control: two heredocs on a line, neither a drop to a client" \
  "$(bash_payload "$(printf "cat <<'A' >/dev/null; psql db <<'B'\nDROP TABLE t;\nA\nSELECT 1;\nB")")"
# GH #559 review round 4: a heredoc on a compound command feeds every command in it, and a
# version-suffixed interpreter is one too; the body stays code.
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into { bash; } is code" \
  "$(bash_payload "$(printf "{ bash; } <<'EOF'\nrm -rf ~\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into (bash; :) is code" \
  "$(bash_payload "$(printf "(bash; :) <<'EOF'\nrm -rf ~\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into a while loop running bash is code" \
  "$(bash_payload "$(printf "while read x; do bash; done <<'EOF'\nrm -rf ~\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into an if running sudo bash is code" \
  "$(bash_payload "$(printf "if true; then sudo bash; fi <<'EOF'\nrm -rf ~\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into { cd; bash; } with git push --force is code" \
  "$(bash_payload "$(printf "{ cd /srv/app; bash; } <<'EOF'\ngit push --force origin develop\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into zsh-5.9 is code" \
  "$(bash_payload "$(printf "zsh-5.9 <<'EOF'\nrm -rf ~\nEOF")")"
# GH #681: python reads the body as python, so a bare shell line in it is a syntax error, not a delete; the
# process-API scan is what reads it now.
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into python3.12 - is code" \
  "$(bash_payload "$(printf "python3.12 - <<'EOF'\nimport os\nos.system('rm -rf ~')\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a backtick is no quote to psql before DROP TABLE" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nSELECT 1 \`; DROP TABLE t; -- \`\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a [bracket] identifier with an apostrophe before DROP TABLE into sqlite3" \
  "$(bash_payload "$(printf "sqlite3 db <<'SQL'\nSELECT [it's]; DROP TABLE t; -- '\nSQL")")"
# GH #621: a { } or ( ) group piped into a client feeds it every inner command's output; a block comment
# may hold a *, and MySQL's # comment separates words too. Once the stripper meets a construct it does not
# model, a plain '...' literal before it is still one word, so a literal that only mentions a drop reads nothing.
test_deny  "$IRRECOVERABLE" "GH #621: DROP TABLE echoed in a { } group piped into psql" \
  "$(bash_payload "{ echo 'DROP TABLE t'; } | psql db")"
test_deny  "$IRRECOVERABLE" "GH #621: DROP TABLE printf'd in a { } group piped into mysql" \
  "$(bash_payload "{ printf 'DROP TABLE t'; } | mysql db")"
test_deny  "$IRRECOVERABLE" "GH #621: DROP TABLE echoed second in a ( ) group piped into psql" \
  "$(bash_payload "( echo a; echo 'DROP TABLE t' ) | psql db")"
test_deny  "$IRRECOVERABLE" "GH #621: DROP TABLE echoed after cat in a { } group piped into psql" \
  "$(bash_payload "{ cat x.sql; echo 'DROP TABLE t'; } | psql db")"
test_deny  "$IRRECOVERABLE" "GH #621: DROP TABLE echoed in a nested group piped into psql" \
  "$(bash_payload "{ ( echo 'DROP TABLE t' ); } | sudo -u postgres psql db")"
test_deny  "$IRRECOVERABLE" "GH #621 guard: DROP TABLE echoed in a one-command ( ) group piped into psql" \
  "$(bash_payload "( echo 'DROP TABLE t' ) | psql db")"
test_deny  "$IRRECOVERABLE" "GH #621 guard: a here-string psql reads inside a { } group" \
  "$(bash_payload "{ cd /x; psql db <<< 'DROP TABLE t'; }")"
test_deny  "$IRRECOVERABLE" "GH #621 guard: DROP TABLE echoed into psql inside a { } group" \
  "$(bash_payload "{ echo 'DROP TABLE t' | psql db; }")"
test_allow "$IRRECOVERABLE" "GH #621 control: a SELECT echoed in a { } group piped into psql" \
  "$(bash_payload "{ echo 'SELECT 1'; echo 'SELECT 2'; } | psql db")"
test_allow "$IRRECOVERABLE" "GH #621 control: a { } group echoing DROP TABLE piped into grep, then psql" \
  "$(bash_payload "{ echo 'DROP TABLE t'; } | grep -c DROP; psql db -c 'SELECT 1'")"
test_deny  "$IRRECOVERABLE" "GH #621: a block comment holding a * between DROP and TABLE on psql -c" \
  "$(bash_payload "psql -c 'DROP /* has * star */ TABLE t'")"
test_deny  "$IRRECOVERABLE" "GH #621: a MySQL # comment between DROP and TABLE on mysql -e" \
  "$(bash_payload "mysql -e \$'DROP # c\\nTABLE t'")"
test_deny  "$IRRECOVERABLE" "GH #621 guard: a -- comment between DROP and TABLE on mysql -e" \
  "$(bash_payload "mysql -e \$'DROP -- c\\nTABLE t'")"
test_deny  "$IRRECOVERABLE" "GH #621: a MySQL # comment between DROP and TABLE in a heredoc into mysql" \
  "$(bash_payload "$(printf "mysql db <<'SQL'\nDROP # c\nTABLE t;\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #621: a backtick column and a literal mentioning truncate table into mysql" \
  "$(bash_payload "$(printf "mysql db <<'SQL'\nSELECT \`id\` FROM t WHERE note='truncate table later';\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #621: a [1] subscript and a literal mentioning drop table into sqlite3" \
  "$(bash_payload "$(printf "sqlite3 db <<'SQL'\nSELECT a[1] FROM t WHERE x = 'drop table x';\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #621: a LIKE literal mentioning drop table before a -- #42 comment into sqlite3" \
  "$(bash_payload "$(printf "sqlite3 db <<'SQL'\nSELECT a FROM t WHERE x LIKE '%%drop table x%%' -- #42\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #621 control: DROP TABLE after a stripped literal next to a backtick column into mysql" \
  "$(bash_payload "$(printf "mysql db <<'SQL'\nSELECT \`id\` FROM t WHERE note='x'; DROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #621 control: a backslash literal stops the stripping before a later quote pair" \
  "$(bash_payload "$(printf "mysql db <<'SQL'\nSELECT 'a\\\\' , '; DROP TABLE t; SELECT ';\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #621 control: a # comment apostrophe does not open a literal over DROP TABLE" \
  "$(bash_payload "$(printf "mysql db <<'SQL'\nSELECT \`a\` # don't\nDROP TABLE t; SELECT 'x';\nSQL")")"
_sql_groups_cmd="$(python3 -c 'print("{ echo x; } | psql; " * 7000)')"
_timed_case 'GH #621: 7000 { } groups piped into psql finish in bounded time' 0 "$_sql_groups_cmd"
_sql_nested_cmd="$(python3 -c 'print("( " * 9000 + "echo \"" + "x " * 20000 + "\" | psql" + " ) | psql" * 9000 + " # DROP TABLE t")')"
_timed_case 'GH #621: 9000 nested groups around 40 KB of echo piped into psql finish in bounded time' 0 "$_sql_nested_cmd"
_sql_nested_cmd="$(python3 -c 'print("( " * 5000 + "echo \"" + "x " * 10000 + "\" | psql" + " ; echo y ) | psql" * 5000 + " # DROP TABLE t")')"
_timed_case 'GH #621: 5000 nested groups each adding a line to 20 KB of SQL deny on the read budget' 2 "$_sql_nested_cmd"
_sql_gap_cmd="$(python3 -c 'print("psql -c \"DROP " + "/* a * b */ " * 5000 + "x\"; mysql db <<SQL\nDROP " + "# c\n" * 10000 + "x\n" + "/*" + "*" * 35000 + "\nSQL")')"
_timed_case 'GH #621: 135 KB of comment runs between DROP and a non-object finish in bounded time' 0 "$_sql_gap_cmd"
_sql_lits_cmd="$(python3 -c 'print("mysql db <<SQL\nSELECT \`a\`" + " ,'"'"'drop table x'"'"'" * 7000 + ";\nSQL")')"
_timed_case 'GH #621: 7000 literals after a backtick in a heredoc into mysql finish in bounded time' 0 "$_sql_lits_cmd"
# GH #621 review: a CR (or U+2028/U+2029) ends a -- or // comment for psql and JavaScript, so a quote in
# the comment may pair with a later literal; such a body, and any body a mongo/mongosh/redis-cli client
# reads (JavaScript, where a ' may sit in a regex), blanks no literal and is matched raw.
test_deny  "$IRRECOVERABLE" "GH #621 review: a CR ends a -- comment holding an apostrophe before DROP TABLE into psql" \
  "$(bash_payload "$(python3 -c 'print("psql db <<'"'"'SQL'"'"'\nSELECT a[1] FROM t -- it'"'"'s\rDROP TABLE t; SELECT '"'"'x'"'"';\nSQL")')")"
test_deny  "$IRRECOVERABLE" "GH #621 review: a CR ends a -- comment holding an apostrophe before TRUNCATE into psql" \
  "$(bash_payload "$(python3 -c 'print("psql db <<'"'"'SQL'"'"'\nSELECT a[1] FROM t -- it'"'"'s\rTRUNCATE t; SELECT '"'"'x'"'"';\nSQL")')")"
test_deny  "$IRRECOVERABLE" "GH #621 review: a CR ends a -- comment before DROP TABLE into psql (no fallback construct)" \
  "$(bash_payload "$(python3 -c 'print("psql db <<'"'"'SQL'"'"'\nSELECT 1 -- x\rDROP TABLE t;\nSQL")')")"
test_deny  "$IRRECOVERABLE" "GH #621 review: an apostrophe in a mongosh regex literal before drop()" \
  "$(bash_payload "$(python3 -c 'print("mongosh db <<'"'"'JS'"'"'\nvar a=[1]; db.x.find({a:/'"'"'/}); db.t.drop(); var y='"'"'z'"'"';\nJS")')")"
test_deny  "$IRRECOVERABLE" "GH #621 review: a U+2028 ends a // comment holding an apostrophe before drop() into mongosh" \
  "$(bash_payload "$(python3 -c 'print("mongosh db <<'"'"'JS'"'"'\nvar a=[1]; // it'"'"'s\u2028db.t.drop(); var y='"'"'z'"'"';\nJS")')")"
test_deny  "$IRRECOVERABLE" "GH #621 review: a CR ends a // comment holding an apostrophe before drop() into mongo" \
  "$(bash_payload "$(python3 -c 'print("mongo db <<'"'"'JS'"'"'\nvar a=[1]; // it'"'"'s\rdb.t.drop(); var y='"'"'z'"'"';\nJS")')")"
test_deny  "$IRRECOVERABLE" "GH #621 review: an apostrophe in a regex literal before drop() echoed into mongosh" \
  "$(bash_payload "echo \"var a=[1]; db.x.find({a:/'/}); db.t.drop(); var y='z';\" | mongosh db")"
# GH #621 review 3: psql -a echoes its input on, so a non-SQL client anywhere downstream of the first client
# reads the body too, and the body blanks no literal.
_js_body="var a=[1]; db.x.find({a:/'/}); db.t.drop(); var y='z';"
test_deny  "$IRRECOVERABLE" "GH #621 review 3: a JS body echoed through psql -a into mongosh" \
  "$(bash_payload "echo \"$_js_body\" | psql -a | mongosh db")"
test_deny  "$IRRECOVERABLE" "GH #621 review 3: a JS here-string through psql -a into mongosh" \
  "$(bash_payload "psql -a <<< \"$_js_body\" | mongosh db")"
test_deny  "$IRRECOVERABLE" "GH #621 review 3: a JS heredoc through psql -a into mongosh" \
  "$(bash_payload "$(printf "psql -a <<'JS' | mongosh db\n%s\nJS" "$_js_body")")"
test_deny  "$IRRECOVERABLE" "GH #621 review 3: a JS body echoed in a { } group through psql -a into mongosh" \
  "$(bash_payload "{ echo \"$_js_body\"; } | psql -a | mongosh db")"
test_deny  "$IRRECOVERABLE" "GH #621 review 3: a JS body echoed through psql -a into docker exec mongosh" \
  "$(bash_payload "echo \"$_js_body\" | psql -a | docker exec -i m mongosh")"
test_deny  "$IRRECOVERABLE" "GH #621 review 3: a JS body echoed through psql -a into mongosh inside bash -c" \
  "$(bash_payload "bash -c \"echo \\\"$_js_body\\\" | psql -a | mongosh db\"")"
# GH #621 review 4: a client with an echo flag (or an echo/print/tee/trace command in the body) copies the body
# to its output, and a mongo/mongosh/redis-cli word anywhere in the command may be where it lands, so either
# one keeps the stdin body unblanked (develop's raw match).
test_deny  "$IRRECOVERABLE" "GH #621 review 4: psql -a output piped into a function running mongosh" \
  "$(bash_payload "f() { mongosh db; }; echo \"$_js_body\" | psql -a | f")"
test_deny  "$IRRECOVERABLE" "GH #621 review 4: psql -a output piped into \$M naming mongosh" \
  "$(bash_payload "M=mongosh; echo \"$_js_body\" | psql -a | \$M db")"
test_deny  "$IRRECOVERABLE" "GH #621 review 4: psql -a output to a temp file mongosh then reads" \
  "$(bash_payload "echo \"$_js_body\" | psql -a > /tmp/o; mongosh db < /tmp/o")"
test_deny  "$IRRECOVERABLE" "GH #621 review 4: a heredoc into psql -a to a temp file mongosh then reads" \
  "$(bash_payload "$(printf "psql -a > /tmp/o <<'JS'\n%s\nJS\nmongosh db < /tmp/o" "$_js_body")")"
test_deny  "$IRRECOVERABLE" "GH #621 review 4: a heredoc into psql -a whose pipe continues past the body" \
  "$(bash_payload "$(printf "psql -a <<'JS' |\n%s\nJS\nmongosh db" "$_js_body")")"
for _flag in -a -qa -ae -e -b -E -s --echo-all --echo-q --echo-errors --echo-hidden "-L /tmp/l" --log-file=/tmp/l \
    "-v ECHO=all" --set=ECHO=queries; do
  test_deny  "$IRRECOVERABLE" "GH #621 review 4: psql $_flag echoes its input on to an unseen client" \
    "$(bash_payload "echo \"$_js_body\" | psql $_flag db | \$M db")"
done
for _flag in -v -vv -sv --verbose --verb --tee=/tmp/t; do
  test_deny  "$IRRECOVERABLE" "GH #621 review 4: mysql $_flag echoes its input on to an unseen client" \
    "$(bash_payload "echo \"$_js_body\" | mysql $_flag db | \$M db")"
done
test_deny  "$IRRECOVERABLE" "GH #621 review 4: mariadb -v echoes its input on to an unseen client" \
  "$(bash_payload "echo \"$_js_body\" | mariadb -v db | \$M db")"
for _flag in -echo --echo "-cmd '.echo on'"; do
  test_deny  "$IRRECOVERABLE" "GH #621 review 4: sqlite3 $_flag echoes its input on to an unseen client" \
    "$(bash_payload "echo \"$_js_body\" | sqlite3 $_flag db | \$M db")"
done
for _cmd in '\\set ECHO all' '\\qecho' '\\w /tmp/q' 'tee /tmp/t' '\\p' '.echo on' '.trace stdout'; do
  test_deny  "$IRRECOVERABLE" "GH #621 review 4: a $_cmd line in the body copies it on to an unseen client" \
    "$(bash_payload "$(printf "psql db <<'JS' | \$M db\n%s\n%s\nJS" "$_cmd" "$_js_body")")"
done
test_allow "$IRRECOVERABLE" "GH #621 review 4 control: mysql -uvictor -h vhost (values, not -v) keeps the literal relief" \
  "$(bash_payload "$(printf "mysql -uvictor -h vhost db <<'SQL'\nSELECT \`id\` FROM t WHERE note='truncate table later';\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #621 review 4 control: psql -U alice -d app (values, not echo flags) keeps the literal relief" \
  "$(bash_payload "$(printf "psql -U alice -d app <<'SQL'\nSELECT a[1] FROM t WHERE x = 'drop table x';\nSQL")")"
# GH #697: the stdin check reads a client name the way the shell does (quotes, backslashes, $'..' dropped), and a
# command named by a variable or substitution ($C, ${C}, $(..), `..`) counts as a client that may read JavaScript.
for _c in 'ps""ql db' "'psql' db" 'p\sql db' "\$'psql' db" "\$'\\x70sql' db" 'sudo -u postgres ps""ql db' \
    'env X=1 "psql" db' "docker exec -i pg ps''ql" '/usr/bin/ps""ql db' 'my"sql" db' '$C db' '${C} db' \
    '$(command -v psql) db' '`which psql` db'; do
  test_deny  "$IRRECOVERABLE" "GH #697: DROP TABLE echoed into $_c" "$(bash_payload "echo 'DROP TABLE t' | $_c")"
done
test_deny  "$IRRECOVERABLE" "GH #697: drop() echoed into mon\"\"gosh" "$(bash_payload "echo 'db.t.drop()' | mon\"\"gosh db")"
test_deny  "$IRRECOVERABLE" "GH #697: a heredoc ps\"\"ql reads" "$(bash_payload "$(printf "ps\"\"ql db <<'SQL'\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #697: a heredoc cat pipes into \$C" "$(bash_payload "$(printf "cat <<'SQL' | \$C db\nDROP TABLE t;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #697: a here-string ps\"\"ql reads" "$(bash_payload "ps\"\"ql db <<< 'DROP TABLE t'")"
test_deny  "$IRRECOVERABLE" "GH #697: DROP TABLE echoed in a { } group into ps\"\"ql" \
  "$(bash_payload "{ echo 'DROP TABLE t'; } | ps\"\"ql db")"
test_deny  "$IRRECOVERABLE" "GH #697: a JS body echoed into \$C keeps its literals" "$(bash_payload "echo \"$_js_body\" | \$C db")"
test_deny  "$IRRECOVERABLE" "GH #697: mon\"\"gosh later in the command withdraws the literal relief" \
  "$(bash_payload "echo \"$_js_body\" | psql db > /tmp/o; mon\"\"gosh db < /tmp/o")"
for _flag in '-v E""CHO=all' "\$'-a'" '$F' '-e""cho-all'; do
  test_deny  "$IRRECOVERABLE" "GH #697: psql $_flag withdraws the literal relief" \
    "$(bash_payload "F=-a; echo \"$_js_body\" | psql $_flag db > /tmp/o")"
done
test_deny  "$IRRECOVERABLE" "GH #697: PSQLRC withdraws the literal relief" \
  "$(bash_payload "echo \"$_js_body\" | PSQLRC=/tmp/rc psql db > /tmp/o")"
test_deny  "$IRRECOVERABLE" "GH #697: sqlite3 -e\"\"cho withdraws the literal relief" \
  "$(bash_payload "echo \"$_js_body\" | sqlite3 -e\"\"cho db > /tmp/o")"
test_allow "$IRRECOVERABLE" "GH #697 control: a SELECT echoed into ps\"\"ql" "$(bash_payload "echo 'SELECT 1' | ps\"\"ql db")"
test_allow "$IRRECOVERABLE" "GH #697 control: DROP TABLE echoed into gr\"\"ep" "$(bash_payload "echo 'DROP TABLE t' | gr\"\"ep -v x")"
test_allow "$IRRECOVERABLE" "GH #697 control: echo hi into \"\$PAGER\"" "$(bash_payload 'echo hi | "$PAGER"')"
test_allow "$IRRECOVERABLE" "GH #697 control: a SELECT heredoc ps\"\"ql reads" \
  "$(bash_payload "$(printf "ps\"\"ql db <<'SQL'\nSELECT 1;\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #697 control: psql \"\$DATABASE_URL\" keeps the literal relief" \
  "$(bash_payload "$(printf "psql \"\$DATABASE_URL\" <<'SQL'\nSELECT \`id\` FROM t WHERE note='truncate table later';\nSQL")")"
# GH #697 review: the per-line checks run once per line, not once per heredoc on it (3000 openers took 15 s).
_sql_opaque_heredocs_cmd="$(python3 -c 'print("psql db $X " + "<<a " * 3000 + "\n" + "SELECT 1\na\n" * 2999 + "DROP TABLE t\na")')"
_timed_case 'GH #697 review: 3000 heredocs on a psql line with a $X word, the last a DROP, deny in bounded time' 2 "$_sql_opaque_heredocs_cmd"
_sql_many_heredocs_cmd="$(python3 -c 'print("psql db " + "<<a " * 7500 + "\n" + "DROP TABLE t\na\n" * 7500)')"
_timed_case 'GH #559 review 3: 7500 heredocs on one psql line finish in bounded time' 2 "$_sql_many_heredocs_cmd"
_sql_many_heredocs_cmd="$(python3 -c 'print("cat " + "<<a " * 7500 + "> f; psql\n" + "DROP TABLE t\na\n" * 7500)')"
_timed_case 'GH #559 review 3: 7500 heredocs into a file on a psql line finish in bounded time' 0 "$_sql_many_heredocs_cmd"
_sql_many_bodies_cmd="$(python3 -c 'print("psql db <<'"'"'SQL'"'"'\n" + "SELECT 1 FROM t;\n" * 4000 + "SQL\n" + "".join("eval x%d;" % i for i in range(7000)) + " rm -rf ~")')"
_timed_case 'GH #559 review 2: 7000 eval bodies after a 68 KB heredoc into psql finish in bounded time' 2 "$_sql_many_bodies_cmd"
_sql_many_bodies_cmd="$(python3 -c 'print("psql db <<'"'"'SQL'"'"'\n" + "SELECT 1 FROM t;\n" * 4000 + "SQL\n" + "".join("bash -c x%d;" % i for i in range(5000)) + " rm -rf ~")')"
_timed_case 'GH #559 review 2: 5000 bash -c bodies after a 68 KB heredoc into psql finish in bounded time' 2 "$_sql_many_bodies_cmd"
_sql_pad_cmd="$(python3 -c 'print("bash -c \"" + "echo DROP TABLE x | grep q psql | " * 4000 + "cat\"")')"
_timed_case 'GH #559 review: a 136 KB bash -c pipeline naming psql and DROP TABLE is scanned in bounded time' 0 "$_sql_pad_cmd"
# GH #563 review of PR #573: send-pack deletes a protected branch as push does (":main"), and a
# git rm dry run (-n bundled, --dry-run or a prefix) deletes nothing, so -f there is allowed.
test_deny  "$IRRECOVERABLE" "GH #563: send-pack :main deletes main on the remote" "$(bash_payload 'git send-pack git@github.com:o/r.git :main')"
test_deny  "$IRRECOVERABLE" "GH #563: send-pack :refs/heads/main" "$(bash_payload 'git send-pack git@github.com:o/r.git feature :refs/heads/main')"
test_deny  "$IRRECOVERABLE" "GH #563: send-pack :develop after another flag" "$(bash_payload 'git send-pack --atomic url :develop')"
test_deny  "$IRRECOVERABLE" "GH #563: send-pack --delete master (mirrors push)" "$(bash_payload 'git send-pack --delete url master')"
test_allow "$IRRECOVERABLE" "GH #563 control: send-pack a feature branch" "$(bash_payload 'git send-pack url feature')"
test_allow "$IRRECOVERABLE" "GH #563 control: send-pack :feature deletes only a feature branch" "$(bash_payload 'git send-pack url :feature')"
test_allow "$IRRECOVERABLE" "GH #563 control: git rm -nf is a dry run" "$(bash_payload 'git rm -nf a.py')"
test_allow "$IRRECOVERABLE" "GH #563 control: git rm -f --dry-run" "$(bash_payload 'git rm -f --dry-run a.py')"
test_allow "$IRRECOVERABLE" "GH #563 control: git rm -rf --dry (unique prefix)" "$(bash_payload 'git rm -rf --dry src')"
test_allow "$IRRECOVERABLE" "GH #563 control: git rm --cached f" "$(bash_payload 'git rm --cached f')"
test_allow "$IRRECOVERABLE" "GH #563 control: git rm f" "$(bash_payload 'git rm f')"
test_deny  "$IRRECOVERABLE" "GH #563: git rm -f -- -n (-n after -- is a path)" "$(bash_payload 'git rm -f -- -n')"
test_deny  "$IRRECOVERABLE" "GH #563: git rm -nf --no-dry-run (last one wins)" "$(bash_payload 'git rm -nf --no-dry-run a.py')"
test_deny  "$IRRECOVERABLE" "GH #563: git rm -f still denies" "$(bash_payload 'git rm -f a.py')"

# GH #561 review of PR #571: the -c alias check ran the alias body against every later word once per
# alias pair (quadratic), so 4000 pairs and 4000 words (80 KB) took 9.3 s, past the 8 s hook timeout
# that allows. git keeps the last alias.<name>, so one map and one body scan is enough.
_alias_dos_cmd="$(python3 -c 'print("git" + " -c alias.p=status" * 4000 + " -c alias.p=\"push --force\" p origin main" + " a" * 4000)')"
_timed_case 'GH #561: 4000 -c alias pairs then 4000 words is judged in bounded time' 2 "$_alias_dos_cmd"
test_deny  "$IRRECOVERABLE" "GH #561: the last -c alias.p wins (push --force after status)" \
  "$(bash_payload 'git -c alias.p=status -c alias.p="push --force" p origin main')"
test_allow "$IRRECOVERABLE" "GH #561 control: the last -c alias.p wins (status after push --force)" \
  "$(bash_payload 'git -c alias.p="push --force" -c alias.p=status p origin main')"
# A bare `-c key` (no "=") sets key to true in git.
test_deny  "$IRRECOVERABLE" "GH #561: bare -c remote.origin.mirror (true) push" "$(bash_payload 'git -c remote.origin.mirror push origin')"
test_deny  "$IRRECOVERABLE" "GH #561: bare -cremote.origin.mirror (joined, true) push" "$(bash_payload 'git -cremote.origin.mirror push origin')"
test_allow "$IRRECOVERABLE" "GH #561 control: bare -c color.ui status" "$(bash_payload 'git -c color.ui status')"
test_allow "$IRRECOVERABLE" "GH #561 control: bare -c clean.requireForce (true) clean -dx stays the plain clean" \
  "$(bash_payload 'git -c clean.requireForce clean -dx')"
# --config-env=<key>=<envvar> reads the value from an env var the gate cannot see: the dangerous reading.
test_deny  "$IRRECOVERABLE" "GH #561: --config-env=alias.p=X p" "$(bash_payload 'git --config-env=alias.p=X p origin main')"
test_deny  "$IRRECOVERABLE" "GH #561: --config-env alias.p=X p (split form)" "$(bash_payload 'git --config-env alias.p=X p origin main')"
test_deny  "$IRRECOVERABLE" "GH #561: --config-env=remote.origin.mirror=X push" "$(bash_payload 'git --config-env=remote.origin.mirror=X push origin')"
test_deny  "$IRRECOVERABLE" "GH #561: --config-env=remote.origin.push=X push" "$(bash_payload 'git --config-env=remote.origin.push=X push origin')"
test_deny  "$IRRECOVERABLE" "GH #561: --config-env=clean.requireForce=X clean" "$(bash_payload 'git --config-env=clean.requireForce=X clean -dx')"
test_deny  "$IRRECOVERABLE" "GH #561: --config-env=gc.pruneExpire=X gc" "$(bash_payload 'git --config-env=gc.pruneExpire=X gc')"
test_allow "$IRRECOVERABLE" "GH #561 control: --config-env=user.name=N commit" "$(bash_payload 'git --config-env=user.name=N commit -m x')"
# A value built at run time ($X, $(...)) is unseen, the same as --config-env: deny, never read it as empty.
test_deny  "$IRRECOVERABLE" 'GH #561: -c alias.p="$X" p' "$(bash_payload 'git -c alias.p="$X" p origin main')"
test_deny  "$IRRECOVERABLE" 'GH #561: -c alias.p="$(cat f)" p' "$(bash_payload 'git -c alias.p="$(cat f)" p origin main')"
test_deny  "$IRRECOVERABLE" 'GH #561: -c remote.origin.mirror="$(cat f)" push' "$(bash_payload 'git -c remote.origin.mirror="$(cat f)" push origin')"
test_deny  "$IRRECOVERABLE" 'GH #561: -c remote.origin.push="$(cat f)" push' "$(bash_payload 'git -c remote.origin.push="$(cat f)" push origin')"
test_deny  "$IRRECOVERABLE" 'GH #561: git config alias.p "$X"' "$(bash_payload 'git config alias.p "$X"')"
test_allow "$IRRECOVERABLE" "GH #561 control: a ! alias using its own \$1" \
  "$(bash_payload "git -c alias.l='!f() { git log -n \"\$1\"; }; f' l 5")"
# A dry run deletes nothing, bundled too (clean -xdn), as clean -n / --dry-run already were.
test_allow "$IRRECOVERABLE" "GH #561 control: requireForce=false clean -xdn (bundled dry run)" \
  "$(bash_payload 'git -c clean.requireForce=false clean -xdn')"
test_allow "$IRRECOVERABLE" "GH #561 control: git clean -n" "$(bash_payload 'git clean -n')"
# --unset's trailing word is a value-pattern that picks entries to remove, not a value written.
test_allow "$IRRECOVERABLE" "GH #561 control: git config --unset remote.origin.push +HEAD:main" \
  "$(bash_payload 'git config --unset remote.origin.push +HEAD:main')"
test_allow "$IRRECOVERABLE" "GH #561 control: git config --unset-all remote.origin.push +HEAD:main" \
  "$(bash_payload 'git config --unset-all remote.origin.push +HEAD:main')"
test_allow "$IRRECOVERABLE" "GH #561 control: git config unset remote.origin.push +HEAD:main" \
  "$(bash_payload 'git config unset remote.origin.push +HEAD:main')"
test_allow "$IRRECOVERABLE" "GH #561 control: git config --get remote.origin.push +HEAD (value-pattern)" \
  "$(bash_payload 'git config --get remote.origin.push +HEAD')"
test_deny  "$IRRECOVERABLE" "GH #561: git config --add remote.origin.push +HEAD:main" \
  "$(bash_payload 'git config --add remote.origin.push +HEAD:main')"
test_deny  "$IRRECOVERABLE" "GH #561: git config set remote.origin.mirror true" "$(bash_payload 'git config set remote.origin.mirror true')"
# Ordinary config use stays allowed.
test_allow "$IRRECOVERABLE" "GH #561 control: -c alias.co=checkout co -b feat" "$(bash_payload 'git -c alias.co=checkout co -b feat')"
test_allow "$IRRECOVERABLE" "GH #561 control: git config --get remote.origin.mirror" "$(bash_payload 'git config --get remote.origin.mirror')"
test_allow "$IRRECOVERABLE" "GH #561 control: git config alias.st status" "$(bash_payload 'git config alias.st status')"
# Round 2 review of the hotfix. git config stops reading options at its first plain word, so an
# option after KEY VALUE is more value and git still writes (checked on git 2.43).
test_deny  "$IRRECOVERABLE" "GH #561 r2: git config alias.p 'push --force' -l still writes" \
  "$(bash_payload 'git config alias.p "push --force" -l')"
test_deny  "$IRRECOVERABLE" "GH #561 r2: git config remote.origin.push +HEAD:main --unset still writes" \
  "$(bash_payload 'git config remote.origin.push +HEAD:main --unset')"
# The clean dry-run exemption reads clean's options in order: -e/--exclude takes a value, -- ends options.
test_deny  "$IRRECOVERABLE" "GH #561 r2: requireForce=false clean -xd -e -xdn (-xdn is -e's value)" \
  "$(bash_payload 'git -c clean.requireForce=false clean -xd -e -xdn')"
test_deny  "$IRRECOVERABLE" "GH #561 r2: requireForce=false clean -xd -- -xdn (-xdn is a path)" \
  "$(bash_payload 'git -c clean.requireForce=false clean -xd -- -xdn')"
test_deny  "$IRRECOVERABLE" "GH #561 r2: requireForce=false clean -xd -e -n (-n is -e's value)" \
  "$(bash_payload 'git -c clean.requireForce=false clean -xd -e -n')"
test_deny  "$IRRECOVERABLE" "GH #561 r2: requireForce=false clean -xd --exclude -n" \
  "$(bash_payload 'git -c clean.requireForce=false clean -xd --exclude -n')"
test_allow "$IRRECOVERABLE" "GH #561 r2 control: requireForce=false clean -xd -eFOO -n" \
  "$(bash_payload 'git -c clean.requireForce=false clean -xd -eFOO -n')"
test_allow "$IRRECOVERABLE" "GH #561 r2 control: requireForce=false clean --exclude=x -n" \
  "$(bash_payload 'git -c clean.requireForce=false clean --exclude=x -n')"
# A non-! alias resolves to its expansion (chains followed, bounded), and every rule reads the resolved verb.
test_deny  "$IRRECOVERABLE" "GH #561 r2: alias chain p -> q -> push --force" \
  "$(bash_payload 'git -c alias.q="push --force" -c alias.p=q p origin main')"
test_deny  "$IRRECOVERABLE" "GH #561 r2: alias p=push with remote.origin.mirror" \
  "$(bash_payload 'git -c alias.p=push -c remote.origin.mirror p origin')"
test_deny  "$IRRECOVERABLE" "GH #561 r2: alias p=clean with requireForce=false" \
  "$(bash_payload 'git -c alias.p=clean -c clean.requireForce=false p -dx')"
test_allow "$IRRECOVERABLE" "GH #561 r2 control: alias chain p -> q -> status" \
  "$(bash_payload 'git -c alias.q=status -c alias.p=q p')"
test_allow "$IRRECOVERABLE" "GH #561 r2 control: an alias loop p -> p (git errors)" "$(bash_payload 'git -c alias.p=p p')"
# An empty boolean is false in git: clean then runs without -f.
test_deny  "$IRRECOVERABLE" 'GH #561 r2: git config clean.requireForce ""' "$(bash_payload 'git config clean.requireForce ""')"
test_deny  "$IRRECOVERABLE" "GH #561 r2: -c clean.requireForce= clean -dx" "$(bash_payload 'git -c clean.requireForce= clean -dx')"
test_allow "$IRRECOVERABLE" "GH #561 r2 control: git config clean.requireForce true" "$(bash_payload 'git config clean.requireForce true')"
# Round 3 review: git always runs a built-in and ignores an alias of the same name, so the risk keys
# are checked against the typed verb and every verb along the alias chain; any deny wins.
test_deny  "$IRRECOVERABLE" "GH #561 r3: alias.clean='clean -n' does not shadow clean (requireForce=false)" \
  "$(bash_payload "git -c alias.clean='clean -n' -c clean.requireForce=false clean -dx")"
test_deny  "$IRRECOVERABLE" "GH #561 r3: alias.push=status does not shadow push (mirror)" \
  "$(bash_payload 'git -c alias.push=status -c remote.origin.mirror=true push origin')"
test_deny  "$IRRECOVERABLE" "GH #561 r3: alias.push=status does not shadow push (+HEAD:main refspec)" \
  "$(bash_payload 'git -c alias.push=status -c remote.origin.push=+HEAD:main push origin')"
test_deny  "$IRRECOVERABLE" "GH #561 r3: alias.gc=status does not shadow gc (pruneExpire=now)" \
  "$(bash_payload 'git -c alias.gc=status -c gc.pruneExpire=now gc')"
test_deny  "$IRRECOVERABLE" "GH #561 r3: alias p='push --force' then alias.push=status still force-pushes" \
  "$(bash_payload 'git -c alias.p="push --force" -c alias.push=status p origin main')"
test_allow "$IRRECOVERABLE" "GH #561 r3 control: alias.push=status push origin" "$(bash_payload 'git -c alias.push=status push origin')"
# A chain past the 10-step bound is unseen (git follows it); a loop is an error in git and runs nothing.
_long_chain="git$(for k in $(seq 0 11); do printf ' -c alias.a%s=a%s' "$k" "$((k + 1))"; done) -c alias.a12='push --force' a0 origin main"
test_deny  "$IRRECOVERABLE" "GH #561 r3: a 13-step alias chain to push --force" "$(bash_payload "$_long_chain")"
test_allow "$IRRECOVERABLE" "GH #561 r3 control: an alias loop p -> q -> p" "$(bash_payload 'git -c alias.p=q -c alias.q=p p')"
_alias_loop_cmd="$(python3 -c 'print("git -c alias.p=\"p" + " a" * 71000 + "\" p")')"
_timed_case 'GH #561 r3: a 142 KB self-looping alias is judged in bounded time' 0 "$_alias_loop_cmd"
# A ! alias runs its shell line with the -c keys in effect (git passes them in GIT_CONFIG_PARAMETERS).
test_deny  "$IRRECOVERABLE" "GH #561 r3: a ! alias runs git push under remote.origin.mirror=true" \
  "$(bash_payload "git -c remote.origin.mirror=true -c alias.p='!git push' p")"
test_allow "$IRRECOVERABLE" "GH #561 r3 control: a ! alias with no risky key" "$(bash_payload "git -c alias.p='!git status' p")"
# The last of -n/--dry-run and --no-dry-run wins.
test_deny  "$IRRECOVERABLE" "GH #561 r3: requireForce=false clean -n --no-dry-run -dx" \
  "$(bash_payload 'git -c clean.requireForce=false clean -n --no-dry-run -dx')"
test_allow "$IRRECOVERABLE" "GH #561 r3 control: requireForce=false clean --no-dry-run -n" \
  "$(bash_payload 'git -c clean.requireForce=false clean --no-dry-run -n')"

# Bypass hunt 2026-10-23 F5: `find | xargs rm` is the same delete as `find -exec rm` (denied with no
# flags at all), but the xargs re-point handed it to the rm-rf rule, which needs both -r and -f.
for _c in \
  'find . -type f | xargs rm' \
  'find . -print0 | xargs -0 rm' \
  "find . -name '*.bak' | xargs -I{} rm {}" \
  'fd -t f | xargs rm' \
  'git ls-files | xargs rm -f' \
  'find . | xargs -n 10 rm' \
  'find . | xargs /bin/rm' \
  'find . | xargs sudo rm' \
  'xargs rm < files.txt' \
  "bash -c 'find . | xargs rm'" \
  "find . | xargs -d'\\n' rm" \
  'find . | xargs -Is rm s' \
  'find . | xargs nice -n 5 rm' \
  'find . | xargs timeout 5 rm' \
  'find . | xargs env FOO=1 rm' \
  'find . | xargs sudo -u bob rm' ; do
  test_deny "$IRRECOVERABLE" "bypass hunt F5: xargs rm deletes every path it is fed: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'git ls-files | xargs grep -l rm' \
  'xargs grep rm src < files.txt' \
  "find . -name '*.o' | xargs ls -l" \
  'echo a | xargs echo rm' \
  'find . | xargs -I{} echo rm {}' \
  'find . -type d -empty | xargs rmdir' \
  'find . -name x | xargs wc -l' \
  'ls | xargs sudo -u rm ls' \
  'ls | xargs env -u rm ls' \
  "ls | xargs -d '\\n' ls" \
  'ls | xargs -a rm ls' ; do
  test_allow "$IRRECOVERABLE" "bypass hunt F5 control: xargs runs something else: $_c" "$(bash_payload "$_c")"
done

# The same xargs flag walk finds gh (review of the F5 fix): an attached -d value hid it.
test_ask_says "$IRRECOVERABLE" "bypass hunt F5 review: xargs -d'\\n' gh pr merge still asks" \
  "$(bash_payload "ls | xargs -d'\\n' gh pr merge 1 --admin")" "gh pr merge"

# GH #562 follow-up: PR #572 regressed an empty value to a read. The token window drops an empty word, and the
# word window's git scan dropped it too, so `core.hooksPath ""` read as the key alone. An empty hooksPath
# unwires every hook. Removing or renaming the core section drops core.hooksPath without naming it.
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" (empty value unwires every hook)" "$(bash_payload 'git config core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath '' (single-quoted empty value)" "$(bash_payload "git config core.hooksPath ''")"
test_deny  "$IRRECOVERABLE" "GH #562: git config set core.hooksPath \"\"" "$(bash_payload 'git config set core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --replace-all core.hooksPath \"\"" "$(bash_payload 'git config --replace-all core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" git-hooks (git-hooks is the value-pattern)" "$(bash_payload 'git config core.hooksPath "" git-hooks')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section core" "$(bash_payload 'git config --remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config remove-section core" "$(bash_payload 'git config remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section Core (section names ignore case)" "$(bash_payload 'git config --remove-section Core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rem core (unique prefix)" "$(bash_payload 'git config --rem core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section core x" "$(bash_payload 'git config --rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config rename-section core x" "$(bash_payload 'git config rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section x core (renaming onto core writes it)" "$(bash_payload 'git config --rename-section x core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --file .git/config --remove-section core" "$(bash_payload 'git config --file .git/config --remove-section core')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config get core.hooksPath" "$(bash_payload 'git config get core.hooksPath')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --remove-section alias" "$(bash_payload 'git config --remove-section alias')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --rename-section alias x" "$(bash_payload 'git config --rename-section alias x')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --get core.hooksPath \"\" (a value-pattern on a read)" "$(bash_payload 'git config --get core.hooksPath ""')"
_hp_pad_cmd="git config core.hooksPath git-hooks$(python3 -c 'print(" \"\"" * 46000)')"
_timed_case 'GH #562: a 140 KB run of empty words after core.hooksPath is denied in bounded time' 2 "$_hp_pad_cmd"

# GH #562 round 2: git runs no hooks with an empty core.hooksPath (git 2.43, a marker pre-commit hook in a
# throwaway repo), so a -c pair with an empty value is the same bypass; the rows above use /tmp/evil.
test_deny  "$IRRECOVERABLE" "GH #562: git -c \"core.hooksPath=\" commit (quoted)" "$(bash_payload 'git -c "core.hooksPath=" commit -m x')"
test_deny  "$IRRECOVERABLE" "GH #562: git --config-env=core.hooksPath=V commit still denies" "$(bash_payload 'git --config-env=core.hooksPath=V commit -m x')"
test_deny  "$IRRECOVERABLE" "GH #562: GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0= still denies" "$(bash_payload 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0= git commit -m x')"
# A section name built at run time counts only when its literal prefix can still become core.
test_allow "$IRRECOVERABLE" "GH #562 control: --rename-section alias \"x\$Y\" (cannot become core)" "$(bash_payload 'git config --rename-section alias "x$Y"')"
test_allow "$IRRECOVERABLE" "GH #562 control: --remove-section alias\$(date) (cannot become core)" "$(bash_payload 'git config --remove-section alias$(date)')"
test_deny  "$IRRECOVERABLE" "GH #562: --remove-section \"\$S\" (may be core)" "$(bash_payload 'git config --remove-section "$S"')"
test_deny  "$IRRECOVERABLE" "GH #562: --remove-section co\$X (may be core)" "$(bash_payload 'git config --remove-section co$X')"
test_deny  "$IRRECOVERABLE" "GH #562: --rename-section alias C\$(echo ore) (may be core)" "$(bash_payload 'git config --rename-section alias C$(echo ore)')"

# Empty config values (git 2.43, live-checked): git reads an empty boolean as false, so a stored
# `clean.requireForce ""` lets a later bare `git clean` delete; the git scan dropped the empty word, so the
# write read as a key alone. An empty `-c core.hooksPath=` skips every hook (the commit lands past a failing
# pre-commit); the -c check required a non-empty value.
test_deny  "$IRRECOVERABLE" "empty value: git config clean.requireForce \"\"" "$(bash_payload 'git config clean.requireForce ""')"
test_deny  "$IRRECOVERABLE" "empty value: git config clean.requireForce ''" "$(bash_payload "git config clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config set clean.requireForce \"\"" "$(bash_payload 'git config set clean.requireForce ""')"
test_deny  "$IRRECOVERABLE" "empty value: git config clean.requireForce \"\$(true)\" (blanks to empty)" \
  "$(bash_payload 'git config clean.requireForce "$(true)"')"
# The write forms that skip options before the key (_git_config_write's options()) see the empty word too.
test_deny  "$IRRECOVERABLE" "empty value: git config --add clean.requireForce ''" "$(bash_payload "git config --add clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --replace-all clean.requireForce ''" "$(bash_payload "git config --replace-all clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --global clean.requireForce ''" "$(bash_payload "git config --global clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --file .git/config clean.requireForce ''" "$(bash_payload "git config --file .git/config clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --type=bool clean.requireForce ''" "$(bash_payload "git config --type=bool clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git -c core.hooksPath= commit" "$(bash_payload 'git -c core.hooksPath= commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git -c core.hooksPath=\"\" commit" "$(bash_payload 'git -c core.hooksPath="" commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git -ccore.hooksPath= commit (joined)" "$(bash_payload 'git -ccore.hooksPath= commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git --config-env=core.hooksPath= commit" "$(bash_payload 'git --config-env=core.hooksPath= commit -m x')"
test_allow "$IRRECOVERABLE" "empty value control: git config user.name \"\"" "$(bash_payload 'git config user.name ""')"
test_allow "$IRRECOVERABLE" "empty value control: git config clean.requireForce true" "$(bash_payload 'git config clean.requireForce true')"
test_allow "$IRRECOVERABLE" "empty value control: git -c user.name= commit" "$(bash_payload 'git -c user.name= commit -m x')"
# A risk key whose empty value is git's false is safe: remote.<name>.mirror "" is no mirror.
test_allow "$IRRECOVERABLE" "empty value control: git config remote.origin.mirror ''" "$(bash_payload "git config remote.origin.mirror ''")"

# GH #563 follow-up review of PR #573: send-pack's -f is --force (bundled too); git rm reads its
# options in order with last-wins for each pair (--cached/--no-cached, -n/--no-dry-run, -f/--no-force),
# stops at "--", and --pathspec-from-file takes the next word; branch -f bundled with -m/-c onto main.
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: send-pack -f overwrites like --force" "$(bash_payload 'git send-pack -f url main')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: send-pack -vf (bundled force)" "$(bash_payload 'git send-pack -vf url main')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: send-pack -qf --all (bundled force)" "$(bash_payload 'git send-pack -qf --all url')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: send-pack url HEAD:main (no force)" "$(bash_payload 'git send-pack url HEAD:main')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm --pathspec-from-file -n -f (-n is the file)" "$(bash_payload 'git rm --pathspec-from-file -n -f')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm --cached --no-cached -f (last one wins)" "$(bash_payload 'git rm --cached --no-cached -f a.py')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up: git rm -- -f (-f after -- is a path)" "$(bash_payload 'git rm -- -f')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up: git rm --no-dry-run -nf (the later -n wins)" "$(bash_payload 'git rm --no-dry-run -nf a.py')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git rm --no-cached --cached -f (last one wins)" "$(bash_payload 'git rm --no-cached --cached -f a.py')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git rm -f --no-force" "$(bash_payload 'git rm -f --no-force a.py')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm a.py -f (an option after a path)" "$(bash_payload 'git rm a.py -f')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm --pathspec-from-file=l -f" "$(bash_payload 'git rm --pathspec-from-file=l -f')"
for _c in 'git branch -fm feat main' 'git branch -mf feat main' 'git branch -fc feat main' 'git branch -cf feat main' 'git branch -vfm feat master'; do
  test_deny  "$IRRECOVERABLE" "GH #563 follow-up: $_c (bundled force move/copy onto main)" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git branch -f feat HEAD" "$(bash_payload 'git branch -f feat HEAD')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git branch -m old new" "$(bash_payload 'git branch -m old new')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git branch -fm old new" "$(bash_payload 'git branch -fm old new')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm -f --end-of-options -n (-n is a path)" "$(bash_payload 'git rm -f --end-of-options -n')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up: git rm --end-of-options -f (-f is a path)" "$(bash_payload 'git rm --end-of-options -f')"
_rm_pad_cmd="$(python3 -c 'print("git rm " + "-n --no-dry-run --cached --no-cached " * 3800 + "-f a.py")')"
_timed_case 'GH #563 follow-up: a 140 KB git rm option list is read in bounded time' 2 "$_rm_pad_cmd"

# GH #584 (bypass hunt 2026-10-23 F6): only `docker exec <flags> <container> <cmd>` re-pointed argv0 to
# the command run inside, so SQL (or any rule) behind compose or kubectl passed; so did a docker exec
# value flag (`-u postgres` read as the container) and a shell body run in the container.
for _c in \
  "docker compose exec db psql -c 'DROP TABLE users'" \
  "docker compose -f prod.yml exec -T db psql -c 'DROP TABLE users'" \
  "docker-compose exec db mysql -e 'DROP DATABASE prod'" \
  "kubectl exec db -- psql -c 'DROP TABLE users'" \
  "kubectl -n prod exec -it db-0 -c pg -- psql -c 'DROP TABLE users'" \
  "kubectl exec db-0 -n prod -- sh -c \"psql -c 'DROP TABLE users'\"" \
  "kubectl exec db -- rm -rf /data" \
  "docker exec -u postgres db psql -c 'DROP TABLE users'" \
  "docker exec -e PGPASSWORD=x -w /tmp db psql -c 'DROP TABLE users'" \
  "docker exec db sh -c 'rm -rf /data'" \
  "podman exec db psql -c 'DROP TABLE users'" \
  "docker exec db env PGPASSWORD=x psql -c 'DROP TABLE users'" \
  "docker exec db sudo -u postgres psql -c 'DROP TABLE users'" \
  'docker exec db timeout 5 rm -rf /data' \
  'kubectl exec db -- env A=1 rm -rf /data' \
  "docker exec -itu postgres db psql -c 'DROP TABLE users'" \
  'docker --tlscacert ca.pem exec db rm -rf /data' \
  'podman --runtime crun exec db rm -rf /data' \
  'kubectl -v 9 exec db -- rm -rf /data' ; do
  test_deny "$IRRECOVERABLE" "GH #584: a rule's command run inside a container: $_c" "$(bash_payload "$_c")"
done
for _c in \
  "docker compose exec db psql -c 'select 1'" \
  "kubectl exec db -- psql -c 'select 1'" \
  'kubectl exec db -- ls /data' \
  "docker compose exec db echo 'DROP TABLE users'" \
  'docker compose logs db' \
  'kubectl get pods -n prod' \
  'docker exec -u postgres db ls' ; do
  test_allow "$IRRECOVERABLE" "GH #584 control: nothing destructive runs in the container: $_c" "$(bash_payload "$_c")"
done


# GH #585 (bypass hunt 2026-10-23 F8): dd-device matched the literal prefix `of=/dev/` on argv0 `dd`.
for _c in \
  'dd if=x of=//dev/disk2' \
  'dd if=x of=/./dev/disk2' \
  'dd if=x of=/dev//disk2' \
  'gdd if=/dev/zero of=/dev/disk2' \
  'sudo gdd if=x of=/dev/rdisk2' \
  '/opt/homebrew/bin/gdd if=x of=/dev/disk2' \
  'dd of=/dev/$DISK' \
  'sudo dd if=img of=/dev/rdisk${N} bs=4m' \
  'dd of="/dev/disk$N"' \
  'dd of=/dev/$(echo disk2)' \
  'find /dev -name sda | xargs gdd if=/dev/zero of=/dev/sda' ; do
  test_deny "$IRRECOVERABLE" "GH #585: dd to a raw device by another spelling: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'dd if=x of=$DISK' \
  'dd if=x of="$DISK"' \
  'dd if=x of=${TARGET}' \
  'dd if=x of=${HOME}/disk.img' \
  'dd if=x of=$PWD/../../dev/sda' ; do
  test_ask_says "$IRRECOVERABLE" "GH #585: dd to a target the text does not show asks: $_c" "$(bash_payload "$_c")" "dd"
done
for _c in \
  'dd if=/dev/zero of=out.img bs=1m count=1' \
  'dd if=disk.img of=copy.img' \
  'dd if=/dev/disk2 of=backup.img' \
  'dd if=x of=./dev/disk2' \
  'gdd if=x of=y.img' \
  'echo of=$DISK' \
  'dd if=/dev/zero of=/dev/null bs=1m count=100' \
  'dd if=x of=/dev/stdout' \
  'dd if=x of=$PWD/out.img' \
  'dd if=x of="$TMPDIR/out.img"' \
  'dd if=x of=$HOME/disk.img' ; do
  test_allow "$IRRECOVERABLE" "GH #585 control: dd to a file, or no dd: $_c" "$(bash_payload "$_c")"
done

# GH #562 follow-up: PR #572 regressed an empty value to a read. The token window drops an empty word, and the
# word window's git scan dropped it too, so `core.hooksPath ""` read as the key alone. An empty hooksPath
# unwires every hook. Removing or renaming the core section drops core.hooksPath without naming it.
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" (empty value unwires every hook)" "$(bash_payload 'git config core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath '' (single-quoted empty value)" "$(bash_payload "git config core.hooksPath ''")"
test_deny  "$IRRECOVERABLE" "GH #562: git config set core.hooksPath \"\"" "$(bash_payload 'git config set core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --replace-all core.hooksPath \"\"" "$(bash_payload 'git config --replace-all core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" git-hooks (git-hooks is the value-pattern)" "$(bash_payload 'git config core.hooksPath "" git-hooks')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section core" "$(bash_payload 'git config --remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config remove-section core" "$(bash_payload 'git config remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section Core (section names ignore case)" "$(bash_payload 'git config --remove-section Core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rem core (unique prefix)" "$(bash_payload 'git config --rem core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section core x" "$(bash_payload 'git config --rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config rename-section core x" "$(bash_payload 'git config rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section x core (renaming onto core writes it)" "$(bash_payload 'git config --rename-section x core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --file .git/config --remove-section core" "$(bash_payload 'git config --file .git/config --remove-section core')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config get core.hooksPath" "$(bash_payload 'git config get core.hooksPath')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --remove-section alias" "$(bash_payload 'git config --remove-section alias')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --rename-section alias x" "$(bash_payload 'git config --rename-section alias x')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config user.name \"\" (empty value, unrelated key)" "$(bash_payload 'git config user.name ""')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --get core.hooksPath \"\" (a value-pattern on a read)" "$(bash_payload 'git config --get core.hooksPath ""')"
_hp_pad_cmd="git config core.hooksPath git-hooks$(python3 -c 'print(" \"\"" * 46000)')"
_timed_case 'GH #562: a 140 KB run of empty words after core.hooksPath is denied in bounded time' 2 "$_hp_pad_cmd"

# GH #586 (bypass hunt 2026-10-23 F9): find-exec-rm needed an `rm` word among find's own words, and
# find-delete compared a word to `-delete` exactly.
for _c in \
  "find . -exec sh -c 'rm \"\$1\"' _ {} \;" \
  "find . -exec bash -c 'rm -- \"\$0\"' {} \;" \
  "find . -execdir sh -c 'rm {}' \;" \
  "find . -exec sh -c 'echo \"\$1\"; rm \"\$1\"' _ {} \;" \
  "find . -exec sh -c 'sudo rm \"\$1\"' _ {} +" \
  'find . -$(echo delete)' \
  'find . -de$(echo l)ete' \
  'find . -$(echo exec) rm {} \;' \
  "find . -exec echo {} \\; -exec sh -c 'rm \"\$1\"' _ {} \\;" \
  'find . -exec cat {} \; -delete' \
  'find . -exec echo {} \; -exec rm -rf {} \;' \
  'find . -exec find {} -exec rm {} \; \;' \
  "find . -exec sh -c 'for f do rm \"\$f\"; done' _ {} +" \
  "find . -exec sh -c 'sh -c \"rm \\\$1\"' _ x \\;" \
  "find . -exec sh -c 'eval rm \"\$1\"' _ {} \\;" \
  "find . -exec sh -c 'busybox rm \"\$1\"' _ {} \\;" \
  'find . -name x | xargs -I {} rm {}' \
  'find . -name -name -delete' \
  'find . -name -size -delete' \
  'find . -printf -name -delete' \
  'find . -name x -name -name -delete' \
  'find . -iname -path -execdir rm {} +' \
  'find . -exec cat {} \;>/dev/null -delete' \
  'find . -exec cat {} \;2>/dev/null -delete' \
  'find . -exec cat {}>/dev/null \; -delete' \
  'find . -fprintf f -name -delete' \
  'find . -fprintf f -name -exec rm {} \;' \
  'find . -newerma -name -delete' \
  'find . -newerBt -iname -delete' \
  'find . -files0-from -name -delete' ; do
  test_deny "$IRRECOVERABLE" "GH #586: find deletes through a shell body or a spliced action: $_c" "$(bash_payload "$_c")"
done
for _c in \
  "find . -exec sh -c 'echo \"\$1\"' _ {} \;" \
  "find . -exec sh -c 'grep -l rm \"\$1\"' _ {} \;" \
  "find . -name '*.sh' -exec sh -n {} \;" \
  'find . -name "$(cat pattern)"' \
  'find . -newer x -exec ls {} \;' \
  'find . -name x -print' \
  'find . -name "-$(date +%s)" -print' \
  'find . -newer "-$(cat f)" -print' \
  "find . -exec sh -c 'for f do echo \"\$f\"; done' _ {} +" \
  "find . -ok sh -c 'rm \"\$1\"' _ {} \\;" \
  'find . -exec echo {} \; -print' ; do
  test_allow "$IRRECOVERABLE" "GH #586 control: find runs no delete: $_c" "$(bash_payload "$_c")"
done

# GH #607: the rest of the data-destroying client commands, on argv and on stdin.
test_deny  "$IRRECOVERABLE" "GH #607: DELETE FROM with no WHERE" "$(bash_payload "psql -c 'DELETE FROM users'")"
test_deny  "$IRRECOVERABLE" "GH #607: UPDATE SET with no WHERE" "$(bash_payload "psql -c 'UPDATE users SET pw = NULL'")"
test_deny  "$IRRECOVERABLE" "GH #607: DROP INDEX" "$(bash_payload "mysql -e 'DROP INDEX i ON t'")"
test_deny  "$IRRECOVERABLE" "GH #607: DELETE FROM echoed into psql" "$(bash_payload "echo 'DELETE FROM t' | psql db")"
test_deny  "$IRRECOVERABLE" "GH #607: mongosh dropDatabase" "$(bash_payload "mongosh --eval 'db.dropDatabase()'")"
test_deny  "$IRRECOVERABLE" "GH #607: mongo deleteMany({})" "$(bash_payload "mongo --eval 'db.users.deleteMany({})'")"
test_deny  "$IRRECOVERABLE" "GH #607: redis-cli FLUSHALL" "$(bash_payload 'redis-cli FLUSHALL')"
test_ask   "$IRRECOVERABLE" "GH #607: rsync --delete asks" "$(bash_payload 'rsync -a --delete src/ dst/')"
test_allow "$IRRECOVERABLE" "GH #607 control: DELETE with WHERE" "$(bash_payload "psql -c 'DELETE FROM users WHERE id = 1'")"
test_allow "$IRRECOVERABLE" "GH #607 control: UPDATE with WHERE on the next line" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nUPDATE t SET a = 1\nWHERE id = 3;\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #607 control: mysql FLUSH PRIVILEGES" "$(bash_payload "mysql -e 'FLUSH PRIVILEGES'")"
test_allow "$IRRECOVERABLE" "GH #607 control: mongosh deleteMany with a filter" "$(bash_payload "mongosh --eval 'db.users.deleteMany({age: 3})'")"
test_allow "$IRRECOVERABLE" "GH #607 control: rsync without --delete" "$(bash_payload 'rsync -a src/ dst/')"
_timed_case 'GH #607: 10000 UPDATE ... SET words before a WHERE are read in bounded time' 2 \
  "psql -c '$(python3 -c "print('UPDATE t SET ' * 10000 + 'WHERE x')")'"

# GH #587 (bypass hunt 2026-10-23 F10): chmod-world's root-or-home test knew only `/` and `~` (and
# their `/*`, `/.` forms); a find action applies the mode to every file it finds, as -R does.
for _c in \
  'chmod 777 $HOME' \
  'chmod 777 "$HOME"' \
  'chmod a+rwx $HOME/' \
  'chmod 777 ${HOME}' \
  'chmod 777 "${HOME}"' \
  'chmod 777 "${HOME:-}"' \
  'chmod 777 ${HOME%/}' \
  'echo hi; chmod 777 ${HOME}' \
  $'chmod 777 \\\n${HOME}' \
  $'chmod 777 \\\n"${HOME}"' \
  'chmod 777 ${HOME}>/dev/null' \
  "bash -c 'chmod 777 \"\${HOME}\"'" \
  'chmod 777 ${HOME}/' \
  'chmod 777 $HOME/./' \
  'chmod 777 $HOME//' \
  'chmod 777 ~/./' \
  "find . -exec sh -c 'chmod 777 \"\$1\"' _ {} \\;" \
  "find . -exec bash -c 'sudo chmod -R a+rwx \"\$0\"' {} \\;" \
  "chmod 777 $HOME" \
  "chmod -R 777 $HOME/" \
  'chmod 777 //' \
  'find . -exec chmod 777 {} +' \
  'find . -type f -execdir chmod a+rwx {} \;' \
  'find . -exec sudo chmod 0777 {} +' \
  'gchmod -R 777 .' \
  '/opt/homebrew/bin/gchmod 777 /' ; do
  test_deny "$IRRECOVERABLE" "GH #587: chmod 777 on home, root or every file find yields: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'chmod 777 f' \
  'chmod 777 $HOME/f' \
  "chmod 777 $HOME/project/run.sh" \
  'chmod 755 $HOME' \
  'chmod -R 755 .' \
  'find . -exec chmod 644 {} +' \
  'find . -name "*.sh" -exec chmod +x {} \;' \
  'gchmod 644 f' \
  'chmod 777 ${HOME}/f' \
  'chmod 777 $HOME/./f' \
  'chmod 777 "$(mktemp)"; echo ${HOME}' \
  'chmod 777 $(mktemp) && ls ${HOME}' \
  'chmod 777 `pwd`; echo ${HOME}' \
  'chmod 777 ${PWD}; echo ${HOME}' \
  "find . -exec sh -c 'chmod 644 \"\$1\"' _ {} \\;" \
  'echo chmod 777 $HOME' ; do
  test_allow "$IRRECOVERABLE" "GH #587 control: chmod that is not world-writable on home, root or a find set: $_c" "$(bash_payload "$_c")"
done


# GH #606, #611 review: the -i exception of rule rm-recursive holds only when rm prompts per file
# and nothing in the command can answer. Finding 1: the command feeds rm's stdin (a pipe, <, <<,
# <<<, <&, a heredoc, a coproc), read over the whole command since a group, loop or shell body
# passes its stdin on. Finding 2: the last of -f/-i/-I/--interactive[=WHEN] wins, as GNU rm reads
# them. Finding 3: a -i after -- is a filename. #636 review: options end at the first operand, as BSD/macOS rm
# and GNU rm under POSIXLY_CORRECT read them (operator decision), so a -i after an operand grants nothing
# (`rm -r build -i` deletes build there), while a later -f/-I/--interactive=never still voids it (GNU
# permutes); an interpreter one-liner's process API can feed stdin itself; a terminal driver counts only as
# a command word, not a path part.
for _c in \
  'yes | rm -ri build' \
  'rm -ri build <<< "$(yes | head -1000)"' \
  'rm -ri build < answers.txt' \
  'rm -ri build 0<answers.txt' \
  'rm -ri build <&3' \
  $'rm -ri build <<EOF\ny\ny\nEOF' \
  'yes |& rm -ri build' \
  'yes | (rm -ri build)' \
  '{ rm -ri build; } <<< y' \
  'while :; do rm -ri build; done < answers.txt' \
  "yes | bash -c 'rm -ri build'" \
  "bash -c 'rm -ri build <<< y'" \
  'exec 0<answers.txt; rm -ri build' \
  $'eval $\'yes \\x7c rm -ri build\'' \
  'coproc rm -ri build; yes >&"${COPROC[1]}"' \
  'rm -ri --interactive=never build' \
  'rm -ri -I build' \
  'rm -i -rI build' \
  'rm -ri --interactive=once build' \
  'rm -ri --inter=never build' \
  'rm -ri --interactive=n build' \
  'rm -ri --interactive=no build' \
  'rm -ri --interactive=o build' \
  'rm -ri --interactive= build' \
  'rm -ri --interactive=bogus build' \
  'rm -rfi build' \
  'rm -ri -f build' \
  'rm -ri "$OPTS" build' \
  'rm -ri $(printf %s -f) build' \
  'rm -r -- -i build' \
  'rm -r build -- -i' \
  'POSIXLY_CORRECT=1 rm -r build -i' \
  'rm -r build -i' \
  'rm -r build --interactive' \
  'rm -rI build -i' \
  'rm -ri build -f' \
  'rm -ri build -I' \
  'rm -ri build --interactive=never' \
  'script -qc "rm -ri build" /dev/null' \
  'unbuffer rm -ri build' \
  'sudo expect -f answer.exp; rm -ri build' \
  "python3 -c \"import subprocess; subprocess.run(['rm','-ri','build'], input=b'y\\n'*99)\"" \
  "node -e \"require('child_process').execSync('rm -ri build', {input: 'y\\n'.repeat(99)})\"" \
  "perl -e 'system(\"rm -ri build\")'" ; do
  test_deny "$IRRECOVERABLE" "GH #606/#611 review: rm -r with no per-file prompt nothing answers: $_c" "$(bash_payload "$_c")"
done
# xargs rm already denies whatever its flags (rule xargs-rm); GNU xargs gives rm /dev/null as stdin
# unless -a or -o, so it would answer no, but the rule stays.
for _c in 'echo build | xargs rm -ri' 'xargs -a list.txt rm -ri' 'find . -name build -exec rm -ri {} +' ; do
  test_deny "$IRRECOVERABLE" "GH #606/#611 review confirm: xargs/find hand rm its paths: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'rm -ri build' \
  'rm -ri build/script' \
  'rm -ri tmux' \
  'rm -ri ./expect screen' \
  'rm -ri build; echo script done' \
  'rm -rI -i build' \
  'rm -r --interactive build' \
  'rm -r --interactive=always build' \
  'rm -r --interactive=a build' \
  'rm -r --interactive=yes build' \
  'rm -r --inter build' \
  'rm -r -I --interactive=always build' \
  'rm -ri build > log.txt 2>&1' \
  'rm -ri -- build' \
  'rm -i file.txt' \
  'rm file.txt' \
  'rm -d emptydir' \
  'git rm -r --cached dir' \
  'echo y | rm -i file.txt' \
  'yes | rm -f file.txt' ; do
  test_allow "$IRRECOVERABLE" "GH #606/#611 review control: per-file prompt nothing answers, or not recursive: $_c" "$(bash_payload "$_c")"
done

# GH #588 (bypass hunt 2026-10-23 F11): the spawn anchor reads the literal word `claude` at a command
# position, so a name made by a substitution, or claude run by a find action, passed.
for _c in \
  '$(echo claude) -p hi' \
  '`echo claude` -p hi' \
  '${C:-claude} -p hi' \
  "\$(echo claude) 'fix the test'" \
  'env $(echo claude) --print hi' \
  'find . -maxdepth 0 -exec claude -p hi \;' \
  'find . -exec env claude -p x \;' \
  'find . -exec claude hi \;' \
  'find . -name x -execdir claude --bg {} +' \
  'cat p | $(which claude)' \
  'echo hi | $(echo claude)' \
  '$(echo claude) <<< hi' \
  '$(echo /usr/local/bin/claude) -p x' \
  '${C:-"claude"} -p x' \
  'ls; $(echo claude) -p x' \
  '"$(echo claude)" "-p" x' \
  '"$(echo claude)" -p x' \
  'if $(echo claude) -p x; then :; fi' \
  '! $(echo claude) -p x' \
  'for i in 1; do $(echo claude) -p x; done' \
  'case x in x) $(echo claude) -p x;; esac' \
  'x=$(echo hi) $(echo claude) -p x' \
  'bash -c "\$(echo claude) -p x"' \
  'bash -c "$(echo claude) -p x"' \
  'eval "$(echo claude) -p x"' \
  'find . -exec $(echo claude) -p x \;' \
  'sh -c "echo hi; $(echo claude) -p x"' \
  'sh -c "x=1 $(echo claude) -p x"' \
  'sh -c "if true; then $(echo claude) -p x; fi"' \
  'bash -lc "$(echo claude) -p x"' \
  'bash -c  "$(echo claude) -p x"' \
  'eval $(echo claude) -p x' \
  'bash -o pipefail -c "$(echo claude) -p x"' \
  'bash -O extglob -c "$(echo claude) -p x"' \
  'bash --norc -c "$(echo claude) -p x"' \
  'bash +e -c "$(echo claude) -p x"' \
  'bash -c -- "$(echo claude) -p x"' \
  'bash -c "$(echo "claude") -p x"' \
  'bash -c "$(printf %s "claude") -p x"' \
  '\bash -c "$(echo claude) -p hi"' \
  'true; \sh -c "$(echo claude) -p hi"' \
  'bash -e -e -e -e -e -e -e -e -e -c "$(echo claude) -p x"' \
  'bash -o pipefail -o errexit -o nounset -O a -O b -O c -O d -O e -c "$(echo claude) -p x"' \
  'bash --rcfile /dev/null -c "$(echo claude) -p x"' \
  'bash --init-file x -c "$(echo claude) -p x"' \
  'bash +c "$(echo claude) -p x"' ; do
  test_deny "$IRRECOVERABLE" "GH #588: subagent spawn behind a substitution or a find action: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  '$(echo claude) --version' \
  '$(which claude) --help' \
  '$(cat claude.txt) -p x' \
  '$(git rev-parse --show-toplevel)/run.sh -p x' \
  'find . -exec claude --version \;' \
  'find . -name claude -print' \
  'find . -exec grep -l claude {} +' \
  'V=$(claude --version); $(which python3) run.py' \
  'ls $(echo claude); $(npm bin) hi' \
  '$(which python3) run.py # `which claude`' \
  '$(which claude) mcp list' \
  '$(echo claude)x -p hi' \
  'if [ -x "$(which claude)" ]; then echo ok; fi' \
  'bash -c "$(which claude) --version"' \
  'grep -c "$(echo claude)" file' \
  'du -c "$(which claude)" "$(which node)"' \
  'foo -c "$(which claude)" -p' \
  'eval "$(echo claude) --help"; eval "$(echo claude) --help"' \
  'echo "$(echo claude) is installed"; ls' ; do
  test_allow "$IRRECOVERABLE" "GH #588 control: no session is started: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in '$(echo claude) -p hi' 'find . -exec claude -p hi \;' ; do
  test_allow "$IRRECOVERABLE" "GH #588 control: the main session may start one: $_c" "$(bash_agent_payload "$_c" '')"
done


# GH #589 (bypass hunt 2026-10-23 F12): a substitution in a flag position blanks to a placeholder with no
# flag letters, so rm's recursive flag (rm-rf, rm-recursive) was never seen. The "subst-literal" view reads
# the command again with each literal substitution replaced by what it prints.
for _c in \
  'rm $(echo -rf) build' \
  'rm `echo -rf` build' \
  'rm -${X:-rf} build' \
  'rm ${F:--rf} build' \
  'rm ${F:+-rf} build' \
  'rm $(printf -- -rf) build' \
  'rm $(echo -r) build' \
  'rm "$(echo -rf)" build' \
  '/bin/rm $(echo -rf) build' \
  'rm --$(echo recursive) build' \
  'rm $(cat l) "a;b" $(echo -rf) build' \
  'rm $(echo -r) x; rm $(echo -i) y' \
  'sudo rm $(echo -rf) /data' \
  'rm $( echo -rf ) x' \
  'rm ` echo -rf` x' \
  'rm ${X:-${Y:--rf}} x' \
  'rm $(echo $(echo -rf)) x' \
  'rm $(command echo -rf) x' \
  'rm $(/bin/echo -rf) x' \
  'rm ${F:-"-rf"} /tmp/x' \
  "rm \${F:-'-rf'} /tmp/x" \
  "rm \${F:-'-r'}f /tmp/x" \
  'rm -${F:-"r"}f /tmp/x' \
  'git reset ${M:-"--hard"}' \
  'rm "${F:-"-rf"}" /tmp/x' \
  'rm "${F:-\\"x"}" ${G:-"-rf"} /' \
  'rm "${F:-\\"x"}" ${G:--rf} /' \
  'git reset "${F:-\\"x"}" ${M:-"--hard"}' \
  'rm "${F:-\\\\"x"}" ${G:-"-rf"} /' ; do
  test_deny "$IRRECOVERABLE" "GH #589: rm's recursive flag held in a substitution: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'rm $(cat list.txt)' \
  'rm $(echo build.log)' \
  'rm -${X:-i} build.log' \
  'rm -f $(git ls-files -d)' \
  'rm $(echo -ri) build' \
  'echo rm $(echo -rf)' \
  'rm $(cat list); echo rm -rf $(date)' \
  'git rm $(git ls-files -d)' \
  'rm "${TMPDIR:-/tmp}/x"' \
  'rm ${X:-build}' \
  'git commit -m "${MSG:-"chore: x && git reset --hard"}"' \
  'echo "${X:-"a && git reset --hard"}"' \
  "printf '%s\\n' \"\${Q:-\\\"}\" \"; git push --force origin main; \" \"\${Q:-\\\"}\"" ; do
  test_allow "$IRRECOVERABLE" "GH #589 control: rm with no recursive delete: $_c" "$(bash_payload "$_c")"
done

# GH #589 x #585: the subst-literal view shows dd's target, so a device named by a literal echo denies.
# The main reading asks first (a substitution target), so stdout holds that ask: exit 2 is what blocks.
_rc=$(bash_payload 'dd if=x of=$(echo /dev/disk2)' | bash "$IRRECOVERABLE" >/dev/null 2>&1; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (exit 2): GH #589: dd if=x of=\$(echo /dev/disk2)"; pass=$((pass + 1))
else
  echo "  ❌ exit 2 EXPECTED, got $_rc: GH #589: dd if=x of=\$(echo /dev/disk2)" >&2; fail=$((fail + 1))
fi


# GH #590 (bypass hunt 2026-10-23 F13): a shell (or source / .) reading a process substitution as its
# script ran the substitution's printed text unscanned. (`bash -c "$(echo ...)"` is read by #589's view.)
for _c in \
  'bash <(echo rm -rf build)' \
  'sh <(printf "rm -rf build")' \
  'bash -e <(echo git push --force origin main)' \
  'source <(echo rm -rf build)' \
  '. <(echo git reset --hard)' \
  'bash -c "$(echo rm -rf build)"' \
  'zsh <( echo rm -rf build )' \
  '\bash <(echo rm -rf x)' \
  'bash -o pipefail <(echo rm -rf x)' \
  'bash < <(echo rm -rf build)' \
  'bash -s < <(echo rm -rf build)' \
  "bash <(printf '%s\\n' 'rm -rf build')" \
  'bash <(printf %s "rm -rf build")' \
  'bash -- <(echo rm -rf x)' \
  'bash - <(echo rm -rf x)' \
  'bash -x -- <(echo rm -rf x)' \
  'bash -eo pipefail <(echo rm -rf x)' \
  'bash -euo pipefail <(echo rm -rf x)' \
  'bash -xO extglob <(echo rm -rf x)' \
  "bash <(printf '%s %s %s\\n' rm -rf x)" ; do
  test_deny "$IRRECOVERABLE" "GH #590: a shell runs a substitution's printed text: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'bash <(echo ls)' \
  'cat <(echo rm -rf build)' \
  'diff <(echo a) <(echo b)' \
  'bash <(curl -s https://example.com/install.sh)' \
  'source <(kubectl completion bash)' \
  'bash -c "$(cat x.sh)"' \
  'bash -x script.sh <(echo rm -rf x)' \
  'bash -e build.sh <(echo rm -rf x)' \
  'sh -x ./run.sh < <(echo rm -rf x)' \
  'bash -c x <(echo rm -rf x)' ; do
  test_allow "$IRRECOVERABLE" "GH #590 control: nothing destructive the text shows runs: $_c" "$(bash_payload "$_c")"
done


# GH #591 (bypass hunt 2026-10-23 F14): xargs feeds mkfs its device on stdin, so the mkfs rule saw no
# operand. (`find ... -exec mkfs.ext4 {} \;` denies since #586 made `{}` a word.)
for _c in \
  'xargs mkfs.ext4 <<< /dev/sda1' \
  'echo /dev/sda1 | xargs mkfs -t ext4' \
  'echo /dev/sda1 | xargs sudo mkfs.ext4' \
  'echo /dev/sda1 | xargs -n1 mke2fs' \
  'find /dev -name sda1 -exec mkfs.ext4 {} \;' \
  'xargs mkfs -V -t ext4 <<< /dev/sda1' \
  'xargs mkfs.ext4 -L -V <<< /dev/sda1' \
  'xargs mkfs.ext4 -L --version <<< /dev/sda1' \
  'printf "0 /dev/sdb" | xargs mkfs.vfat -h' \
  'echo d | xargs mkfs.fat -h' ; do
  test_deny "$IRRECOVERABLE" "GH #591: mkfs on a device xargs or find hands it: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'xargs mkfs.ext4 --help' \
  'xargs mkfs --version' \
  'echo x | xargs echo mkfs.ext4' \
  'echo mkfs.ext4' \
  'man mkfs' \
  'git ls-files | xargs grep -l mkfs' ; do
  test_allow "$IRRECOVERABLE" "GH #591 control: no filesystem is made: $_c" "$(bash_payload "$_c")"
done


# GH #647: a PH argv0 reads as every dangerous verb, gh included, and each such window searched the whole
# command for a written `gh <sub>`: quadratic, so padding pushed a later deny past the 8 s hook timeout.
_timed_case "GH #647: 60 KB of 'sudo \${a} x;' then git reset --hard, denied in bounded time" 2 \
  "git status; $(printf 'sudo ${a} x; %.0s' $(seq 4600))git reset --hard"
_timed_case "GH #647: a written gh, then 4000 distinct PH subcommands, then git reset --hard, denied in bounded time" 2 \
  "gh -R o/r issue list; $(for i in $(seq 4000); do printf 'sudo ${a} x%d; ' "$i"; done)git reset --hard"
# the gh-unknown-subcommand reading it replaced: a `gh <sub>` the command writes, past gh's own flags
test_ask   "$IRRECOVERABLE" "GH #647: gh -R o/r nuke still asks" "$(bash_payload 'gh -R o/r nuke')"
test_ask   "$IRRECOVERABLE" "GH #647: gh --repo o/r nuke still asks" "$(bash_payload 'gh --repo o/r nuke')"
test_ask   "$IRRECOVERABLE" "GH #647: ls;gh nuke still asks" "$(bash_payload 'ls;gh nuke')"
test_ask   "$IRRECOVERABLE" "GH #647: gh nuke, then the sub glued to a separator" "$(bash_payload 'gh nuke;ls')"
test_allow "$IRRECOVERABLE" "GH #647 control: a PH argv0 with no gh written" "$(bash_payload 'sudo ${a} x')"
test_allow "$IRRECOVERABLE" "GH #647 control: gh-nuke is a different program" "$(bash_payload 'echo gh-nuke x')"
# GH #594: after a bare `--` every word is an operand, so `rm -- -rf` deletes a file named -rf. GNU rm
# still permutes the options before `--` (`rm build -rf` is -rf).
test_allow "$IRRECOVERABLE" "GH #594: rm -- -rf removes a file named -rf" "$(bash_payload 'rm -- -rf')"
test_allow "$IRRECOVERABLE" "GH #594: rm -f -- -r removes a file named -r" "$(bash_payload 'rm -f -- -r')"
test_deny  "$IRRECOVERABLE" "GH #594: rm -r -- -f is still rm -r (rm-recursive)" "$(bash_payload 'rm -r -- -f')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm -rf -- build" "$(bash_payload 'rm -rf -- build')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm build -rf (options permute before --)" "$(bash_payload 'rm build -rf')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm -r build -- -f still has -r" "$(bash_payload 'rm -r build -- -f')"
# a -- a substitution builds may not be one: a non-empty $(x) makes it an operand and leaves -rf a flag
test_deny  "$IRRECOVERABLE" "GH #594 control: rm \$(x)-- -rf build" "$(bash_payload 'rm $(x)-- -rf build')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm --x -rf build (not a bare --)" "$(bash_payload 'rm --x -rf build')"
# the tokenizer splits at a carriage return and bash does not: `a<CR>--` is one operand, and -rf after it a flag
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a<CR>-- -rf build (not a bare --)" "$(bash_payload $'rm a\r-- -rf build')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a<CR>-- -r build (rm-recursive)" "$(bash_payload $'rm a\r-- -r build')"
# ...nor one the gate decodes from `$'\r'` into a bash -c or eval body
test_deny  "$IRRECOVERABLE" "GH #594 control: bash -c \$'rm a\\r-- -rf b'" "$(bash_payload "bash -c \$'rm a\\r-- -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #594 control: eval \$'rm a\\r-- -rf b'" "$(bash_payload "eval \$'rm a\\r-- -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #594 control: eval rm a\$'\\r'-- -rf b" "$(bash_payload "eval rm a\$'\\r'-- -rf b")"
test_allow "$IRRECOVERABLE" "GH #594: rm -r -i -- -f prompts for every file" "$(bash_payload 'rm -r -i -- -f')"
# ...nor one a redirect or an interpreter's argv only seems to show: the stop needs a plain rm command
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a <<- -- -rf b (-- is the heredoc word)" "$(bash_payload $'rm a <<- -- -rf b\n--')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a >x> -- -rf b (-- is a redirect target)" "$(bash_payload 'rm a >x> -- -rf b')"
test_deny  "$IRRECOVERABLE" "GH #594 control: subprocess.run([rm, 'a --', -rf, b])" \
  "$(bash_payload 'python3 -c '"'"'import subprocess; subprocess.run(["rm", "a --", "-rf", "b"])'"'"'')"
test_allow "$IRRECOVERABLE" "GH #594: rm -f -- -r ./x.log (plain operands)" "$(bash_payload 'rm -f -- -r ./x.log')"

# GH #662: `busybox [--] APPLET args` runs the applet, so every rule reads the applet as the command.
test_deny  "$IRRECOVERABLE" "GH #662: busybox rm -rf b" "$(bash_payload 'busybox rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox -- rm -rf b" "$(bash_payload 'busybox -- rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: /bin/busybox rm -r b" "$(bash_payload '/bin/busybox rm -r b')"
test_deny  "$IRRECOVERABLE" "GH #662: sudo busybox rm -rf b" "$(bash_payload 'sudo busybox rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox dd of=/dev/sda" "$(bash_payload 'busybox dd if=/dev/zero of=/dev/sda')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox mkfs.ext2 /dev/sda1" "$(bash_payload 'busybox mkfs.ext2 /dev/sda1')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox find . -delete" "$(bash_payload 'busybox find . -delete')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox sh -c 'rm -rf b'" "$(bash_payload "busybox sh -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox xargs rm -rf" "$(bash_payload 'echo b | busybox xargs rm -rf')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox chmod -R 777 /" "$(bash_payload 'busybox chmod -R 777 /')"
# the rules that walk their own wrapper list (xargs, find -exec, a shell reading stdin) read past it too
test_deny  "$IRRECOVERABLE" "GH #662: xargs busybox rm" "$(bash_payload 'echo b | xargs busybox rm')"
test_deny  "$IRRECOVERABLE" "GH #662: xargs busybox mkfs.ext2" "$(bash_payload 'echo /dev/sdb1 | xargs busybox mkfs.ext2')"
test_deny  "$IRRECOVERABLE" "GH #662: find -exec busybox chmod 777" "$(bash_payload 'find . -exec busybox chmod 777 {} +')"
test_deny  "$IRRECOVERABLE" "GH #662: find -exec busybox sh -c 'rm b'" "$(bash_payload "find . -exec busybox sh -c 'rm b' \\;")"
test_deny  "$IRRECOVERABLE" "GH #662: echo 'rm -rf b' | busybox sh" "$(bash_payload "echo 'rm -rf b' | busybox sh")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox sh <<< 'rm -rf b'" "$(bash_payload "busybox sh <<< 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: cat <<EOF | busybox sh" "$(bash_payload $'cat <<EOF | busybox sh\nrm -rf b\nEOF')"
# busybox's shells, and busybox's other names
test_deny  "$IRRECOVERABLE" "GH #662: busybox ash -c 'rm -rf b'" "$(bash_payload "busybox ash -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox hush -c 'rm -rf b'" "$(bash_payload "busybox hush -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: ash -c 'rm -rf b'" "$(bash_payload "ash -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: cat <<EOF | busybox ash" "$(bash_payload $'cat <<EOF | busybox ash\nrm -rf b\nEOF')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox.static rm -rf b" "$(bash_payload '/bin/busybox.static rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox-static rm -rf b" "$(bash_payload 'busybox-static rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: toybox dd of=/dev/sda" "$(bash_payload 'toybox dd if=/dev/zero of=/dev/sda')"
# ash and dash take the next word for every o in a cluster (bash's reading), and +c runs CMD as -c does
test_deny  "$IRRECOVERABLE" "GH #662: ash -oc pipefail 'rm -rf b'" "$(bash_payload "ash -oc pipefail 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox ash -ooc errexit pipefail 'rm -rf b'" "$(bash_payload "busybox ash -ooc errexit pipefail 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: dash -oc pipefail 'rm -rf b'" "$(bash_payload "dash -oc pipefail 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: ash +c 'rm -rf b'" "$(bash_payload "ash +c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: bash +c 'rm -rf b'" "$(bash_payload "bash +c 'rm -rf b'")"
# the echo upstream of a stdin shell, written through busybox or a path
test_deny  "$IRRECOVERABLE" "GH #662: busybox echo 'rm -rf b' | sh" "$(bash_payload "busybox echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: toybox echo 'rm -rf b' | ash" "$(bash_payload "toybox echo 'rm -rf b' | ash")"
test_deny  "$IRRECOVERABLE" "GH #662: /bin/echo 'rm -rf b' | sh" "$(bash_payload "/bin/echo 'rm -rf b' | sh")"
# busybox's `--`, and command's -p / --, before a stdin shell, its echo, or a find body's applet
test_deny  "$IRRECOVERABLE" "GH #662: echo 'rm -rf b' | busybox -- sh" "$(bash_payload "echo 'rm -rf b' | busybox -- sh")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox -- sh <<< 'rm -rf b'" "$(bash_payload "busybox -- sh <<< 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: cat <<EOF | busybox -- sh" "$(bash_payload $'cat <<EOF | busybox -- sh\nrm -rf b\nEOF')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox -- echo 'rm -rf b' | sh" "$(bash_payload "busybox -- echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: command -p echo 'rm -rf b' | sh" "$(bash_payload "command -p echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: command -- echo 'rm -rf b' | sh" "$(bash_payload "command -- echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: find -exec sh -c 'busybox -- chmod 777 \"\$1\"'" \
  "$(bash_payload "find . -exec sh -c 'busybox -- chmod 777 \"\$1\"' _ {} \\;")"
test_allow "$IRRECOVERABLE" "GH #662 control: ash +x script.sh" "$(bash_payload 'ash +x script.sh')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox echo 'ls' | sh" "$(bash_payload "busybox echo 'ls' | sh")"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox sh -c 'ls -la'" "$(bash_payload "busybox sh -c 'ls -la'")"
test_allow "$IRRECOVERABLE" "GH #662 control: toybox ls" "$(bash_payload 'toybox ls')"
test_allow "$IRRECOVERABLE" "GH #662 control: cat <<EOF | busybox ash (echo body)" "$(bash_payload $'cat <<EOF | busybox ash\necho hi\nEOF')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox ls -la" "$(bash_payload 'busybox ls -la')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox --list" "$(bash_payload 'busybox --list')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox rm x.log" "$(bash_payload 'busybox rm x.log')"
test_allow "$IRRECOVERABLE" "GH #662 control: echo busybox rm -rf b" "$(bash_payload 'echo busybox rm -rf b')"

# GH #661: bash brace-expands rm's own words before rm parses them: `--{r,f}` is `--r --f`, i.e. -rf.
test_deny  "$IRRECOVERABLE" "GH #661: rm --{r,f} b" "$(bash_payload 'rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm --{recursive,force} b" "$(bash_payload 'rm --{recursive,force} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm {-r,-f} b" "$(bash_payload 'rm {-r,-f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm --{r,} b (rm-recursive)" "$(bash_payload 'rm --{r,} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm --{rec,verbose} b (rm-recursive)" "$(bash_payload 'rm --{rec,verbose} b')"
test_deny  "$IRRECOVERABLE" "GH #661: sudo rm --{r,f} b" "$(bash_payload 'sudo rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: bash -c 'rm --{r,f} b'" "$(bash_payload "bash -c 'rm --{r,f} b'")"
test_deny  "$IRRECOVERABLE" "GH #661: rm --no-preserve-{root,x} -r /" "$(bash_payload 'rm --no-preserve-{root,x} -r /')"
# a shadowed brace-view hit earlier in the command does not end the view before the rm
test_deny  "$IRRECOVERABLE" "GH #661: fi{nd,nd} ... -delete; rm --{r,f} b" "$(bash_payload 'fi{nd,nd} /nonexistent -delete; rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: git push --fo{rce,rce} ...; rm --{r,f} b" "$(bash_payload 'git push --fo{rce,rce} --dry-run origin main; rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: git br{anch,anch} -D x; r{m,} -rf /tmp/x" "$(bash_payload 'git br{anch,anch} -D nosuchbranch; r{m,} -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "GH #661: true && fi{nd,nd} ... || r{m,} -rf /tmp/x" "$(bash_payload 'true && fi{nd,nd} /nonexistent -delete || r{m,} -rf /tmp/x')"
# ...nor a word window the first pass already saw, nor another rule firing first in the rm's own window
test_deny  "$IRRECOVERABLE" "GH #661: decoy; sudo -u \$U r{m,} -rf b" "$(bash_payload 'fi{nd,nd} x -delete; sudo -u $U r{m,} -rf b')"
test_deny  "$IRRECOVERABLE" "GH #661: decoy; X=\$Y r{m,} -rf b" "$(bash_payload 'fi{nd,nd} x -delete; X=$Y r{m,} -rf b')"
test_deny  "$IRRECOVERABLE" "GH #661: GIT_CONFIG_PARAMETERS=core.hooks{path,path} rm --{r,f} b" \
  "$(bash_payload 'GIT_CONFIG_PARAMETERS=core.hooks{path,path} rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: echo b | xargs r{m,} -rf" "$(bash_payload 'echo b | xargs r{m,} -rf')"
# a structural limit only the expanded text reaches (an eval chain past the depth limit, the xargs handover
# budget) denies in the enforced pass, as it does in the main reading
test_deny  "$IRRECOVERABLE" "GH #661: e{val,val} x3 rm --{r,f} b" "$(bash_payload 'e{val,val} e{val,val} e{val,val} rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: 55 xargs e{nv,} decoys, then xargs env r{m,} -rf b" \
  "$(bash_payload "$(printf ': | xargs e{nv,} true; %.0s' $(seq 55)): | xargs env r{m,} -rf b")"
# a word glued to a substitution is not every verb in the enforced pass's word windows (as in _run_words)
test_allow "$IRRECOVERABLE" "GH #661 control: decoy; sudo -u \$U ./build\"\$(date +%s)\" -r out" \
  "$(bash_payload 'echo {a,b}; f{ind,ind} . -name x -delete; sudo -u $U ./build"$(date +%s)" -r out')"
test_allow "$IRRECOVERABLE" "GH #661 control: decoy; sudo -u \$U python\"\$(echo 3)\" -m compileall -r 2 {a,b}" \
  "$(bash_payload 'fi{nd,nd} x -delete; sudo -u $U python"$(echo 3)" -m compileall -r 2 {a,b}')"

# GH #309: push's force, mirror and protected-delete rules read the brace-expanded words too (`--{force,force}`).
test_deny  "$IRRECOVERABLE" "GH #309: git push --{force,force} origin main" "$(bash_payload 'git push --{force,force} origin main')"
test_deny  "$IRRECOVERABLE" "GH #309: git push -{f,f} origin main" "$(bash_payload 'git push -{f,f} origin main')"
test_deny  "$IRRECOVERABLE" "GH #309: git push --fo{rce,rce} origin HEAD:feat" "$(bash_payload 'git push --fo{rce,rce} origin HEAD:feat')"
test_deny  "$IRRECOVERABLE" "GH #309: git push origin +{main,main}:main" "$(bash_payload 'git push origin +{main,main}:main')"
test_deny  "$IRRECOVERABLE" "GH #309: git push --{mirror,mirror} origin" "$(bash_payload 'git push --{mirror,mirror} origin')"
test_deny  "$IRRECOVERABLE" "GH #309: git push origin :{main,main}" "$(bash_payload 'git push origin :{main,main}')"
test_deny  "$IRRECOVERABLE" "GH #309: echo {a,b}; git push --{force,force} origin main" "$(bash_payload 'echo {a,b}; git push --{force,force} origin main')"
test_allow "$IRRECOVERABLE" "GH #309 control: git push origin HEAD:{feat1,feat2}" "$(bash_payload 'git push origin HEAD:{feat1,feat2}')"
# the enforced pass runs no spawn scan: a subagent body the main reading fits is not denied as a spawn
test_allow "$IRRECOVERABLE" "GH #661 control: subagent bash -c with 800 statements, then echo {a,b}" \
  "$(bash_agent_payload "bash -c '$(printf 'true; %.0s' $(seq 800))true'; echo {a,b}" fork)"
# the pass reads rm's rules only and runs no spawn scan, so an expansion that copies a long eval body many times
# spends no scan budget there: allowed, as on develop, and the rm in or after that body is still read
_x661="eval '$(printf 'true;%.0s' $(seq 50))true'{$(seq -s, 0 29)}"
test_allow "$IRRECOVERABLE" "GH #661 control: subagent eval 'true;...'{0..29} (no spawn scan in the pass)" \
  "$(bash_agent_payload "$_x661" fork)"
test_deny  "$IRRECOVERABLE" "GH #661: subagent: the rm inside the body that spends the budget" \
  "$(bash_agent_payload "eval '$(printf 'true;%.0s' $(seq 50))true'{$(seq -s, 0 29)} '; rm --{r,f} b'" fork)"
test_deny  "$IRRECOVERABLE" "GH #661: subagent: budget-spending expansion, then bash -c 'rm --{r,f} b'" \
  "$(bash_agent_payload "$_x661; bash -c 'rm --{r,f} b'" fork)"
test_deny  "$IRRECOVERABLE" "GH #661: subagent: budget-spending expansion, then e{val,val} x3 rm --{r,f} b" \
  "$(bash_agent_payload "$_x661; e{val,val} e{val,val} e{val,val} rm --{r,f} b" fork)"
test_allow "$IRRECOVERABLE" "GH #661 control: rm {a,b}.log" "$(bash_payload 'rm {a,b}.log')"
test_allow "$IRRECOVERABLE" "GH #661 control: rm -f {a,b}.tmp" "$(bash_payload 'rm -f {a,b}.tmp')"
test_allow "$IRRECOVERABLE" "GH #661 control: rm --{verbose,force} b (no -r)" "$(bash_payload 'rm --{verbose,force} b')"
# GH #663: `sh -c BODY ARG0 ARGS...` sets $0 to ARG0 and $1.. / "$@" to ARGS, so the body runs with them.
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\$@\"' -- -rf b" "$(bash_payload "bash -c 'rm \"\$@\"' -- -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: sh -c 'rm \$@' _ -rf b" "$(bash_payload "sh -c 'rm \$@' _ -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: sh -c 'rm \"\$1\" \"\$2\"' _ -rf b" "$(bash_payload "sh -c 'rm \"\$1\" \"\$2\"' _ -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \$*' _ -r b" "$(bash_payload "bash -c 'rm \$*' _ -r b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\${@}\"' x -rf b" "$(bash_payload "bash -c 'rm \"\${@}\"' x -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c '\$1 -rf b' _ rm (the verb as a parameter)" "$(bash_payload "bash -c '\$1 -rf b' _ rm")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'git \"\$@\"' _ push --force origin main" "$(bash_payload "bash -c 'git \"\$@\"' _ push --force origin main")"
test_deny  "$IRRECOVERABLE" "GH #663: sudo sh -c 'rm \"\$@\"' sh -rf b" "$(bash_payload "sudo sh -c 'rm \"\$@\"' sh -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c \"rm \\\"\\\$@\\\"\" -- -rf b (double-quoted body)" "$(bash_payload 'bash -c "rm \"\$@\"" -- -rf b')"
# slices, multi-digit and operator forms, and a leading shift
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \${@:1}' _ -rf b" "$(bash_payload "bash -c 'rm \${@:1}' _ -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\${@:2}\"' _ x -rf b" "$(bash_payload "bash -c 'rm \"\${@:2}\"' _ x -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \${10} \${11}' _ 1..9 -rf b" "$(bash_payload "bash -c 'rm \${10} \${11}' _ 1 2 3 4 5 6 7 8 9 -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\${1:-}\" b' _ -rf" "$(bash_payload "bash -c 'rm \"\${1:-}\" b' _ -rf")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'shift; git \$1 \$2' _ x push --force" "$(bash_payload "bash -c 'shift; git \$1 \$2 origin main' _ x push --force")"
# a parameter inside a larger quoted string is text (a message), and one in single quotes never expands
test_allow "$IRRECOVERABLE" "GH #663 control: git commit -m \"fix: \$1\" with it's" "$(bash_payload "bash -c 'git commit -m \"fix: \$1\"' _ \"it's done\"")"
test_allow "$IRRECOVERABLE" "GH #663 control: echo \"x \$1 y\" with an arg that holds ; rm -rf" "$(bash_payload "bash -c 'echo \"x \$1 y\"' _ 'a\" ; rm -rf b ; \"'")"
test_allow "$IRRECOVERABLE" "GH #663 control: echo \"args: \$@\" with it's" "$(bash_payload "bash -c 'echo \"args: \$@\"' _ \"it's\" b")"
# the filled body is capped: 1500 "\$@" times 1500 words would be millions of words
_timed_case "GH #663: 1500 \"\$@\" x 1500 args then rm -rf b, denied in bounded time" 2 \
  "sh -c 'echo $(printf '"\$@" %.0s' $(seq 1500))' _ $(printf 'a %.0s' $(seq 1500)); rm -rf b"
# GH #663 review 2: escapes, word splitting, glued parameters, redirects, slices and operators
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'echo a\\; rm "$@"'"'"' _ -rf b (an escaped backslash ends the word)' "$(bash_payload 'sh -c '"'"'echo a\\; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'echo "a\\" ; rm "$@"'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'echo "a\\" ; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'x=\"; rm "$@"'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'x=\"; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'$1'"'"' _ '"'"'rm -rf b'"'"' (an unquoted value is word-split)' "$(bash_payload 'sh -c '"'"'$1'"'"' _ '"'"'rm -rf b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'git $1 origin main'"'"' _ '"'"'push --force'"'"'' "$(bash_payload 'sh -c '"'"'git $1 origin main'"'"' _ '"'"'push --force'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "$@">/dev/null'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'rm "$@">/dev/null'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm ${@: -2}'"'"' _ x -rf b' "$(bash_payload 'bash -c '"'"'rm ${@: -2}'"'"' _ x -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1#x}" b'"'"' _ x-rf' "$(bash_payload 'sh -c '"'"'rm "${1#x}" b'"'"' _ x-rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1,,}" b'"'"' _ -RF' "$(bash_payload 'sh -c '"'"'rm "${1,,}" b'"'"' _ -RF')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1/x/r}" b'"'"' _ -xf' "$(bash_payload 'sh -c '"'"'rm "${1/x/r}" b'"'"' _ -xf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm -$1 b'"'"' _ rf (glued to text)' "$(bash_payload 'sh -c '"'"'rm -$1 b'"'"' _ rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'r$1 -rf b'"'"' _ m' "$(bash_payload 'sh -c '"'"'r$1 -rf b'"'"' _ m')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm $1$2 b'"'"' _ -r f' "$(bash_payload 'sh -c '"'"'rm $1$2 b'"'"' _ -r f')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "-$1" b'"'"' _ rf' "$(bash_payload 'sh -c '"'"'rm "-$1" b'"'"' _ rf')"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'echo $1'"'"' _ '"'"'a; rm -rf b'"'"' (a value'"'"'s ; is not a separator)' "$(bash_payload 'sh -c '"'"'echo $1'"'"' _ '"'"'a; rm -rf b'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'echo '"'"'"'"'"'"'"'"'$1'"'"'"'"'"'"'"'"''"'"' _ rm -rf (single quotes never expand)' "$(bash_payload 'sh -c '"'"'echo '"'"'"'"'"'"'"'"'$1'"'"'"'"'"'"'"'"''"'"' _ rm -rf')"
# the filled text is capped across the whole command: 20 bodies of 300 "$@" x 245 words each fill ~3 MB
_f663="$(printf '"$@" %.0s' $(seq 300))"; _a663="$(printf 'a %.0s' $(seq 245))"
_s663=""; for _i in $(seq 20); do _s663+="sh -c 'echo $_f663' _ $_a663; "; done
_t0=$(date +%s); bash_agent_payload "${_s663}rm -rf b" fork | timeout 10 bash "$IRRECOVERABLE" >/dev/null 2>&1; _rc=$?; _t1=$(( $(date +%s) - _t0 ))
if [[ "$_rc" == 2 ]] && [ "$_t1" -le 4 ]; then echo "  ✅ GH #663: subagent flood of filled bodies denied in bounded time (rc=2 in ${_t1}s)"; pass=$((pass + 1))
else echo "  ❌ GH #663: subagent flood of filled bodies: expected rc=2 within 4s, got rc=$_rc in ${_t1}s" >&2; fail=$((fail + 1)); fi
# GH #663 review 3: default words, shift past $#, ${!#}, pattern quoting, anchors, comments, $'...'
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm ${1+"$@"}'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'rm ${1+"$@"}'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm ${3:-$2} b'"'"' _ x -rf' "$(bash_payload 'sh -c '"'"'rm ${3:-$2} b'"'"' _ x -rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm ${3:-${2}} b'"'"' _ x -rf' "$(bash_payload 'sh -c '"'"'rm ${3:-${2}} b'"'"' _ x -rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'shift 3; rm $1 $2'"'"' _ -rf b (a failed shift keeps the args)' "$(bash_payload 'bash -c '"'"'shift 3; rm $1 $2'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm ${!#} b'"'"' _ -rf' "$(bash_payload 'bash -c '"'"'rm ${!#} b'"'"' _ -rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1#"x"}" b'"'"' _ x-rf' "$(bash_payload 'sh -c '"'"'rm "${1#"x"}" b'"'"' _ x-rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm "${1#[^x]}" b'"'"' _ a-rf' "$(bash_payload 'bash -c '"'"'rm "${1#[^x]}" b'"'"' _ a-rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm "${1/#x/-}" b'"'"' _ xrf' "$(bash_payload 'bash -c '"'"'rm "${1/#x/-}" b'"'"' _ xrf')"
_c663=$'bash -c \'echo hi # it\'"\'"\'s\nrm "$@"\' _ -rf b'
test_deny  "$IRRECOVERABLE" 'GH #663: a comment with an apostrophe before rm "$@"' "$(bash_payload "$_c663")"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'sh -c "echo \"\$@\"" _ "$@"'"'"' _ a b (nested forwarding)' "$(bash_payload 'sh -c '"'"'sh -c "echo \"\$@\"" _ "$@"'"'"' _ a b')"
_timed_case "GH #663: a \${1##*/} cut on a 100 KB value is read in bounded time" 2 \
  "sh -c 'echo \"\${1##*/}\"; rm -rf b' _ $(printf 'a/%.0s' $(seq 45000))"
# GH #663 review 4: comments after an expansion, backticks in quotes, glob replacements, shift forms, assignments
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'echo $9#; rm "$@"'"'"' _ -rf b ($9# is a word, not a comment)' "$(bash_payload 'sh -c '"'"'echo $9#; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: a backtick in double quotes holding an apostrophe' "$(bash_payload 'sh -c '"'"'x="`echo "it'"'"'"'"'"'"'"'"'s"`"; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1/#*x/-}" b'"'"' _ zzxrf' "$(bash_payload 'sh -c '"'"'rm "${1/#*x/-}" b'"'"' _ zzxrf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'git push "${1/%/-force}" origin main'"'"' _ -' "$(bash_payload 'bash -c '"'"'git push "${1/%/-force}" origin main'"'"' _ -')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'shift || exit; rm $1 b'"'"' _ x -rf' "$(bash_payload 'bash -c '"'"'shift || exit; rm $1 b'"'"' _ x -rf')"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'msg=$1; git commit -m "$msg"'"'"' _ '"'"'docs: rm -rf is replaced'"'"' (no split in an assignment)' "$(bash_payload 'sh -c '"'"'msg=$1; git commit -m "$msg"'"'"' _ '"'"'docs: rm -rf is replaced'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #663 control: bash -c '"'"'f=$1; cp "$f" "$f.bak"'"'"' _ '"'"'notes rm -rf b.txt'"'"'' "$(bash_payload 'bash -c '"'"'f=$1; cp "$f" "$f.bak"'"'"' _ '"'"'notes rm -rf b.txt'"'"'')"
_timed_case "GH #663: 9000 unclosed \${ in a body are read in bounded time" 2 \
  "sh -c 'echo $(printf '\${%.0s' $(seq 9000))' _ a; rm -rf b"
_timed_case "GH #663: a \${1//a/<30000 b>} on 30000 a's is charged before it is built" 2 \
  "sh -c 'echo \"\${1//a/$(printf 'b%.0s' $(seq 30000))}\"' _ $(printf 'a%.0s' $(seq 30000)); rm -rf b"
# GH #663 review 5: a shift's glued redirects and a / replacement on a long value are read in bounded time
_timed_case "GH #663: shift with 30 glued <a redirects, then a force push outside the body" 2 \
  "bash -c 'shift$(printf '<a%.0s' $(seq 30)) x y; echo \$1' _ a; git push --force origin main"
_timed_case "GH #663: a \${1//*z/x} on a 120000-character value is bounded" 2 \
  "sh -c 'echo \"\${1//*z/x}\"' _ $(printf 'a%.0s' $(seq 120000)); git push --force origin main"
_timed_case "GH #663: a \${1/%*z/x} on a 60000-character value is bounded" 2 \
  "sh -c 'echo \"\${1/%*z/x}\"' _ $(printf 'a%.0s' $(seq 60000)); git push --force origin main"
test_allow "$IRRECOVERABLE" "GH #663 control: bash -c 'shift 2>/dev/null; ls \$1' _ a -la" "$(bash_payload "bash -c 'shift 2>/dev/null; ls \$1' _ a -la")"
test_allow "$IRRECOVERABLE" "GH #663 control: bash -c 'rm \"\$@\"' _ a.log b.log" "$(bash_payload "bash -c 'rm \"\$@\"' _ a.log b.log")"
test_allow "$IRRECOVERABLE" "GH #663 control: bash -c 'echo \"\$@\"' _ rm -rf b" "$(bash_payload "bash -c 'echo \"\$@\"' _ rm -rf b")"
test_allow "$IRRECOVERABLE" "GH #663 control: sh -c 'ls \$1' _ -la" "$(bash_payload "sh -c 'ls \$1' _ -la")"
# GH #664: a here-string or echo argument written with ANSI-C quoting is decoded before the stdin shell's body is read.
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'rm -rf b'" "$(bash_payload "bash <<< \$'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: sh <<< \$'rm\\x20-rf b'" "$(bash_payload "sh <<< \$'rm\\x20-rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'ls\\nrm -rf b'" "$(bash_payload "bash <<< \$'ls\\nrm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: zsh <<< \$\"rm -rf b\"" "$(bash_payload 'zsh <<< $"rm -rf b"')"
test_deny  "$IRRECOVERABLE" "GH #664: echo \$'rm -rf b' | sh" "$(bash_payload "echo \$'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #664: dash <<< \$'git push --force origin main'" "$(bash_payload "dash <<< \$'git push --force origin main'")"
# an even backslash run escapes nothing, and \u, \U and \cX are decoded too (also at the top level)
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \\\\\$\"rm -rf b\"" "$(bash_payload 'bash <<< \\$"rm -rf b"')"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'\\u0072m -rf b'" "$(bash_payload "bash <<< \$'\\u0072m -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'\\U00000072m -rf b'" "$(bash_payload "bash <<< \$'\\U00000072m -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'echo hi\\cJrm -rf b'" "$(bash_payload "bash <<< \$'echo hi\\cJrm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: \$'\\u0072m' -rf b (top level)" "$(bash_payload "\$'\\u0072m' -rf b")"
# \cX is X & 0x1f as bash computes it, a NUL ends the $'...' value, and a \U past U+10FFFF is empty
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< $'"'"'echo hi\c*rm -rf b'"'"' (\c* is a newline)' "$(bash_payload 'bash <<< $'"'"'echo hi\c*rm -rf b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< $'"'"'rm\c)-rf\c)b'"'"' (\c) is a tab)' "$(bash_payload 'bash <<< $'"'"'rm\c)-rf\c)b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #664: r$'"'"'\u0000'"'"'m -rf b (a NUL ends the value)' "$(bash_payload 'r$'"'"'\u0000'"'"'m -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664: r$'"'"'\0'"'"'m -rf b' "$(bash_payload 'r$'"'"'\0'"'"'m -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664: r$'"'"'\UFFFFFFFF'"'"'m -rf b' "$(bash_payload 'r$'"'"'\UFFFFFFFF'"'"'m -rf b')"
test_allow "$IRRECOVERABLE" 'GH #664 control: echo $'"'"'\cß'"'"' (no crash)' "$(bash_payload 'echo $'"'"'\cß'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #664 control: bash <<< $'"'"'echo hi\c{rm -rf b'"'"' (\c{ is ESC, not ;)' "$(bash_payload 'bash <<< $'"'"'echo hi\c{rm -rf b'"'"'')"
test_allow "$IRRECOVERABLE" "GH #664 control: echo \"\\\$\" | sh" "$(bash_payload 'echo "\$" | sh')"
# a $'...' inside double quotes is literal to that shell (the stdin shell decodes it later), and \x{HH} decodes
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< "$'"'"'\x22'"'"'; rm -rf b; #"' "$(bash_payload 'bash <<< "$'"'"'\x22'"'"'; rm -rf b; #"')"
test_deny  "$IRRECOVERABLE" 'GH #664: echo "x$'"'"'\x22'"'"'; rm -rf b; : $'"'"'\x22'"'"'" | bash' "$(bash_payload 'echo "x$'"'"'\x22'"'"'; rm -rf b; : $'"'"'\x22'"'"'" | bash')"
test_deny  "$IRRECOVERABLE" 'GH #664: echo "$'"'"'\x22'"'"'"; rm -rf b; echo "$'"'"'\x22'"'"'" (top level)' "$(bash_payload 'echo "$'"'"'\x22'"'"'"; rm -rf b; echo "$'"'"'\x22'"'"'"')"
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< $'"'"'\x{72}m -rf b'"'"'' "$(bash_payload 'bash <<< $'"'"'\x{72}m -rf b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #664: $'"'"'\x{172}m'"'"' -rf b (top level, & 0xFF)' "$(bash_payload '$'"'"'\x{172}m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664: bash -c "$'"'"'\x72m'"'"' -rf b" (decoded when the body is read)' "$(bash_payload 'bash -c "$'"'"'\x72m'"'"' -rf b"')"
test_deny  "$IRRECOVERABLE" 'GH #664: a literal $'"'"' in "..." does not swallow a live one after it' "$(bash_payload '"$'"'"'" ; $'"'"'\x72m'"'"' -rf b')"
test_allow "$IRRECOVERABLE" 'GH #664 control: echo "$'"'"'say hi'"'"'"' "$(bash_payload 'echo "$'"'"'say hi'"'"'"')"
test_allow "$IRRECOVERABLE" "GH #664 control: bash <<< \$'echo hi'" "$(bash_payload "bash <<< \$'echo hi'")"
test_allow "$IRRECOVERABLE" "GH #664 control: grep x <<< \$'rm -rf b'" "$(bash_payload "grep x <<< \$'rm -rf b'")"
# GH #664 review 4: a $'...' the line's own shell reads is decoded wherever it sits, as develop did.
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: $(true)# is no comment' "$(bash_payload 'echo $(true)#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: $((1))# is no comment' "$(bash_payload 'echo $((1))#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: an escaped blank before # is no comment' "$(bash_payload 'echo a\ #; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: an escaped ; before # is no comment' "$(bash_payload 'echo x\;#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: a line continuation before # is no comment' "$(bash_payload 'echo a\
#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: octal after $(true)#' "$(bash_payload 'echo $(true)#; $'"'"'\162m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: git verb after $(true)#' "$(bash_payload 'echo $(true)#; git $'"'"'\x70ush'"'"' --force origin main')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: case ) inside $(...) inside "..."' "$(bash_payload 'echo "$(case x in x) $'"'"'\x72m'"'"' -rf b;; esac)"')"
test_allow "$IRRECOVERABLE" 'GH #664 review 4 control: \x{} is a NUL that ends the value' "$(bash_payload 'bash <<< $'"'"'\x{}\nrm -rf b'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #664 review 4 control: \U past U+10FFFF spells no verb' "$(bash_payload '$'"'"'\U110000a'"'"'rm -rf b')"
# GH #664 review 5: a decoded " \ $ or backtick in "..." is escaped there, not left undecoded.
test_deny  "$IRRECOVERABLE" 'GH #664 review 5: a nested shell'"'"'s eval of \$'"'"'...'"'"' whose text holds a $' "$(bash_payload 'sh -c "eval \$'"'"'\x72m -rf b \x24x'"'"'"')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 5: a nested shell'"'"'s eval of \$'"'"'...'"'"' whose text holds a "' "$(bash_payload 'sh -c "eval \$'"'"'\x72m -rf b \x22'"'"'"')"
test_allow "$IRRECOVERABLE" 'GH #664 review 5 control: a decoded " inside $(case) in "..."' "$(bash_payload 'echo "$(case x in x) echo $'"'"'a\x22b'"'"';; esac)"')"

# GH #693: a $(...)/backtick in the word of a ${...} (default, pattern, subscript, offset) runs, and a bash 5.3
# funsub/valsub (`${ cmd; }`, `${| cmd; }`) is a command; the ${...} body was never read.
_p693=('echo ${x:-$(@V@)}' 'echo ${x-$(@V@)}' 'echo ${x:=$(@V@)}' 'echo ${x:?$(@V@)}' 'echo ${x:+$(@V@)}'
  'echo ${x#$(@V@)}' 'echo ${x##$(@V@)}' 'echo ${x%$(@V@)}' 'echo ${x%%$(@V@)}' ': ${x/$(@V@)/}'
  ': ${x//$(@V@)/y}' 'echo ${x[$(@V@)]}' 'echo ${x:$(@V@)}' 'echo ${x:0:$(@V@)}' 'echo "${x:-$(@V@)}"'
  'echo ${x:-`@V@`}' 'echo ${x:-${y:-$(@V@)}}' 'x=${x:-$(@V@)}' 'echo ${x:-a #$(@V@)}'
  "echo \"\${x:-'\$(@V@)'}\"" 'echo ${ @V@; }' 'echo ${| @V@; }' 'echo ${ echo $(@V@); }'
  'echo ${ echo `@V@`; }'
  # a quoted word holding "}" is not the funsub's closer (the quote-blind closer cut the body there)
  "echo \${ echo 'a}'; @V@; }" 'echo ${ echo "a}"; @V@; }' "echo \${| REPLY='a}'; @V@; }"
  "echo \${ echo 'a}'; }; @V@")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p693[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #693: $_c" "$(bash_payload "$_c")"
  done
done
for _c in 'ls ${HOME:-/tmp}' 'echo ${x:-$(date)}' 'echo "${x:-$(date)}"' 'echo ${x//a/b}' 'echo ${#x}' \
  'echo ${PWD##*/}' 'echo ${1:?usage}' 'cmd ${var:+--flag}' 'printf %s "${arr[@]}"' 'echo $((1+$(date +%s)))' \
  'echo ${x:-$(rm --help)}' 'echo "${HOME}/rm -rf"' 'echo ${ date; }' 'echo ${x:- default}' \
  "echo '\${x:-\$(rm -rf ~/x)}'" 'echo ${x:-\$(rm -rf ~/x)}' "echo \${ echo 'a}'; }; echo \"\$PWD\"" \
  "echo \${ printf '%s}' x; }; echo \"\$PWD\""; do
  test_allow "$IRRECOVERABLE" "GH #693 control: $_c" "$(bash_payload "$_c")"
done
_timed_case 'GH #693: 10000 ${x:-$(date)} words are read in bounded time' 0 \
  "echo $(printf '${x:-$(date)} %.0s' $(seq 10000))"
_timed_case 'GH #693: a ${x:-$(rm -rf ~/x)} target before 9000 padding words denies in bounded time' 2 \
  "echo \${x:-\$(rm -rf ~/x)} $(printf '${x:-$(date)} %.0s' $(seq 9000))"
_timed_case 'GH #693: a ${x:-$(rm -rf ~/x)} target after 9000 padding words denies in bounded time' 2 \
  "echo $(printf '${x:-$(date)} %.0s' $(seq 9000)) \${x:-\$(rm -rf ~/x)}"
_timed_case 'GH #693: a flood of unclosed ${ is read in bounded time' 2 \
  "echo $(printf '${x:-a %.0s' $(seq 20000))"
# each nested funsub level appends its body blanked, not raw, so nested text is not read once per level.
# GH #761: timed against one funsub around the same words, not a fixed 4 s (blanked ~2.7x, raw ~6.1x).
_timed_ratio_case 'GH #693: 12 nested funsubs around 62 KB of words run within the gate'"'"'s deadline and 4x one funsub' 0 4 \
  "echo \${ echo $(printf "'a}' x; %.0s" $(seq 7750)); }" \
  "echo $(printf '${ echo %.0s' $(seq 12))$(printf "'a}' x; %.0s" $(seq 7750))$(printf '; }%.0s' $(seq 12))"

# GH #702: the ${...} closer counted every "{" and ignored quotes, escapes and nested $(...)/backtick, so it
# ended the word before bash (a "}" in a nested substitution) or after it (a "\{", a bare "{"), and a "#"
# comment in a funsub or <(...) held a closer bash skips. bash 5.3 runs @V@ in each.
_N=$'\n'
_p702=('echo ${x:-$(@V@; echo })}' 'echo ${x:-`@V@; echo }`}' 'echo "${x:-$(@V@; echo })}"'
  'echo ${x:-"$(@V@; echo })"}' "echo \${x:-\${ echo 'a}'; @V@; }}" "echo \"\${x:-\${ echo 'a}'; @V@; }}\""
  "echo \${ : # }'$_N@V@$_N: # '$_N}" "cat <( : # )'$_N@V@$_N: # '$_N)"
  "echo \${x:-\\{}$_N@V@${_N}echo }" "echo \"\${x:-\\{}\"$_N@V@${_N}echo }" "echo \${x:-{}$_N@V@${_N}echo }"
  "echo \${x:-\`echo {\`}$_N@V@${_N}echo }" "echo \${x:-\$'\\{'}$_N@V@${_N}echo }"
  "echo \"\${x:-'{'}\"$_N@V@${_N}echo }" "echo \${x:-\${y:-\\{}}$_N@V@${_N}echo }"
  # a plain "..." is let through only when it ends the gate's word early; a "{" in one still denies
  "echo \${x:-\"a{\"}$_N@V@${_N}echo }" 'echo ${x:-"a}"}; @V@'
  # already denied before #702; kept so the new closer cannot lose them
  'echo ${x:-$(case a in a) @V@; echo };; esac)}' 'echo ${x:-$(case a in a) echo };; esac; @V@)}'
  "echo \${x:-\$(cat <<E$_N})${_N}E$_N@V@)}" "echo \${x:-'a}'}$_N@V@" "echo \"\${x:-'a}'}\"$_N@V@")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p702[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #702: $_c" "$(bash_payload "$_c")"
  done
done
for _c in 'echo ${x//\"/}' 'echo ${x:-"a b"}' "echo \${x:-'a b'}" 'echo ${x:-$(echo "a b")}' 'echo ${x:-`date`}' \
  'echo ${x:-${y:-z}}' 'echo ${x:-$((1+2))}' 'echo ${arr[$i]}' 'echo "${x:-$(date +%s)}"' 'echo ${x/#\//}' \
  "echo \${ echo x # note$_N}" "cat <(echo a # note$_N)" 'echo ${x:-$(echo "}")}' "echo \${x:-\$(echo '}')}" 'echo ${y:-"a}b"}'; do
  test_allow "$IRRECOVERABLE" "GH #702 control: $_c" "$(bash_payload "$_c")"
done
# the funsub body's odd quote comes from the inner word's wrong close, so that reason is the one shown
test_deny_says "$IRRECOVERABLE" "GH #702: a funsub holding \${x:-'a}'} names the \${...} word, not the depth budget" \
  "$(bash_payload "echo \${ echo \${x:-'a}'}; }")" "ends at a different place" "depth-scan budget"
test_deny_says "$IRRECOVERABLE" "GH #702: a bash -c body keeps the \${...} word reason" \
  "$(bash_payload "bash -c 'echo \${x:-\\{}${_N}rm -rf ~/x${_N}echo }'")" "ends at a different place" "depth-scan budget"
_timed_case 'GH #702: a ${x:-\{} target before 9000 padding words denies in bounded time' 2 \
  "echo \${x:-\\{}$_N$(printf '${x:-a} %.0s' $(seq 9000))"
_timed_case 'GH #702: a ${x:-\{} target after 9000 padding words denies in bounded time' 2 \
  "echo $(printf '${x:-a} %.0s' $(seq 9000))\${x:-\\{}"
_timed_case 'GH #702: 10000 ${y:-"a}b"} words (the plain-quote exemption) are read in bounded time' 0 \
  "echo $(printf '${y:-"a}b"} %.0s' $(seq 10000))"

# GH #676: chroot, taskset, unshare, nsenter, chpst and setuidgid run the command after their own options
# and positionals (chroot NEWROOT, taskset's mask, setuidgid's account). Option syntax checked on util-linux
# 2.39 / coreutils 9.4 (live), runit 2.1.2's chpst getopt string and daemontools 0.76's setuidgid (man pages).
test_deny  "$IRRECOVERABLE" "GH #676: chroot / rm -rf b" "$(bash_payload 'chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset 1 rm -rf b" "$(bash_payload 'taskset 1 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare rm -rf b" "$(bash_payload 'unshare rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 rm -rf b" "$(bash_payload 'nsenter -t 1 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chpst -u x rm -rf b" "$(bash_payload 'chpst -u x rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: setuidgid x rm -rf b" "$(bash_payload 'setuidgid x rm -rf b')"
# value options, attached or as the next word, and `--`
test_deny  "$IRRECOVERABLE" "GH #676: chroot --userspec u:g / rm -rf b" "$(bash_payload 'chroot --userspec u:g / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chroot --groups=g --skip-chdir / rm -rf b" "$(bash_payload 'chroot --groups=g --skip-chdir / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chroot -- / rm -rf b" "$(bash_payload 'chroot -- / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset -c 0-3 rm -rf b" "$(bash_payload 'taskset -c 0-3 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset -a 0x3 rm -rf b" "$(bash_payload 'taskset -a 0x3 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -S 0 -G 0 rm -rf b" "$(bash_payload 'unshare -S 0 -G 0 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -R /x -w /y rm -rf b" "$(bash_payload 'unshare -R /x -w /y rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare --map-user 0 --setgroups deny rm -rf b" "$(bash_payload 'unshare --map-user 0 --setgroups deny rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -m -f --mount-proc rm -rf b" "$(bash_payload 'unshare -m -f --mount-proc rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 -m -u -i -n -p rm -rf b" "$(bash_payload 'nsenter -t 1 -m -u -i -n -p rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -S 0 -G 0 -W/x -t 1 rm -rf b" "$(bash_payload 'nsenter -S 0 -G 0 -W/x -t 1 rm -rf b')"
# nsenter's -W, like -m -r -w, takes an optional value that must be attached: `-W cmd` runs cmd
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -W rm -rf b" "$(bash_payload 'nsenter -W rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 --wdns rm -rf b" "$(bash_payload 'nsenter -t 1 --wdns rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter --wdns=/x -t 1 rm -rf b" "$(bash_payload 'nsenter --wdns=/x -t 1 rm -rf b')"
# an attached optional value is part of its flag word (nsenter's m u i n p C U T r w W are "::"), however
# it ends: `-m/proc/1/ns/mnt` is -m with that path, not -t. Bundled clusters are GH #709.
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -m/proc/1/ns/mnt rm -rf b" "$(bash_payload 'nsenter -m/proc/1/ns/mnt rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -n/proc/1/ns/net rm -rf b" "$(bash_payload 'nsenter -n/proc/1/ns/net rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 -m/proc/1/ns/mnt sh -c 'rm -rf b'" "$(bash_payload "nsenter -t 1 -m/proc/1/ns/mnt sh -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 -r/mnt rm -rf b" "$(bash_payload 'nsenter -t 1 -r/mnt rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -rS rm -rf b" "$(bash_payload 'nsenter -rS rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -fw/x rm -rf b" "$(bash_payload 'unshare -fw/x rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: subagent: nsenter -m/proc/1/ns/mnt claude -p x" "$(bash_agent_payload 'nsenter -m/proc/1/ns/mnt claude -p x' fork)"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter --target 1 -r -w rm -rf b" "$(bash_payload 'nsenter --target 1 -r -w rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chpst -u x -/ /r -b y rm -rf b" "$(bash_payload 'chpst -u x -/ /r -b y rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chpst -v -P -n 5 rm -rf b" "$(bash_payload 'chpst -v -P -n 5 rm -rf b')"
# nested, behind another wrapper or a path, and the other rules and shell bodies through them
test_deny  "$IRRECOVERABLE" "GH #676: busybox chroot / rm -rf b" "$(bash_payload 'busybox chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: sudo chroot / rm -rf b" "$(bash_payload 'sudo chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: /usr/sbin/chroot / rm -rf b" "$(bash_payload '/usr/sbin/chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset 1 setuidgid x rm -rf b" "$(bash_payload 'taskset 1 setuidgid x rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chroot / bash -c 'rm -rf b'" "$(bash_payload "chroot / bash -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #676: unshare dd of=/dev/sda" "$(bash_payload 'unshare dd if=/dev/zero of=/dev/sda')"
test_deny  "$IRRECOVERABLE" "GH #676: subagent: taskset 1 claude -p x" "$(bash_agent_payload 'taskset 1 claude -p x' fork)"
test_allow "$IRRECOVERABLE" "GH #676 control: chroot /srv/root ls" "$(bash_payload 'chroot /srv/root ls')"
test_allow "$IRRECOVERABLE" "GH #676 control: chroot /srv/root (a shell, no command)" "$(bash_payload 'chroot /srv/root')"
test_allow "$IRRECOVERABLE" "GH #676 control: taskset -p 700" "$(bash_payload 'taskset -p 700')"
test_allow "$IRRECOVERABLE" "GH #676 control: taskset -c 0 make -j4" "$(bash_payload 'taskset -c 0 make -j4')"
test_allow "$IRRECOVERABLE" "GH #676 control: unshare -r id" "$(bash_payload 'unshare -r id')"
test_allow "$IRRECOVERABLE" "GH #676 control: nsenter -t 1 -n ip addr" "$(bash_payload 'nsenter -t 1 -n ip addr')"
test_allow "$IRRECOVERABLE" "GH #676 control: nsenter -W ls" "$(bash_payload 'nsenter -W ls')"
test_allow "$IRRECOVERABLE" "GH #676 control: chpst -u www ls" "$(bash_payload 'chpst -u www ls')"
test_allow "$IRRECOVERABLE" "GH #676 control: setuidgid www ls -la" "$(bash_payload 'setuidgid www ls -la')"
test_allow "$IRRECOVERABLE" "GH #676 control: echo chroot / rm -rf b" "$(bash_payload 'echo chroot / rm -rf b')"

# GH #690: brace-view's expanded text is also read with the ifs-split and subst-literal rewrites applied.
test_deny  "$IRRECOVERABLE" 'GH #690: r{m,m}${IFS}-rf b' "$(bash_payload 'r{m,m}${IFS}-rf b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm${IFS}--{r,f} b' "$(bash_payload 'rm${IFS}--{r,f} b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm --{r,f}${IFS}b' "$(bash_payload 'rm --{r,f}${IFS}b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm $(echo --{r,f}) b' "$(bash_payload 'rm $(echo --{r,f}) b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm `echo --{r,f}` b' "$(bash_payload 'rm `echo --{r,f}` b')"
test_deny  "$IRRECOVERABLE" 'GH #690: r{m,m}${IFS}$(echo -{r,f}) b' "$(bash_payload 'r{m,m}${IFS}$(echo -{r,f}) b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm $(printf -- --{recursive,force}) b' "$(bash_payload 'rm $(printf -- --{recursive,force}) b')"
test_allow "$IRRECOVERABLE" 'GH #690 control: echo {a,b}${IFS}x; ls' "$(bash_payload 'echo {a,b}${IFS}x; ls')"
test_allow "$IRRECOVERABLE" 'GH #690 control: mkdir -p {a,b}/c && echo $(echo hi)' "$(bash_payload 'mkdir -p {a,b}/c && echo $(echo hi)')"
test_allow "$IRRECOVERABLE" 'GH #690 control: rm -f {a,b}.log $(echo c.log)' "$(bash_payload 'rm -f {a,b}.log $(echo c.log)')"
# The composed copies run on ~63 KB of brace text here; develop allows the second row, so it proves they ran.
_timed_case 'GH #690: 3000 {a,b}${IFS}$(echo c) words are read in bounded time' 0 \
  "echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 3000))"
_timed_case 'GH #690: r{m,m}${IFS}-rf after 3000 brace words denies in bounded time' 2 \
  "echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 3000)); r{m,m}\${IFS}-rf b"

# GH #713: the $(...) closer had no comment state, so a commented ")" ended it before bash and the "'" in the
# comment hid the rest; and a funsub ended at any "}", where bash ends it only at a "}" in command position,
# so a "}" argument inside "..." left the rest in the gate's quotes. bash 5.3 runs @V@ in each.
_p713=("echo \$( : # )'$_N@V@$_N: # '$_N)" "echo \${x:-\$( : # )'$_N@V@$_N: # '$_N)}"
  "echo \"\$( : # )'$_N@V@$_N: # '$_N)\"" "echo \$(: #)'$_N@V@$_N#'$_N)" "x=\$( : # )'$_N@V@$_N: # '$_N)"
  'echo "${ echo }; @V@; }"' 'echo "${ echo a}b; @V@; }"' 'echo "${| echo }; @V@; }"' 'x="${ echo }; @V@; }"'
  'echo "${ printf %s }; @V@; }"' 'echo "${ echo {; @V@; }"' 'echo "${ echo \;}; @V@; }"'
  # a "#" after an escaped char is mid-word, so bash closes the $(...) at the next ")"
  "echo \"\$( : \\ #)'\"$_N@V@$_N\"'$_N)\"" "echo \"\$( : \\;#)'\"$_N@V@$_N\"'$_N)\""
  "x=\"\$( : \\ #)'\"$_N@V@$_N\"'$_N)\"")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p713[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #713: $_c" "$(bash_payload "$_c")"
  done
done
for _c in 'echo $(grep "#" f)' "echo \$(grep '#' f)" 'echo $(echo ${#x})' 'echo $(( 16#ff ))' \
  "echo \$(awk -F'#' '{print \$1}' f)" 'echo $(sed "s/#.*//" f)' "echo \$(git log --format='%h #%s' -1)" \
  "echo \$(ls # list$_N)" 'echo ${ echo {a,b}; }' 'echo ${ f() { echo; }; f; }' \
  'echo ${ if true; then { echo; }; fi; }' 'echo "${ echo a; }"' 'echo ${x:-${ echo a; }}' \
  'echo "${ true && { echo a; }; }"' 'echo "${ (echo a) }"' "echo \"\${ echo a$_N}\"" 'echo "${ echo a;}"' \
  'echo $(echo \ #)' 'echo "$(printf %s \ #)"' 'echo $(echo a\ #b)'; do
  test_allow "$IRRECOVERABLE" "GH #713 control: $_c" "$(bash_payload "$_c")"
done
test_deny_says "$IRRECOVERABLE" "GH #713: a funsub whose \"}\" argument ends it early names the substitution" \
  "$(bash_payload 'echo "${ echo }; rm -rf ~/x; }"')" "substitution ends at a different place"
# kept on purpose: a harmless funsub with a "}" argument over-denies (fail closed), quoted or not
test_deny_says "$IRRECOVERABLE" "GH #713: a funsub with a \"}\" argument over-denies, by design" \
  "$(bash_payload 'echo ${ echo }; }')" "substitution ends at a different place"
_timed_case 'GH #713: a commented-) $(...) target before 9000 $(echo #) words denies in bounded time' 2 \
  "echo \$( : # )'${_N}rm -rf ~/x$_N: # '$_N) $(printf '$(echo "#") %.0s' $(seq 9000))"
_timed_case 'GH #713: a commented-) $(...) target after 9000 $(echo #) words denies in bounded time' 2 \
  "echo $(printf '$(echo "#") %.0s' $(seq 9000))\$( : # )'${_N}rm -rf ~/x$_N: # '$_N)"
_timed_case 'GH #713: 10000 $(echo #) words are read in bounded time' 0 \
  "echo $(printf '$(echo "#") %.0s' $(seq 10000))"
_timed_case 'GH #713: 5000 "${ echo a; }" funsubs are read in bounded time' 0 \
  "echo $(printf '"${ echo a; }" %.0s' $(seq 5000))"

# GH #726: the same $(...) inside a ${...} word with "..." around the ${...} or inside the word: the word is read
# quote-blind, so #713's newline split (done only inside "...") never ran. bash 5.3 runs @V@ in each.
_p726=("echo \"\${x:-\$( : # )'$_N@V@$_N: # '$_N)}\"" "echo \${x:-\"\$( : # )'$_N@V@$_N: # '$_N)\"}"
  "z=\"\${x:+\$(: #)'$_N@V@$_N#'$_N)}\"" "echo \"a\${x#\$( : # )'$_N@V@$_N: # '$_N)}b\""
  "echo \${x/\"\$(: #)'$_N@V@$_N#'$_N)\"/y}" "echo \"\${x:-\${x:-\$( : # )'$_N@V@$_N: # '$_N)}}\""
  "echo \"\${x:-\$(: #)'$_N@V@$_N#'$_N)}\"")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p726[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #726: $_c" "$(bash_payload "$_c")"
  done
done
for _c in "echo \"\${x:-\$(ls # list$_N)}\"" "echo \${x:-\"\$(date$_N)\"}" "echo \"\${x:-\$(echo a$_N echo b)}\""; do
  test_allow "$IRRECOVERABLE" "GH #726 control: $_c" "$(bash_payload "$_c")"
done

# GH #674: a shell reads its commands on stdin behind a wrapper, with its own wrapper options, or with its own
# -o NAME / +o NAME pairs; the echo feeding it may sit behind a wrapper or an assignment too.
for _c674 in "echo 'rm -rf b' | command -p sh" "echo 'rm -rf b' | time -p sh" "echo 'rm -rf b' | bash -o pipefail" \
  "bash -o pipefail <<< 'rm -rf b'" "echo 'rm -rf b' | nice sh" "echo 'rm -rf b' | nice -n 5 sh" \
  "echo 'rm -rf b' | timeout 5 sh" "echo 'rm -rf b' | timeout -s KILL 5 sh" "echo 'rm -rf b' | env -i sh" \
  "echo 'rm -rf b' | env -u HOME sh" "echo 'rm -rf b' | sudo -u bob sh" "echo 'rm -rf b' | dash -o errexit" \
  "echo 'rm -rf b' | bash +o histexpand" "echo 'rm -rf b' | bash -eo pipefail" "echo 'rm -rf b' | builtin command sh" \
  "echo 'rm -rf b' | FOO=1 sh" "echo 'rm -rf b' | nohup nice timeout 5 sh" \
  "echo 'rm -rf b' | nsenter -t 1 sh" "echo 'rm -rf b' | chroot / sh" "chroot / sh <<< 'rm -rf b'" \
  "echo 'rm -rf b' | unshare sh" "echo 'rm -rf b' | taskset 1 bash" "echo 'rm -rf b' | chpst -u x sh" \
  "echo 'rm -rf b' | setuidgid x sh" "echo 'rm -rf b' | flock f sh" "echo 'rm -rf b' | strace -o log sh" \
  "sudo echo 'rm -rf b' | sh" "env echo 'rm -rf b' | sh" "FOO=1 echo 'rm -rf b' | sh" \
  "timeout 5 echo 'rm -rf b' | sh" "nice -n 5 printf 'rm -rf b' | sh" "echo 'rm -rf b' | watch sh" \
  "echo 'rm -rf b' | bash -O extglob" "bash +O extglob <<< 'rm -rf b'" "echo 'rm -rf b' | timeout 5 bash -o nounset -O extglob" \
  "echo 'rm -rf b' | sudo --prompt x sh" "echo 'rm -rf b' | sudo -T 5 sh" \
  "echo 'rm -rf b' | sh 2>/dev/null" "echo 'rm -rf b' | sh 2>&1" "echo 'rm -rf b' | sh >log" "echo 'rm -rf b' | sh > log" \
  "echo 'rm -rf b' | 2>/dev/null sh" "echo 'rm -rf b' | timeout 5 sh 2>/dev/null" "echo 'rm -rf b' | sh &>log" \
  "sh 2>/dev/null <<< 'rm -rf b'"; do
  test_deny "$IRRECOVERABLE" "GH #674: $_c674" "$(bash_payload "$_c674")"
done
test_deny  "$IRRECOVERABLE" "GH #674: cat <<EOF | timeout 5 sh" "$(bash_payload $'cat <<EOF | timeout 5 sh\nrm -rf b\nEOF')"
test_deny  "$IRRECOVERABLE" "GH #674: cat <<EOF | nsenter -t 1 sh" "$(bash_payload $'cat <<EOF | nsenter -t 1 sh\nrm -rf b\nEOF')"
for _c674 in "echo 'ls' | timeout 5 sh" "echo 'rm -rf b' | bash -o pipefail x.sh" "echo 'rm -rf b' | timeout 5 sh x.sh" \
  "echo 'rm -rf b' | flock f -c ls" "echo 'rm -rf b' | sh < in.sh" "echo 'rm -rf b' | bash -O extglob x.sh" \
  "echo 'rm -rf b' | sh x.sh 2>/dev/null" "echo 'rm -rf b' | sudo -u bob cat" "echo 'rm -rf b' | nice grep rm" \
  "echo 'rm -rf b' | env -i bash -c ls" "printf 'ls\n' | nice sh"; do
  test_allow "$IRRECOVERABLE" "GH #674 control: $_c674" "$(bash_payload "$_c674")"
done

# Force-push spec v3: the WHOLE command, as one plain `git [-C P] push [opts] <remote> <src:dst>...` with no
# protected dst or lease ref, is the one allowed force push. Leases count as forced everywhere else.
for _c in 'git push -f origin HEAD:feat' 'git push --force origin HEAD:feat' 'git push origin +HEAD:feat' \
  'git push -f origin feat:refs/heads/feat' 'git push -fu origin HEAD:feat' 'git push -fq origin HEAD:feat' \
  'git push -fv origin HEAD:feat' 'git push -fn origin HEAD:feat' 'git push -f -u -q -v -n origin HEAD:feat' \
  'git push --force --set-upstream origin HEAD:feat' 'git push --force --quiet origin HEAD:feat' \
  'git push --force --verbose origin HEAD:feat' 'git push --force --dry-run origin HEAD:feat' \
  'git push --force --atomic origin HEAD:feat' 'git push --force --porcelain origin HEAD:feat' \
  'git push --force --progress origin HEAD:feat' 'git push --force --no-progress origin HEAD:feat' \
  'git push --force-with-lease origin HEAD:feat' 'git push --force-if-includes --force-with-lease origin HEAD:feat' \
  'git push --force-with-lease=feat origin HEAD:feat' 'git push --force-with-lease=feat:abc1234 origin HEAD:feat' \
  'git push --force-with-lease=refs/heads/feat:0123456789abcdef0123456789abcdef01234567 origin HEAD:feat' \
  'git -C ~/x push -f origin HEAD:feat' 'git -C ../repo push -f origin HEAD:feat' 'git -C push push -f origin HEAD:feat' \
  'git push -f origin a:feat-a +b:feat-b c:refs/heads/feat-c' 'git push -f upstream v1.2@x:feature/main' \
  'git push -f origin HEAD:mainline' 'git push -f origin HEAD:release' '  git push -f origin HEAD:feat  '; do
  test_allow "$IRRECOVERABLE" "force-push v3 strict allow: $_c" "$(bash_payload "$_c")"
done
for _d in main master develop production staging release/1.0 Main MASTER Develop refs/heads/main heads/develop \
  Refs/Heads/Staging RELEASE/x refs/heads/release/2; do
  test_deny "$IRRECOVERABLE" "force-push v3: protected dst $_d" "$(bash_payload "git push -f origin HEAD:$_d")"
done
for _c in 'git push -f origin a:feat b:main' 'git push origin +HEAD:production' 'git push --force-with-lease origin HEAD:main' \
  'git push --force-with-lease=main origin HEAD:feat' 'git push --force-with-lease=refs/heads/main:abc1234 origin HEAD:feat' \
  'git push --force-with-lease=Release/9:abcd origin HEAD:feat' 'git push --force-with-lease=main:abc origin HEAD:feat' \
  'git push -f origin a:b:feat' 'git push 2>&1 -f origin HEAD:feat' 'git push -f origin HEAD:feat &>/dev/null' \
  'git push -f origin HEAD:feat <<< x' 'git push --repo=origin -f HEAD:feat' 'echo HEAD:feat | xargs git push -f origin' \
  'legit=1 xargs git push -f origin HEAD:feat' 'git push --force-with-lease origin :/msg:main' \
  'git push --recurse-submodules=on-demand -f origin HEAD:feat' 'git push -fo ci.skip origin HEAD:feat' \
  'git push -f -o ci.skip origin HEAD:feat' 'git push --m -f origin HEAD:feat' 'git push -f git@github.com:o/r.git HEAD:feat' \
  'git push -f https://github.com/o/r HEAD:feat' 'cd $(mktemp -d) && git push -f origin HEAD:feat' \
  'git push> x -f origin HEAD:feat' 'git push -f origin HEAD:feat && echo ok' 'git push  -f origin HEAD:feat' \
  $'git push\t-f origin HEAD:feat' $'git push -f origin HEAD:feat\necho ok' 'git push -f origin "HEAD:feat"' \
  "git push -f origin 'HEAD:feat'" 'git push -f --mirror HEAD:feat' 'git push -f --all origin:feat' \
  'git push --force -u HEAD:feat' 'git -c remote.origin.push=+HEAD:main push -f origin HEAD:feat' \
  'git push --force-with-lease origin develop' 'git push --force-with-lease=main:12345 origin develop' \
  'git push --force-with-lease --force-if-includes origin develop' 'git push --force-if-includes origin feat' \
  'git push --force-with-lease origin feat' 'sudo git push -f origin HEAD:feat' 'git send-pack -f origin HEAD:feat'; do
  test_deny "$IRRECOVERABLE" "force-push v3 deny: $_c" "$(bash_payload "$_c")"
done

# GH #750: the Bash tool sources the user's shell snapshot, so oh-my-zsh's git-plugin push aliases and
# functions run `git push`. Each is read as its git push text; none gets the strict force-push allow.
for _c in 'gp -f' 'gpf' 'ggp -f' 'gpu --force' \
  'gp -f origin main' 'gpd -f origin main' 'gpf origin feat' 'gpf! origin feat' 'gpsup -f' 'gpsupf' \
  'gpv -f origin main' 'gpoat -f' 'gpod -f origin x' 'ggpush -f' 'gpu -f main' 'ggf' 'ggf feat' 'ggfl feat' \
  'ggp --force main' 'gp origin +HEAD:main' 'gp --mirror origin' 'gpod main' 'gp origin :develop' \
  'sudo gp -f origin main' 'env gp -f origin main' "sh -c 'gpf! origin feat'" 'echo x && gp -f origin main' \
  '"gp" -f origin main' 'gp -f origin HEAD:feat' 'ggp -f origin HEAD:feat' \
  'ggpnp -f' 'grename main foo' 'grename develop x' 'echo x; grename Master y' 'grename feat -f'; do
  test_deny "$IRRECOVERABLE" "GH #750 push alias: $_c" "$(bash_payload "$_c")"
done
for _c in 'gp' 'gp origin feat' 'gpu' 'ggp' 'ggp feat' 'gpsup' 'gpd origin main' 'gpv' 'ggpush' 'gpoat' \
  'gpod feat' 'gpg --verify x.sig' 'echo gp -f' 'git push origin HEAD:feat' \
  'ggpnp' 'ggpnp feat' 'grename feat x' 'grename'; do
  test_allow "$IRRECOVERABLE" "GH #750 push alias control: $_c" "$(bash_payload "$_c")"
done
# Operator 2026-10-31: #750 stays push-only, so `alias g='git'` is not read (the general alias table is #781).
# These pin that scope; #781 flips them if it widens the table.
for _c in 'g push -f origin main' 'g reset --hard' 'g>/dev/null push -f origin main'; do
  test_allow "$IRRECOVERABLE" "GH #750 scope: g is not read as git: $_c" "$(bash_payload "$_c")"
done
echo ""
echo "=== GH #771: the python gate's own deadline asks, never times out silently ==="
MH_IRR_DEADLINE_SECS=0.001 test_ask_says "$IRRECOVERABLE" "forced deadline expiry on an allowed candidate command asks, reason says time" \
  "$(bash_payload 'git status && git log -1')" "time"
MH_IRR_DEADLINE_SECS=0.001 test_ask "$IRRECOVERABLE" "forced deadline expiry emits exactly one ask JSON" "$(bash_payload 'git status')"
if python3 - "$ROOT/hooks/gates/irrecoverable.py" "$ROOT/hooks/hooks.json" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^DEADLINE_SECS = ([0-9.]+)", src, re.M)
hooks = [h for e in json.load(open(sys.argv[2]))["hooks"]["PreToolUse"] for h in e["hooks"]]
irr = [h for h in hooks if "irrecoverable.sh" in h["command"]]
others = [h for h in hooks if "irrecoverable.sh" not in h["command"] and "onFailure" in h]
assert m and len(irr) == 1, "constant or entry missing"
assert float(m.group(1)) <= irr[0]["timeout"] / 2, "deadline not well under the hook timeout"
assert irr[0].get("onFailure") == "block", "irrecoverable.sh lacks onFailure block"
assert not others, "onFailure set on another entry"
PY
then echo "  ✅ DEADLINE_SECS is at most half the hooks.json timeout; onFailure block on irrecoverable.sh only"; pass=$((pass + 1))
else echo "  ❌ deadline/onFailure contract broken" >&2; fail=$((fail + 1)); fi

# The PATH-stub and gate-copy dirs above (GH #729: they leaked on every run).
tmp_delete "$NOPY_BIN" "$TRASHLESS_BIN" "$MISSPY_IRR_DIR"

# GH #741: a python/node stage that reads its script from a heredoc and pipes its stdout into a shell reading
# stdin hands that shell code the gate never sees (print("git reset --hard") | bash), so it denies whatever the
# body prints. A pipe into anything else, or a heredoc python only reads, keeps the GH #681 reading, and so does
# one inside $( or a backtick (x=$(python3 - <<'EOF' | sh): its re-read timed out (GH #741 review 2), so it was dropped.
# The rule enforces (operator, 2026-11-01, after the attack review): each row denies.
_rows741() { # <journal>: would_deny rows for interp-pipe-shell
  python3 -c 'import json,sys; print(sum(json.loads(l).get("decision") == "would_deny" and json.loads(l).get("rule") == "interp-pipe-shell" for l in open(sys.argv[1])))' "$1"
}
_would741() { # <cmd>: interp-pipe-shell enforces -> deny
  test_deny "$IRRECOVERABLE" "GH #741 interpreter heredoc piped to a shell: ${1//$'\n'/ | }" "$(bash_payload "$1")"
}
for _c in $'python3 - <<\'EOF\' | bash\nprint("git reset --hard")\nEOF' \
  $'python3 - <<\'EOF\' | sh\nprint("ls")\nEOF' $'python3 <<EOF | dash\nprint("ls")\nEOF' \
  $'node - <<\'EOF\' | zsh\nconsole.log("ls")\nEOF' $'nodejs <<\'EOF\' | ksh\nconsole.log("ls")\nEOF' \
  $'cat <<\'EOF\' | python3 - | bash\nprint("ls")\nEOF' $'python3 - <<\'EOF\' | tee out.log | bash\nprint("ls")\nEOF' \
  $'python3 -u - <<\'EOF\' | sudo bash -s\nprint("ls")\nEOF' $'git status; python3 - <<\'EOF\' 2>/dev/null | sh\nprint("ls")\nEOF'; do
  _would741 "$_c"
done
for _c in $'python3 - <<\'EOF\'\nprint("bash")\nEOF' $'python3 - <<\'EOF\' | grep bash\nprint("bash")\nEOF' \
  $'node - <<\'EOF\' | sort\nconsole.log("sh")\nEOF' $'python3 - <<\'EOF\' | bash x.sh\nprint("ls")\nEOF' \
  $'cat <<\'EOF\' | bash\nls\nEOF' $'python3 - <<\'EOF\'\nprint(1)\nEOF\necho ok | sh -c cat' \
  $'x=$(python3 - <<\'EOF\' | sh\nprint("ls")\nEOF\n)' $'echo "`node - <<\'EOF\' | bash\nconsole.log(1)\nEOF\n`"'; do
  : > "$_JOURNAL_TMP/a741.jsonl"
  test_allow "$IRRECOVERABLE" "GH #741 control: ${_c//$'\n'/ | }" "$(bash_payload "$_c")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a741.jsonl"
  if [[ "$(_rows741 "$_JOURNAL_TMP/a741.jsonl")" == "0" ]]; then
    echo "  ✅ GH #741 control journals no would_deny: ${_c//$'\n'/ | }"; pass=$((pass + 1))
  else
    echo "  ❌ GH #741 control journaled a would_deny row: ${_c//$'\n'/ | }" >&2; fail=$((fail + 1))
  fi
done
# GH #741: the process-API scan (GH #608 -c bodies, GH #681 heredoc scripts) also reads asyncio's
# create_subprocess_shell/exec, the argv-list exec/spawn forms whose first literal is the path (execvp("git",
# ["git", ...])), and getattr/importlib.import_module/__import__ next to a process-module name.
for _p in 'import asyncio; asyncio.run(asyncio.create_subprocess_shell("git reset --hard"))' \
  'import asyncio; asyncio.run(asyncio.create_subprocess_exec("git", "reset", "--hard"))' \
  'import os; os.execvp("git", ["git", "reset", "--hard"])' 'import os; os.execv("/usr/bin/git", ["git", "reset", "--hard"])' \
  'import os; os.spawnlp(os.P_WAIT, "git", "git", "reset", "--hard")' \
  'import os; os.posix_spawnp("git", ["git", "reset", "--hard"], os.environ)' \
  'import os; getattr(os, "sys" + "tem")("git reset --hard")' \
  'import importlib; importlib.import_module("os").__dict__["sys" + "tem"]("git reset --hard")' \
  '__import__("os").__dict__["sys" + "tem"]("git reset --hard")'; do
  test_deny "$IRRECOVERABLE" "GH #741 python -c: $_p" "$(bash_payload "python3 -c '$_p'")"
  test_deny "$IRRECOVERABLE" "GH #741 python heredoc: $_p" "$(bash_payload "python3 - <<'EOF'"$'\n'"${_p//; /$'\n'}"$'\nEOF')"
done
for _p in 'import asyncio; print("create_subprocess_shell is async")' 'import os; os.execvp("ls", ["ls", "-l"])' \
  'import subprocess; subprocess.run(["echo", "rm", "-rf", "build"])' 'import os; print(getattr(os, "sep"), "done")' \
  'import importlib; importlib.import_module("json"); print("git reset --hard")'; do
  test_allow "$IRRECOVERABLE" "GH #741 control python -c: $_p" "$(bash_payload "python3 -c '$_p'")"
  test_allow "$IRRECOVERABLE" "GH #741 control python heredoc: $_p" "$(bash_payload "python3 - <<'EOF'"$'\n'"${_p//; /$'\n'}"$'\nEOF')"
done
# GH #741: trash-whole-tree also reads every dotfile of home (~/.*, $HOME/.*). A quoted braced home glob ("${HOME}/"*,
# "${HOME}/."*) keeps develop's reading: its widened raw regex failed two reviews on time (GH #741 reviews 1 and 3).
for _c in 'trash ~/.*' 'trash $HOME/.*' 'trash "$HOME"/.*' 'trash ./.*' 'gio trash ~/.*'; do
  test_deny "$IRRECOVERABLE" "GH #741 trash whole tree: $_c" "$(bash_payload "$_c")"
done
for _c in 'trash ~/foo' 'trash ~/.cache' 'trash ~/.*.bak' 'trash "${HOME}/foo"' 'trash "${HOME}/"*.log' 'trash ./.cache' \
  'trash "${HOME}/"*' 'trash "${HOME}/."*'; do
  test_allow "$IRRECOVERABLE" "GH #741 trash control: $_c" "$(bash_payload "$_c")"
done
# GH #741 review: a full-path argv0 in an exec argv list, and a getattr on a process
# module whose name is one plain literal (the API it names is read on its own: getattr(os, "system") still is).
_c="python3 -c 'import os; os.execv(\"/usr/bin/git\", [\"/usr/bin/git\", \"reset\", \"--hard\"])'"
test_deny "$IRRECOVERABLE" "GH #741 review: $_c" "$(bash_payload "$_c")"
for _c in "python3 -c 'import os; print(getattr(os, \"sep\")); print(\"rm -rf build\")'" \
  $'python3 - <<\'EOF\'\nimport os\nprint(getattr(os.path, "sep"))\nprint("rm -rf node_modules is what the docs say")\nEOF'; do
  test_allow "$IRRECOVERABLE" "GH #741 review control: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
test_deny "$IRRECOVERABLE" "GH #741 review: getattr(os, \"system\") still reads its literals" \
  "$(bash_payload "python3 -c 'import os; getattr(os, \"system\")(\"git reset --hard\")'")"
# GH #741 review 3: in a heredoc script (GH #681: read only on a call) the asyncio and posix_spawn names count only
# when called; a comment or string naming them is prose.
for _c in $'python3 - <<\'EOF\'\n# docs: posix_spawn is faster\nprint("rm -rf build")\nEOF' \
  $'python3 - <<\'EOF\'\ns = \'use create_subprocess_exec\'\nprint(\'git reset --hard\')\nEOF'; do
  test_allow "$IRRECOVERABLE" "GH #741 review 3 control: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
# GH #741 review: each new scan in bounded time (repo-gotchas: time every new regex and scan piece). An unquoted
# ${HOME} before a long run of slashes (the home regex), and 12000 heredoc openers before 37000 pipe stages (the
# interpreter-to-shell walk, unquoted delimiters included), the target before the openers (the body lines after
# them are read as before, GH #681).
_timed_case 'GH #741 review: ${HOME} before 30000 slashes, then git reset --hard, denies in bounded time' 2 \
  "chmod 777 \${X} \${HOME}$(printf '/%.0s' $(seq 30000))x; git reset --hard"
_timed_case 'GH #741 review: trash ${HOME} before 30000 slashes, then git reset --hard, denies in bounded time' 2 \
  "trash \$(true) \${HOME}$(printf '/%.0s' $(seq 30000))x; git reset --hard"
_timed_case 'GH #741 review: git reset --hard before 12000 node heredoc openers and 37000 pipe stages denies in bounded time' 2 \
  "git reset --hard; node x <<A|$(printf '<<A|%.0s' $(seq 12000))$(printf 'x|%.0s' $(seq 37000))cat"$'\n'"$(printf 'A\n%.0s' $(seq 12001))echo ok"
_timed_case "GH #741 review: git reset --hard before 9000 quoted node heredoc openers and 30000 pipe stages denies in bounded time" 2 \
  "git reset --hard; node x <<'A'|$(printf "<<'A'|%.0s" $(seq 9000))$(printf 'x|%.0s' $(seq 30000))cat"$'\n'"$(printf 'A\n%.0s' $(seq 9001))echo ok"
# GH #741 review 3: trash's placeholder words re-read its raw arguments (quadratic since develop); a widened
# braced-home regex there pushed 48 KB past the hook timeout, so it was dropped. A guard against a slower scan, not a
# red row: sized well under the gate's own 4 s deadline (GH #771, which asks on expiry) on develop's reading too,
# since 1500 placeholders already reach that deadline on develop under gauntlet load.
_timed_case 'GH #741 review 3: trash with 600 placeholders and 430 "${HOME}/" words, then git reset --hard, denies in bounded time' 2 \
  "trash $(printf '"$(true)" %.0s' $(seq 600))$(printf '"${HOME}/"/x %.0s' $(seq 430))"$'\n'"git reset --hard"
# GH #741 review 4: a substitution word ending /.* ($(x)/.*) is not a bare placeholder (develop's reading), so it never
# enters that per-placeholder re-read: 3100 of them took 6 s once the /.* strip made each one bare.
_timed_case 'GH #741 review 4: trash with 3100 $(x)/.* words, then git reset --hard, denies in bounded time' 2 \
  "trash $(printf '$(x)/.* %.0s' $(seq 3100)); git reset --hard"
_timed_case 'GH #741 review 4: trash with 3100 `x`/.* words, then git reset --hard, denies in bounded time' 2 \
  "trash $(printf '`x`/.* %.0s' $(seq 3100)); git reset --hard"
# GH #741 review 5: the python/node word test ran once per heredoc opener over the whole line; a cat line of 18000
# quoted openers took 5.4 s (develop 3 s). It now runs once per line.
_timed_case "GH #741 review 5: git reset --hard before a cat line of 18000 quoted heredoc openers denies in bounded time" 2 \
  "git reset --hard"$'\n'"cat $(printf "<<'o' %.0s" $(seq 18000))"$'\n'"$(printf 'o\n%.0s' $(seq 18000))"
# GH #741 review 6: the shell check split every pipe stage of a python/node heredoc line (two shlex.split calls each),
# for unquoted delimiters too, about 1 s per 60000 stages; past the 4 s deadline (GH #771) with $( frames added. A
# stage that names no shell or python/node (quotes and backslashes removed) is no longer split, and a line with no
# shell word is not walked. Guards, not red rows: the old head took about 2.3 s here, under the 4 s bound.
_timed_case 'GH #741 review 6: git reset --hard before an unquoted python heredoc of 70000 pipe stages denies in bounded time' 2 \
  "git reset --hard"$'\n'"python3 - <<Z$(printf '|x%.0s' $(seq 70000))"$'\n'"Z"
_timed_case 'GH #741 review 6: an unquoted node heredoc of 70000 pipe stages is allowed in bounded time' 0 \
  "node - <<A$(printf '|x%.0s' $(seq 70000))"$'\n'"A"
# GH #741 review 2: heredocs nested in ( frames, each piped through many stages, are read in bounded time (a re-read
# from each frame's ( parsed every stage once per frame: 300 frames of 30 stages took 8-9 s, past the hook timeout).
_timed_case 'GH #741 review 2: git reset --hard before 300 python heredoc frames of 30 pipe stages denies in bounded time' 2 \
  "$(python3 -c "n = 300; print('git reset --hard\\n' + ''.join('(python3 - <<A%d' % i + ' | x' * 30 for i in range(n)) + ')' * n + ''.join('\\nx\\nA%d' % i for i in range(n)))")"
_timed_case 'GH #741 review 2: 1000 python heredoc frames piped into cat are allowed in bounded time' 0 \
  "$(python3 -c "n = 1000; print(''.join('(python3 - <<A%d | cat' % i for i in range(n)) + ')' * n + ''.join('\\nx\\nA%d' % i for i in range(n)))")"

# GH #718: a view no longer stops on the brace-token ambiguity the main reading already checked, and a literal
# substitution's unquoted output is split into words as the shell does.
test_deny  "$IRRECOVERABLE" 'GH #718: echo {a,b}; git${IFS}reset --hard' "$(bash_payload 'echo {a,b}; git${IFS}reset --hard')"
test_deny  "$IRRECOVERABLE" 'GH #718: echo {a,b}; git${IFS}clean${IFS}-fdx' "$(bash_payload 'echo {a,b}; git${IFS}clean${IFS}-fdx')"
test_deny  "$IRRECOVERABLE" 'GH #718: mkdir -p {a,b}; git${IFS}reset${IFS}--hard' "$(bash_payload 'mkdir -p {a,b}; git${IFS}reset${IFS}--hard')"
test_deny  "$IRRECOVERABLE" 'GH #718: echo {a,b} && git${IFS}reset${IFS}--hard' "$(bash_payload 'echo {a,b} && git${IFS}reset${IFS}--hard')"
test_deny  "$IRRECOVERABLE" 'GH #718: echo {a,b}; git${IFS}checkout${IFS}--${IFS}.' "$(bash_payload 'echo {a,b}; git${IFS}checkout${IFS}--${IFS}.')"
test_deny  "$IRRECOVERABLE" 'GH #718: echo {a,b}; git${IFS}stash${IFS}drop' "$(bash_payload 'echo {a,b}; git${IFS}stash${IFS}drop')"
test_deny  "$IRRECOVERABLE" 'GH #718: rm $(echo '"'"' -rf'"'"') b' "$(bash_payload 'rm $(echo '"'"' -rf'"'"') b')"
test_deny  "$IRRECOVERABLE" 'GH #718: rm `echo '"'"' -rf'"'"'` b' "$(bash_payload 'rm `echo '"'"' -rf'"'"'` b')"
test_deny  "$IRRECOVERABLE" 'GH #718: rm $(printf -- '"'"' -rf'"'"') b' "$(bash_payload 'rm $(printf -- '"'"' -rf'"'"') b')"
test_deny  "$IRRECOVERABLE" 'GH #718: subagent: echo {a,b}; git${IFS}reset --hard' "$(bash_agent_payload 'echo {a,b}; git${IFS}reset --hard' fork)"
test_allow "$IRRECOVERABLE" 'GH #718 control: echo {a,b}; git${IFS}status' "$(bash_payload 'echo {a,b}; git${IFS}status')"
test_allow "$IRRECOVERABLE" 'GH #718 control: echo {a,b}; git${IFS}reset --soft HEAD~1' "$(bash_payload 'echo {a,b}; git${IFS}reset --soft HEAD~1')"
test_allow "$IRRECOVERABLE" 'GH #718 control: git commit -m "$(echo "don'"'"'t rm -rf /")"' "$(bash_payload 'git commit -m "$(echo "don'"'"'t rm -rf /")"')"
test_allow "$IRRECOVERABLE" 'GH #718 control: git commit -m "$(printf '"'"'%s'"'"' '"'"'fix: rm -rf docs'"'"')"' "$(bash_payload 'git commit -m "$(printf '"'"'%s'"'"' '"'"'fix: rm -rf docs'"'"')"')"
test_allow "$IRRECOVERABLE" 'GH #718 control: rm -f $(echo '"'"'*.log'"'"')' "$(bash_payload 'rm -f $(echo '"'"'*.log'"'"')')"
# GH #718: brace-view enforces git's discard rules: a brace inside the git words was read only there.
test_deny  "$IRRECOVERABLE" 'GH #718: git reset --{hard,hard}' "$(bash_payload 'git reset --{hard,hard}')"
test_deny  "$IRRECOVERABLE" 'GH #718: git${IFS}reset --{hard,hard}' "$(bash_payload 'git${IFS}reset --{hard,hard}')"
test_deny  "$IRRECOVERABLE" 'GH #718: git${IFS}clean -{f,d}' "$(bash_payload 'git${IFS}clean -{f,d}')"
test_deny  "$IRRECOVERABLE" 'GH #718: git${IFS}{reset,reset} --hard' "$(bash_payload 'git${IFS}{reset,reset} --hard')"
test_allow "$IRRECOVERABLE" 'GH #718 control: git restore --staged {a,b}.txt' "$(bash_payload 'git restore --staged {a,b}.txt')"
test_allow "$IRRECOVERABLE" 'GH #718 control: git stash push -- {a,b}.txt' "$(bash_payload 'git stash push -- {a,b}.txt')"
test_allow "$IRRECOVERABLE" 'GH #718 control: git rm --cached {a,b}.txt' "$(bash_payload 'git rm --cached {a,b}.txt')"
test_allow "$IRRECOVERABLE" 'GH #718 control: git log --oneline {main,develop}' "$(bash_payload 'git log --oneline {main,develop}')"
# GH #718 review: bash still expands ~, braces and globs in echo's own arguments, so they stay bare in the output.
test_deny  "$IRRECOVERABLE" 'GH #718 review: trash $(echo ~/{.,x})' "$(bash_payload 'trash $(echo ~/{.,x})')"
test_deny  "$IRRECOVERABLE" 'GH #718 review: trash $(echo /{,})' "$(bash_payload 'trash $(echo /{,})')"
test_deny  "$IRRECOVERABLE" 'GH #718 review: trash `echo ~/{.,.}`' "$(bash_payload 'trash `echo ~/{.,.}`')"
test_deny  "$IRRECOVERABLE" 'GH #718 review: trash $(printf '"'"'%s '"'"' ~/{.,x})' "$(bash_payload 'trash $(printf '"'"'%s '"'"' ~/{.,x})')"
test_deny  "$IRRECOVERABLE" 'GH #718 review: chmod 777 $(echo ~/{.,.})' "$(bash_payload 'chmod 777 $(echo ~/{.,.})')"
test_allow "$IRRECOVERABLE" 'GH #718 review control: echo $(echo '"'"'x; rm -rf /'"'"')' "$(bash_payload 'echo $(echo '"'"'x; rm -rf /'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #718 review control: rm -f $(echo build/*.o)' "$(bash_payload 'rm -f $(echo build/*.o)')"
test_allow "$IRRECOVERABLE" 'GH #718 review control: trash $(echo build/{a,b})' "$(bash_payload 'trash $(echo build/{a,b})')"
# GH #718 review 2: echo's arguments keep develop's plain rewrite; the word-split copy is additive and escaped.
test_deny  "$IRRECOVERABLE" 'GH #718 review 2: trash $(echo ~/{.,\'"'"'})' "$(bash_payload 'trash $(echo ~/{.,\'"'"'})')"
test_deny  "$IRRECOVERABLE" 'GH #718 review 2: trash $(echo ~/{.,x\;})' "$(bash_payload 'trash $(echo ~/{.,x\;})')"
test_deny  "$IRRECOVERABLE" 'GH #718 review 2: eval $(echo trash ~/{.,x}\;)' "$(bash_payload 'eval $(echo trash ~/{.,x}\;)')"
test_deny  "$IRRECOVERABLE" 'GH #718 review 2: git checkout $(echo '"'"'-- .'"'"')' "$(bash_payload 'git checkout $(echo '"'"'-- .'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #718 review 2 control: echo '"'"''"'"'$(echo '"'"'a;rm -rf /'"'"')' "$(bash_payload 'echo '"'"''"'"'$(echo '"'"'a;rm -rf /'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #718 review 2 control: echo '"'"'x'"'"'$(echo '"'"'&& git push -f'"'"')' "$(bash_payload 'echo '"'"'x'"'"'$(echo '"'"'&& git push -f'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #718 review 2 control: echo foo\ $(echo '"'"'a;git reset --hard'"'"')' "$(bash_payload 'echo foo\ $(echo '"'"'a;git reset --hard'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #718 review 2 control: trash $(echo '"'"'~/{.,x}'"'"')' "$(bash_payload 'trash $(echo '"'"'~/{.,x}'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #718 review 2 control: echo "x $(echo '"'"' -rf'"'"')"' "$(bash_payload 'echo "x $(echo '"'"' -rf'"'"')"')"
test_allow "$IRRECOVERABLE" 'GH #718 review 3 control: a $(...) inside '"'"'...'"'"' is data to the split copy' "$(bash_payload 'echo '"'"'see $(echo "'"'"'") && git reset --hard '"'"'"\'"'"'')"
# GH #769/#770: Monitor and context-mode's ctx_execute tools run shell too; the gate judges it like Bash.
_CTX=mcp__plugin_context-mode_context-mode__ctx
test_deny  "$IRRECOVERABLE" "GH #769: Monitor rm -rf" '{"tool_name":"Monitor","tool_input":{"command":"rm -rf /tmp/x"}}'
test_allow "$IRRECOVERABLE" "GH #769: Monitor ws payload" '{"tool_name":"Monitor","tool_input":{"ws":"ws://localhost:1/rm"}}'
test_allow "$IRRECOVERABLE" "GH #769: Monitor harmless" '{"tool_name":"Monitor","tool_input":{"command":"tail -f log | grep rm"}}'
test_deny  "$IRRECOVERABLE" "GH #770: ctx_execute shell rm -rf" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"shell\",\"code\":\"rm -rf /tmp/x\"}}"
test_allow "$IRRECOVERABLE" "GH #770: ctx_execute javascript holding rm -rf text" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"javascript\",\"code\":\"console.log('rm -rf /')\"}}"
test_deny  "$IRRECOVERABLE" "GH #770: ctx_execute_file shell rm -rf" "{\"tool_name\":\"${_CTX}_execute_file\",\"tool_input\":{\"path\":\"a.log\",\"language\":\"shell\",\"code\":\"rm -rf /tmp/x\"}}"
test_deny  "$IRRECOVERABLE" "GH #770: ctx_batch_execute one harmless, one rm -rf" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"label\":\"a\",\"command\":\"ls\"},{\"label\":\"b\",\"command\":\"rm -rf /tmp/x\"}],\"queries\":[\"rm -rf\"]}}"
test_deny  "$IRRECOVERABLE" "GH #770: ctx_batch_execute heredoc opener cannot hide the next command" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":\"cat <<EOF\"},{\"command\":\"rm -rf /tmp/x\"}]}}"
test_allow "$IRRECOVERABLE" "GH #770: ctx_batch_execute all harmless (rm only in queries)" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":\"ls\"},{\"command\":\"git status\"}],\"queries\":[\"rm -rf\"]}}"
test_allow "$IRRECOVERABLE" "GH #770: ctx_execute missing code field" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"shell\"}}"
test_allow "$IRRECOVERABLE" "GH #770: ctx_batch_execute non-command entries do not crash" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":5},null,7,{\"label\":\"rm\"}]}}"
# context-mode's coerceCommandsArray runs these shapes too: a string item, a bare string, a JSON-array string.
test_deny  "$IRRECOVERABLE" "GH #770: ctx_batch_execute string item" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[\"ls\",\"rm -rf /tmp/x\"]}}"
test_deny  "$IRRECOVERABLE" "GH #770: ctx_batch_execute commands as a bare string" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":\"rm -rf /tmp/x\"}}"
test_deny  "$IRRECOVERABLE" "GH #770: ctx_batch_execute commands as a JSON-array string" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":\"[{\\\"label\\\":\\\"a\\\",\\\"command\\\":\\\"rm -rf /tmp/x\\\"}]\"}}"
test_allow "$IRRECOVERABLE" "GH #770: ctx_batch_execute harmless bare string" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":\"git status\"}}"
# Each command is judged with the outer payload's fields, so a subagent's nested claude spawn is still denied.
test_deny  "$IRRECOVERABLE" "GH #770: subagent ctx_batch_execute claude -p" "{\"tool_name\":\"${_CTX}_batch_execute\",\"agent_id\":\"a1\",\"tool_input\":{\"commands\":[{\"command\":\"ls\"},{\"command\":\"claude -p hi\"}]}}"
test_allow "$IRRECOVERABLE" "GH #770: main-session ctx_batch_execute claude -p" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":\"claude -p hi\"}]}}"
# A batch that outruns the time budget asks for the rest instead of allowing it.
# The first command is always judged; a bad budget value falls back to the 4 s default, never crashes or disables it.
export MH_GATE_BATCH_BUDGET_S=0
test_ask_says "$IRRECOVERABLE" "GH #770: ctx_batch_execute over its time budget asks" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":\"ls\"},{\"command\":\"rm -rf /tmp/x\"}]}}" "time budget"
test_deny  "$IRRECOVERABLE" "GH #770: budget 0 still judges the first command" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":\"rm -rf /tmp/x\"},{\"command\":\"ls\"}]}}"
for _bv in abc nan inf -1 4s; do
  export MH_GATE_BATCH_BUDGET_S="$_bv"
  test_deny  "$IRRECOVERABLE" "GH #770: budget '$_bv' uses the default (rm -rf denied)" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":\"ls\"},{\"command\":\"rm -rf /tmp/x\"}]}}"
  test_allow "$IRRECOVERABLE" "GH #770: budget '$_bv' uses the default (git status allowed)" "{\"tool_name\":\"${_CTX}_batch_execute\",\"tool_input\":{\"commands\":[{\"command\":\"ls\"},{\"command\":\"git status\"}]}}"
done
unset MH_GATE_BATCH_BUDGET_S
# GH #769/#770: the coverage itself lives in hooks.json's matcher (the gate reads tool_input.command for any tool).
if python3 -c '
import json, sys
names = {"Bash", "Monitor"} | {"mcp__plugin_context-mode_context-mode__ctx_" + t for t in ("execute", "execute_file", "batch_execute")}
hooks = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
m = [e["matcher"] for e in hooks if any("gates/irrecoverable.sh" in h.get("command", "") for h in e["hooks"])]
sys.exit(not (len(m) == 1 and names <= set(m[0].split("|"))))' "$ROOT/hooks/hooks.json"; then
  echo "  ✅ hooks.json: irrecoverable.sh matcher covers Bash, Monitor and the three ctx tools"; pass=$((pass + 1))
else
  echo "  ❌ hooks.json: irrecoverable.sh matcher misses Bash, Monitor or a ctx tool" >&2; fail=$((fail + 1))
fi

# GH #767: rm's rules enforce in var-verb, and a substitution glued to a word splits off output that starts with a blank.
test_deny  "$IRRECOVERABLE" 'GH #767: F=-rf; rm $F b' "$(bash_payload 'F=-rf; rm $F b')"
test_deny  "$IRRECOVERABLE" 'GH #767: F='"'"'-rf'"'"'; rm $F b' "$(bash_payload 'F='"'"'-rf'"'"'; rm $F b')"
test_deny  "$IRRECOVERABLE" 'GH #767: F=-r; rm $F b' "$(bash_payload 'F=-r; rm $F b')"
test_deny  "$IRRECOVERABLE" 'GH #767: rm \ $(echo '"'"' -rf'"'"') b' "$(bash_payload 'rm \ $(echo '"'"' -rf'"'"') b')"
test_deny  "$IRRECOVERABLE" 'GH #767: rm x$(echo '"'"' -rf'"'"') b' "$(bash_payload 'rm x$(echo '"'"' -rf'"'"') b')"
test_deny  "$IRRECOVERABLE" 'GH #767: rm '"'"'a'"'"'$(echo '"'"' -rf'"'"') b' "$(bash_payload 'rm '"'"'a'"'"'$(echo '"'"' -rf'"'"') b')"
test_allow "$IRRECOVERABLE" 'GH #767 control: F=-f; rm $F a.log' "$(bash_payload 'F=-f; rm $F a.log')"
test_allow "$IRRECOVERABLE" 'GH #767 control: F=-i; rm $F x' "$(bash_payload 'F=-i; rm $F x')"
test_allow "$IRRECOVERABLE" 'GH #767 control: D=build; rm -f $D/a.o' "$(bash_payload 'D=build; rm -f $D/a.o')"
test_allow "$IRRECOVERABLE" 'GH #767 control: F=-rf; echo $F' "$(bash_payload 'F=-rf; echo $F')"
test_allow "$IRRECOVERABLE" 'GH #767 control: F=-rf; grep $F file' "$(bash_payload 'F=-rf; grep $F file')"
test_allow "$IRRECOVERABLE" 'GH #767 control: echo a\ $(echo '"'"'b'"'"')' "$(bash_payload 'echo a\ $(echo '"'"'b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 control: rm -f x\ $(echo '"'"'y.log'"'"')' "$(bash_payload 'rm -f x\ $(echo '"'"'y.log'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 control: echo foo$(echo '"'"' a;rm -rf /'"'"')' "$(bash_payload 'echo foo$(echo '"'"' a;rm -rf /'"'"')')"
# GH #767 review: a glued substitution keeps only its first output word glued; a backslash-newline is a continuation.
test_deny  "$IRRECOVERABLE" 'GH #767 review: rm \ $(echo '"'"'x -rf'"'"') b' "$(bash_payload $'rm \\ $(echo \'x -rf\') b')"
test_deny  "$IRRECOVERABLE" 'GH #767 review: rm \\\ $(echo '"'"'x -rf'"'"') b' "$(bash_payload $'rm \\\\\\ $(echo \'x -rf\') b')"
test_deny  "$IRRECOVERABLE" 'GH #767 review: rm \<NL>$(echo '"'"'x -rf'"'"') b' "$(bash_payload $'rm \\\n$(echo \'x -rf\') b')"
test_deny  "$IRRECOVERABLE" 'GH #767 review: rm \<NL>$(echo '"'"'x --no-preserve-root -r'"'"') /' "$(bash_payload $'rm \\\n$(echo \'x --no-preserve-root -r\') /')"
test_deny  "$IRRECOVERABLE" 'GH #767 review: rm x$(echo '"'"'a -rf'"'"') b' "$(bash_payload $'rm x$(echo \'a -rf\') b')"
test_deny  "$IRRECOVERABLE" 'GH #767 review: rm '"'"'a'"'"'$(echo '"'"'b -rf'"'"') c' "$(bash_payload $'rm \'a\'$(echo \'b -rf\') c')"
test_allow "$IRRECOVERABLE" 'GH #767 review control: rm -f x\ $(echo '"'"'y z.log'"'"')' "$(bash_payload 'rm -f x\ $(echo '"'"'y z.log'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review control: touch out$(echo '"'"' a b'"'"').txt' "$(bash_payload 'touch out$(echo '"'"' a b'"'"').txt')"
test_allow "$IRRECOVERABLE" 'GH #767 review control: echo x$(echo '"'"'a; rm -rf /'"'"')' "$(bash_payload 'echo x$(echo '"'"'a; rm -rf /'"'"')')"
# GH #767 review 2: bash does not split an assignment's value; an argument holding = does split.
test_deny  "$IRRECOVERABLE" 'GH #767 review 2: env X=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'env X=$(echo '"'"' rm -rf b'"'"')')"
test_deny  "$IRRECOVERABLE" 'GH #767 review 2: rm --one-file-system=$(echo '"'"' -rf b'"'"')' "$(bash_payload 'rm --one-file-system=$(echo '"'"' -rf b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 2 control: X=$(echo '"'"' rm -rf /tmp/x'"'"')' "$(bash_payload 'X=$(echo '"'"' rm -rf /tmp/x'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 2 control: CMD=$(echo '"'"'sudo rm -rf /tmp/build'"'"')' "$(bash_payload 'CMD=$(echo '"'"'sudo rm -rf /tmp/build'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 2 control: P=$(echo '"'"' git push --force origin main'"'"')' "$(bash_payload 'P=$(echo '"'"' git push --force origin main'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 2 control: X="a b"$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'X="a b"$(echo '"'"' rm -rf b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 2 control: A=1 X=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'A=1 X=$(echo '"'"' rm -rf b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 2 control: true && X=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'true && X=$(echo '"'"' rm -rf b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 2 control: export X=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'export X=$(echo '"'"' rm -rf b'"'"')')"
# GH #767 review 3 (operator): var-verb's enforced pass, rm-no-preserve-root through a variable, the linear assignment
# check, and assignment leads, quoted separators and subscripts the split copy reads as assignments.
test_deny  "$IRRECOVERABLE" 'GH #767 review 3: X=mkfs.ext4; $X /dev/sdb1; F=-rf; rm $F b' "$(bash_payload 'X=mkfs.ext4; $X /dev/sdb1; F=-rf; rm $F b')"
test_deny  "$IRRECOVERABLE" 'GH #767 review 3: F=--no-preserve-root; rm -i $F /' "$(bash_payload 'F=--no-preserve-root; rm -i $F /')"
test_allow "$IRRECOVERABLE" 'GH #767 review 3 control: declare -x X=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'declare -x X=$(echo '"'"' rm -rf b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 3 control: if X=$(echo '"'"' rm -rf b'"'"'); then :; fi' "$(bash_payload 'if X=$(echo '"'"' rm -rf b'"'"'); then :; fi')"
test_allow "$IRRECOVERABLE" 'GH #767 review 3 control: while X=$(echo '"'"' rm -rf b'"'"'); do break; done' "$(bash_payload 'while X=$(echo '"'"' rm -rf b'"'"'); do break; done')"
test_allow "$IRRECOVERABLE" 'GH #767 review 3 control: X[0]=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'X[0]=$(echo '"'"' rm -rf b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 3 control: A='"'"'x;y'"'"' X=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload 'A='"'"'x;y'"'"' X=$(echo '"'"' rm -rf b'"'"')')"
# GH #767 review 4: the glued split is its own copy, so develop's split copy still denies; continuations and quoted values.
test_deny  "$IRRECOVERABLE" 'GH #767 review 4: X=`echo '"'"'a b'"'"'` Y=`echo '"'"'a b'"'"'` rm `echo '"'"' -rf'"'"'` b' "$(bash_payload 'X=`echo '"'"'a b'"'"'` Y=`echo '"'"'a b'"'"'` rm `echo '"'"' -rf'"'"'` b')"
test_deny  "$IRRECOVERABLE" 'GH #767 review 4: X=$(echo '"'"'a b'"'"') Y=$(echo '"'"'a b'"'"') rm $(echo '"'"' -rf'"'"') b' "$(bash_payload 'X=$(echo '"'"'a b'"'"') Y=$(echo '"'"'a b'"'"') rm $(echo '"'"' -rf'"'"') b')"
test_allow "$IRRECOVERABLE" 'GH #767 review 4 control: true && \<NL>  X=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload $'true && \\\n  X=$(echo \' rm -rf b\')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 4 control: A=1 \<NL>  B=$(echo '"'"' rm -rf b'"'"')' "$(bash_payload $'A=1 \\\n  B=$(echo \' rm -rf b\')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 4 control: X='"'"'a b'"'"' CMD=$(echo '"'"' rm -rf build'"'"')' "$(bash_payload $'X=\'a b\' CMD=$(echo \' rm -rf build\')')"
# GH #767 review 5: the glued copy stays out of brace-view's copies (shared positional budget); var-verb's structural
# denies only end its window; $(...) and backticks are one word to the assignment check.
test_deny  "$IRRECOVERABLE" "GH #767 review 5: a brace, a glued subst and a 5000-argument bash -c still reach git add -A" "$(bash_payload "echo {a,b}x$(echo 'p q'); bash -c 'echo \"\$@\"' _ $(printf 'y %.0s' $(seq 5000)); git add $(echo ' -A')")"
test_deny  "$IRRECOVERABLE" 'GH #767 review 5: rm $(X=1) Y=$(echo '"'"' -rf b'"'"')' "$(bash_payload 'rm $(X=1) Y=$(echo '"'"' -rf b'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 5 control: GREETING="it'"'"'s"; export GREETING; bash -c "echo \$GREETING"' "$(bash_payload 'GREETING="it'"'"'s"; export GREETING; bash -c "echo \$GREETING"')"
test_allow "$IRRECOVERABLE" 'GH #767 review 5 control: TS=$(date +%s) NOTE=build-$(echo '"'"'cleanup: rm -rf dist'"'"')' "$(bash_payload 'TS=$(date +%s) NOTE=build-$(echo '"'"'cleanup: rm -rf dist'"'"')')"
test_allow "$IRRECOVERABLE" 'GH #767 review 5 control: A="$(pwd)" F=x$(echo '"'"'b rm -rf c'"'"')' "$(bash_payload 'A="$(pwd)" F=x$(echo '"'"'b rm -rf c'"'"')')"
# GH #767 review 6: the glued copy drops printf's % format; var-verb puts no value in '...' or after \$, nor reads --opt= as NAME=.
test_allow "$IRRECOVERABLE" 'GH #767 review 6 control: git checkout -b hotfix-$(printf '"'"'%03d'"'"' 7)' "$(bash_payload 'git checkout -b hotfix-$(printf '"'"'%03d'"'"' 7)')"
test_allow "$IRRECOVERABLE" 'GH #767 review 6 control: git checkout -b rel-$(printf '"'"'%s'"'"' 2026)' "$(bash_payload 'git checkout -b rel-$(printf '"'"'%s'"'"' 2026)')"
test_allow "$IRRECOVERABLE" 'GH #767 review 6 control: F=-rf; rm '"'"'$F'"'"' x' "$(bash_payload 'F=-rf; rm '"'"'$F'"'"' x')"
test_allow "$IRRECOVERABLE" 'GH #767 review 6 control: X=-r; echo "\$X"; rm \$X y' "$(bash_payload 'X=-r; echo "\$X"; rm \$X y')"
test_allow "$IRRECOVERABLE" 'GH #767 review 6 control: git log --format=-rf; rm $format x' "$(bash_payload 'git log --format=-rf; rm $format x')"
test_deny  "$IRRECOVERABLE" 'GH #767 review 6: F=-rf; rm "$F" b' "$(bash_payload 'F=-rf; rm "$F" b')"
# GH #767 review 7 (operator): the NAME= test runs once per word, so a 40,000-character word before 7000 glued
# backtick substitutions is read in bounded time (14.6 s before, about 1.5 s after).
_timed_case "GH #767 review 7: a 40 KB word, then 7000 glued backtick substitutions, then a split-copy target" 2 \
  "echo $(printf 'a%.0s' $(seq 40000))$(printf '`echo '"'"'p q'"'"'`%.0s' $(seq 7000)); rm \`echo ' -rf'\` b"
_timed_case "GH #767 review 3: 8900 glued X=\`echo 'a b'\` words, then a split-copy target, denied in bounded time" 2 \
  "echo x; $(printf 'X=`echo '"'"'a b'"'"'` %.0s' $(seq 8900)); rm \`echo ' -rf'\` b"
# GH #691: in a subagent, a view no longer re-runs the body spawn scan (it could only end the view), so padding that
# spends the spawn budget in the main reading no longer stops ifs-split before a later rm${IFS}-rf / git${IFS}reset.
_pad691="eval '$(printf 'env a b c d e f g h i j k l m n o p q r s t u v w x y z ; %.0s' $(seq 240))true'; "
test_deny  "$IRRECOVERABLE" "GH #691: subagent, spawn-budget padding, then rm\${IFS}-rf b" "$(bash_agent_payload "${_pad691}rm\${IFS}-rf b" fork)"
test_deny  "$IRRECOVERABLE" "GH #691: subagent, spawn-budget padding, then bash -c 'rm\${IFS}-rf b'" "$(bash_agent_payload "${_pad691}bash -c 'rm\${IFS}-rf b'" fork)"
test_deny  "$IRRECOVERABLE" "GH #691: subagent, spawn-budget padding, then git\${IFS}reset --hard" "$(bash_agent_payload "${_pad691}git\${IFS}reset --hard" fork)"
test_deny  "$IRRECOVERABLE" "GH #691: subagent, spawn-budget padding, then bash -c 'claude -p x' (spawn still denied)" "$(bash_agent_payload "${_pad691}bash -c 'claude -p x'" fork)"
test_allow "$IRRECOVERABLE" "GH #691 control: subagent, spawn-budget padding, then echo ok" "$(bash_agent_payload "${_pad691}echo ok" fork)"
# GH #798: a spawn only a view reads denies in a subagent (views scan their own text and the bodies they rewrote, on a
# budget of their own); a spent scan budget says "too dense".
test_deny  "$IRRECOVERABLE" 'GH #798: subagent: bash${IFS}-c '"'"'claude -p x'"'"'' "$(bash_agent_payload 'bash${IFS}-c '"'"'claude -p x'"'"'' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798: subagent: X=claude; bash -c "$X -p x"' "$(bash_agent_payload 'X=claude; bash -c "$X -p x"' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798: subagent: X=claude; $X -p x' "$(bash_agent_payload 'X=claude; $X -p x' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798: subagent: claude${IFS}-p${IFS}x' "$(bash_agent_payload 'claude${IFS}-p${IFS}x' fork)"
test_deny  "$IRRECOVERABLE" "GH #798: subagent, spawn-budget padding, then bash\${IFS}-c 'claude -p x'" "$(bash_agent_payload "${_pad691}bash\${IFS}-c 'claude -p x'" fork)"
test_allow "$IRRECOVERABLE" 'GH #798 control: subagent: X=echo; bash -c "$X -p x"' "$(bash_agent_payload 'X=echo; bash -c "$X -p x"' fork)"
test_allow "$IRRECOVERABLE" 'GH #798 control: subagent: X=claude; echo $X -p x' "$(bash_agent_payload 'X=claude; echo $X -p x' fork)"
test_allow "$IRRECOVERABLE" 'GH #798 control: subagent: bash${IFS}-c '"'"'echo hi'"'"'' "$(bash_agent_payload 'bash${IFS}-c '"'"'echo hi'"'"'' fork)"
# GH #798 review: no $IFS re-check drops a raw spawn finding (it hid ${IFS%..}, ${IFS/?/-p hi} and X=a${IFS}b claude -p);
# the views scan only the statements they changed, so a script changed near each end is not refused as too dense.
test_deny  "$IRRECOVERABLE" 'GH #798 review: subagent: echo '"'"'${IFS%'"'"' ; claude -p x ; echo '"'"'}'"'"'' "$(bash_agent_payload 'echo '"'"'${IFS%'"'"' ; claude -p x ; echo '"'"'}'"'"'' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review: subagent: echo \${IFS%; claude -p x; echo }' "$(bash_agent_payload 'echo \${IFS%; claude -p x; echo }' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review: subagent: claude ${IFS/?/-p hi}' "$(bash_agent_payload 'claude ${IFS/?/-p hi}' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review: subagent: IFS=-; claude${IFS}--help' "$(bash_agent_payload 'IFS=-; claude${IFS}--help' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review: subagent: claude$IFS'"'"'-p'"'"' hi' "$(bash_agent_payload 'claude$IFS'"'"'-p'"'"' hi' fork)"
_s798="set -e
OUT=build
[ -n \"\$CI\" ] && OUT=dist
mkdir -p \"\$OUT\"
$(for i in $(seq 0 135); do printf 'cp src/file_%s.txt "$OUT/" \&\& echo copied %s\n' $i $i; done)"
test_allow "$IRRECOVERABLE" "GH #798 review control: subagent: a 6 KB script that sets OUT twice" "$(bash_agent_payload "$_s798" fork)"
test_deny  "$IRRECOVERABLE" "GH #798 review: subagent: the same script, then C=claude; \$C -p x" "$(bash_agent_payload "$_s798"$'\nC=claude; $C -p x' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 2: subagent: X=a${IFS}b claude -p hi' "$(bash_agent_payload 'X=a${IFS}b claude -p hi' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 2: subagent: X=${IFS}z claude -p hi' "$(bash_agent_payload 'X=${IFS}z claude -p hi' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 2: subagent: echo hi | X=a${IFS}b claude -p' "$(bash_agent_payload 'echo hi | X=a${IFS}b claude -p' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 2: subagent: eval '"'"'X=a${IFS}b claude -p hi'"'"'' "$(bash_agent_payload 'eval '"'"'X=a${IFS}b claude -p hi'"'"'' fork)"
# GH #798 review 3: views scan only the body statements the main reading did not, and var-verb's spawn copy reads
# each variable in order, so a reused variable and a medium bash -c body are not refused.
test_allow "$IRRECOVERABLE" 'GH #798 review 3 control: subagent: D=/tmp/w; mkdir -p $D; D=/tmp/w2; bash -c "OUT=$(echo out); ... (60 if-lines)' "$(bash_agent_payload 'D=/tmp/w; mkdir -p $D; D=/tmp/w2; bash -c "OUT=$(echo out); if [ -f $D/f0.txt ]; then cat $D/f0.txt | grep -c foo0 || echo none0; fi; if [ -f $D/f1.txt ]; then cat $D/f1.txt | grep -c foo1 || echo none1; fi; if [ -f $D/f2.txt ]; then cat $D/f2.txt | grep -c foo2 || echo none2; fi; if [ -f $D/f3.txt ]; then cat $D/f3.txt | grep -c foo3 || echo none3; fi; if [ -f $D/f4.txt ]; then cat $D/f4.txt | grep -c foo4 || echo none4; fi; if [ -f $D/f5.txt ]; then cat $D/f5.txt | grep -c foo5 || echo none5; fi; if [ -f $D/f6.txt ]; then cat $D/f6.txt | grep -c foo6 || echo none6; fi; if [ -f $D/f7.txt ]; then cat $D/f7.txt | grep -c foo7 || echo none7; fi; if [ -f $D/f8.txt ]; then cat $D/f8.txt | grep -c foo8 || echo none8; fi; if [ -f $D/f9.txt ]; then cat $D/f9.txt | grep -c foo9 || echo none9; fi; if [ -f $D/f10.txt ]; then cat $D/f10.txt | grep -c foo10 || echo none10; fi; if [ -f $D/f11.txt ]; then cat $D/f11.txt | grep -c foo11 || echo none11; fi; if [ -f $D/f12.txt ]; then cat $D/f12.txt | grep -c foo12 || echo none12; fi; if [ -f $D/f13.txt ]; then cat $D/f13.txt | grep -c foo13 || echo none13; fi; if [ -f $D/f14.txt ]; then cat $D/f14.txt | grep -c foo14 || echo none14; fi; if [ -f $D/f15.txt ]; then cat $D/f15.txt | grep -c foo15 || echo none15; fi; if [ -f $D/f16.txt ]; then cat $D/f16.txt | grep -c foo16 || echo none16; fi; if [ -f $D/f17.txt ]; then cat $D/f17.txt | grep -c foo17 || echo none17; fi; if [ -f $D/f18.txt ]; then cat $D/f18.txt | grep -c foo18 || echo none18; fi; if [ -f $D/f19.txt ]; then cat $D/f19.txt | grep -c foo19 || echo none19; fi; if [ -f $D/f20.txt ]; then cat $D/f20.txt | grep -c foo20 || echo none20; fi; if [ -f $D/f21.txt ]; then cat $D/f21.txt | grep -c foo21 || echo none21; fi; if [ -f $D/f22.txt ]; then cat $D/f22.txt | grep -c foo22 || echo none22; fi; if [ -f $D/f23.txt ]; then cat $D/f23.txt | grep -c foo23 || echo none23; fi; if [ -f $D/f24.txt ]; then cat $D/f24.txt | grep -c foo24 || echo none24; fi; if [ -f $D/f25.txt ]; then cat $D/f25.txt | grep -c foo25 || echo none25; fi; if [ -f $D/f26.txt ]; then cat $D/f26.txt | grep -c foo26 || echo none26; fi; if [ -f $D/f27.txt ]; then cat $D/f27.txt | grep -c foo27 || echo none27; fi; if [ -f $D/f28.txt ]; then cat $D/f28.txt | grep -c foo28 || echo none28; fi; if [ -f $D/f29.txt ]; then cat $D/f29.txt | grep -c foo29 || echo none29; fi; if [ -f $D/f30.txt ]; then cat $D/f30.txt | grep -c foo30 || echo none30; fi; if [ -f $D/f31.txt ]; then cat $D/f31.txt | grep -c foo31 || echo none31; fi; if [ -f $D/f32.txt ]; then cat $D/f32.txt | grep -c foo32 || echo none32; fi; if [ -f $D/f33.txt ]; then cat $D/f33.txt | grep -c foo33 || echo none33; fi; if [ -f $D/f34.txt ]; then cat $D/f34.txt | grep -c foo34 || echo none34; fi; if [ -f $D/f35.txt ]; then cat $D/f35.txt | grep -c foo35 || echo none35; fi; if [ -f $D/f36.txt ]; then cat $D/f36.txt | grep -c foo36 || echo none36; fi; if [ -f $D/f37.txt ]; then cat $D/f37.txt | grep -c foo37 || echo none37; fi; if [ -f $D/f38.txt ]; then cat $D/f38.txt | grep -c foo38 || echo none38; fi; if [ -f $D/f39.txt ]; then cat $D/f39.txt | grep -c foo39 || echo none39; fi; if [ -f $D/f40.txt ]; then cat $D/f40.txt | grep -c foo40 || echo none40; fi; if [ -f $D/f41.txt ]; then cat $D/f41.txt | grep -c foo41 || echo none41; fi; if [ -f $D/f42.txt ]; then cat $D/f42.txt | grep -c foo42 || echo none42; fi; if [ -f $D/f43.txt ]; then cat $D/f43.txt | grep -c foo43 || echo none43; fi; if [ -f $D/f44.txt ]; then cat $D/f44.txt | grep -c foo44 || echo none44; fi; if [ -f $D/f45.txt ]; then cat $D/f45.txt | grep -c foo45 || echo none45; fi; if [ -f $D/f46.txt ]; then cat $D/f46.txt | grep -c foo46 || echo none46; fi; if [ -f $D/f47.txt ]; then cat $D/f47.txt | grep -c foo47 || echo none47; fi; if [ -f $D/f48.txt ]; then cat $D/f48.txt | grep -c foo48 || echo none48; fi; if [ -f $D/f49.txt ]; then cat $D/f49.txt | grep -c foo49 || echo none49; fi; if [ -f $D/f50.txt ]; then cat $D/f50.txt | grep -c foo50 || echo none50; fi; if [ -f $D/f51.txt ]; then cat $D/f51.txt | grep -c foo51 || echo none51; fi; if [ -f $D/f52.txt ]; then cat $D/f52.txt | grep -c foo52 || echo none52; fi; if [ -f $D/f53.txt ]; then cat $D/f53.txt | grep -c foo53 || echo none53; fi; if [ -f $D/f54.txt ]; then cat $D/f54.txt | grep -c foo54 || echo none54; fi; if [ -f $D/f55.txt ]; then cat $D/f55.txt | grep -c foo55 || echo none55; fi; if [ -f $D/f56.txt ]; then cat $D/f56.txt | grep -c foo56 || echo none56; fi; if [ -f $D/f57.txt ]; then cat $D/f57.txt | grep -c foo57 || echo none57; fi; if [ -f $D/f58.txt ]; then cat $D/f58.txt | grep -c foo58 || echo none58; fi; if [ -f $D/f59.txt ]; then cat $D/f59.txt | grep -c foo59 || echo none59; fi; "' fork)"
test_allow "$IRRECOVERABLE" 'GH #798 review 3 control: subagent: BIN=claude; command -v $BIN; BIN=python3; $BIN -c '"'"'print(1)'"'"' input.txt' "$(bash_agent_payload 'BIN=claude; command -v $BIN; BIN=python3; $BIN -c '"'"'print(1)'"'"' input.txt' fork)"
test_allow "$IRRECOVERABLE" 'GH #798 review 3 control: subagent: X=claude; X=echo; $X -p x' "$(bash_agent_payload 'X=claude; X=echo; $X -p x' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 3: subagent: X=echo; X=claude; $X -p x' "$(bash_agent_payload 'X=echo; X=claude; $X -p x' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 3: subagent: X=claude; ( $X -p hi )' "$(bash_agent_payload 'X=claude; ( $X -p hi )' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 3: subagent: C=claude; ls | xargs $C' "$(bash_agent_payload 'C=claude; ls | xargs $C' fork)"
# GH #798 review 4: var-verb keeps its last-value copy (a later pass of a loop, a function called after the assignment).
test_deny  "$IRRECOVERABLE" 'GH #798 review 4: F=-i; for i in 1 2; do rm $F b; F=-rf; done' "$(bash_payload 'F=-i; for i in 1 2; do rm $F b; F=-rf; done')"
test_deny  "$IRRECOVERABLE" 'GH #798 review 4: F=-i; g(){ rm $F b; }; F=-rf; g' "$(bash_payload 'F=-i; g(){ rm $F b; }; F=-rf; g')"
test_deny  "$IRRECOVERABLE" 'GH #798 review 4: subagent: for i in 1 2; do $X -p x; X=claude; done' "$(bash_agent_payload 'for i in 1 2; do $X -p x; X=claude; done' fork)"
test_deny  "$IRRECOVERABLE" 'GH #798 review 4: subagent: g(){ $X -p x; }; X=claude; g' "$(bash_agent_payload 'g(){ $X -p x; }; X=claude; g' fork)"
# GH #798 review 5 (operator): only var-verb's in-order copy is spawn-scanned, so a tool variable later set to claude
# for a lookup is not a spawn.
test_allow "$IRRECOVERABLE" 'GH #798 review 5 control: subagent: BIN=python3; $BIN -c '"'"'print(1)'"'"'; BIN=claude; command -v $BIN' "$(bash_agent_payload 'BIN=python3; $BIN -c '"'"'print(1)'"'"'; BIN=claude; command -v $BIN' fork)"
test_allow "$IRRECOVERABLE" 'GH #798 review 5 control: subagent: T=pytest; $T tests/; T=claude; which $T' "$(bash_agent_payload 'T=pytest; $T tests/; T=claude; which $T' fork)"
test_allow "$IRRECOVERABLE" 'GH #798 review 5 control: subagent: N=npm; $N run build; N=claude; command -v $N' "$(bash_agent_payload 'N=npm; $N run build; N=claude; command -v $N' fork)"
# GH #805: rm also reads a fourth copy, in order with a never-yet-assigned reference left as written: bash expands it
# to nothing, so the -i set after rm runs does not make it prompt. The in-order copy's last-value fallback read it as -i.
test_deny  "$IRRECOVERABLE" 'GH #805: F=-r; rm $F $G b; G=-i' "$(bash_payload 'F=-r; rm $F $G b; G=-i')"
test_deny  "$IRRECOVERABLE" 'GH #805: F=-r; for i in 1 2; do rm $F $G b; done; G=-i' "$(bash_payload 'F=-r; for i in 1 2; do rm $F $G b; done; G=-i')"
test_deny  "$IRRECOVERABLE" 'GH #805: F=-r; g(){ rm $F $G b; }; g; G=-i' "$(bash_payload 'F=-r; g(){ rm $F $G b; }; g; G=-i')"
test_allow "$IRRECOVERABLE" 'GH #805 control: G=-i; F=-r; rm $F $G b' "$(bash_payload 'G=-i; F=-r; rm $F $G b')"
test_allow "$IRRECOVERABLE" 'GH #805 control: F=-i; g(){ rm $F b; }; g' "$(bash_payload 'F=-i; g(){ rm $F b; }; g')"
# GH #804: a view's statements keep the `|` / `|&` before them, so the pipe-in check sees a claude that reads
# stdin; `||` stays one separator, so a claude after it is not read as piped.
test_deny  "$IRRECOVERABLE" 'GH #804: subagent: X=claude; echo hi | $X' "$(bash_agent_payload 'X=claude; echo hi | $X' fork)"
test_deny  "$IRRECOVERABLE" 'GH #804: subagent: X=claude; echo hi |& $X' "$(bash_agent_payload 'X=claude; echo hi |& $X' fork)"
test_deny  "$IRRECOVERABLE" 'GH #804 control: subagent: echo hi | claude' "$(bash_agent_payload 'echo hi | claude' fork)"
test_allow "$IRRECOVERABLE" 'GH #804 control: subagent: X=claude; true || $X' "$(bash_agent_payload 'X=claude; true || $X' fork)"
test_allow "$IRRECOVERABLE" 'GH #804 control: subagent: X=claude; echo hi | grep $X' "$(bash_agent_payload 'X=claude; echo hi | grep $X' fork)"
# GH #810: a pipe that ends a line goes on to the next line, past blank lines, a comment or a backslash-newline.
for _c in $'X=claude; echo hi |\n$X' $'X=claude; echo hi |\n\n$X' $'X=claude; echo hi | \\\n$X' \
  $'X=claude; echo hi | # feed it\n$X' $'X=claude; echo hi |&\n$X'; do
  test_deny  "$IRRECOVERABLE" "GH #810: subagent: ${_c//$'\n'/ \\n }" "$(bash_agent_payload "$_c" fork)"
done
for _c in $'X=claude; echo hi |\ngrep $X' $'X=claude; echo hi\n$X' $'X=claude; true ||\n$X'; do
  test_allow "$IRRECOVERABLE" "GH #810 control: subagent: ${_c//$'\n'/ \\n }" "$(bash_agent_payload "$_c" fork)"
done
# GH #812: a single-quoted bash -c / eval body is a script of its own: its own assignments (GH #812) and the outer
# command's (GH #810 item 2: `export X=claude`, read as the child's environment) are substituted into it, in order and
# up to 8 links, bounded in size. GH #810 comment: a pipe at a line end crosses a comment, one holding an apostrophe or
# after a backslash-newline too, to the next line's `claude` or `$X`.
for _c in "bash -c 'X=claude; \$X -p x'" "bash -c 'X=claude; echo hi | \$X'" "sh -c 'X=claude; \$X -p x'" \
  "eval 'X=claude; \$X -p x'" "export X=claude; bash -c '\$X -p x'" "export X=claude; bash -c 'echo hi | \$X'" \
  "X=claude bash -c '\$X -p x'" "export X=claude; bash -c 'Y=\$X; \$Y -p x'" \
  "bash -c 'X=claude; Y=\$X; Z=\$Y; W=\$Z; \$W -p x'" \
  "X='\$X\$X\$X\$X\$X\$X\$X\$X\$X\$X\$X\$X\$X\$X\$X\$X'; bash -c 'echo \$X'; Y=claude; \$Y -p x" \
  $'X=claude; echo hi | # it\'s fed\n$X' $'echo hi | # c\nclaude' $'echo hi | # c\n\nclaude' $'echo hi |#c\nclaude' \
  $'echo hi |& # c\nclaude' $'echo hi | # it\'s\nclaude' $'echo hi | # c\n$(echo claude)' $'echo hi # c |\nclaude' \
  $'echo hi | \\\n# c\nclaude' $'echo hi | \\\n# c \\\nclaude'; do
  test_deny  "$IRRECOVERABLE" "GH #812: subagent: ${_c//$'\n'/ \\n }" "$(bash_agent_payload "$_c" fork)"
done
for _c in "bash -c 'X=claude; \$X --version'" "bash -c 'X=claude; echo \$X'" "export X=claude; bash -c '\$X --version'" \
  "export X=claude; bash -c 'echo \$X'" "bash -c 'X=python3; \$X -c 1'" "bash -c 'PAT=\"error|claude\"; grep -E \$PAT log'" \
  "X='\$X\$X\$X\$X\$X\$X'; bash -c 'echo \$X'" $'X=claude; echo hi # it\'s |\n$X' $'echo hi | # c\ngrep claude'; do
  test_allow "$IRRECOVERABLE" "GH #812 control: subagent: ${_c//$'\n'/ \\n }" "$(bash_agent_payload "$_c" fork)"
done
# GH #810 item 3 (decision: keep the deny): a `>|` redirect and a case / [[ =~ pattern `|` stay a pipe in. Nine fresh
# reviews of an exemption each found the text bash parses differ from the text read: a `case` or `[[` as an argument,
# escaped, quoted, inside ${..} / $[..] / backticks / a heredoc, built by an expansion (`X=; $X case ..`), or an alias
# (bash expands one even on a reserved word; the shell snapshot turns expand_aliases on). None is realistic.
for _c in 'echo hi >| claude' 'X=claude; echo hi >| $X' 'X=claude; echo hi 2>| $X' 'case y in a|claude) echo;; esac' \
  'X=claude; case y in a|$X) echo;; esac' '[[ y =~ (a|claude) ]]' 'X=claude; [[ y =~ (a|$X) ]]' \
  'echo test case 3 in prod | claude' 'echo hi >& case x in a|claude' '\case x in a|claude' '"case" y in a|"claude"' \
  'X=; Y=claude; $X case y in a|$Y' 'echo ${v:-;case x in a}|claude' '[[ x =~ $(echo|claude) ]]' \
  'echo `true;case x` in a|claude' $'shopt -s expand_aliases; alias case=echo\ncase y in a|claude' \
  $'bash -c \'cat <<";;"\nx\n;;\ndate|claude\'' 'case y in a) echo hi | claude;; esac' 'case y in a) ;; esac | claude'; do
  test_deny  "$IRRECOVERABLE" "GH #810 item 3 (kept): subagent: ${_c//$'\n'/ \\n }" "$(bash_agent_payload "$_c" fork)"
done
gates_summary
