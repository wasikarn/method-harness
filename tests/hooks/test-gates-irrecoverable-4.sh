#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal \$ in test payload strings is intentional
# Gate unit tests: simulates PreToolUse JSON payloads and asserts allow/deny/ask.
# Each test_deny call expects exit 2; test_allow expects exit 0 + empty stdout;
# test_ask expects exit 0 + a permissionDecision: ask JSON on stdout.
# Run standalone: bash tests/hooks/test-gates-irrecoverable-4.sh
# Part 4 of 5 of the gate tests (see test-gates.sh); helpers in tests/_lib/gates-harness.sh.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/_lib/gates-harness.sh"

echo "=== irrecoverable gate (part 4) ==="
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
# GH #785: the batch budget was measured from after the module's own deadline started, so the deadline always fired
# first and the batch's clearer ask never showed. Now each later command waits only while the module deadline has
# room for it (3 x the slowest command so far, plus 0.3 s). A 2 s deadline keeps the row short; 300 commands outrun it.
_b785="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__plugin_context-mode_context-mode__ctx_batch_execute", "tool_input": {"commands": [{"command": "echo $X"}] * 300}}))')"
MH_IRR_DEADLINE_SECS=2 test_ask_says "$IRRECOVERABLE" "GH #785: a batch that outruns the module deadline asks with the batch's own message" "$_b785" "time budget"
# GH #785: every exit disarms the deadline first, or a timer firing in that last window turns a deny into an ask, adds a
# second JSON object, or dies with rc 142. Checked on the source: each sys.exit has a _disarm() earlier in its block.
if _r785=$(python3 - "$ROOT/hooks/gates/irrecoverable.py" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
def is_call(st, name):
    return isinstance(st, ast.Expr) and isinstance(st.value, ast.Call) and ast.unparse(st.value.func) == name
bad = []
for node in ast.walk(tree):
    for field in ("body", "orelse", "finalbody"):
        block = getattr(node, field, None)
        if not isinstance(block, list):
            continue
        seen = False
        for st in block:
            seen = seen or is_call(st, "_disarm")
            if is_call(st, "sys.exit") and not seen:
                bad.append(st.lineno)
print(" ".join(map(str, sorted(bad))))
sys.exit(1 if bad else 0)
PY
); then
  echo "  ✅ GH #785: every sys.exit in irrecoverable.py disarms the deadline first"; pass=$((pass + 1))
else
  echo "  ❌ GH #785: sys.exit without an earlier _disarm() in its block, lines: $_r785" >&2; fail=$((fail + 1))
fi
# GH #911: context-mode 2.x. ctx_batch (string[] commands) is judged like ctx_batch_execute; ctx_execute code is
# judged for shell/sh/bash, passes for javascript/typescript/python/python3/node (#784), and any other language is
# denied, harmless code included (2.1.0 runs a shell under any runtime name; zsh, dash, ksh and powershell parse
# differently from the bash the gate reads). Benign code has no destructive token, so these rows also pin that
# irrecoverable.sh sends every __ctx_execute payload past its prefilter.
test_deny  "$IRRECOVERABLE" "GH #911: ctx_batch one harmless, one rm -rf" "{\"tool_name\":\"${_CTX}_batch\",\"tool_input\":{\"commands\":[\"ls\",\"rm -rf /tmp/x\"],\"queries\":[\"x\"]}}"
test_deny  "$IRRECOVERABLE" "GH #911: ctx_batch commands as a JSON-array string" "{\"tool_name\":\"${_CTX}_batch\",\"tool_input\":{\"commands\":\"[\\\"rm -rf /tmp/x\\\"]\",\"queries\":\"[\\\"x\\\"]\"}}"
test_allow "$IRRECOVERABLE" "GH #911: ctx_batch pwd (a real call)" "{\"tool_name\":\"${_CTX}_batch\",\"tool_input\":{\"commands\":[\"pwd\"],\"queries\":[\"pwd\"]}}"
test_deny  "$IRRECOVERABLE" "GH #911: ctx_execute bash rm -rf" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"bash\",\"code\":\"rm -rf /tmp/x\"}}"
test_deny  "$IRRECOVERABLE" "GH #911: ctx_execute sh rm -rf" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"sh\",\"code\":\"rm -rf /tmp/x\"}}"
test_allow "$IRRECOVERABLE" "GH #911: ctx_execute bash harmless" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"bash\",\"code\":\"ls -la; git status\"}}"
test_allow "$IRRECOVERABLE" "GH #911: ctx_execute python3 subprocess grep (a real call)" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"python3\",\"code\":\"import subprocess; subprocess.run(['grep', '-rn', 'x', '.'])\"}}"
test_allow "$IRRECOVERABLE" "GH #911: ctx_execute python string naming rm -rf" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"python\",\"code\":\"print('rm -rf /tmp/x')\"}}"
test_allow "$IRRECOVERABLE" "GH #911: ctx_execute bash with non-string code (the server rejects it)" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"bash\",\"code\":123}}"
for _l911 in zsh ksh dash powershell tcsh csh fish Bash zsh-5.9 ../../../bin/bash ruby; do
  test_deny "$IRRECOVERABLE" "GH #911: ctx_execute language $_l911 denied, harmless code" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"$_l911\",\"code\":\"ls -la\"}}"
done
test_deny_says "$IRRECOVERABLE" "GH #911: ctx_execute zsh noglob rm denied by language" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":\"zsh\",\"code\":\"noglob rm -rf /tmp/x\"}}" 'use language "shell"'
test_deny  "$IRRECOVERABLE" "GH #911: ctx_execute language as a list" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":[\"bash\"],\"code\":\"ls\"}}"
test_deny  "$IRRECOVERABLE" "GH #911: ctx_execute language as a number" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"language\":5,\"code\":\"ls\"}}"
test_deny  "$IRRECOVERABLE" "GH #911: ctx_execute missing language" "{\"tool_name\":\"${_CTX}_execute\",\"tool_input\":{\"code\":\"ls\"}}"
test_deny  "$IRRECOVERABLE" "GH #911: ctx_execute_file language bash" "{\"tool_name\":\"${_CTX}_execute_file\",\"tool_input\":{\"path\":\"a.log\",\"language\":\"bash\",\"code\":\"rm -rf /tmp/x\"}}"

# GH #769/#770: the coverage itself lives in hooks.json's matcher (the gate reads tool_input.command for any tool).
if python3 -c '
import json, sys
names = {"Bash", "Monitor"} | {"mcp__plugin_context-mode_context-mode__ctx_" + t for t in ("execute", "execute_file", "batch_execute", "batch")}
hooks = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
m = [e["matcher"] for e in hooks if any("gates/irrecoverable.sh" in h.get("command", "") for h in e["hooks"])]
sys.exit(not (len(m) == 1 and names <= set(m[0].split("|"))))' "$ROOT/hooks/hooks.json"; then
  echo "  ✅ hooks.json: irrecoverable.sh matcher covers Bash, Monitor and the four ctx tools"; pass=$((pass + 1))
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
# GH #857: since GH #838 the main reading denies these itself, and a main reading past the budget denies "too dense",
# so no padding can starve a view now: 40 statements (not 240, up to 3.7 s under load) keep the long-eval-body check.
_pad691="eval '$(printf 'env a b c d e f g h i j k l m n o p q r s t u v w x y z ; %.0s' $(seq 40))true'; "
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
# GH #812 review 10: the comment-aware literal-$ reading only adds substitutions: `\ #` and `\<newline>#` are no comment
# in bash, so the later $X / $F is still read.
for _c in $'X=claude\necho a\\ #\'\n\'; $X -p hi' $'X=claude\necho a\\\n#\'\n\'; $X -p hi'; do
  test_deny  "$IRRECOVERABLE" "GH #812 review 10: subagent: ${_c//$'\n'/ \\n }" "$(bash_agent_payload "$_c" fork)"
done
test_deny  "$IRRECOVERABLE" 'GH #812 review 10: F=-rf \n echo a\ #'"'"' \n '"'"'; rm $F ~/proj' \
  "$(bash_payload $'F=-rf\necho a\\ #\'\n\'; rm $F ~/proj')"
# GH #812 review 11: develop's literal-$ reading stays as it was (the comment-aware one is one extra var-verb copy), so a
# misread `\ #` cannot put a value inside a real '...' and hide -rf; the body scans share one work budget.
test_deny  "$IRRECOVERABLE" 'GH #812 review 11: G="'"' # '"'"; F=-rf \n rm \ #'"'"' \n $G'"'"' $F ~/proj' \
  "$(bash_payload "G=\"' # '\"; F=-rf"$'\n'"rm \\ #'"$'\n'"\$G' \$F ~/proj")"
_c="X='$(printf '$X%.0s' {1..60})'; $(for i in $(seq 700); do printf "bash -c '\$X %s';" "$i"; done) F=-rf; rm \$F b"
test_deny  "$IRRECOVERABLE" 'GH #812 review 11: 700 bodies of a growing $X, then rm -rf, deny in bounded time' \
  "$(bash_agent_payload "$_c" fork)"
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
# GH #801: interp-pipe-shell read the python/node word on the raw line, so a backslash in it (pyth\on3) got past;
# a python -c / node -e|-p script piped into a stdin shell is the same unseen code; and a by-name import read at once
# as a plain attribute (__import__('os').path) is no process API, so its literals are not read as commands.
for _c in $'pyth\\on3 - <<\'EOF\' | bash\nprint("ls")\nEOF' $'no\\de - <<\'EOF\' | sh\nconsole.log("ls")\nEOF' \
  $'cat <<\'EOF\' | py\\thon3 - | bash\nprint("ls")\nEOF' $'\\nod\\e - <<\'EOF\' | zsh\nconsole.log("ls")\nEOF' \
  $'python3 -c \'print("ls")\' | bash' $'node -e \'console.log("ls")\' | sh' $'node -p \'"ls"\' | bash' \
  $'python3 -uc \'print("ls")\' | sh' $'cat f | python3 -c \'import sys; print(sys.stdin.read())\' | bash' \
  $'python3 -c \'print(1)\' | tee log | sudo bash -s' $'node --eval=\'console.log(1)\' | sh' \
  $'pyth\\on3 -c \'print(1)\' | bash' $'git status; python3 -c "print(1)" 2>/dev/null | dash' \
  $'python3 -c $\'print(\\\'ls\\\')\' | bash'; do
  test_deny  "$IRRECOVERABLE" "GH #801: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
for _c in $'pyth\\on3 - <<\'EOF\' | grep x\nprint(1)\nEOF' $'no\\de - <<\'EOF\'\nconsole.log("sh")\nEOF' \
  $'python3 -c \'print(1)\' | grep 1' $'python3 -c \'print(1)\' | bash x.sh' $'python3 -c \'print(1)\' | sh -c cat' \
  $'node -e \'console.log("sh")\' | sort' $'python3 -c \'print(1)\'; echo ls | grep sh' \
  $'bash -c \'echo hi\' | python3 -c \'import sys; print(sys.stdin.read())\'' \
  $'for c in $\'python3 -W ignore -c \\\'print(1)\\\' | bash\' $\'cat f | python3 -c 1 | bash\' $\'git status; python3 -c "print(1)" 2>/dev/null | dash\'; do ./probe "$c"; done' \
  $'cat > x.sh <<\'EOF\'\npython3 -c \'print(1)\' | bash\nEOF' $'cat > notes.md <<\'EOF\'\nnode -e 1 | sh\nEOF'; do
  test_allow "$IRRECOVERABLE" "GH #801 control: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
_rows801() { # <journal>: would_ask rows for opaque-var-verb
  python3 -c 'import json,sys; print(sum(json.loads(l).get("rule") == "opaque-var-verb" for l in open(sys.argv[1])))' "$1"
}
for _c in $'for f in a b; do python3 -c "print(__import__(\'os\').path.getsize(\'$f\'))"; done' \
  $'python3 -c "print(__import__(\'os\').environ.get(\'$K\'))"' \
  $'python3 - <<\'EOF\'\nimport sys\nprint(__import__("os").path.exists("$f"))\nEOF'; do
  : > "$_JOURNAL_TMP/a801.jsonl"
  test_allow "$IRRECOVERABLE" "GH #801: ${_c//$'\n'/ | }" "$(bash_payload "$_c")" "MH_GATE_JOURNAL_PATH=$_JOURNAL_TMP/a801.jsonl"
  if [[ "$(_rows801 "$_JOURNAL_TMP/a801.jsonl")" == "0" ]]; then
    echo "  ✅ GH #801 journals no opaque-var-verb row: ${_c//$'\n'/ | }"; pass=$((pass + 1))
  else
    echo "  ❌ GH #801 journaled an opaque-var-verb row: ${_c//$'\n'/ | }" >&2; fail=$((fail + 1))
  fi
