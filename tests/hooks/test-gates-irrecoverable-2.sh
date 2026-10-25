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
# Dangerous-direction control: the abbreviation helper must not itself start
# denying git's own already-documented noisy neighbors (an ambiguous prefix
# these long forms don't uniquely resolve to, or a flag never named in the
# specific per-call-site long_forms list).
test_allow "$IRRECOVERABLE" "git push --force-with-lease still allowed (prefix helper is call-site-scoped, not global)" \
  "$(bash_payload 'git push --force-with-lease origin develop')"
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
# GH #567: a shell reading stdin gets its commands from a heredoc piped in, a here-string, or an echo/printf.
test_deny  "$IRRECOVERABLE" "GH #567: bash <<< rm -rf" "$(bash_payload "bash <<< 'rm -rf build'")"
test_deny  "$IRRECOVERABLE" "GH #567: echo into bash" "$(bash_payload "echo 'git push --force' | bash")"
test_deny  "$IRRECOVERABLE" "GH #567: printf into bash -s" "$(bash_payload "printf 'git reset --hard\n' | bash -s")"
test_deny  "$IRRECOVERABLE" "GH #567: heredoc piped into bash" "$(bash_payload "$(printf 'cat <<EOF | bash\nrm -rf build\nEOF')")"
test_allow "$IRRECOVERABLE" "GH #567 control: echo into tee" "$(bash_payload "echo 'rm -rf build' | tee notes.txt")"
test_allow "$IRRECOVERABLE" "GH #567 control: echo into bash script.sh (stdin is data)" "$(bash_payload 'echo hi | bash x.sh')"
test_allow "$IRRECOVERABLE" "GH #567 control: heredoc piped into grep bash" "$(bash_payload "$(printf "cat <<'EOF' | grep bash\nrm -rf build\nEOF")")"
# Non-goal: eval "$(cat <<EOF)", fish <<EOF, and a << lookalike inside quotes.
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

trash "$MERGE_FIX" "$NOMERGE_FIX" 2>/dev/null || true
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
trash "$MISSPY_RTG_DIR" 2>/dev/null || true

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
trash "$_trdir" 2>/dev/null || true

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


test_nopython_allow "$IRRECOVERABLE" "irrecoverable: rm -rf passes with note (was: rc=127 read as fail-CLOSED, blocking every git/rm command)" \
  "$(bash_payload 'rm -rf /tmp/x')"
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
[ -e "$MISSRUN_DIR/_run.py" ] && trash "$MISSRUN_DIR/_run.py"
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
trash "$MISSRUN_DIR"

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
ns = {"re": re}; exec(block, ns)
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
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a heredoc into python3.12 - is code" \
  "$(bash_payload "$(printf "python3.12 - <<'EOF'\nrm -rf ~\nEOF")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a backtick is no quote to psql before DROP TABLE" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nSELECT 1 \`; DROP TABLE t; -- \`\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559 review 4: a [bracket] identifier with an apostrophe before DROP TABLE into sqlite3" \
  "$(bash_payload "$(printf "sqlite3 db <<'SQL'\nSELECT [it's]; DROP TABLE t; -- '\nSQL")")"
_sql_many_heredocs_cmd="$(python3 -c 'print("psql db " + "<<a " * 20000 + "\n" + "DROP TABLE t\na\n" * 20000)')"
_timed_case 'GH #559 review 3: 20000 heredocs on one psql line finish in bounded time' 2 "$_sql_many_heredocs_cmd"
_sql_many_heredocs_cmd="$(python3 -c 'print("cat " + "<<a " * 15000 + "> f; psql\n" + "DROP TABLE t\na\n" * 15000)')"
_timed_case 'GH #559 review 3: 15000 heredocs into a file on a psql line finish in bounded time' 0 "$_sql_many_heredocs_cmd"
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
test_deny  "$IRRECOVERABLE" "empty value: git -c core.hooksPath= commit" "$(bash_payload 'git -c core.hooksPath= commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git -c core.hooksPath=\"\" commit" "$(bash_payload 'git -c core.hooksPath="" commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git -ccore.hooksPath= commit (joined)" "$(bash_payload 'git -ccore.hooksPath= commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git --config-env=core.hooksPath= commit" "$(bash_payload 'git --config-env=core.hooksPath= commit -m x')"
test_allow "$IRRECOVERABLE" "empty value control: git config user.name \"\"" "$(bash_payload 'git config user.name ""')"
test_allow "$IRRECOVERABLE" "empty value control: git config clean.requireForce true" "$(bash_payload 'git config clean.requireForce true')"
test_allow "$IRRECOVERABLE" "empty value control: git -c user.name= commit" "$(bash_payload 'git -c user.name= commit -m x')"

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
  'dd if=x of=$(echo /dev/disk2)' \
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


gates_summary