done
# GH #801 controls: a by-name import not read at once as a plain attribute is still a process API.
for _c in $'python3 -c "getattr(__import__(\'os\'), \'sys\' + \'tem\')(\'git reset --hard\')"' \
  $'python3 -c "__import__(\'os\').system(\'git reset --hard\')"' \
  $'python3 -c "__import__(\'subprocess\').run(\'git reset --hard\', shell=True)"' \
  $'python3 - <<\'EOF\'\nm = __import__("os")\ngetattr(m, "sys" + "tem")("git reset --hard")\nEOF' \
  $'python3 - <<\'EOF\'\n__import__("os").system("git reset --hard")\nEOF' \
  $'python3 - <<\'EOF\'\nf = __import__(\'os\').system\nf(\'git reset --hard\')\nEOF' \
  $'python3 - <<\'EOF\'\nrun = __import__(\'os\').execvp\nrun(\'git\', [\'git\', \'reset\', \'--hard\'])\nEOF' \
  $'python3 - <<\'EOF\'\np = __import__(\'os\').popen\np(\'git push --force origin main\')\nEOF'; do
  test_deny  "$IRRECOVERABLE" "GH #801 control: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
# GH #808: the raw copy drops a value bash never expands there: one `unset` after it is set, one set inside a
# subshell that closed before the reference, and a prefix assignment on a command (bash expands the words first).
for _c in 'G=-i; F=-r; unset G; rm $F $G b' 'F=-r; G=-i; unset -v X G; rm $F $G b' '(G=-i); F=-r; rm $F $G b' \
  'F=-r; (G=-i; true) && rm $F $G b' 'F=-r; G=-i rm $F $G b' 'F=-r; G=-i H=1 rm $F $G b' 'F=-r; G=-i; (G=-i); unset G; rm $F $G b'; do
  test_deny  "$IRRECOVERABLE" "GH #808: $_c" "$(bash_payload "$_c")"
done
# GH #808 review: a redirection after an assignment is no command (`F=-r 2>/dev/null;` keeps F), and an unset or a
# paren inside quotes or a comment is text.
for _c in 'F=-r 2>/dev/null; rm $F $G b; G=-i' 'F=-r >/dev/null; rm $F $G b; G=-i' 'F=-r; G=-i 2>/dev/null rm $F $G b' \
  'F=-r; G=-i; unset -- G; rm $F $G b'; do
  test_deny  "$IRRECOVERABLE" "GH #808 review: $_c" "$(bash_payload "$_c")"
done
for _c in 'G=-i; F=-r; echo "run unset G later"; rm $F $G b' 'G=-i; F=-r; echo '"'"'unset G'"'"'; rm $F $G b' \
  $'G=-i; F=-r; # then unset G\nrm $F $G b' $'F=-r\n# prompt (interactive mode\nG=-i\n# end)\nrm $F $G b'; do
  test_allow "$IRRECOVERABLE" "GH #808 review control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
for _c in 'G=-i; F=-r; unset X; rm $F $G b' 'G=-i; F=-r; unset -f G; rm $F $G b' '(G=-i; F=-r; rm $F $G b)' \
  'G=-i; (F=-r; rm $F $G b)' 'G=-i; F=-r; (unset G); rm $F $G b' 'G=-i; F=-r; X=1 rm $F $G b' 'G=-i; F=-r; G=-i rm $F $G b' \
  'export G=-i F=-r; rm $F $G b' 'G=-i F=-r; rm $F $G b' 'F=-r; unset G; G=-i; rm $F $G b'; do
  test_allow "$IRRECOVERABLE" "GH #808 control: $_c" "$(bash_payload "$_c")"
done
# GH #816/#820: a double-quoted bash -c / eval body keeps the outer shell's `\$` (shlex leaves it), which the child
# reads as `$`: a copy of the body with `\$` / `\`` unescaped is substituted too, at every nesting level (GH #816:
# `bash -c 'bash -c "\$X -p x"'`, the innermost body read with the enclosing body's assignments). A single-quoted body
# keeps its backslash (`bash -c '\$Y -p x'` runs a command named `$Y`). A pipe into a compound command (case, if,
# while, until, for, select) feeds every claude inside it (GH #820 item 3); `>(claude)` reads what is written to it
# (GH #820 item 4).
for _c in "export X=claude; bash -c 'bash -c \"\\\$X -p x\"'" "export X=claude; bash -c 'bash -c \"echo hi | \\\$X\"'" \
  "bash -c 'export X=claude; bash -c \"\\\$X -p x\"'" "bash -c 'X=claude; bash -c \"\\\$X -p x\"'" \
  "export X=claude; bash -c 'export Y=\$X; bash -c \"\\\$Y -p x\"'" \
  'export Y=claude; bash -c "date|\$Y"' 'export Y=claude; bash -c "\$Y -p x"' 'Y=claude bash -c "\$Y -p x"' \
  'export Y=claude; eval "\$Y -p x"' 'export Y=claude; sh -c "echo hi | \$Y"' 'Y=claude; bash -c "Z=\$Y; \$Z -p x"' \
  'echo hi | case a in a) claude;; esac' 'echo hi | case a in (a) claude;; esac' 'echo hi | case a in a) true; claude;; esac' \
  'echo hi | case a in b) true;; a) claude;; esac' 'echo hi | if true; then claude; fi' \
  'echo hi | while read l; do claude; done' 'ls | for f in 1; do claude; done' 'X=claude; echo hi | if true; then $X; fi' \
  'echo hi > >(claude)' 'echo hi | tee >(claude)' 'echo hi | tee >( claude ) >/dev/null' 'X=claude; echo hi > >($X)'; do
  test_deny  "$IRRECOVERABLE" "GH #816/#820: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in "export X=claude; bash -c 'bash -c \"\\\$X --version\"'" "export X=claude; bash -c 'bash -c \"echo \\\$X\"'" \
  'export Y=claude; bash -c "\$Y --version"' 'export Y=claude; bash -c "echo \$Y"' "export Y=claude; bash -c '\\\$Y -p x'" \
  'export B=python3; bash -c "\$B -c 1"' 'export Y=claude; bash -c "command -v \$Y"' \
  'echo hi | case a in a) claude --version;; esac' 'case a in a) claude;; esac' 'true || case a in a) claude;; esac' \
  'echo hi | if true; then true; fi; claude' 'echo hi | while read l; do echo $l; done; claude mcp list' \
  'echo hi | case "$x" in done) true;; esac; claude' 'echo hi > >(claude --version)' 'diff <(claude --version) f' \
  'echo hi > >(grep claude)'; do
  test_allow "$IRRECOVERABLE" "GH #816/#820 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
# GH #816/#820 review: every body as written is read before any unescaped copy, so 25 copies of a 15 KB value cannot
# spend the shared budget before a later `$X -p x` body; a `}` before done / fi closes, and `if)` is a case pattern.
_c="H=$(printf 'y%.0s' $(seq 15000)); $(for i in $(seq 0 24); do printf 'bash -c "echo \\$H %s"; ' "$i"; done)export X=claude; bash -c '\$X -p x'"
test_deny  "$IRRECOVERABLE" 'GH #816/#820 review: subagent: 25 double-quoted bodies of a 15 KB $H, then export X=claude; bash -c '"'"'$X -p x'"'"'' \
  "$(bash_agent_payload "$_c" fork)"
for _c in 'echo hi | while read l; do { echo "$l"; } done; claude --continue' 'echo hi | if true; then { :; } fi; claude --resume' \
  'echo hi | case a in a|if) true;; esac; claude --continue'; do
  test_allow "$IRRECOVERABLE" "GH #816/#820 review control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
# GH #816/#820 review 2: a body's assignments reach only the unescaped copies, never a sibling body as written (its own
# later value stays read); `done>file` and `fi done` close; a `$((..))` / `<(..)` close is no case arm.
for _c in "bash -c 'echo \$HOME; Y=python3'; bash -c 'f(){ \$Y -p x; }; trap f EXIT; Y=claude'" \
  "W=python3; X=claude; bash -c 'Y=\$W'; bash -c 'f(){ \$Y -p x; }; trap f EXIT; Y=\$X; true'" \
  "echo $(printf 'a%.0s' $(seq 21000)); bash -c 'X=python3; echo \$X'; bash -c 'f(){ \$X -p x; }; X=claude; f'"; do
  test_deny  "$IRRECOVERABLE" "GH #816/#820 review 2: subagent: ${_c:0:120}" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'git log --oneline | while read l; do echo "$l"; done>log.txt; claude --continue' \
  'git log | if grep -q x; then echo y; fi>/dev/null; claude --resume' \
  'echo hi | while read l; do if [ x ]; then echo; fi done; claude --continue' \
  'echo | case a in a) echo $((1+2)) claude;; esac' 'echo | case a in a) cat <(ls) claude;; esac'; do
  test_allow "$IRRECOVERABLE" "GH #816/#820 review 2 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
# GH #815: interp-pipe-shell gaps left after GH #801. An inline python/node/perl/ruby script piped into a shell
# is read past a project runner (uv/poetry/pipenv/pdm/hatch/rye/conda run), in a { } or ( ) group, past more node
# value flags, with the shell or interpreter name spelled s\h, s''h or $'\x73h', across a backslash-newline after
# the pipe, inside $(..) or a backtick, in a body a stdin shell reads (bash <<'EOF', cat <<'EOF' | bash) and in the
# $(..) of an unquoted data body; a stored os.system / from-os import is a process API in a heredoc script.
for _c in $'uv run python -c \'print(1)\' | bash' $'poetry run python3 -c 1 | sh' \
  $'uv run --with requests --python 3.12 python3 -c 1 | bash' $'pipenv run python -c 1 | sh' \
  $'conda run -n base python -c 1 | bash' $'{ python3 -c \'print(1)\'; } | bash' $'(python3 -c \'print(1)\') | bash' \
  $'(cd /tmp && node -e 1) | sh' $'{ echo x\npython3 -c 1\n} | bash' $'node --title x -e 1 | bash' \
  $'node --env-file f -e 1 | sh' $'python3 -c 1 | s\\h' $'python3 -c 1 | s\'\'h' $'python3 -c 1 | $\'\\x73h\'' \
  $'echo \'git reset --hard\' | s\\h' $'$\'\\x70ython3\' -c 1 | bash' $'$\'pyth\\157n3\' -c 1 | sh' \
  $'python3 -c 1 | \\\nbash' $'echo \'git reset --hard\' | \\\nbash' $'x=$(python3 -c 1 | sh)' \
  $'echo `python3 -c 1 | sh`' $'bash <<\'EOF\'\npython3 -c 1 | sh\nEOF' $'cat <<\'EOF\' | bash\nnode -e 1 | sh\nEOF' \
  $'perl -e \'print "ls"\' | sh' $'perl -lne \'print\' f | bash' $'ruby -e \'puts 1\' | bash' \
  $'python3 - <<\'EOF\'\nimport os\nf = os.system\nf(\'git reset --hard\')\nEOF' \
  $'python3 - <<\'EOF\'\nfrom os import system as run\nrun(\'git reset --hard\')\nEOF' \
  $'cat <<EOF\n$(python3 -c 1 | bash)\nEOF' $'cat <<EOF\nx\nEO\\\nF\npython3 -c 1 | bash' \
  $'python3 -c \'print("git reset --hard")\' | bash -s \\<\\<' \
  $'python3 -c 1 | bash -s 2<<EOF\nx\nEOF' $'python3 -c 1 | bash -s <(cat <<<x)' $'python3 -c 1 | bash -s ${x:-<<}' \
  $'python3 -c 1 | bash -s $[1<<2]' $'python3 -c 1 | bash <<EOF\nx\nEOF'; do
  test_deny  "$IRRECOVERABLE" "GH #815: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #815 controls: the same shapes with no shell reading the script's output, a script file (not read either way),
# a value word naming sh or holding e, a code body's own data heredoc, and an expanding body's literal text. A shell
# given a heredoc (`| bash <<EOF`, the issue's NIT) stays denied: a << that is no stdin redirect must not get past.
for _c in $'uv run python -c \'print(1)\' | grep 1' $'uv run --with sh python3 -c 1 | tee log' \
  $'{ python3 -c 1; } | grep x' $'(python3 -c 1); bash x.sh' $'(cd /tmp && python3 -c 1) > out.txt; echo ls | grep sh' \
  $'node --env-file .env -e 1 | jq .' $'python3 -c 1 | s\\ort' $'$\'\\x70ython3\' -c 1 | wc -l' \
  $'python3 -c 1 | \\\ngrep sh' $'x=$(python3 -c \'print(1)\'); bash -c \'echo hi\'' \
  $'bash <<\'EOF\'\npython3 -c 1 | grep 1\nEOF' $'bash <<\'EOF\'\ncat > y.sh <<\'IN\'\npython3 -c 1 | sh\nIN\nEOF' \
  $'perl -e \'print 1\' | wc -l' $'perl -Mfeature=say x.pl | sh' \
  $'python3 - <<\'EOF\'\nimport os\nf = os.path.join\nprint(f(\'a\', \'git reset --hard\'))\nEOF' \
  $'cat > notes.md <<EOF\nbuilt $(date)\nrun python3 -c 1 | bash\nEOF' $'cat <<EOF\nx\nEO\\\nF\npython3 -c 1 | wc -l'; do
  test_allow "$IRRECOVERABLE" "GH #815 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #818: more values the raw copy drops: an `unset` whose name is quoted or comes after an expansion, an assignment
# in a background job (a subshell), `local`/`declare` with no value in the function the reference is in, an unset later
# in the loop body a later pass reads, and a value set in a function not called before the reference.
for _c in "G=-i; F=-r; unset 'G'; rm \$F \$G b" 'G=-i; F=-r; unset "G"; rm $F $G b' 'G=-i; F=-r; unset ${X} G; rm $F $G b' \
  'G=-i & F=-r; rm $F $G b' 'F=-r; G=-i & rm $F $G b' 'G=-i; F=-r; f(){ local G; rm $F $G b; }; f' \
  'G=-i; F=-r; f() { declare G; rm $F $G b; }; f' 'G=-i; F=-r; for i in 1 2; do rm $F $G b; unset G; done' \
  'G=-i; F=-r; while true; do rm $F $G b; unset G; done' 'F=-r; f(){ G=-i; }; rm $F $G b' \
  'F=-r; function f { G=-i; }; rm $F $G b; f'; do
  test_deny  "$IRRECOVERABLE" "GH #818: $_c" "$(bash_payload "$_c")"
done
for _c in "G=-i; F=-r; unset 'X'; rm \$F \$G b" 'G=-i; F=-r; unset ${X} H; rm $F $G b' 'G=-i && F=-r; rm $F $G b' \
  'G=-i 2>&1; F=-r; rm $F $G b' 'F=-r; sleep 1 & G=-i; rm $F $G b' 'G=-i; F=-r; f(){ local G; }; f; rm $F $G b' \
  'G=-i; F=-r; f(){ local X; rm $F $G b; }; f' 'G=-i; F=-r; declare G; rm $F $G b' \
  'G=-i; F=-r; for i in 1 2; do G=-i; rm $F $G b; unset G; done' 'G=-i; F=-r; for i in 1 2; do unset X; rm $F $G b; done' \
  'G=-i; F=-r; for i in 1 2; do rm $F $G b; done; unset G' 'F=-r; f(){ G=-i; }; f; rm $F $G b' \
  'F=-r; f(){ G=-i; }; g(){ f; }; g; rm $F $G b' 'F=-r; f(){ G=-i; rm $F $G b; }; f'; do
  test_allow "$IRRECOVERABLE" "GH #818 control: $_c" "$(bash_payload "$_c")"
done
# GH #818 review: an `&` inside ${..}, backticks, $[..] or a [..] subscript is no background list; a call written inside
# another function's body counts; an unset in a function never called is no unset for the loop rule.
for _c in 'G=-i; F=-r; unset G && T=${S//&/and}; rm $F $G b' 'G=-i; F=-r; unset G && echo `true & true`; rm $F $G b' \
  'G=-i; F=-r; unset G && T=$[ 3 & 1 ]; rm $F $G b' 'G=-i; F=-r; unset G && a[1&1]=1; rm $F $G b' \
  'G=-i; F=-r; unset G && echo ${S:-&}; rm $F $G b' 'G=-i; F=-r; unset G ${Z//x/&}; rm $F $G b' \
  'G=-i; F=-r; unset G ${Z:+a&b}; rm $F $G b'; do
  test_deny  "$IRRECOVERABLE" "GH #818 review: $_c" "$(bash_payload "$_c")"
done
for _c in 'F=-r; G=-i && T=${S//&/x}; rm $F $G b' 'F=-r; G=-i && echo `date & wait`; rm $F $G b' \
  'F=-r; main(){ init; }; init(){ G=-i; }; main; rm $F $G b' \
  'G=-i; F=-r; for x in a b; do rm $F $G b; f(){ unset G; }; done'; do
  test_allow "$IRRECOVERABLE" "GH #818 review control: $_c" "$(bash_payload "$_c")"
done
# GH #818 review 2: the scan does not follow quotes nested in "$( .. )" or "` .. `", so with one in the text no `&` is read
# as a background list.
for _c in 'G=-i; F=-r; unset G && echo "$(printf "%s & %s" a b)"; rm $F $G b' \
  'G=-i; F=-r; unset G && msg="$(git log -1 --format="%an & %ae")"; rm $F $G b' \
  $'G=-i; F=-r\nunset G && echo "`date "+%a & %b"`"\nrm $F $G b' 'G=-i; F=-r; unset G "$(echo "a & b")"; rm $F $G b'; do
  test_deny  "$IRRECOVERABLE" "GH #818 review 2: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
for _c in 'F=-r; G=-i && T="$(sed "s/&/and/" f)"; rm $F $G b' 'F=-r; G=-i && echo "$(printf "%s & %s" a b)"; rm $F $G b' \
  'F=-r; export G=-i X="$(fmt "a & b")"; rm $F $G b'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 2 control: $_c" "$(bash_payload "$_c")"
done
# GH #818 review 3: the same for a "${X:-"default"}" (its inner quotes). A background list drops a value only: an unset
# there still counts (develop's reading), so the raw copy never reads less than develop's did.
for _c in 'G=-i; F=-r; unset G && echo "${X:-"Tom & Jerry"}"; rm $F $G b' 'F=-r; G=-i; unset G & wait; rm $F $G b' \
  'G=-i; F=-r; unset G && echo "${MSG:-"build & test"}" >&2; rm $F $G b' \
  'G=-i; F=-r; unset G && echo "${X:+"a & b"}" "${Y:-"$Z"}"; rm $F $G b'; do
  test_deny  "$IRRECOVERABLE" "GH #818 review 3: $_c" "$(bash_payload "$_c")"
done
# GH #818 review 4: the scoped reading is one more copy, not a change to the raw one, so a first loop pass, a value set in a
# function a later body reads, and an earlier value past a dropped one all keep develop's reading.
for _c in 'G=-i; F=-r; unset G; for i in 1; do rm $F $G b; unset F; done' \
  'G=-i; F=-r; unset G; while true; do rm $F $G b; unset F; break; done' \
  'init(){ F=-r; }; main(){ rm $F $G b; }; G=-i; unset G; init; main' 'G=-i; unset G; f(){ F=-r; }; g(){ rm $F $G b; }; f; g' \
  'G=-i; F=-r & unset G; wait; rm $F $G b'; do
  test_deny  "$IRRECOVERABLE" "GH #818 review 4: $_c" "$(bash_payload "$_c")"
done
# GH #818 review 5: a reference inside a function body runs when that function is called, so the function rule reads
# only a reference outside every body; a second `local` of a name the body already made local keeps its value.
for _c in $'set -e\nFLAGS=-r\nconfigure() {\n  SAFE=-i\n}\nremove_build() {\n  rm $FLAGS $SAFE build\n}\nconfigure\nremove_build' \
  'R=-r; main(){ I=-i; run; }; run(){ rm $R $I d; }; main "$@"' 'R=-r; f(){ local I=-i; local I; rm $R $I d; }; f'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 5 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #818 review 6: the function rule is off unless every function head has a body the scan recorded (a `f() ( .. )`
# body, a `}` right after `fi`, or a comment before the `{` is not one).
for _c in 'F=-r; init() { G=-i; }; run() ( rm $F $G b ); init; run' \
  'F=-r; setup() { G=-i; }; clean() { if [ -d b ]; then rm $F $G b; fi }; setup; clean' \
  'F=-r; setup() { G=-i; }; clean() { (cd /tmp && rm $F $G b) }; setup; clean' \
  $'RFLAG=-r\nparse_opts() {\n  CONFIRM=-i\n}\nclean_build()  # remove the build dir\n{\n  rm $RFLAG $CONFIRM build\n}\nparse_opts\nclean_build' \
  'F=-r; G=-i; f(){ local G; G=-i; local G; rm $F $G b; }; f' 'F=-r; G=-i; f(){ local -I G; rm $F $G b; }; f'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 6 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #818 review 7: a function called between `local G` (or a loop's unset) and the reference may set G (bash's dynamic
# scope), so may source, eval, read G or any G= there; a loop body that can stop early is no later pass; a dynamic call
# (`setup_$mode`) turns the function rule off; a scoped `unset`/`local` is a command, not an argument.
for _c in $'RFLAG=-r\nload_defaults() {\n  CONFIRM=-i\n  TARGET=build\n}\nmain() {\n  local CONFIRM TARGET\n  load_defaults\n  rm $RFLAG $CONFIRM "$TARGET"\n}\nmain "$@"' \
  'F=-r; set_g() { G=-i; }; clean() { local G; set_g; rm $F $G build; }; clean' \
  $'F=-r\nset_confirm() { G=-i; }\nfor d in a b; do\n  set_confirm\n  rm $F $G x\n  unset G\ndone' \
  $'F=-r\nset_confirm() { G=-i; }\nset_confirm\nfor d in a b; do\n  rm $F $G x\n  unset G\n  set_confirm\ndone' \
  'G=-i; F=-r; while true; do rm $F $G x; break; unset G; done' $'F=-r\nsetup_safe() { G=-i; }\nmode=safe\nsetup_$mode\nrm $F $G x' \
  'F=-r; G=-i; echo unset "G"; rm $F $G x'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 7 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #818 review 8: past a value the scoped copy drops (an uncalled body, a background list) it skips that scope's earlier
# entries too, so an unset there does not count; an unset in a body that is all there is still counts, as develop read it.
for _c in $'RFLAG=-r\nCONFIRM=-i\nreset_confirm() {\n  unset CONFIRM\n  CONFIRM=-i\n}\nrm $RFLAG $CONFIRM build\nreset_confirm' \
  'F=-r; G=-i; reset(){ unset G; G=-i; }; rm $F $G b; reset; rm $F $G b' 'F=-r; G=-i; { unset G; G=-i; sleep 1; } & wait; rm $F $G b'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 8 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" "GH #818 review 8: an unset alone in a body (develop's reading)" \
  "$(bash_payload 'F=-r; G=-i; f(){ unset G; }; rm $F $G b')"
# GH #818 review 9: a while/until condition runs before each pass: the loop rule's scans start at the loop keyword, and a
# condition that reads G (it may end the loop) turns the rule off; under set -u an unset G aborts bash before rm, so the
# local and loop rules are off.
for _c in 'F=-r; n=0; next_opt(){ n=$((n+1)); [ $n -le 2 ] && G=-i; }; while next_opt; do rm $F $G b; unset G; done' \
  'F=-r; G=-i; while [ -n "$G" ]; do rm $F $G b; unset G; done' 'F=-r; G=-i; until [ -z "$G" ]; do rm $F $G b; unset G; done' \
  'set -u; F=-r; G=-i; f(){ local G; rm $F $G b; }; f'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 9 control: $_c" "$(bash_payload "$_c")"
done
# GH #818 review 10: a call whose name is built at run time ("${a}_cmd", "$fn", $fn) turns the function rule off; for the
# loop rule an unset in a background list the reference is not in, or one that is no command, does not count.
for _c in $'F=-r\nsafe_cmd() { G=-i; }\naction=safe\n"${action}_cmd"\nrm $F $G b' $'F=-r\nsafe_init() { G=-i; }\nprintf -v fn \'%s_init\' safe\n"$fn"\nrm $F $G b' \
  $'F=-r\nsafe_init() { G=-i; }\nfn=$(printf \'%s_%s\' safe init)\n$fn\nrm $F $G b' \
  'F=-r; G=-i; for d in a b; do rm $F $G b; { unset G; echo "$d"; } & done; wait' \
  'F=-r; G=-i; for d in a b; do rm $F $G b; kubectl config unset G; done'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 10 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #818 review 11: an unset in a ( .. ) that closes within the loop body never reaches a later pass; G[0]= may set G.
for _c in $'F=-r; G=-i\nfor f in a b; do (cd /tmp && rm $F $G x; unset G); done' $'F=-r; G=-i\nf(){ local G; G[0]=-i; rm $F $G d; }\nf'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 11 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #818 review 12: select may set G; a loop condition naming G in any form (declare -p G) may end the loop.
for _c in 'R=-r; I=-i; f(){ local I; select I in -i; do break; done; rm $R $I x; }; f' \
  'R=-r; I=-i; while declare -p I >/dev/null 2>&1; do rm $R $I a; unset I; done'; do
  test_allow "$IRRECOVERABLE" "GH #818 review 12 control: $_c" "$(bash_payload "$_c")"
done
# GH #823: interp-pipe-shell gaps left after GH #815. An inline script piped into a shell is read out of a compound
# command (if/while/until/for, and a function whose body runs one, called later), past `!` and `coproc`, into a shell
# reached through xargs or a >(..) process substitution, past the uvx / npx / pipx run runners (a name@version
# program too), and an echo piped into a shell spelled $'\x73h'.
for _c in 'if true; then python3 -c 1; fi | bash' 'while read l; do python3 -c 1; done < f | bash' \
  'f() { python3 -c 1; }; f | bash' 'until false; do node -e 1; done | sh' 'for x in a b; do python3 -c 1; done | bash' \
  'if python3 -c 1; then :; fi | bash' $'function f {\n  python3 -c 1\n}\nf | bash' 'g() ( perl -e 1 ); g | sh' \
  'f() { python3 -c 1; }; h() { f; }; h | bash' '{ if true; then python3 -c 1; fi; } | bash' \
  '! python3 -c 1 | bash' 'coproc python3 -c 1 | bash' '! { python3 -c 1; } | bash' \
  'python3 -c 1 | xargs bash' 'python3 -c 1 | xargs -n 1 -I{} sh -c {}' 'python3 -c 1 | xargs -0 sudo bash' \
  'python3 -c 1 | tee >(bash)' 'python3 -c 1 | tee >(bash) | wc -l' 'python3 -c 1 > >(sh)' 'x=$(date); python3 -c 1 | tee >(bash)' \
  'uvx python -c 1 | bash' 'uvx python@3.12 -c 1 | bash' 'uvx --from x python3 -c 1 | bash' \
  'npx -y node@18 -e 1 | sh' 'pipx run python -c 1 | bash' 'pipx run --spec x python3 -c 1 | sh' \
  'uv tool run python -c 1 | bash' $'echo \'git reset --hard\' | $\'\\x73h\'' $'printf \'git reset --hard\' | $\'\\163h\'' \
  'for ((i=0;i<2;i++)); do python3 -c 1; done | bash' 'for((i=0;i<2;i++)); do node -e 1; done | sh' \
  'while(true); do python3 -c 1; done | bash' 'if(true); then python3 -c 1; fi | bash' \
  'for ((i=0; i<1; i++)) { python3 -c 1; } | bash' 'f() { for ((i=0;i<1;i++)) { python3 -c 1; }; }; f | bash' \
  'f() { for ((;;)) { :; }; python3 -c 1; }; f | bash' 'f() { for x in a; { python3 -c 1; }; }; f | bash' \
  'for x do python3 -c 1; done | bash' 'f() { for x do { python3 -c 1; }; done; }; f | bash' \
  'f() { for x do if true; then :; fi; done; python3 -c 1; }; f | bash'; do
  test_deny  "$IRRECOVERABLE" "GH #823: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #823 review 2: only a real ((..)) arithmetic command is blanked: a quoted or commented (( .. )) pair hides no pipe,
# nor does a (( .. )) holding a comment, which bash reads as nested subshells (review 3).
for _c in 'echo "((" ; python3 -c 1 | bash ; echo "))"' "echo '((' ; python3 -c 1 | bash ; echo '))'" \
  'x="((";python3 -c 1|bash;y="))"' $'echo hi # ((\npython3 -c 1 | bash\n# ))' 'echo a((b; python3 -c 1 | bash; echo c))' \
  $'(( # (\n python3 -c 1 | bash ))' $'echo x; (( # (\npython3 -c 1 | bash ))' $'if (( # (\n python3 -c 1 | bash )); then :; fi'; do
  test_deny  "$IRRECOVERABLE" "GH #823 review 2: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "GH #823 review 2 control: a quoted (( .. )) and no shell" \
  "$(bash_payload 'echo "((" ; python3 -c 1 | grep x ; echo "))"')"
# GH #823 review: many >(..) cost one paren pass, not a scan per opener (the deny comes inside the deadline).
_c="python3 -c 1 | tee $(printf '>(%.0s' $(seq 6000))sh"
test_deny  "$IRRECOVERABLE" "GH #823 review: 6000 nested >( (fast)" "$(bash_payload "$_c")"
# GH #823 controls: the same shapes with no shell reading the script's output, a function whose body runs none (or one
# not called before the pipe), xargs running no shell, a >(..) that is no shell, a runner running no inline script,
# and $'..' naming no shell.
for _c in 'if true; then python3 -c 1; fi | grep x' 'while read l; do python3 -c 1; done < f | wc -l' \
  'f() { python3 -c 1; }; f | grep 1' 'if true; then python3 -c 1; fi; echo ls | bash' \
  'f() { echo ls; }; python3 -c 1; f | bash' 'for x in a b; do echo $x; done | bash' 'g() { python3 -c 1; }; echo hi | bash' \
  '! python3 -c 1 | grep x' 'coproc python3 -c 1 | wc -l' '! python3 -c 1; echo ls | bash' \
  'python3 -c 1 | xargs echo' 'python3 -c 1 | xargs -n 1 grep bash' 'echo ls | xargs bash' \
  'python3 -c 1 | tee >(gzip > out.gz)' 'python3 -c 1 | tee >(wc -l) | grep sh' 'x=$(date); python3 -c 1 | tee >(wc -l)' \
  'uvx ruff check . | bash' 'uvx python x.py | sh' 'npx -y node@18 x.js | sh' 'pipx run black . | bash' \
  $'echo \'git status\' | $\'\\x73h\'' $'echo \'git reset --hard\' | $\'\\x67rep\' x' \
  'for ((i=0;i<2;i++)); do python3 -c 1; done | sort' 'while(true); do echo ls; done | bash' 'x=$((1+2)); echo ls | bash'; do
  test_allow "$IRRECOVERABLE" "GH #823 control: ${_c//$'\n'/ \\n }" "$(bash_payload "$_c")"
done
# GH #820 item 5: a `#` glued after the `)` of $(..), $((..)), <(..), >(..) or name=(..) is part of the word in bash,
# never a comment (`echo $(date)#|$X` pipes into $X). A `)` closing a subshell `(..)` or `((..))` still ends the word,
# so a `#` after it, or after a blank, opens a comment. The mask is _quote_mask here and the shared _quotemask.py
# (subagent-git-guard, test-integrity) with its inline copies.
for _c in 'X=claude; echo $(date)#|$X' 'X=claude; echo $(date)#x|$X' 'X=claude; echo $((1+1))#|$X' \
  'X=claude; cat <(date)#|$X' 'X=claude; echo $( (date) )#|$X' 'echo $(date)#|claude' 'X=claude; a=$(date)#; $X -p hi'; do
  test_deny  "$IRRECOVERABLE" "GH #820 item 5: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'X=claude; echo $(date) #|$X' 'X=claude; (date)#|$X' 'X=claude; ((1))#|$X' 'X=claude; echo $(date)#|$X --version'; do
  test_allow "$IRRECOVERABLE" "GH #820 item 5 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_deny  "$IRRECOVERABLE" 'GH #820 item 5: X=rm; echo a #'"'"' \n $X -rf /' "$(bash_payload $'X=rm; echo a #\'\n$X -rf /')"
test_deny  "$IRRECOVERABLE" 'GH #820 item 5: X=rm; echo $(date)#; $X -rf /' "$(bash_payload 'X=rm; echo $(date)#; $X -rf /')"
test_allow "$IRRECOVERABLE" 'GH #820 item 5 control: X=rm; echo a #'"'"' \n $X --version' "$(bash_payload $'X=rm; echo a #\'\n$X --version')"
test_allow "$IRRECOVERABLE" 'GH #820 item 5 control: X=rm; echo $(date) #; $X -rf /' "$(bash_payload 'X=rm; echo $(date) #; $X -rf /')"
test_deny  "$SUBAGENT_GIT_GUARD" 'GH #820 item 5: subagent: echo $(date)#; git stash' "$(bash_agent_payload 'echo $(date)#; git stash' fork)"
test_allow "$SUBAGENT_GIT_GUARD" 'GH #820 item 5 control: subagent: echo $(date) #; git stash' "$(bash_agent_payload 'echo $(date) #; git stash' fork)"
# GH #787: the var-verb view's enforced rm rules read as far as the parser does (_CMD_LEN_CAP), like ifs-split; it
# stopped at _VIEW_LEN_CAP (20 KB), so padding in front of `F=-rf; rm $F b` allowed it. Timed: a timed-out hook allows.
_pad787="$(printf 'echo a; %.0s' $(seq 3000))"
test_deny  "$IRRECOVERABLE" 'GH #787: 24 KB of statements, then F=-rf; rm $F b' "$(bash_payload "${_pad787}F=-rf; rm \$F b")"
test_deny  "$IRRECOVERABLE" 'GH #787: F=-rf, 24 KB of statements, then rm $F b' "$(bash_payload "F=-rf; ${_pad787}rm \$F b")"
test_allow "$IRRECOVERABLE" 'GH #787 control: 24 KB of statements, then F=-f; rm $F b' "$(bash_payload "${_pad787}F=-f; rm \$F b")"
_timed_case 'GH #787: F=-rf; rm $F b after 48 KB of statements, denied in bounded time' 2 \
  "$(printf 'echo a; %.0s' $(seq 6000))F=-rf; rm \$F b"
_timed_case 'GH #787 control: 1200 F=x assignments and $F references after 24 KB of statements, allowed in bounded time' 0 \
  "${_pad787}$(printf 'F=x; echo $F; %.0s' $(seq 1200))"
test_allow "$IRRECOVERABLE" 'GH #787 control: 1200 F=x assignments and $F references after 24 KB of statements' \
  "$(bash_payload "${_pad787}$(printf 'F=x; echo $F; %.0s' $(seq 1200))")"
# GH #787 review: past the cap a var-verb copy that would cost more than its budget is not read, so the command asks
# (the raw copy, whose scan budget the subshells and references below spend, alone reads `rm -r $G b`).
# References each walking back past the subshell assignments spend it; a build script reading its $LOG does not.
# GH #857: at the full budget (3000 x 1500) the row took 3 to 4 s and met the 4 s deadline first on a slower machine.
# MH_IRR_BUDGET_SCALE shrinks the budget instead: this 24 KB text (past the 20 KB cap) peaks at about 620,000 units of
# copy work, so at 0.1 (400,000) it asks in about 0.6 s, and the same text at 0.5 (2,000,000) is read whole and denies:
# only the budget differs, so the ask is the budget's.
_t787="$(printf 'echo a; %.0s' $(seq 1600))$(printf '(H=1); %.0s' $(seq 400))$(printf 'echo $H; %.0s' $(seq 900))F=-r; rm \$F \$G b; G=-i"
MH_IRR_BUDGET_SCALE=0.1 test_ask_says "$IRRECOVERABLE" 'GH #787 review: a raw copy past its budget asks: F=-r; rm $F $G b; G=-i' \
  "$(bash_payload "$_t787")" 'too many variable readings'
MH_IRR_BUDGET_SCALE=0.5 test_deny "$IRRECOVERABLE" 'GH #857 control: the same raw copy under a larger budget is read: rm $F $G b denies' \
  "$(bash_payload "$_t787")"
_log787="LOG=build.log; rm -f \$LOG; $(printf 'cc -c f.c -o f.o 2>>$LOG || (echo fail; exit 1); %.0s' $(seq 1500))"
test_allow "$IRRECOVERABLE" 'GH #787 review control: a 73 KB build script, 1500 subshells and $LOG references' "$(bash_payload "$_log787")"
# GH #787 review 3: the raw copy's spans holding an entry are found once per entry, not once per reference.
_cp787="SRC=/data/in"$'\n'"DST=/data/out/y"$'\n'"$(for i in $(seq 1500); do printf 'cp $SRC/f%d.txt $(dirname $DST)/x%d\n' "$i" "$i"; done)"
test_allow "$IRRECOVERABLE" 'GH #787 review 3 control: 1500 lines of cp $SRC/f $(dirname $DST)/x (58 KB)' "$(bash_payload "$_cp787")"
# A copy is bounded while it is built: a 5 KB value at 6000 references would be 30 MB (70 KB at 25000 took 9 s, 1.7 GB).
test_ask_says "$IRRECOVERABLE" 'GH #787 review: a copy over the read budget while built asks (5 KB value, 6000 references)' \
  "$(bash_payload "${_pad787}F='$(printf 'a%.0s' $(seq 5000))'; rm a; $(printf '$F;%.0s' $(seq 6000))F=b")" \
  'too many variable readings'
# GH #787 review: a prefix assignment's statement start is a bisect, not a split of the whole text before it.
_timed_case 'GH #787 review control: 130 KB of LC_ALL=C sort prefix assignments, allowed in bounded time' 0 \
  "$(printf 'LC_ALL=C sort file > out; %.0s' $(seq 5000))X=1; echo \$X"
test_allow "$IRRECOVERABLE" 'GH #787 review control: 130 KB of LC_ALL=C sort prefix assignments' \
  "$(bash_payload "$(printf 'LC_ALL=C sort file > out; %.0s' $(seq 5000))X=1; echo \$X")"
# GH #731: a claude spawn built by a brace (`cl{aude,aude} -p x` runs `claude -p x claude -p x`), with or without
# ${IFS}, denies in a subagent; brace-view's copies are spawn-scanned, statement by statement, where they name claude.
# (`cl{aude,aude}${IFS}-p x` itself denies on develop as git-restore, a brace-view misread of `W{,}${IFS}a b` in any
# session: the follow-up issue; the `${IFS}x` rows here read as the spawn only.)
for _c in 'cl{aude,aude} -p x' 'cl{aude,aude}${IFS}-p x' 'cl{aude,aude}${IFS}-p${IFS}x' 'c{l,l}aude -p x' \
    'true; cl{aude,} -p x' 'echo hi | cl{aude,aude}' "cla\$'u'de{,} -p x" "cl{\$'a',}ude -p x"; do
  test_deny  "$IRRECOVERABLE" "GH #731: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'cl{aude,aude} -p x' 'cl{aude,aude}${IFS}-p${IFS}x'; do
  test_allow "$IRRECOVERABLE" "GH #731 control: main session: $_c" "$(bash_payload "$_c")"
done
for _c in 'echo cl{aude,aude} -p x' 'grep -r cl{aude,aude} {a,b}/' 'mkdir -p {a,b}/claude' 'cl{aude,aude} --version'; do
  test_allow "$IRRECOVERABLE" "GH #731 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
# brace text in a subagent (300 #690 words: more spends the main reading's spawn budget on develop): bounded and
# allowed, and the spawn after it denies
_timed_case 'GH #731: subagent: 300 {a,b}${IFS}$(echo c) words are read in bounded time' 0 \
  "echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 300))" fork
_timed_case 'GH #731: subagent: cl{aude,aude}${IFS}-p${IFS}x after 300 brace words denies in bounded time' 2 \
  "echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 300)); cl{aude,aude}\${IFS}-p\${IFS}x" fork
# GH #833: the # misreads #829 left (GH #820 item 5 residuals). A case pattern's `)` inside $(..) no longer closes the
# $(, a backslash-newline before # (or between $ and its `(`) is a line continuation bash deletes, an escaped blank or
# separator before # is part of the word, and an extglob group @( !( ?( *( +( ends inside its word. Each runs claude in
# bash 5.2. Fail safe (review): a case misread from an argument (`echo do case`) or whose esac goes unseen leaves every
# later `)` unsure, read as glued while a $( is open, and never touches a ".." frame. Masks: _quote_mask here, the shared _quotemask.py and its inline copies (subagent-git-guard, test-integrity).
for _c in 'X=claude; echo $(case a in a) echo b;; esac)#|$X' 'X=claude; echo $(case a in (a) echo b;; esac)#|$X' \
    $'X=claude; echo $(case a in\n a|b) echo b;;\n esac)#|$X' 'X=claude; echo $(case a in a) (echo b);; esac)#|$X' \
    'X=claude; echo $(if true; then case a in a) echo b;; esac; fi)#|$X' 'X=claude; echo $(case a in esac)#|$X' \
    'X=claude; echo $(echo do case)#|$X' 'X=claude; echo $(echo then case)#|$X' 'X=claude; echo $(echo ! case)#|$X' \
    'X=claude; echo $(echo { case)#|$X' 'X=claude; echo $(echo time case)#|$X' 'X=claude; echo $( (echo do case) )#|$X' \
    'X=claude; echo "$(echo do case)" | $X' 'X=claude; echo "$(case a in a) { :; } esac)" | $X' \
    'X=claude; echo "$(case a in a) if :; then :; fi esac)" | $X' 'X=claude; echo $(case a in a) { :; } esac)#|$X' \
    'X=claude; echo $(if case a in a) :;; esac; then :; fi)#|$X' \
    'X=claude; echo $(while case a in a) false;; esac; do :; done)#|$X' \
    'X=claude; echo $(case a in a) case b in b) :;; esac;; c) :;; esac)#|$X' 'X=claude; echo $(f() case a in a) :;; esac; f)#|$X' \
    'X=claude; echo $(case a in a) echo in esac;; b) :;; esac)#|$X' \
    $'X=claude; echo a\\\n#|$X' $'X=claude; echo $(date)\\\n#|$X' $'X=claude; echo $\\\n(date)#|$X' \
    'X=claude; echo a\ #|$X' 'X=claude; echo a\;#|$X' \
    $'shopt -s extglob\nX=claude; echo @(a)#|$X' $'shopt -s extglob\nX=claude; echo !(a)#|$X' \
    $'shopt -s extglob\nX=claude; echo ?(a)#|$X' $'shopt -s extglob\nX=claude; echo *(a)#|$X' \
    $'shopt -s extglob\nX=claude; echo +(a)#|$X'; do
  test_deny  "$IRRECOVERABLE" "GH #833: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'X=claude; echo $(case a in a) echo b;; esac) #|$X' 'X=claude; echo $(case a in a) echo b;; esac)#|$X --version' \
    'X=claude; echo $(echo case)#|$X --version' 'X=claude; echo $(echo do case) #|$X' $'X=claude; echo a \\\n#|$X' $'X=claude; echo a\\\\\n#|$X' \
    'X=claude; echo a\\ #|$X' $'shopt -s extglob\nX=claude; echo @(a) #|$X' \
    $'shopt -s extglob\nX=claude; echo +(a)#|$X --version' 'X=claude; case a in a)#|$X'$'\n''esac'; do
  test_allow "$IRRECOVERABLE" "GH #833 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'echo $(case a in a) :;; esac)#; git stash' 'echo $(echo do case)#; git stash' 'echo $(echo then case)#; git stash' \
    'echo $(case a in a) { :; } esac)#; git stash' 'echo $(case a in a) echo in esac;; b) :;; esac)#; git stash' $'echo a\\\n#; git stash' $'echo $\\\n(date)#; git stash' \
    'echo @(a)#; git stash'; do
  test_deny  "$SUBAGENT_GIT_GUARD" "GH #833: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'echo $(case a in a) :;; esac) #; git stash' $'echo a \\\n#; git stash' 'echo @(a) #; git stash'; do
  test_allow "$SUBAGENT_GIT_GUARD" "GH #833 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
# GH #833 review 2: a # right after an unsure `)` (a case marker on top, a glued ( open) is read both ways: its line
# stays visible, but no quote or << on it opens anything, so neither reading hides the lines below it.
test_deny  "$IRRECOVERABLE" 'GH #833 review 2: a=(do case); case a in a)#<<E \n ;; esac; rm -rf ~/ \n E' \
  "$(bash_payload $'a=(do case); case a in a)#<<E\n;; esac; rm -rf ~/\nE')"
test_allow "$IRRECOVERABLE" 'GH #833 review 2 control: a=(do case); case a in a)#<<E \n ;; esac; rm -f x \n E' \
  "$(bash_payload $'a=(do case); case a in a)#<<E\n;; esac; rm -f x\nE')"
for _c in $'a=(do case); case a in a)#<<E\n;; esac; claude -p hi\nE' $'a=(do case); case a in a)#<<E\n;; esac; X=claude; $X -p hi\nE' \
    $'shopt -s extglob\necho @(do|case); case a in a)#<<E\n;; esac; claude -p hi\nE' \
    $'X=claude; echo $(echo do case); case a in a)#\'\n;; esac; $X -p hi\n#\''; do
  test_deny  "$IRRECOVERABLE" "GH #833 review 2: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #833 review 2 control: subagent: ...#<<E \n ;; esac; claude --version \n E' \
  "$(bash_agent_payload $'a=(do case); case a in a)#<<E\n;; esac; claude --version\nE' fork)"
for _c in $'a=(do case); case a in a)#\'\n;; esac; git stash\n#\'' $'a=(do case); case a in a)#"\n;; esac; git stash\n#"' \
    $'shopt -s extglob\necho @(x|case); case a in a)#\'\n;; esac; git stash\n#\'' $'a=(do case); case a in a)#<<E\n;; esac; git stash\nE'; do
  test_deny  "$SUBAGENT_GIT_GUARD" "GH #833 review 2: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 2 control: subagent: ...)#'"'"' \n ;; esac; git status \n #'"'" \
  "$(bash_agent_payload $'a=(do case); case a in a)#\'\n;; esac; git status\n#\'' fork)"
# GH #833 review 3: the unsure line is still read as a word (frames, parens, continuations), with only its quotes and
# < inert, so a $( opened on it or a backslash-newline ending it carries on as in bash.
test_deny  "$IRRECOVERABLE" 'GH #833 review 3: echo $(echo do case)#$( \n cat <<E \n hi \n E) \n rm -rf ~/ \n E' \
  "$(bash_payload $'echo $(echo do case)#$(\ncat <<E\nhi\nE)\nrm -rf ~/\nE')"
test_deny  "$IRRECOVERABLE" "GH #833 review 3: echo \$(echo do case)#\$( \\n cat <<'E' ... rm -rf ~/" \
  "$(bash_payload $'echo $(echo do case)#$(\ncat <<\'E\'\nhi\nE)\nrm -rf ~/\nE')"
test_allow "$IRRECOVERABLE" 'GH #833 review 3 control: echo $(echo do case)#$( \n cat <<E \n hi \n E) \n ls x \n E' \
  "$(bash_payload $'echo $(echo do case)#$(\ncat <<E\nhi\nE)\nls x\nE')"
for _c in $'X=claude; echo $(echo do case)#$(\ncat <<E\nhi\nE)\n$X -p hi\nE' $'X=claude; echo $(echo do case)#\\\n#|$X'; do
  test_deny  "$IRRECOVERABLE" "GH #833 review 3: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #833 review 3 control: subagent: X=claude; echo $(echo do case)#\ \n #|$X --version' \
  "$(bash_agent_payload $'X=claude; echo $(echo do case)#\\\n#|$X --version' fork)"
test_deny  "$SUBAGENT_GIT_GUARD" 'GH #833 review 3: subagent: echo $(echo do case)#\ \n #; git stash' \
  "$(bash_agent_payload $'echo $(echo do case)#\\\n#; git stash' fork)"
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 3 control: subagent: echo $(echo do case)#\ \n #; git status' \
  "$(bash_agent_payload $'echo $(echo do case)#\\\n#; git status' fork)"
# GH #833 review 4: a quote bash opens on the unsure line may close on a later one, so once an inert quote or < shows
# up the rest of the text is read with no quote, comment or heredoc opening (more reading, never less).
for _c in $'X=claude; echo $(echo do case)#"\n" | $X' $'X=claude; echo $(echo then case)#"\n" | $X # "' \
    $'X=claude; echo $(echo then case)#\'\n\' | $X # \'' $'X=claude; echo $(echo do case)#$\'\n\' | $X # \'' \
    $'X=claude; cat <(echo do case)#"\n" | $X' $'X=claude; a=( do case )#"\n" | $X'; do
  test_deny  "$IRRECOVERABLE" "GH #833 review 4: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #833 review 4 control: subagent: X=claude; echo $(echo do case)#" \n " | $X --version' \
  "$(bash_agent_payload $'X=claude; echo $(echo do case)#"\n" | $X --version' fork)"
test_deny  "$IRRECOVERABLE" 'GH #833 review 4: echo $(echo do case)#" \n cat <<E \n " \n rm -rf ~/ \n E \n "' \
  "$(bash_payload $'echo $(echo do case)#"\ncat <<E\n"\nrm -rf ~/\nE\n"')"
for _c in $'echo $(echo do case)#"\n"; git stash' $'echo $(echo do case)#"\n" && git reset --hard # "' \
    $'echo $(echo do case)#${x:-"\n"}; git stash # "'; do
  test_deny  "$SUBAGENT_GIT_GUARD" "GH #833 review 4: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 4 control: subagent: echo $(echo do case)#" \n "; git status' \
  "$(bash_agent_payload $'echo $(echo do case)#"\n"; git status' fork)"
# GH #833 review 5: bash drops an inert quote mark (and the $ of an inert $'..'), so the shared mask drops it too, its
# blank moved to the word front: a quoted git word on or after the unsure line still reads whole.
for _c in 'echo $(echo do case)#; "git" stash' 'echo $(echo do case)#; git "stash"' \
    "echo \$(echo do case)#'x' && g''it stash" "echo \$(echo do case)#; 'g'it reset --hard" \
    "echo \$(echo do case)#; \$'git' stash" $'echo $(echo do case)# \'\n\'\ngit "stash"'; do
  test_deny  "$SUBAGENT_GIT_GUARD" "GH #833 review 5: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 5 control: subagent: echo $(echo do case)#; "git" status' \
  "$(bash_agent_payload 'echo $(echo do case)#; "git" status' fork)"
# GH #833 review 6: the $ of an inert $".." is dropped too ($"git" is git in bash).
for _c in 'echo $(echo do case)#; $"git" stash' 'echo $(echo do case)#; x=1 $"git" stash' 'echo $(echo do case)#; $"g"it stash' \
    'echo $(echo do case)#; g$"it" stash' 'echo $(echo do case)#; $"g"$"it" stash' 'echo $(echo do case)#"a"; $"git" stash' \
    'echo $(echo do case)#; git $"reset" --hard'; do
  test_deny  "$SUBAGENT_GIT_GUARD" "GH #833 review 6: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 6 control: subagent: echo $(echo do case)#; $"git" status' \
  "$(bash_agent_payload 'echo $(echo do case)#; $"git" status' fork)"
# GH #833 review 7: with extglob off (plain bash -c) !( is a negated subshell and x+() f@() a function, so a # after
# their ) is a comment; the ) of an extglob candidate is unsure, and the # after it is read both ways.
test_deny  "$IRRECOVERABLE" 'GH #833 review 7: !(true)#<<E \n rm -rf ~ \n E' "$(bash_payload $'!(true)#<<E\nrm -rf ~\nE')"
test_deny  "$IRRECOVERABLE" 'GH #833 review 7: !(true)#<<E \n git reset --hard \n E' "$(bash_payload $'!(true)#<<E\ngit reset --hard\nE')"
test_allow "$IRRECOVERABLE" 'GH #833 review 7 control: !(true)#<<E \n rm -f x \n E' "$(bash_payload $'!(true)#<<E\nrm -f x\nE')"
for _c in $'!(true)#<<E\nclaude -p a\nE' $'x+()#<<E\n{ claude -p hi; }\nx+\nE' $'f@()#\'\n{ claude -p hi; }\nf@\n#\''; do
  test_deny  "$IRRECOVERABLE" "GH #833 review 7: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #833 review 7 control: subagent: !(true)#<<E \n claude --version \n E' \
  "$(bash_agent_payload $'!(true)#<<E\nclaude --version\nE' fork)"
for _c in $'x+()#\'\n{ git stash; }\nx+\n#\'' $'f@()#\'\n{ git clean -fdx; }\nf@\n#\'' $'!(true)#"\ngit reset --hard\n#"'; do
  test_deny  "$SUBAGENT_GIT_GUARD" "GH #833 review 7: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 7 control: subagent: x+()#'"'"' \n { git status; } \n x+ \n #'"'" \
  "$(bash_agent_payload $'x+()#\'\n{ git status; }\nx+\n#\'' fork)"
# GH #833 review 8: hd mode's (( branch: !((1)) with extglob off is ! and an arithmetic command, so its ) is unsure too.
for _c in $'!((1))#<<E\nrm -rf ~\nE' $'true; !((1))#<<E\nrm -rf ~\nE' $'if !((1))#<<E\nrm -rf ~\nE\nthen :; fi' \
    $'?((1))#<<E\nrm -rf ~\nE' $'@((a))#<<E\nrm -rf ~\nE'; do
  test_deny  "$IRRECOVERABLE" "GH #833 review 8: $_c" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" 'GH #833 review 8 control: !((1))#<<E \n rm -f x \n E' "$(bash_payload $'!((1))#<<E\nrm -f x\nE')"
test_deny  "$IRRECOVERABLE" 'GH #833 review 8: subagent: !((1))#<<E \n claude -p hi \n E' \
  "$(bash_agent_payload $'!((1))#<<E\nclaude -p hi\nE' fork)"
test_allow "$IRRECOVERABLE" 'GH #833 review 8 control: subagent: !((1))#<<E \n claude --version \n E' \
  "$(bash_agent_payload $'!((1))#<<E\nclaude --version\nE' fork)"
# GH #833 review 9: a ) on an unsure # line that pops below the depth at its # closes what the comment reading still
# has open, so every later ) is unsure (fail safe): the real closer's # is read both ways.
for _c in $'echo $(!(true)#)\n)#|claude' $'X=claude; echo $(!(true)#)\n)#|$X' $'echo $(!((1))#)\n)#|claude' \
    $'echo $(f+()#)\n{ :; }\n)#|claude'; do
  test_deny  "$IRRECOVERABLE" "GH #833 review 9: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #833 review 9 control: subagent: echo $(!(true)#) \n )#|claude --version' \
  "$(bash_agent_payload $'echo $(!(true)#)\n)#|claude --version' fork)"
test_deny  "$SUBAGENT_GIT_GUARD" 'GH #833 review 9: subagent: echo $(!(true)#) \n )#; git stash' \
  "$(bash_agent_payload $'echo $(!(true)#)\n)#; git stash' fork)"
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 9 control: subagent: echo $(!(true)#) \n )#; git status' \
  "$(bash_agent_payload $'echo $(!(true)#)\n)#; git status' fork)"
# GH #833 review 10: what the unsure line does (quote frames, an esac, an opened ( or $(, a continuation) outlives it,
# so from an unsure # to the end the state is unknown: no quote or comment opens and every later ) is unsure.
for _c in $'X=claude; echo "$(!(true)#)"\n)" | $X' $'X=claude; echo $(!(true)#(\n)#|$X' $'X=claude; !(true)#\\\n#\'\necho hi |$X #\'' \
    $'X=claude; echo "$(!(true)#)\nclaude -p hi)"'; do
  test_deny  "$IRRECOVERABLE" "GH #833 review 10: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #833 review 10 control: subagent: X=claude; echo "$(!(true)#)" \n )" | $X --version' \
  "$(bash_agent_payload $'X=claude; echo "$(!(true)#)"\n)" | $X --version' fork)"
for _c in $'echo $(case a in a) !(true)#;esac\n;; b)#\'\n;; esac); git stash\n\'' $'( !(true)#$(\n)#\'\ngit stash\n\'' \
    $'echo $(!(true)#(\n)#; git stash' $'!(true)#\\\n#\'\ngit stash #\''; do
  test_deny  "$SUBAGENT_GIT_GUARD" "GH #833 review 10: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$SUBAGENT_GIT_GUARD" 'GH #833 review 10 control: subagent: !(true)#\ \n #'"'"' \n git status #'"'" \
  "$(bash_agent_payload $'!(true)#\\\n#\'\ngit status #\'' fork)"
# GH #834/#835
# GH #834: brace-view's raw copy read a bare unquoted ${IFS} as any text, so `ls{,}${IFS}-p x` (bash runs
# `ls -p ls -p x`) read as `<any> <any> x`, a git restore with a pathspec, in any session. Unquoted and bare,
# ${IFS} is a word break or nothing (an empty IFS), never other text: the ifs-split copy reads the break, and the
# raw copy now reads it as nothing.
for _c in 'ls{,}${IFS}-l x' 'ls{,}${IFS}-W x' 'ls{,}${IFS}. x' 'e{cho,cho}${IFS}-p x' 'cl{aude,aude}${IFS}-p x' \
    'ls{,} -p x' 'cl{aude,aude}${IFS}-p${IFS}x' 'ls{,}$IFS-l x' 'ls{,}${IFS}-l x y'; do
  test_allow "$IRRECOVERABLE" "GH #834: main session: $_c" "$(bash_payload "$_c")"
done
for _c in 'ls{,}${IFS}-l x' 'e{cho,cho}${IFS}-p x'; do
  test_allow "$IRRECOVERABLE" "GH #834: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
# controls: brace-view still reads git's discard rules through ${IFS}, a quoted "${IFS}" and an operator form
for _c in 'gi{t,t}${IFS}restore x' 'git{,}${IFS}restore${IFS}x' 'git re{store,store} x' 'g{i,i}t${IFS}reset --hard' \
    'IFS=; gi${IFS}t restore{,} x'; do
  test_deny  "$IRRECOVERABLE" "GH #834 control: $_c" "$(bash_payload "$_c")"
done
test_deny  "$IRRECOVERABLE" 'GH #834 control: subagent: cl{aude,aude}${IFS}-p x is the spawn' \
  "$(bash_agent_payload 'cl{aude,aude}${IFS}-p x' fork)"
# GH #835: four subagent claude spawns that were allowed. Rows 1-2 need the ifs-split and var-verb rewrites at once
# (one in-order var-verb copy of the ifs-split text); row 3 is an ANSI-C escape the spawn anchor never decoded; row 4
# is a brace in a bash -c / eval body, which brace-view never expands (it reads quoted text as written).
for _c in 'X=claude; bash${IFS}-c "$X -p x"' 'X=claude; env${IFS}$X -p x' $'$\'\\x63laude\' -p x' \
    "bash -c 'cl{aude,aude} -p x'" \
    'X=claude; env${IFS}$X${IFS}-p${IFS}x' 'X=claude; bash${IFS}-c${IFS}"$X -p x"' $'$\'\\143laude\' -p x' \
    $'cl$\'\\x61\'ude -p x' $'bash -c "$\'\\x63laude\' -p x"' "bash -c \"cl{aude,aude} -p x\"" \
    "eval 'cl{aude,aude} -p x'" "bash -c 'true; c{l,l}aude -p x'" "sh -c 'bash -c \"cl{aude,aude} -p x\"'" \
    "bash\${IFS}-c 'cl{aude,aude} -p x'"; do
  test_deny  "$IRRECOVERABLE" "GH #835: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'X=claude; bash${IFS}-c "$X -p x"' 'X=claude; env${IFS}$X -p x' $'$\'\\x63laude\' -p x' \
    "bash -c 'cl{aude,aude} -p x'"; do
  test_allow "$IRRECOVERABLE" "GH #835 control: main session: $_c" "$(bash_payload "$_c")"
done
for _c in 'X=claude; bash${IFS}-c "$X --version"' 'X=python3; env${IFS}$X -p x' $'$\'\\x63laude\' --version' \
    $'echo $\'\\x63laude\' -p x' "bash -c 'echo cl{aude,aude} -p x'" "bash -c 'mkdir -p {a,b}/claude'" \
    "bash -c 'cl{aude,aude} --version'"; do
  test_allow "$IRRECOVERABLE" "GH #835 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
# a body's brace text is read in bounded time, and the spawn after it still denies (150 words: 300 in a body spend
# the main reading's spawn budget on develop, which denies as too dense)
_timed_case 'GH #835: subagent: bash -c with 150 {a,b}${IFS}$(echo c) words is read in bounded time' 0 \
  "bash -c 'echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 150))'" fork
_timed_case 'GH #835: subagent: bash -c cl{aude,aude} -p x after 150 brace words denies in bounded time' 2 \
  "bash -c 'echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 150)); cl{aude,aude} -p x'" fork
# GH #838/#840
# GH #838: the main reading blanked a bare unquoted ${IFS} to a placeholder, which a token window reads as any text,
# so `ls${IFS}-p ls${IFS}-p x` (bash runs `ls -p ls -p x`) read as `<any> <any> x`, a git restore, in any session.
# Unquoted and bare, ${IFS} is a word break or nothing (GH #834): the main reading now reads it as the break, as the
# ifs-split view does, and one extra ifs-split copy reads it as nothing. Other ${NAME} keep the broad reading
# (`${G}it` may be git).
for _c in 'ls${IFS}-p ls${IFS}-p x' 'ls${IFS} ls${IFS} x' 'ls$IFS-p ls$IFS-p x' 'ls${IFS}-p ls${IFS}-p x y' \
    'echo${IFS}a echo${IFS}a x' 'ls${IFS}-p x'; do
  test_allow "$IRRECOVERABLE" "GH #838: main session: $_c" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" 'GH #838: subagent: ls${IFS}-p ls${IFS}-p x' "$(bash_agent_payload 'ls${IFS}-p ls${IFS}-p x' fork)"
# controls: a ${IFS} that is a break or nothing still reads the verb; a quoted "${IFS}", an operator form and any other
# ${NAME} keep the placeholder
for _c in 'git${IFS}restore x' 'gi${IFS}t restore x' 'git${IFS}restore${IFS}x' 'rm${IFS}-rf${IFS}x' 'r${IFS}m -rf x' \
    'git${IFS}reset${IFS}--hard' 'ls${HOME}-p ls${HOME}-p x' 'ls${A} ls${A} x' 'ls${IFS:0:1}-p ls${IFS:0:1}-p x' \
    'ls"${IFS}"-p ls"${IFS}"-p x' 'X=${IFS}; gi${X}t restore x' 'echo ${IFS}#; rm -rf x' 'echo ${IFS}#x | gi${IFS}t restore y'; do
  test_deny  "$IRRECOVERABLE" "GH #838 control: $_c" "$(bash_payload "$_c")"
done
# GH #838 review: a here-string or an unquoted heredoc body does no word splitting, so after `IFS=m` a ${IFS} there is
# the letter m (`IFS=m; bash <<< "r"${IFS}" -rf x"` runs rm). A command that names IFS other than as a bare $IFS / ${IFS}
# keeps the placeholder reading.
for _c in 'IFS=m; bash <<< "r"${IFS}" -rf /"' 'IFS=m; sh <<< "r"${IFS}" -rf x"' "IFS=m; bash<<<r\${IFS}' -rf x'" \
    'IFS=i; bash <<< g${IFS}t\ restore\ x' 'IFS=t; bash <<< gi${IFS}\ res${IFS}ore\ x' $'IFS=i; bash <<EOF\ng${IFS}t restore x\nEOF' \
    'read IFS <<< m; bash <<< "r"${IFS}" -rf x"' 'export IFS=m; bash <<< "r"${IFS}" -rf x"'; do
  test_deny  "$IRRECOVERABLE" "GH #838 review: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" 'GH #838 review control: IFS=m; cat <<< "r"${IFS}" x"' "$(bash_payload 'IFS=m; cat <<< "r"${IFS}" x"')"
# GH #838 review 2: the default IFS holds a newline, so in a here-string or heredoc body ${IFS} starts a new command
# (`bash <<< "echo"${IFS}"rm -rf x"`), and IFS may be set under a spelling the text does not show (`printf -v I""FS m`):
# a command with `<<` in it keeps the placeholder reading.
for _c in 'bash <<< "echo"${IFS}"rm -rf x"' 'bash<<<"echo"${IFS}"rm -rf x"' 'sh <<< "true"${IFS}"rm -rf x"' \
    'bash <<< "echo"${IFS}"git reset --hard"' 'bash <<< "echo"${IFS}"git restore x"' $'bash <<EOF\necho${IFS}rm -rf x\nEOF' \
    $'bash <<-EOF\n\techo${IFS}rm -rf x\n\tEOF' 'printf -v I""FS m; bash <<< "r"${IFS}" -rf x"' 'eval I""FS=m; bash <<< "r"${IFS}" -rf x"' \
    'read I\FS <<< m; bash <<< "r"${IFS}" -rf x"' 'declare I\FS=m; bash <<< "r"${IFS}" -rf x"' \
    'printf -v I""FS i; bash <<< g${IFS}t\ restore\ x' $'eval I""FS=m; bash <<EOF\nr${IFS} -rf x\nEOF'; do
  test_deny  "$IRRECOVERABLE" "GH #838 review 2: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
_c='printf -v I""FS m; ls${IFS}-p ls${IFS}-p x'
test_allow "$IRRECOVERABLE" "GH #838 review 2 control: $_c" "$(bash_payload "$_c")"
# GH #838 review 3: read as nothing, ${IFS} glued a -c body to the next word (`sh -c 'claude -p'${IFS}x` read as
# `claude -px`); bash splits there, so the main reading reads a break, and an extra ifs-split copy reads nothing (an IFS
# emptied under a spelling the text hides: `printf -v I""FS ''; gi${IFS}t restore x`).
for _c in "sh -c 'claude -p'\${IFS}x" "bash -c 'claude --print'\${IFS}x" "echo hi | sh -c 'claude -p'\${IFS}x" \
    "sh -c 'echo hi | claude'\${IFS}x" "sh -c 'claude --bg'\${IFS}x" 'bash -c claude\ -p${IFS}x' 'sh -c "claude -p"${IFS}"x"' \
    "bash -c 'claude -p'\${IFS}'x'" "bash -c 'claude -p'\${IFS}\\x" "env sh -c 'claude -p'\${IFS}x" "nohup bash -lc 'claude -p'\${IFS}x"; do
  test_deny  "$IRRECOVERABLE" "GH #838 review 3: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in "sh -c 'claude -p'\${IFS}x" "bash -c 'claude --version'\${IFS}x"; do
  test_allow "$IRRECOVERABLE" "GH #838 review 3 control: main session: $_c" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "GH #838 review 3 control: subagent: sh -c 'claude --version'\${IFS}x" \
  "$(bash_agent_payload "sh -c 'claude --version'\${IFS}x" fork)"
for _c in 'printf -v I""FS ""; gi${IFS}t restore x' 'eval I""FS=; r${IFS}m -rf x' "bash -c 'git reset --hard'\${IFS}y"; do
  test_deny  "$IRRECOVERABLE" "GH #838 review 3: $_c" "$(bash_payload "$_c")"
done
# GH #838 review 4: a quoted "${IFS}" is IFS's text, newline included, and an echo / printf fed to a shell drops the
# quotes before its body is read (`echo "x${IFS}rm -rf x" | bash` runs the rm): a command with a quoted or escaped
# $IFS / ${IFS} keeps the placeholder reading.
for _c in 'echo "x${IFS}rm -rf x" | bash' 'printf "x${IFS}rm -rf x" | sh' "printf '%s\\n' \"x\${IFS}rm -rf x\" | bash" \
    'echo "true${IFS}rm -rf x" | sh' 'echo "x${IFS}git reset --hard" | bash' 'echo "x${IFS}git restore y" | bash' \
    'echo x"${IFS}"rm -rf x | bash' 'echo "x${IFS}r""m -rf x" | bash' 'echo -e "x${IFS}rm -rf x" | bash -s' \
    'echo "x${IFS}rm -rf x" | env bash' 'command echo "x${IFS}git reset --hard" | sh'; do
  test_deny  "$IRRECOVERABLE" "GH #838 review 4: $_c" "$(bash_payload "$_c")"
done
# GH #838 review 5: text a shell reads again (an echo fed to `| bash`, a -c body) is no longer what ${IFS} was where it
# was written (`unset I""FS; echo g${IFS}it reset --hard | bash` runs git reset --hard): only the command's own top-level
# text reads a bare ${IFS} as a break; every body keeps the placeholder.
for _c in 'unset I""FS; echo g${IFS}it reset --hard | bash' "printf -v I''FS ''; echo r\${IFS}m -rf x | bash" \
    'export I""FS=; echo r${IFS}m -rf x | bash' 'unset I""FS; echo g${IFS}it restore x | sh' \
    "printf -v I''FS ''; echo g\${IFS}it clean -fdx | sh -s"; do
  test_deny  "$IRRECOVERABLE" "GH #838 review 5: $_c" "$(bash_payload "$_c")"
done
# GH #838 review 6: an assignment word is not split, so `X=a${IFS}echo` is one prefix assignment and the next word is
# the command (`X=a${IFS}echo git push${IFS}--force origin x` pushes): a bare ${IFS} in a NAME= / NAME+= / NAME[..]=
# word keeps the placeholder reading.
for _c in 'X=a${IFS}echo git push${IFS}--force origin x' 'X=${IFS}echo git push${IFS}--force origin x' \
    'X=a${IFS}true git push${IFS}-f origin x' 'X=a${IFS}echo git push${IFS}--delete origin x' \
    'X=a${IFS}echo git push${IFS}origin${IFS}:x' 'X=a${IFS}echo git branch${IFS}-D x' 'X=a${IFS}echo git checkout${IFS}-- x' \
    'cd . && X=a${IFS}echo git push${IFS}--force origin x' 'A=1 X="a b"${IFS}echo git push${IFS}--force origin x'; do
  test_deny  "$IRRECOVERABLE" "GH #838 review 6: $_c" "$(bash_payload "$_c")"
done
# bounded: a run of NAME= starts in one word is scanned once, not once per start
_timed_case 'GH #838 review 6: ${IFS} and 5000 a= in one word are read in bounded time' 0 \
  "echo \${IFS} $(printf 'a=%.0s' $(seq 5000))b<x"
# GH #838 review 7: an assignment value may hold any substitution or a backslash-newline (`X=$(true)a${IFS}echo`), so
# any NAME= / NAME+= / ]= before the last bare ${IFS} keeps the placeholder reading.
for _c in 'X=$(true)a${IFS}echo git push${IFS}--force origin x' 'X=$(true)${IFS}echo git push${IFS}--force origin x' \
    'X=$((1))${IFS}echo git push${IFS}--force origin x' 'X=<(true)${IFS}echo git push${IFS}--force origin x' \
    'X=${A-a b}${IFS}echo git push${IFS}--force origin x' 'X=`echo a b`${IFS}echo git push${IFS}--force origin x' \
    'X=a Y=$(true)${IFS}echo git push${IFS}--force origin x' 'if X=$(true)${IFS}echo git push${IFS}--force origin x; then :; fi' \
    $'X=a\\\nb${IFS}echo git push${IFS}--force origin x' 'X=$(true)a${IFS}echo git branch${IFS}-D x'; do
  test_deny  "$IRRECOVERABLE" "GH #838 review 7: ${_c//$'\n'/ | }" "$(bash_payload "$_c")"
done
_timed_case 'GH #838 review 7: ${IFS} after 20000 name characters is read in bounded time' 0 \
  "echo $(printf 'a%.0s' $(seq 20000)) ls\${IFS}-p ls\${IFS}-p x"
# GH #846: the ifs-split copy that reads a bare ${IFS} as nothing is spawn-scanned, so a subagent's `cl${IFS}aude -p x`
# (an empty IFS runs claude) denies
for _c in 'cl${IFS}aude -p x' 'cl$IFS"aude" -p x' 'IFS=; cl${IFS}aude -p x'; do
  test_deny  "$IRRECOVERABLE" "GH #846: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
test_allow "$IRRECOVERABLE" 'GH #846 control: main session: cl${IFS}aude -p x' "$(bash_payload 'cl${IFS}aude -p x')"
test_allow "$IRRECOVERABLE" 'GH #846 control: subagent: cl${IFS}aude --version' "$(bash_agent_payload 'cl${IFS}aude --version' fork)"
# GH #840: a variable's value was never decoded, split, or carried into a nested body.
# Row 1: an ANSI-C value (`X=$'\x63laude'`) is no plain value, so var-verb never put claude back.
# Row 2: a value assigned in an outer body, used in a nested '...' body that the outer "..." unescapes (`\$X`).
# Row 3: an assignment does not split `git${IFS}restore`; the unquoted `$X` does, so an ifs-split copy puts it back.
for _c in $'X=$\'\\x63laude\'; $X -p x' $'X=$\'\\x63laude\'; bash -c "$X -p x"' $'X=$\'\\143laude\'; ${X} -p x' \
    "bash -c \"X=claude; bash -c '\\\$X -p x'\"" "bash -c \"X=claude; bash -c '\\\$X{,} -p x'\"" \
    "bash -c \"X=claude; sh -c 'echo; \\\$X -p x'\""; do
  test_deny  "$IRRECOVERABLE" "GH #840: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in $'X=$\'\\x63laude\'; $X -p x' "bash -c \"X=claude; bash -c '\\\$X -p x'\""; do
  test_allow "$IRRECOVERABLE" "GH #840 control: main session: $_c" "$(bash_payload "$_c")"
done
for _c in $'X=$\'\\x63laude\'; $X --version' $'X=$\'\\x70ython3\'; $X -p x' "bash -c \"X=claude; bash -c '\\\$X --version'\"" \
    "bash -c 'X=claude; bash -c '\\''\\\$X -p x'\\'''" "bash -c \"X=python3; bash -c '\\\$X -p x'\""; do
  test_allow "$IRRECOVERABLE" "GH #840 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'X=git${IFS}restore; $X x' 'X=git${IFS}restore; $X ${IFS}x' \
    'X=rm${IFS}-rf; $X x' 'X=git${IFS}reset${IFS}--hard; ${X}' 'X=git${IFS}restore; true && $X x'; do
  test_deny  "$IRRECOVERABLE" "GH #840: main session: $_c" "$(bash_payload "$_c")"
done
for _c in 'X=git${IFS}restore; "$X" x' 'X=git${IFS}status; $X x' 'X=git${IFS}restore; echo "$X" x' \
    'X=git${IFS}restore; X=ls; $X x' "X=git\${IFS}restore; echo '\$X x'"; do
  test_allow "$IRRECOVERABLE" "GH #840 control: main session: $_c" "$(bash_payload "$_c")"
done
# bounded: many nested bodies and many IFS-valued assignments are read in bounded time
_timed_case 'GH #840: subagent: 300 nested \$X bodies in a double-quoted body are read in bounded time' 0 \
  "bash -c \"X=python3; $(printf "bash -c '\\\\\$X -V'; %.0s" $(seq 300))\"" fork
_timed_case 'GH #840: 300 IFS-valued assignments and references are read in bounded time' 2 \
  "$(printf 'X=ls${IFS}-l; $X y; %.0s' $(seq 300))X=git\${IFS}restore; \$X x"
# GH #796
# GH #796: _PROC_BY_NAME is spliced onto the end of _INTERP_PROC_RE and _PYNODE_PROC_RE; its getattr quote is a named
# group, so a capturing group added earlier in either host regex cannot steal the backreference. Each host regex is
# compiled as is and again behind a capturing group of its own: getattr(os, "sep") never matches, getattr(os,
# "system") always does.
if _r796="$(python3 - "$ROOT/hooks/gates/irrecoverable.py" <<'PY' 2>&1
import ast, re, sys
tree = ast.parse(open(sys.argv[1]).read())
names = ("_PROC_BY_NAME", "_INTERP_PROC_RE", "_PYNODE_PROC_RE")
ns = {"re": re}
for n in tree.body:
    if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in names:
        exec(compile(ast.Module([n], []), "irrecoverable.py", "exec"), ns)
assert all(k in ns for k in names), "a regex assignment is missing"
assert not re.search(r"\\[1-9]", ns["_PROC_BY_NAME"]), "_PROC_BY_NAME holds a numbered backreference"
for host in ("_INTERP_PROC_RE", "_PYNODE_PROC_RE"):
    pat = ns[host].pattern
    for label, rx in (("as is", ns[host]), ("behind a capturing group", re.compile("(?:(Z)|)(?:" + pat + ")"))):
        assert not rx.search('getattr(os, "sep")'), host + " " + label + ': getattr(os, "sep") matches'
        assert rx.search('getattr(os, "system")'), host + " " + label + ': getattr(os, "system") does not match'
        assert rx.search("getattr(os, 'popen')"), host + " " + label + ": getattr(os, 'popen') does not match"
        assert rx.search("getattr(os, 'sep\")"), host + " " + label + ": a mixed-quote literal is read as one plain literal"
PY
)"; then echo "  ✅ GH #796: both host regexes read getattr literals through a named group"; pass=$((pass + 1))
else echo "  ❌ GH #796: $_r796" >&2; fail=$((fail + 1)); fi
# GH #839: a case arm inside "$(..)" was masked as quoted text: the pattern's `)` popped the "$( frame, so the arm up
# to the real `)` read as "..". Each runs claude in bash 5.2. Fail safe: that `)` may be a pattern's or the real one
# (a case misread from an argument, or an esac never seen), so the text is read both ways and masked only where both
# readings agree; the traps below must keep denying, and so must a pipe through a comment both readings see (GH #810,
# review 1) or one the keep reading drifts through and back (review 2), and a piped compound whose closer sits in a
# real string after a misread case (review 3), in a ${..} word (review 4), a [[ ]] or arithmetic operand (review 5),
# a \\$( in backticks, or after an esac the scan cannot see (reviews 6, 7), or an arm's argument a consumer takes for
# a closer or a rich arm a consumer parses unlike bash (review 8, fuzz), or a wrapper cut from its command (review 9).
for _c in 'echo "$(case a in a) echo hi | claude;; esac)"' 'X=claude; echo "$(case a in a) echo hi | $X;; esac)"' \
    'X=claude; echo "$(case a in (a) echo hi | $X;; esac)"' 'X=claude; echo "$(case a in a|b) $X -p x;; esac)"' \
    $'X=claude; echo "$(case a in\n a) $X -p x;;\n esac)"' 'X=claude; echo "x $(case a in a) $X -p x;; esac) y"' \
    'X=claude; echo "$(case a in b) :;; a) $X -p x;; esac)"' 'X=claude; echo "$(case a in a) echo "q" | $X;; esac)"' \
    'echo "$(echo do case)" | claude' 'X=claude; echo "$(echo do case)" | $X' \
    'X=claude; echo "$(case a in a) { :; } esac)" | $X' 'X=claude; echo "$(echo do case a in a) b)" | $X' \
    'X=claude; echo "$(echo then case a)" "b" | $X' 'X=claude; echo "$(case a in a) :;; esac)" | $X' \
    $'echo "$(case a in a) :;; esac)"; echo hi | # feed\nclaude' $'echo "$(echo do case)"; echo hi | # feed\nclaude' \
    $'echo "$(case a in a) :;; esac)"; echo hi | { # }\nclaude; }' $'echo "$(echo do case)"; echo hi | # a "b\nclaude' \
    $'X=claude; echo "$(echo do case)" | # "; esac) "\n$X' $'X=claude; echo "$(echo do case)" |\n# "; esac) "\n$X' \
    $'echo "$(echo do case)" | \\\n# "; esac) "\nclaude' $'echo "$(echo do case)" | { # "; esac) "\nclaude; }' \
    $'echo "$(echo do case)" | ( # "; esac) "\nclaude )' \
    'X=claude; echo hi | if true; then echo "$(echo do case)" "; esac) "; $X; fi' \
    'X=claude; echo hi | if true; then echo "$(echo do case); esac) "; $X; fi' \
    'X=claude; echo hi | case a in a) echo "$(echo then case)" "& esac)"; $X;; esac' \
    'X=claude; echo hi | while true; do echo "$(echo do case)" "; esac) "; $X; break; done' \
    'X=claude; echo hi | if true; then echo "$(:; case a in a) :;; esac)" "; esac) "; $X; fi' \
    'X=claude; echo "$(true && case a in a) echo hi | $X;; esac)"' 'X=claude; echo "$(:; case a in a) $X -p x;; esac)"' \
    'X=claude; echo hi | if true; then echo "$(echo ${x:-; case b in b) y; esac; fi )})"; $X; fi' \
    'X=claude; echo hi | case a in a) echo "$(echo ${x:-; case b in b) y; esac; esac )})"; $X;; esac' \
    'X=claude; echo hi | while true; do echo "$(echo ${x:-; case b in b) y; esac; done )})"; $X; break; done' \
    'X=claude; echo hi | if true; then echo "$(echo ${x:-&& case b in b) y; esac; fi )})"; $X; fi' \
    'X=claude; echo hi | if true; then echo "$(echo ${x:-|| case b in b) y; esac; fi )})"; $X; fi' \
    'X=claude; echo hi | if :; then echo "$(echo ${x/;case b in b)/; esac; fi )})"; $X; fi' \
    'X=claude; echo "${y}$(:; case a in a) $X -p x;; esac)"' \
    'echo hi | if true; then echo "$([[ x && case ]]) ; fi; esac ) "; claude; fi' \
    'X=claude; echo hi | if true; then echo "$([[ x || case ]]) ; fi; esac ) "; $X; fi' \
    'X=claude; echo hi | case a in a) echo "$([[ x && case ]]) ; esac; esac ) "; $X;; esac' \
    'X=claude; echo hi | if true; then echo "$(( 1 && case )) ; fi; esac ) ) "; $X; fi' \
    'X=claude; echo hi | if true; then echo "$(echo $[ 1 && case ]) ; fi; esac ) "; $X; fi' \
    'X=claude; echo hi | if true; then echo "$(echo ${x:-`echo }`; case b in b) y; esac; fi )})"; $X; fi' \
    'X=claude; echo "$$(case a in a) y; esac ) " | $X' \
    'X=claude; echo "$( case a in a) echo hi | $X;; esac)"' 'X=claude; echo "$$$(case a in a) echo hi | $X;; esac)"' \
    'echo hi | if true; then echo `echo "\\$(case a in a) ; fi; esac ) "`; claude; fi' \
    'X=claude; echo hi | if true; then echo "`echo "\\$(case a in a) ; fi; esac ) "`"; $X; fi' \
    'X=claude; echo hi | if true; then echo "$(case a in a) :;; esac>/dev/null) ; fi; esac ) "; $X; fi' \
    'echo hi | if true; then echo "$(case a in a) :;; esac</dev/null) ; fi; esac ) "; claude; fi' \
    'echo hi | if true; then echo "$(case a in a) :;; esac>&2) ; fi; esac ) "; claude; fi' \
    $'echo hi | if true; then echo "$(case a in a) :;; es\\\nac) ; fi; esac ) "; claude; fi' \
    'echo hi | while true; do echo "$(case a in a) :;; esac>/dev/null) ; done; esac ) "; claude; break; done' \
    $'echo hi | if true; then X="$(case x in x) echo;; esac>/dev/null; echo in b) fi "; claude; fi # "\nesac ) # "' \
    $'echo hi | case y in y) X="$(case x in x) echo;; esac>/dev/null; echo in b) esac "; claude;; esac # "\nesac ) # "' \
    $'echo hi | if true; then X="$(case x in x) echo;; esac<<<q; echo in b) fi "; claude; fi # "\nesac ) # "' \
    $'echo hi | if true; then X="$(case x in x) echo;; esac>/dev/null; echo \\;; b) fi "; claude; fi # "\nesac ) # "' \
    $'echo hi | if true; then X="$(case x in x) echo;; esac>/dev/null # ;; b\n) fi "; claude; fi # "\nesac ) # "' \
    $'echo hi | if true; then X="$(case x in x) echo;; esac>/dev/null; echo case y in b) fi "; claude; fi # "\nesac ) # "' \
    'echo hi | if true; then X="$(case x in x) echo } fi;; esac)"; claude; fi' \
    'echo hi | while true; do X="$(case x in x) echo } done;; esac)"; claude; break; done' \
    'echo hi | case y in y) X="$(case x in x) echo then esac;; esac)"; claude;; esac' \
    'echo hi | if true; then X="$(case x in x) a=(b) fi;; esac)"; claude; fi' \
    'echo hi | if true; then X="$(case x in x) echo $(( 1 )) fi;; esac)"; claude; fi' \
    'echo hi | if true; then X="$(case x in x) echo <(:) fi;; esac)"; claude; fi' \
    $'echo hi | if true; then X="$(case x in x) echo a\\\nfi;; esac)"; claude; fi' \
    'echo hi | if true; then X="$( case x in x) echo   fi{ fi;; esac)"; claude; fi' \
    $'echo hi | if true; then X="$(case x in\n x) echo $(( esac)\\${}|;; y) :;; esac)"; claude; fi' \
    'X=claude; nice -n "$(case x in x) echo 5;; esac)" $X -p x' 'X=claude; timeout "$(case x in x) echo 5;; esac)" $X -p x' \
    'X=claude; time "$(case x in x) echo env;; esac)" $X -p x' 'X=claude; env -u "$(case x in x) echo 5;; esac)" "$X" -p x' \
    'X=claude; echo hi | nice -n "$(case x in x) echo 5;; esac)" $X${IFS}-p${IFS}x' \
    $'X=claude; nice -n "$(case x in x) echo 5\nesac)" ${X} -p x'; do
  test_deny  "$IRRECOVERABLE" "GH #839: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in 'echo "$(case a in a) echo hi | claude --version;; esac)"' 'X=claude; echo "$(case a in a) $X --version;; esac)"' \
    'echo "$(echo do case)" | claude --version' 'X=claude; echo "$(case a in a) { :; } esac)" | $X --version' \
    'X=claude; echo "$(echo do case a in a) b)" | $X --version' \
    'echo "$(case a in a) echo hi;; esac)"' 'echo "$(case a in a) echo hi;; esac)" | claude --version' \
    $'echo "$(echo do case)"; echo hi | # feed\nclaude --version' $'echo "$(echo do case)" | \\\n# "; esac) "\nclaude --version' \
    'X=claude; nice -n "$(case x in x) echo 5;; esac)" $X --version'; do
  test_allow "$IRRECOVERABLE" "GH #839 control: subagent: $_c" "$(bash_agent_payload "$_c" fork)"
done
gates_summary
