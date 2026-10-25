#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal \$ in test payload strings is intentional
# Gate unit tests: simulates PreToolUse JSON payloads and asserts allow/deny/ask.
# Each test_deny call expects exit 2; test_allow expects exit 0 + empty stdout;
# test_ask expects exit 0 + a permissionDecision: ask JSON on stdout.
# Run standalone: bash tests/hooks/test-gates.sh
# Part 1 of 3 (with test-gates-irrecoverable-2.sh, test-gates-other.sh); helpers in tests/_lib/gates-harness.sh.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/_lib/gates-harness.sh"


echo "=== irrecoverable gate ==="
test_deny  "$IRRECOVERABLE" "rm -rf"                    "$(bash_payload 'rm -rf /tmp/test')"
test_deny  "$IRRECOVERABLE" "rm -fr variant"            "$(bash_payload 'rm -fr /tmp/test')"
test_deny  "$IRRECOVERABLE" "git push --force"          "$(bash_payload 'git push --force origin develop')"
test_deny  "$IRRECOVERABLE" "git push -f"               "$(bash_payload 'git push -f origin develop')"
test_deny  "$IRRECOVERABLE" "--no-verify"               "$(bash_payload 'git commit --no-verify -m msg')"
test_deny  "$IRRECOVERABLE" "git reset --hard"          "$(bash_payload 'git reset --hard HEAD~1')"
test_deny  "$IRRECOVERABLE" "git clean -f"              "$(bash_payload 'git clean -f')"
test_deny  "$IRRECOVERABLE" "git clean -fd"             "$(bash_payload 'git clean -fd')"
test_allow "$IRRECOVERABLE" "safe rm (no -rf)"          "$(bash_payload 'rm /tmp/file.txt')"
test_allow "$IRRECOVERABLE" "git push no force"         "$(bash_payload 'git push origin develop')"
test_allow "$IRRECOVERABLE" "git reset soft"            "$(bash_payload 'git reset --soft HEAD~1')"
test_allow "$IRRECOVERABLE" "normal bash command"       "$(bash_payload 'ls -la')"

# Raw-substring matching produced both false positives (blocked safe commands merely mentioning
# a pattern in quoted text) and bypasses (quoted/tokenization tricks slipped past the regex).
test_allow "$IRRECOVERABLE" "grep for rm -rf text (was a false positive)" \
  "$(bash_payload 'grep -rn "rm -rf" scripts/')"
test_allow "$IRRECOVERABLE" "commit msg mentioning rm -rf (was a false positive)" \
  "$(bash_payload 'git commit -m "docs: warn against rm -rf usage"')"
test_deny  "$IRRECOVERABLE" "quoted rm word (was a bypass)" \
  "$(bash_payload "'rm' -rf /tmp/x")"
test_deny  "$IRRECOVERABLE" "find -exec rm (was a bypass)" \
  "$(bash_payload 'find /tmp/x -exec rm {} \;')"
test_deny  "$IRRECOVERABLE" "git checkout -- discards changes (was a bypass)" \
  "$(bash_payload 'git checkout -- .')"
test_deny  "$IRRECOVERABLE" "git switch --force (was a bypass)" \
  "$(bash_payload 'git switch --force main')"
test_deny  "$IRRECOVERABLE" "git commit --amend (was a bypass)" \
  "$(bash_payload 'git commit --amend')"
test_deny  "$IRRECOVERABLE" "dd to raw device (was a bypass)" \
  "$(bash_payload 'dd if=/dev/zero of=/dev/disk2')"
test_deny  "$IRRECOVERABLE" "SQL DROP TABLE (was a bypass)" \
  "$(bash_payload 'mysql -e "DROP TABLE users"')"
# H3 (harness gap-audit, 2026-09-20): the same DROP/TRUNCATE check names all
# four SQL clients (line 938's argv0 tuple) but only mysql had a test.
test_deny  "$IRRECOVERABLE" "SQL DROP DATABASE via psql (H3, was untested)" \
  "$(bash_payload 'psql -c "DROP DATABASE x"')"
test_deny  "$IRRECOVERABLE" "SQL DROP TABLE via sqlite3 (H3, was untested)" \
  "$(bash_payload 'sqlite3 db.sqlite "DROP TABLE users"')"
test_deny  "$IRRECOVERABLE" "SQL TRUNCATE via mariadb (H3, was untested)" \
  "$(bash_payload 'mariadb -e "TRUNCATE orders"')"
# Rule shapes a mutation run showed no row pinned (each mutant survived the whole file).
test_deny  "$IRRECOVERABLE" "rm -Rf: the capital-R recursive flag" \
  "$(bash_payload 'rm -Rf /tmp/test')"
test_deny  "$IRRECOVERABLE" "find -execdir rm: the -execdir action, not just -exec" \
  "$(bash_payload 'find /tmp/x -execdir rm {} \;')"
test_deny  "$IRRECOVERABLE" "git push -uf: a force flag bundled with other short flags" \
  "$(bash_payload 'git push -uf origin develop')"
test_deny  "$IRRECOVERABLE" "mysql -e drop table: the SQL verb in lower case" \
  "$(bash_payload 'mysql -e "drop table users"')"
test_deny  "$IRRECOVERABLE" "psql -c DROP SCHEMA: a schema drop, not just table/database" \
  "$(bash_payload 'psql -c "DROP SCHEMA public CASCADE"')"
# GH #559: SQL a client reads on stdin, and the client tools that drop a database without SQL.
test_deny  "$IRRECOVERABLE" "GH #559: DROP TABLE in a heredoc psql reads" \
  "$(bash_payload "$(printf "psql mydb <<'SQL'\nDROP TABLE users;\nSQL")")"
test_deny  "$IRRECOVERABLE" "GH #559: TRUNCATE in a heredoc piped into psql" \
  "$(bash_payload "$(printf 'cat <<EOF | psql mydb\nTRUNCATE users;\nEOF')")"
test_deny  "$IRRECOVERABLE" "GH #559: DROP TABLE echoed into psql" \
  "$(bash_payload "echo 'DROP TABLE users' | psql mydb")"
test_deny  "$IRRECOVERABLE" "GH #559: DROP TABLE in a here-string psql reads" \
  "$(bash_payload "psql mydb <<< 'DROP TABLE users'")"
test_deny  "$IRRECOVERABLE" "GH #559: a SQL comment between DROP and TABLE" \
  "$(bash_payload "psql -c 'DROP/**/TABLE users'")"
test_deny  "$IRRECOVERABLE" "GH #559: dropdb" "$(bash_payload 'sudo -u postgres dropdb prod')"
test_deny  "$IRRECOVERABLE" "GH #559: mysqladmin drop" "$(bash_payload 'mysqladmin -f drop mydb')"
test_allow "$IRRECOVERABLE" "GH #559 control: psql output piped to grep for drop table" \
  "$(bash_payload "psql -c '\\dt' | grep -i 'drop table'")"
test_allow "$IRRECOVERABLE" "GH #559 control: a heredoc into a file mentioning DROP TABLE" \
  "$(bash_payload "$(printf "cat <<'EOF' > notes.md\nDROP TABLE users resets it\nEOF")")"
test_allow "$IRRECOVERABLE" "GH #559 control: a SELECT heredoc into psql" \
  "$(bash_payload "$(printf "psql mydb <<'SQL'\nSELECT * FROM users;\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #559 control: dropdb --help" "$(bash_payload 'dropdb --help')"
test_deny  "$IRRECOVERABLE" "git config core.HooksPath: the hook-bypass key in any case" \
  "$(bash_payload 'git config core.HooksPath /dev/null')"
test_deny  "$IRRECOVERABLE" "git add -A (was prose-only)" \
  "$(bash_payload 'git add -A')"
test_deny  "$IRRECOVERABLE" "git add . (was prose-only)" \
  "$(bash_payload 'git add .')"
test_allow "$IRRECOVERABLE" "git add named file (must not over-block)" \
  "$(bash_payload 'git add foo.txt')"
# GH #200: --pathspec-from-file's VALUE is a pathspec list the gate cannot read, so any use denies
# (same policy as restore/checkout above).
test_deny  "$IRRECOVERABLE" "GH #200: git add --pathspec-from-file <(...) can stage everything" \
  "$(bash_payload 'git add --pathspec-from-file <(printf .)')"
test_deny  "$IRRECOVERABLE" "GH #200: git add --pathspec-from-file=<file> can stage everything" \
  "$(bash_payload 'git add --pathspec-from-file=paths.txt')"
test_deny  "$IRRECOVERABLE" "GH #200: git add --pathspec-from-file=- reads stdin pathspecs" \
  "$(bash_payload 'git add --pathspec-from-file=-')"
# GH #290: doas is a privilege wrapper like sudo; its -u/-C take a value.
for _c in "doas rm -rf x" "doas git reset --hard" "doas git add -A" "doas -u root rm -rf x" \
          "doas -n rm -rf x" "doas -C /etc/doas.conf rm -rf x" "doas -uroot rm -rf x" \
          "echo hi && doas rm -rf x"; do
  test_deny  "$IRRECOVERABLE" "GH #290: $_c is judged like the bare command" "$(bash_payload "$_c")"
done
for _c in "doas ls /root" "doas -u root cat x" "doas git status"; do
  test_allow "$IRRECOVERABLE" "GH #290 control: $_c is benign, must not over-block" "$(bash_payload "$_c")"
done
# GH #289: whole-tree pathspec spellings stage everything like a bare `.`; named paths stay allowed.
for _c in "git add :/" "git add ':/'" "git add '*'" "git add '**'" "git add ./" "git add ':(top)'" \
          "git add ':/*'" "git add ':(top,glob)**'" "git add -f '*'"; do
  test_deny  "$IRRECOVERABLE" "GH #289: $_c stages the whole tree" "$(bash_payload "$_c")"
done
for _c in "git add :/foo.txt" "git add ':(top)foo.txt'" "git add src/*.py" "git add ./foo.txt" "git add '*.md'"; do
  test_allow "$IRRECOVERABLE" "GH #289 control: $_c names a path, must not over-block" "$(bash_payload "$_c")"
done
# GH #308: more spellings real git (git add -n, checked in a temp repo) treats as the whole tree:
# dot components joined by one or more slashes, a "./*" glob, and exclude-only pathspecs.
for _c in "git add ./." "git add ././" "git add .//" "git add .//." "git add ./**" "git add './*'" "git add './**'" \
          "git add ':!x'" "git add ':^x'" "git add ':(exclude)x'" "git add ':(top,exclude)x'" "git add ':(exclude,top)x'" \
          "git add ':!x' ':!y'" "git add -f ':!x'" "git add -- ':!x'" "git add --chmod=+x ':!x'" "git add --chmod +x ':!x'" \
          "git add :!x" "git add :^x" "git add ':'" "git add '::'" "git add ':' src" "git add ':.'" "git add ':./'" "git add ':*'" "git add ':***'"; do
  test_deny  "$IRRECOVERABLE" "GH #308: $_c stages the whole tree" "$(bash_payload "$_c")"
done
# Narrow shapes stay allowed: a positive pathspec beside an exclude, dotfile globs, `.` inside a name,
# and the top-anchored dot forms that select nothing in real git.
for _c in "git add src/a.txt" "git add ./a.txt" "git add .gitignore" "git add ./.gitignore" "git add src ':!x'" \
          "git add ':!x' src" "git add ':(exclude)x' src/a.txt" "git add -- src ':!x'" "git add ./src/." "git add '.*'" \
          "git add ./.env" "git add ./sub//a.txt" "git add -- ./a.txt" "git add :!x src" "git add src :^x" "git add :/src/a.txt" "git add -- ':!x' -weird"; do
  test_allow "$IRRECOVERABLE" "GH #308 control: $_c names a path, must not over-block" "$(bash_payload "$_c")"
done
# GH #315: real git (git add -n, 7-file temp repo) collapses "x/.." lexically, so a name then ".."
# is the whole tree; so are the magic-colon combos below. ".." alone names an ancestor dir.
for _c in "git add src/.." "git add sub/.." "git add '*/..'" "git add src/../" "git add src/../." "git add ./src/.." \
          "git add src//.." "git add src/./.." "git add sub/deep/../.." "git add nonexist/.." "git add 'src/../*'" \
          "git add '**/..'" "git add '.../..'" "git add a.txt/.." "git add ':(glob)src/..'" "git add ':(literal)*/..'" \
          "git add -- src/.." "git add -f src/.. a.txt" "git add '::.'" "git add '://'" "git add ':///*'" "git add ':/^.'" \
          "git add ':/!x'" "git add ':/:'" "git add '::*'" "git add .." "git add ../" "git add 'src\\/..'" \
          "git add '?*'" "git add '*?'" "git add './.*//../?*'" "git add ':(top,glob)***/*'" "git add ':(glob)**/**'" \
          "git add ':(glob)**/?*'"; do
  test_deny  "$IRRECOVERABLE" "GH #315: $_c stages the whole tree" "$(bash_payload "$_c")"
done
for _c in "git add src/../a.txt" "git add sub/deep/.." "git add src/.../.." "git add ../foo.txt" "git add 'src/..x'" \
          "git add src/..." "git add ':/::'" "git add '://x'" "git add ':!x' src/.../.." "git add ./sub/../a.txt" "git add '?'" "git add '*?.txt'" \
          "git add '**/*'" "git add ':(glob)*/**'" "git add ':(glob)*/*'"; do
  test_allow "$IRRECOVERABLE" "GH #315 control: $_c names a path, must not over-block" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "git checkout branch (must not over-block)" \
  "$(bash_payload 'git checkout main')"
test_allow "$IRRECOVERABLE" "git checkout -m --conflict merge feature: the style word is an option value, not a path" \
"$(bash_payload 'git checkout -m --conflict merge feature')"
test_allow "$IRRECOVERABLE" "git checkout --conflict diff3 feature" \
"$(bash_payload 'git checkout --conflict diff3 feature')"
test_deny  "$IRRECOVERABLE" "git checkout --conflict merge <tree> <path> still discards" \
"$(bash_payload 'git checkout --conflict merge HEAD~1 file')"
test_deny  "$IRRECOVERABLE" "git checkout --conflict=merge <tree> <path> still discards" \
"$(bash_payload 'git checkout --conflict=merge HEAD~1 file')"
test_allow "$IRRECOVERABLE" "git checkout -b new branch (must not over-block)" \
  "$(bash_payload 'git checkout -b new-branch')"
test_allow "$IRRECOVERABLE" "git checkout -b new branch from start-point (create, not tree+path)" \
  "$(bash_payload 'git checkout -b feat origin/develop')"
test_deny  "$IRRECOVERABLE" "git checkout -b with tree-ish AND path still denied" \
  "$(bash_payload 'git checkout -b feat HEAD~1 file.txt')"
# The force check only matched the exact token "-f"/ "--force", missing a bundled short-flag
# cluster like "-qf" (quiet+force).
test_deny "$IRRECOVERABLE" "git checkout -qf bundled force flag (was a bypass)" \
  "$(bash_payload 'git checkout -qf other-branch')"
test_deny "$IRRECOVERABLE" "git switch -fq bundled force flag (was a bypass)" \
  "$(bash_payload 'git switch -fq other-branch')"
# The fix scans bundled clusters for "f" but must stop at a value-taking flag letter (checkout's
# -b/-B, switch's -c/-C) so the branch-name argument itself isn't misread as more bundled flags.
test_allow "$IRRECOVERABLE" "git checkout -bfoo (branch name starting with f, must not over-block)" \
  "$(bash_payload 'git checkout -bfoo')"
test_allow "$IRRECOVERABLE" "git switch -cfoo (branch name starting with f, must not over-block)" \
  "$(bash_payload 'git switch -cfoo')"
test_allow "$IRRECOVERABLE" "git checkout -Bfoo (uppercase stop-char variant, must not over-block)" \
  "$(bash_payload 'git checkout -Bfoo')"
test_allow "$IRRECOVERABLE" "git switch -Cfoo (uppercase stop-char variant, must not over-block)" \
  "$(bash_payload 'git switch -Cfoo')"
# A HEREDOC-authored commit message (this repo's own documented convention) that merely mentions
# "git checkout X Y" in prose was tokenized as a real command and falsely denied.
test_allow "$IRRECOVERABLE" "quoted-delimiter heredoc body mentioning checkout no longer false-blocks" \
  "$(bash_payload $'git commit -m "$(cat <<\'EOF\'\nthis mentions git checkout old new extra in prose\nEOF\n)"')"
test_deny "$IRRECOVERABLE" "dangerous cmd inside a heredoc feeding an interpreter still blocked" \
  "$(bash_payload $'bash <<EOF\nrm -rf /tmp/danger\nEOF')"
# Newline and '&' are command separators in bash but shlex ate newline as whitespace and '&'
# wasn't in OPERATORS — a dangerous command after either hid inside the first command's window.
test_deny  "$IRRECOVERABLE" "dangerous cmd after newline" \
  "$(bash_payload $'echo hi\nrm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "dangerous cmd after & (background)" \
  "$(bash_payload 'echo done & rm -rf /tmp/x')"

# A backslash-newline inside a "#" comment is not a continuation: the newline still separates.
test_deny  "$IRRECOVERABLE" "backslash-newline inside a # comment does not hide the next real command (exact repro)" \
  "$(bash_payload $'git status # comment \\\ngit push origin develop --force')"
test_deny  "$IRRECOVERABLE" "same shape, comment with no trailing backslash (pre-existing case, must stay denied)" \
  "$(bash_payload $'git status # comment\ngit push origin develop --force')"
test_deny  "$IRRECOVERABLE" "real backslash-newline continuation (no comment) still joins tokens for detection" \
  "$(bash_payload $'git push --force \\\n  origin develop')"
test_allow "$IRRECOVERABLE" "legit backslash-newline continuation outside a comment still allows (no false split)" \
  "$(bash_payload $'git log --oneline \\\n  -5')"

# A backslash-newline continuation with NO leading whitespace on the continuation line bypassed
# force-push detection.
test_deny  "$IRRECOVERABLE" "backslash-newline continuation with NO leading whitespace on the next line (exact repro, was a bypass)" \
  "$(bash_payload $'git push \\\n--force origin develop')"
test_deny  "$IRRECOVERABLE" "same shape, leading whitespace on the next line (already worked, stays denied)" \
  "$(bash_payload $'git push \\\n  --force origin develop')"
# Adjacent shapes: back-to-back continuations gluing flags, and a trailing continuation.
test_deny  "$IRRECOVERABLE" "two whitespace-less continuations back to back, force flag glued onto the second (adjacent-shape check)" \
  "$(bash_payload $'git push origin\\\ndevelop --for\\\nce')"
test_allow "$IRRECOVERABLE" "trailing whitespace-less continuation at the very end of the command, nothing after it (no crash, no dangerous token)" \
  "$(bash_payload $'git push origin develop\\\n')"
# The DQ-quoted branch of _newlines_to_seps had the identical unremoved- newline defect for a
# continuation inside a double-quoted string (bash strips backslash-newline there too).
test_deny  "$IRRECOVERABLE" "whitespace-less continuation inside a double-quoted flag still reassembles (adjacent-shape check)" \
  "$(bash_payload $'git push "--for\\\nce" origin develop')"
test_deny  "$IRRECOVERABLE" "trailing # comment on the same line does not hide the command before it" \
  "$(bash_payload 'git push origin develop --force # not a real flag, just a comment')"

# ANSI-C ($'...') quoting resolves escape sequences in real bash.
test_deny "$IRRECOVERABLE" "ANSI-C quoted argv0 splice (gi\$'\x74' push --force, was a bypass)" \
  "$(bash_payload "gi\$'\\x74' push --force origin develop")"
# Negative control 1: an ordinary single-quoted argument (no \$'...' form, never enters the
# ANSI-C regex at all) must stay correctly classified.
test_allow "$IRRECOVERABLE" "ordinary single-quoted commit message unaffected by ANSI-C normalization" \
  "$(bash_payload "git commit -m 'a normal message'")"
# Negative control 2: a REAL \$'...' payload that DOES enter the new decode path.
test_allow "$IRRECOVERABLE" "ANSI-C commit message with embedded \\n stays one window, not force-push (real decode-path exercise)" \
  "$(bash_payload $'git commit -m $\'line1\\nline2\'')"

# A command-substitution splice (backtick or \$(...)) vanishes in real bash once its output
# splices into the surrounding text.
test_deny "$IRRECOVERABLE" "argv0-level backtick splice (gi\`true\`t push --force, GH #129)" \
  "$(bash_payload 'gi`true`t push --force origin develop')"
test_deny "$IRRECOVERABLE" "git-subcommand-level backtick splice (git pu\`true\`sh --force, clean argv0 but spliced sub, GH #129)" \
  "$(bash_payload 'git pu`true`sh --force')"
test_deny "$IRRECOVERABLE" "argv0-level \$(...) splice, different KNOWN_DANGEROUS candidate (gi\$(true)t reset --hard, GH #129)" \
  "$(bash_payload 'gi$(true)t reset --hard')"
# Negative controls: the duplication must not over-deny.
test_allow "$IRRECOVERABLE" "substitution in an ARGUMENT, not the dispatch token (ls \$(pwd)) -- argv0 stays clean, never enters duplication" \
  "$(bash_payload 'ls $(pwd)')"
test_allow "$IRRECOVERABLE" "substitution IS the whole dispatch token but resolves to a benign subcommand (\$(which git) status)" \
  "$(bash_payload '$(which git) status')"
test_allow "$IRRECOVERABLE" "substitution IS the dispatch token, candidate set has no dangerous match (\$(command -v ls) -la)" \
  "$(bash_payload '$(command -v ls) -la')"
test_allow "$IRRECOVERABLE" "argv0-level \$(...) splice resolving to a benign git subcommand (gi\$(true)t status, proves duplication does not over-deny)" \
  "$(bash_payload 'gi$(true)t status')"
test_allow "$IRRECOVERABLE" "ordinary bare \$VAR usage stays untouched by the placeholder pass (git push \$REMOTE \$BRANCH)" \
  "$(bash_payload 'git push $REMOTE $BRANCH')"
# Blanking a substitution SPAN must not DISCARD its body.
test_deny "$IRRECOVERABLE" "substitution BODY is the dangerous command, not just the dispatch token (echo \$(git push --force), was silently allowed by a blank-only pass)" \
  "$(bash_payload 'echo $(git push --force)')"
test_allow "$IRRECOVERABLE" "re-appended substitution body is ordinary commit-message prose, not a command (git commit -m \"\$(cat msg.txt)\") -- proves body re-append does not false-deny" \
  "$(bash_payload 'git commit -m "$(cat msg.txt)"')"
# A SINGLE-quoted $(...) is inert in bash and must not be extracted as a body; a DOUBLE-quoted
# one is live and must still be caught.
test_allow "$IRRECOVERABLE" "single-quoted \$(...) is inert prose, must not be extracted and re-denied (git commit -m single-quote prose mentioning \$(git push --force))" \
  "$(bash_payload "git commit -m 'prose mentioning \$(git push --force)'")"
test_deny "$IRRECOVERABLE" "double-quoted argv0 splice stays a live vector, not given the single-quote passthrough (\"gi\$(true)t\" push --force)" \
  "$(bash_payload '"gi$(true)t" push --force')"

# An apostrophe inside a blanked substitution body raises ValueError in shlex; the old raw
# cmd.split() fallback carried no PH, so the splice was silently allowed.
test_deny "$IRRECOVERABLE" "backtick splice with an apostrophe inside the body defeats the old raw cmd.split() fallback (gi\`it's\`t push --force, was silently ALLOWed)" \
  "$(bash_payload $'gi`it\'s`t push --force')"
test_deny "$IRRECOVERABLE" "\$(...) splice with an apostrophe inside the body, same bypass shape (gi\$(it's)t push --force, was silently ALLOWed)" \
  "$(bash_payload $'gi$(it\'s)t push --force')"

# Bug 2 (false-DENY): the KNOWN_DANGEROUS/KNOWN_GIT_SUBS candidate duplication runs every
# candidate's check against the SAME rest/scan tokens, and two of those checks were bare letter-
# containment against a whole joined-flags string rather than a real flag-boundary test.
test_allow "$IRRECOVERABLE" "substitution dispatch token resolving to a benign command, long flag falsely read as rm -rf (\$(which node) --before=1, was a false DENY)" \
  "$(bash_payload '$(which node) --before=1')"
test_allow "$IRRECOVERABLE" "git diff splice, long flag falsely read as git clean -f (git di\$(true)ff --find-renames, was a false DENY)" \
  "$(bash_payload 'git di$(true)ff --find-renames')"
test_allow "$IRRECOVERABLE" "git show splice, long flag falsely read as git clean -f (git sh\$(true)ow --format=fuller, was a false DENY)" \
  "$(bash_payload 'git sh$(true)ow --format=fuller')"

# The _SQ_SPAN regex used to detect inert single-quoted text paired literal apostrophe
# CHARACTERS wherever they fell, with zero notion of real shell quote state.
test_deny "$IRRECOVERABLE" "contraction apostrophes inside double quotes pair up ACROSS a real \$(...) splice, hiding it as inert single-quoted data (was a live bypass)" \
  "$(bash_payload $'echo "it\'s" ; gi$(true)t push --force ; echo "isn\'t"')"
test_allow "$IRRECOVERABLE" "same stray contraction apostrophe shifts pairing so a REAL single-quoted -m argument is no longer matched as one span (was a false DENY of inert commit-message text)" \
  "$(bash_payload $'echo "it\'s" ; git commit -m \'see $(git push --force)\'')"

# "$(true)-rf" IS "-rf" in bash but blanks to "PH-rf", which no longer starts with "-", so every
# flag-shape check missed it; PH is stripped before each such check.
test_deny "$IRRECOVERABLE" "empty-substitution splice hides rm -rf's dash (rm \$(true)-rf /tmp/x, was silently ALLOWed)" \
  "$(bash_payload 'rm $(true)-rf /tmp/x')"
test_deny "$IRRECOVERABLE" "same bug via backticks (rm \`true\`-rf /tmp/x, was silently ALLOWed)" \
  "$(bash_payload 'rm `true`-rf /tmp/x')"
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git push --force's dashes (git push \$(true)--force, was silently ALLOWed)" \
  "$(bash_payload 'git push $(true)--force')"
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git clean -f's dash (git clean \$(true)-f, was silently ALLOWed)" \
  "$(bash_payload 'git clean $(true)-f')"
# Negative control: the substitution sits inside a QUOTED ARGUMENT VALUE (a real -m message),
# not in flag position.
test_allow "$IRRECOVERABLE" "substitution inside a quoted -m message value, not a bare flag position (git commit -m \"\$(cat msg.txt)\") -- must stay ALLOW" \
  "$(bash_payload 'git commit -m "$(cat msg.txt)"')"

# The $(...)/${...} closer-search used to stop at the FIRST ")" byte, not the matching one, so
# a nested paren left the span un-blanked.
test_deny "$IRRECOVERABLE" "nested function-construct inside \$(...) defeats the old first-byte closer-search, real bash resolves to git push --force (GH #139, was a silent bypass)" \
  "$(bash_payload 'gi$(f() { :; }; f)t push --force origin develop')"

# Companion DoS check for the same fix: depth-counting a closer-search that never balances (an
# adversarial flood of unclosed "$(" starts) must stay bounded by a work budget instead of
# costing O(remaining length) PER start.
DEPTH_FLOOD_CMD=$(python3 -c 'print("$(" * 50000)')
depth_flood_start=$(date +%s)
depth_flood_out=$(bash_payload "$DEPTH_FLOOD_CMD" | timeout 10 bash "$IRRECOVERABLE" 2>/dev/null)
depth_flood_rc=$?
depth_flood_elapsed=$(( $(date +%s) - depth_flood_start ))
if [[ "$depth_flood_rc" == "2" ]] && [ "$depth_flood_elapsed" -le 10 ]; then
  echo "  ✅ DENY: 50,000x unclosed \"\$(\" flood completes within a generous ceiling (GH #139 fail-closed budget-exhaustion fix)"
  pass=$((pass + 1))
else
  echo "  ❌ depth-scan work-budget expected fast deny but got rc=$depth_flood_rc elapsed=${depth_flood_elapsed}s out='$depth_flood_out'" >&2
  fail=$((fail + 1))
fi

# Leading-PH strip applied to every flag check (Layer 1), the wrapper/re-pointing loops
# (Layer 2), and standalone vanish tokens compacted out (Layer 3).
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git stash drop (git stash \$(true)drop, was silently ALLOWed)" \
  "$(bash_payload 'git stash $(true)drop')"
test_deny "$IRRECOVERABLE" "empty-substitution splice hides git stash clear (git stash \$(true)clear, was silently ALLOWed)" \
  "$(bash_payload 'git stash $(true)clear')"
test_deny "$IRRECOVERABLE" "baseline: plain git stash drop, no splice at all (must still deny)" \
  "$(bash_payload 'git stash drop')"
test_deny "$IRRECOVERABLE" "baseline: plain git stash clear, no splice at all (must still deny)" \
  "$(bash_payload 'git stash clear')"
# A splice landing mid-basename or mid-SQL-keyword needs full PH removal, not a leading strip.
test_deny "$IRRECOVERABLE" "empty-substitution splice hides dd's of=/dev/ prefix (was silently ALLOWed)" \
  "$(bash_payload 'dd if=/dev/zero $(true)of=/dev/sda')"
test_deny "$IRRECOVERABLE" "baseline: plain dd of=/dev, no splice (must still deny)" \
  "$(bash_payload 'dd if=/dev/zero of=/dev/sda')"
test_deny "$IRRECOVERABLE" "splice lands mid-keyword in a destructive SQL statement (DR\$(true)OP TABLE, was silently ALLOWed -- the old check only handled a LEADING splice, not one INSIDE a keyword)" \
  "$(bash_payload 'mysql -e "DR$(true)OP TABLE users"')"
test_deny "$IRRECOVERABLE" "baseline: plain destructive SQL, no splice (must still deny)" \
  "$(bash_payload 'mysql -e "DROP TABLE users"')"
# --- Layer 2, exhaustive-grep finds: the prefix-wrapper unwrap loops
# (env/nice/sudo/command/nohup/time) and the xargs/docker-exec re-pointing never stripped a
# leading PH from the flags they read either.
test_deny "$IRRECOVERABLE" "docker exec flag splice defeats the inner-command re-point, hiding destructive SQL (docker exec \$(true)-i c1 mysql -e DROP TABLE, was silently ALLOWed)" \
  "$(bash_payload 'docker exec $(true)-i c1 mysql -e "DROP TABLE users"')"
test_deny "$IRRECOVERABLE" "docker exec-itself splice defeats the inner-command re-point, hiding destructive SQL (docker \$(true)exec c1 mysql -e DROP TABLE, was silently ALLOWed)" \
  "$(bash_payload 'docker $(true)exec c1 mysql -e "DROP TABLE users"')"
# --- Layer 3: a standalone unquoted vanish token shifts fixed-index reads.
test_allow "$IRRECOVERABLE" "Layer 3 negative control: \$(which git) status -- compacted window drops argv0 entirely, must stay ALLOW" \
  "$(bash_payload '$(which git) status')"

# Appending recovered substitution bodies with a plain " ; " separator left no newline to
# terminate an earlier, still-open "#" comment.
test_deny "$IRRECOVERABLE" "trailing comment after a live substitution buried the recovered body in an open shlex comment (echo \$(git push --force)  # push it, was silently ALLOWed)" \
  "$(bash_payload 'echo $(git push --force)  # push it')"
test_deny "$IRRECOVERABLE" "same bug via a # embedded inside an EARLIER recovered body (echo \$(echo hi # note) \$(git push --force), was silently ALLOWed)" \
  "$(bash_payload 'echo $(echo hi # note) $(git push --force)')"
test_deny "$IRRECOVERABLE" "baseline: same splice with no comment at all, no bug involved (must stay denied)" \
  "$(bash_payload 'echo $(git push --force)')"

# Finding 5 (MEDIUM, live, universal): _scan_once tracked in_squote/ in_dquote but had no
# in_comment state, so a substitution-shaped string sitting INSIDE a real "#" comment still got
# matched, blanked, and its body collected as if it were live code.
test_allow "$IRRECOVERABLE" "a substitution-shaped fake payload sitting inside a real # comment must not be recovered as a live body (git status # see also: \$(git push --force), followed by a real newline and echo done, was a false DENY)" \
  "$(bash_payload $'git status # see also: $(git push --force)\necho done\n')"

# The closer-search does not track quotes INSIDE a span, so a span crossing a quote char left a
# valid command unbalanced and falsely denied; re-parse of the original cmd tells the cases apart.
test_allow "$IRRECOVERABLE" "read-only python3 heredoc with an unmatched \${ inside a properly-quoted string desyncs _blank_substitutions own quote tracking (was a false DENY with no override)" \
  "$(bash_payload $'python3 - <<\'PY\'\n "10k unmatched ${ (20KB)": "${ "*10000,\n}\nPY\n')"
# Negative control: a genuinely malformed command (unterminated quote, no _scan_once span
# involved at all) must still deny with the same message.
test_deny "$IRRECOVERABLE" "genuinely malformed command, unterminated quote unrelated to any substitution span (must still deny)" \
  "$(bash_payload "echo 'unterminated")"
# Negative control: the two GH #129 apostrophe-in-body bypass tests already above
# (backtick/\$(...) splice with an apostrophe inside the recovered body) must still deny.
test_deny "$IRRECOVERABLE" "Finding 4 fix must not reopen the GH #129 apostrophe-in-body bypass, backtick form (gi\`it's\`t push --force, must stay DENY)" \
  "$(bash_payload $'gi`it\'s`t push --force')"
test_deny "$IRRECOVERABLE" "Finding 4 fix must not reopen the GH #129 apostrophe-in-body bypass, \$(...) form (gi\$(it's)t push --force, must stay DENY)" \
  "$(bash_payload $'gi$(it\'s)t push --force')"

# The fallback split must be separator-aware: a bare cmd.split() glued "};git" into one token.
test_deny "$IRRECOVERABLE" "Finding 4 fallback must not glue a dangerous SECOND command onto its no-space ; separator (echo \${y:-\"a}b\"};git push --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"};git push --force')"
test_deny "$IRRECOVERABLE" "same bug via a no-space && separator (echo \${y:-\"a}b\"}&&git push --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"}&&git push --force')"
test_deny "$IRRECOVERABLE" "baseline: same compound command with the ; surrounded by whitespace, no bug involved (must stay denied)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; git push --force')"

# A splice reaching only the fallback path carries raw substitution syntax, no PH; duplication
# also fires on raw syntax.
test_deny "$IRRECOVERABLE" "Finding 4 fallback duplication trigger missed a spliced ARGV0 with no PH (echo \${y:-\"a}b\"} ; gi\$(true)t push --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; gi$(true)t push --force')"
test_deny "$IRRECOVERABLE" "same bug, spliced git SUBCOMMAND instead of argv0 (echo \${y:-\"a}b\"} ; git pu\$(true)sh --force, was silently ALLOWed)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; git pu$(true)sh --force')"
test_deny "$IRRECOVERABLE" "same argv0 bug with the dangerous command BEFORE the quote-crossing span (gi\$(true)t push --force ; echo \${y:-\"a}b\"}, was silently ALLOWed)" \
  "$(bash_payload 'gi$(true)t push --force ; echo ${y:-"a}b"}')"
test_deny "$IRRECOVERABLE" "same subcommand bug with the dangerous command BEFORE the quote-crossing span (git pu\$(true)sh --force ; echo \${y:-\"a}b\"}, was silently ALLOWed)" \
  "$(bash_payload 'git pu$(true)sh --force ; echo ${y:-"a}b"}')"
# Negative controls: the widened trigger must not over-deny once the fallback path is live.
test_allow "$IRRECOVERABLE" "fallback-path splice resolving to a benign git subcommand (echo \${y:-\"a}b\"} ; gi\$(true)t status, must stay ALLOW even though duplication tries argv0==git -- the quote-crossing span forces the fallback so this token never gets PH at all, only _has_raw_subst catches it)" \
  "$(bash_payload 'echo ${y:-"a}b"} ; gi$(true)t status')"

# The fallback path must tokenize the SAME blanked pipeline as the primary path, or every
# downstream PH-based check is blind on it.
FORCE_FALLBACK='echo ${y:-"a}b"} ; '
test_deny "$IRRECOVERABLE" "sweep: docker exec re-point splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}docker exec \$(true)-i c1 mysql -e \"DROP TABLE users\"")"
test_deny "$IRRECOVERABLE" "sweep: rm -rf leading-dash splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}rm \$(true)-rf /tmp/x")"
test_deny "$IRRECOVERABLE" "sweep: find -exec splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}find /tmp/x \$(true)-exec rm {} \\;")"
test_deny "$IRRECOVERABLE" "sweep: find -delete splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}find /tmp/x \$(true)-delete")"
test_deny "$IRRECOVERABLE" "sweep: git --no-verify splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git commit \$(true)--no-verify -m msg")"
test_deny "$IRRECOVERABLE" "sweep: git push --force splice reaching scan, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git push \$(true)--force origin develop")"
test_deny "$IRRECOVERABLE" "sweep: git clean -f splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git clean \$(true)-f")"
test_deny "$IRRECOVERABLE" "sweep: git stash drop splice on args[0], fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git stash \$(true)drop")"
test_deny "$IRRECOVERABLE" "sweep: dd of=/dev splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}dd if=/dev/zero \$(true)of=/dev/sda")"
test_deny "$IRRECOVERABLE" "sweep: SQL DROP mid-keyword splice, fallback path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}mysql -e \"DR\$(true)OP TABLE users\"")"
# Negative controls: the systemic fallback-blanking fix must not over-deny.
test_allow "$IRRECOVERABLE" "sweep neg: benign command after a forced fallback (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}ls -la")"
test_allow "$IRRECOVERABLE" "sweep neg: git status after a forced fallback (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}git status")"
test_allow "$IRRECOVERABLE" "sweep neg: git push safe after a forced fallback (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}git push origin develop")"
test_allow "$IRRECOVERABLE" "sweep neg: commit message mentioning rm -rf, fallback path (must ALLOW)" \
  "$(bash_payload "${FORCE_FALLBACK}git commit -m \"docs: warn against rm -rf\"")"

# A PH/raw-subst splice landing MID-FLAG (not leading) defeated every flag-recovery check
# written as "t.lstrip(PH) == '--force'".
test_deny "$IRRECOVERABLE" "mid-flag splice, git push --force (--for\$(true)ce, was silently ALLOWed)" \
  "$(bash_payload 'git push --for$(true)ce origin develop')"
test_deny "$IRRECOVERABLE" "mid-flag splice, git reset --hard (--har\$(true)d, was silently ALLOWed)" \
  "$(bash_payload 'git reset --har$(true)d HEAD~1')"
test_deny "$IRRECOVERABLE" "mid-flag splice, git commit --amend (--am\$(true)end, was silently ALLOWed)" \
  "$(bash_payload 'git commit --am$(true)end -m x')"
test_deny "$IRRECOVERABLE" "mid-flag splice reaches the flag check via the fallback path too, not just the primary shlex path (was silently ALLOWed)" \
  "$(bash_payload "${FORCE_FALLBACK}git push --for\$(true)ce origin develop")"
# Negative controls: the same flags with no splice at all must stay denied exactly as before.
test_deny "$IRRECOVERABLE" "baseline: plain --force with no splice still denies (unaffected by the fix)" \
  "$(bash_payload 'git push --force origin develop')"
test_deny "$IRRECOVERABLE" "baseline: plain --hard with no splice still denies (unaffected by the fix)" \
  "$(bash_payload 'git reset --hard HEAD~1')"
test_deny "$IRRECOVERABLE" "baseline: plain --amend with no splice still denies (unaffected by the fix)" \
  "$(bash_payload 'git commit --amend -m x')"

test_allow "$IRRECOVERABLE" "git push --force-with-lease (safe variant)" \
  "$(bash_payload 'git push --force-with-lease origin develop')"
test_allow "$IRRECOVERABLE" "git push --force-with-lease with refspec (still safe)" \
  "$(bash_payload 'git push --force-with-lease=main:12345 origin develop')"
test_allow "$IRRECOVERABLE" "git push --force-with-lease --force-if-includes (safest variant)" \
  "$(bash_payload 'git push --force-with-lease --force-if-includes origin develop')"
test_allow "$IRRECOVERABLE" "git push normal (no force)" \
  "$(bash_payload 'git push origin develop')"

# A leading git GLOBAL flag (-C/-c/--git-dir/--work-tree/ --config-env, bare or
# combined -Cpath/--git-dir=path) set sub to the flag itself, so the push/worktree/--no-verify
# gates were bypassable by prefixing it.
test_deny "$IRRECOVERABLE" "git -C /repo push --force (global-flag bypass)" \
  "$(bash_payload 'git -C /repo push --force origin develop')"
test_deny "$IRRECOVERABLE" "git -Cpath push --force (combined -C)" \
  "$(bash_payload 'git -C/repo push --force origin develop')"
test_deny "$IRRECOVERABLE" "git --no-pager push --force (non-value global)" \
  "$(bash_payload 'git --no-pager push --force origin develop')"
test_deny "$IRRECOVERABLE" "git -c key=val push --force (value global -c)" \
  "$(bash_payload 'git -c core.foo=bar push --force origin develop')"
test_allow "$IRRECOVERABLE" "git -C /repo status (global flag, safe sub)" \
  "$(bash_payload 'git -C /repo status')"
test_allow "$IRRECOVERABLE" "git -C /repo log (no sub after globals→no-op safe)" \
  "$(bash_payload 'git -C /repo')"
test_deny "$IRRECOVERABLE" "--no-verify on earlier line (multiline bypass)" \
  "$(bash_payload $'echo staging\ngit commit --no-verify -m msg')"
test_allow "$IRRECOVERABLE" "echo --no-verify (git-specific, no false positive)" \
  "$(bash_payload 'echo --no-verify is a git flag')"
# GH #233: a quoted operator-only argument must not split the command and hide a later flag.
test_deny "$IRRECOVERABLE" "GH #233 quoted ; then --no-verify" \
  "$(bash_payload 'git commit -m ";" --no-verify')"
test_deny "$IRRECOVERABLE" "GH #233 quoted ; then commit -n" \
  "$(bash_payload 'git commit -m ";" -n')"
test_deny "$IRRECOVERABLE" "GH #233 quoted && then commit -n" \
  "$(bash_payload 'git commit -m "&&" -n')"
test_deny "$IRRECOVERABLE" "GH #233 quoted | then commit -n" \
  "$(bash_payload 'git commit -m "|" -n')"
test_deny "$IRRECOVERABLE" "GH #233 single-quoted ; then push -f" \
  "$(bash_payload "git push origin ';' -f")"
test_deny "$IRRECOVERABLE" "GH #233 quoted ; then branch -D" \
  "$(bash_payload 'git branch ";" -D')"
test_deny "$IRRECOVERABLE" "GH #233 real ; after quoted ; still splits" \
  "$(bash_payload 'git commit -m ";" ; git commit -n -m x')"
# GH #310: a backslash-escaped operator-only token is a literal word, not a separator.
test_deny "$IRRECOVERABLE" "GH #310 escaped ; then push -f" \
  "$(bash_payload 'git push \; -f')"
test_deny "$IRRECOVERABLE" "GH #310 escaped | then push -f" \
  "$(bash_payload 'git push \| -f')"
test_deny "$IRRECOVERABLE" "GH #310 escaped & then commit -n" \
  "$(bash_payload 'git commit -m x \& -n')"
test_deny "$IRRECOVERABLE" "GH #310 escaped && then branch -D" \
  "$(bash_payload 'git branch \&\& -D x')"
test_deny "$IRRECOVERABLE" "GH #310 escaped ( then commit -n" \
  "$(bash_payload 'git commit -m x \( -n')"
test_deny "$IRRECOVERABLE" "GH #310 escaped ) then push -f" \
  "$(bash_payload 'git push \) -f')"
test_deny "$IRRECOVERABLE" "GH #310 escaped ; inside double quotes then push -f" \
  "$(bash_payload 'git push "a\;" -f')"
test_deny "$IRRECOVERABLE" "GH #310 doubled backslash before ; is a real separator" \
  "$(bash_payload 'git commit -m x \\; git commit -n -m y')"
test_deny "$IRRECOVERABLE" "GH #310 real ; after escaped ; still splits" \
  "$(bash_payload 'git commit -m x \; ; git commit -n -m y')"
test_allow "$IRRECOVERABLE" "GH #310 control: escaped ; as commit message arg" \
  "$(bash_payload 'git commit -m \;')"
test_allow "$IRRECOVERABLE" "GH #310 control: find -exec escaped ; terminator" \
  "$(bash_payload 'find . -name x -exec echo {} \;')"
test_allow "$IRRECOVERABLE" "GH #310 control: real ; separates, later -f is not git's" \
  "$(bash_payload 'git status ; ls -f')"
test_allow "$IRRECOVERABLE" "GH #233 control: commit message is a quoted ;" \
  "$(bash_payload 'git commit -m ";"')"
test_allow "$IRRECOVERABLE" "GH #233 control: quoted ; argument to printf then rm word" \
  "$(bash_payload 'printf "%s\n" ";" rm -rf x')"
test_deny "$IRRECOVERABLE" "git restore . (discards worktree)" \
  "$(bash_payload 'git restore .')"
test_deny "$IRRECOVERABLE" "git restore -- file (discards worktree)" \
  "$(bash_payload 'git restore -- file.txt')"
test_deny "$IRRECOVERABLE" "git restore file (pathspec, no branch ambiguity)" \
  "$(bash_payload 'git restore src/index.ts')"
test_deny "$IRRECOVERABLE" "git restore --worktree file (explicit worktree mode)" \
  "$(bash_payload 'git restore --worktree file.txt')"
test_deny "$IRRECOVERABLE" "git restore --staged --worktree file (worktree touched)" \
  "$(bash_payload 'git restore --staged --worktree file.txt')"
test_allow "$IRRECOVERABLE" "git restore --staged file (index-only, recoverable)" \
  "$(bash_payload 'git restore --staged file.txt')"
test_allow "$IRRECOVERABLE" "git restore --staged . (un-stage all, recoverable)" \
  "$(bash_payload 'git restore --staged .')"
test_allow "$IRRECOVERABLE" "git restore --staged (no pathspec, no-op)" \
  "$(bash_payload 'git restore --staged')"
test_deny "$IRRECOVERABLE" "git checkout HEAD~1 file (tree-ish + path)" \
  "$(bash_payload 'git checkout HEAD~1 src/index.ts')"
test_allow "$IRRECOVERABLE" "git checkout main (1 nonflag = branch switch)" \
  "$(bash_payload 'git checkout main')"

# A shell redirection token (">", "2>&1", ">/dev/null", ...) is consumed by bash before it ever
# reaches git's own argv -- counting it toward checkout's nonflag-arg tally falsely turned an
# everyday idiom into a "tree-ish + path" deny (found live, 2026-09-29, while exercising the
# checkout-isolation pilot: `git checkout <branch> 2>&1` was blocked).
test_allow "$IRRECOVERABLE" "git checkout main 2>&1 (redirection must not count as a 2nd nonflag arg)" \
  "$(bash_payload 'git checkout main 2>&1')"
test_allow "$IRRECOVERABLE" "git checkout main >/dev/null (stdout redirect must not over-block)" \
  "$(bash_payload 'git checkout main >/dev/null')"
test_allow "$IRRECOVERABLE" "git checkout main >>log.txt (append redirect must not over-block)" \
  "$(bash_payload 'git checkout main >>log.txt')"
test_allow "$IRRECOVERABLE" "git checkout main <in.txt (input redirect must not over-block)" \
  "$(bash_payload 'git checkout main <in.txt')"
test_allow "$IRRECOVERABLE" "git checkout main 2>&1 | cat (redirect + pipe must not over-block)" \
  "$(bash_payload 'git checkout main 2>&1 | cat')"
# The redirection strip must not swallow a real dangerous token that happens to sit right before,
# or disguise itself as, a redirection -- these must all still deny.
test_deny "$IRRECOVERABLE" "git checkout -- file.txt 2>&1 (deny survives trailing redirection)" \
  "$(bash_payload 'git checkout -- file.txt 2>&1')"
test_deny "$IRRECOVERABLE" "git checkout HEAD~1 file 2>&1 (tree-ish+path deny survives trailing redirection)" \
  "$(bash_payload 'git checkout HEAD~1 src/index.ts 2>&1')"
# Round-2 regression (found by an adversarial Codex pass against the first attempt at this fix,
# 2026-09-29, see security-gate-token-strip-needs-quote-state memory): a space-separated bare
# digit is a REAL positional arg, not an fd prefix, unless glued with no space to the operator --
# and a QUOTED redirect-lookalike character must never be treated as a real operator.
test_deny "$IRRECOVERABLE" "git checkout HEAD 2 >/dev/null (space-separated digit is a real 2nd pathspec, not an fd prefix)" \
  "$(bash_payload 'git checkout HEAD 2 >/dev/null')"
test_deny "$IRRECOVERABLE" "git checkout HEAD 2 2>/dev/null (real 2nd pathspec PLUS a glued fd-prefixed redirect, still 2 real nonflag args)" \
  "$(bash_payload 'git checkout HEAD 2 2>/dev/null')"
test_allow "$IRRECOVERABLE" "git checkout HEAD 2>/dev/null (glued fd prefix on the ONLY digit present, genuinely 1 real nonflag arg)" \
  "$(bash_payload 'git checkout HEAD 2>/dev/null')"
test_deny "$IRRECOVERABLE" 'rm -r ">" -f file (quoted redirect-lookalike must not hide a real -f)' \
  "$(bash_payload 'rm -r ">" -f hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'git checkout HEAD ">tracked" (quoted > must not be treated as a real operator)' \
  "$(bash_payload 'git checkout HEAD ">tracked"')"
test_deny "$IRRECOVERABLE" 'git restore ">tracked" (same quoted-operator check on restore)' \
  "$(bash_payload 'git restore ">tracked"')"
# Round-3 regression (found by a 2nd-round adversarial Codex pass against round 2's rewrite,
# 2026-09-29): a "#" glued mid-word into a redirect target ("out#suffix") is a literal filename
# character in real bash, not a comment start -- bash only treats "#" as a comment when it opens a
# new word. The redirect-target consumption loop stopped at ANY unquoted "#", silently dropping
# everything after it (including a real trailing dangerous pathspec) from the scan. Confirmed this
# exact payload correctly denies on the unmodified (pre-this-fix) gate.
test_deny "$IRRECOVERABLE" 'git checkout HEAD >out#suffix file (# glued mid-target must not truncate the scan)' \
  "$(bash_payload 'git checkout HEAD >out#suffix hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'rm -r >out#suffix -f file (same # mid-target check on rm)' \
  "$(bash_payload 'rm -r >out#suffix -f hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'git reset >out#suffix --hard (same # mid-target check on reset)' \
  "$(bash_payload 'git reset >out#suffix --hard')"
test_allow "$IRRECOVERABLE" 'git checkout main > #comment ("#" as the FIRST target char is still a real comment)' \
  "$(bash_payload 'git checkout main > #comment')"
# Round-4 regression (found by a 3rd-round adversarial Codex pass, 2026-09-29): same class of bug
# as the "#" fix above, for "{"/"}" -- verified empirically (`bash -n -c 'echo out{suffix'` is
# valid bash, unlike the same test with "(" or ")") that a bare "{"/"}" mid-word is just a literal
# character, not a real shell metacharacter, so the target-consumption loop must not stop there.
test_deny "$IRRECOVERABLE" 'git checkout HEAD >out{suffix file ({ glued mid-target must not truncate the scan)' \
  "$(bash_payload 'git checkout HEAD >out{suffix hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'git checkout HEAD >out}suffix file (} glued mid-target must not truncate the scan)' \
  "$(bash_payload 'git checkout HEAD >out}suffix hooks/gates/irrecoverable.py')"

# GH #178: a bare "#" mid-word in an ORDINARY argument (not a redirect target) was mistaken for a
# comment start ANYWHERE by shlex's own commenters="#" (never overridden -- it has no word-position
# awareness), hiding a real trailing dangerous command. Fixed by swapping a non-boundary "#" for a
# HASH_LIT placeholder (added to lex.wordchars) before shlex ever sees it, so only a genuine
# word-boundary "#" still reaches shlex's own comment-stripping.
test_deny "$IRRECOVERABLE" 'GH #178: bare # mid-word must not hide a real trailing rm -rf' \
  "$(bash_payload 'echo foo#suffix; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178: double ## mid-word, same check' \
  "$(bash_payload 'echo foo##bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178: # right after a blanked $(...) substitution must not hide the rest' \
  "$(bash_payload 'echo $(true)#x; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178: same check inside a bash -c body' \
  "$(bash_payload 'bash -c "echo foo#bar; rm -rf hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #178: # mid-word inside a $(...) body re-scanned on the fixed-point pass' \
  "$(bash_payload 'echo "$(cat foo#bar)"; rm -rf hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #178 control: bare # mid-word with nothing dangerous after it still allows' \
  "$(bash_payload 'echo foo#bar')"
test_allow "$IRRECOVERABLE" 'GH #178 control: a genuine word-boundary "#" comment is still stripped' \
  "$(bash_payload 'git checkout main # trailing comment')"

# GH #178 round 2 (adversarial Codex pass found this before ship): an escaped separator
# ("\ ", "\;", "\|", "\&", "\(") is still a LITERAL character in bash, not a real word break, so a
# "#" right after it is mid-word too -- out[-1] alone can't tell an escaped separator from a real
# one (both leave the same byte). Fixed with a `last_escaped` flag tracking whether the last
# appended char came from an escaped pair, discounted from the "#" boundary check.
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped space before # must not hide a real trailing rm -rf' \
  "$(bash_payload 'echo foo\ #bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped semicolon before #, same check' \
  "$(bash_payload 'echo foo\;#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped pipe before #, same check' \
  "$(bash_payload 'echo foo\|#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped ampersand before #, same check' \
  "$(bash_payload 'echo foo\&#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped open-paren before #, same check' \
  "$(bash_payload 'echo foo\(#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped close-paren before #, same check' \
  "$(bash_payload 'echo foo\)#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped space after a blanked $(...) placeholder before #, same check' \
  "$(bash_payload 'echo $(true)\ #x; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2: escaped space right after a closing double-quote before #, same check' \
  "$(bash_payload 'echo "x"\ #bar; rm -rf hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #178 round 2 control: escaped space before # with nothing dangerous after still allows' \
  "$(bash_payload 'echo foo\ #bar')"
test_allow "$IRRECOVERABLE" 'GH #178 round 2 control: an EVEN run of escaped backslashes leaves the next separator real, so # is a genuine comment' \
  "$(bash_payload 'echo foo\\\\ #realcomment; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #178 round 2 control: a backslash-escaped # itself is never re-examined as a boundary/non-boundary case' \
  "$(bash_payload 'echo foo\#bar; rm -rf hooks/gates/irrecoverable.py')"

# GH #181: a "#" right after a process substitution's closing ")" (<(...)/>(...)) has the same
# word-boundary gap GH #178 fixed for a plain mid-word "#" -- unlike "$(...)"/backtick, this file
# never recognized <(...)/>(...) at all, so its closing ")" reached the "#"-boundary check as a
# bare character (")" is in _REDIRECT_TARGET_STOP, wrongly read as a real word break). Fixed by
# blanking <(...)/>(...) to PSUB (its own placeholder, distinct from "$(...)"'s PH -- see PSUB's
# own comment) before _blank_redirections or the "#"-boundary check ever see it, with the body
# re-appended and re-scanned like a real $(...) body.
test_deny "$IRRECOVERABLE" 'GH #181: # right after <(...) must not hide a real trailing rm -rf' \
  "$(bash_payload 'echo <(true)#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #181: same check with >(...) (output process substitution)' \
  "$(bash_payload 'echo >(true)#bar; rm -rf hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #181: same check with a git subcommand after the ;' \
  "$(bash_payload 'echo <(true)#bar; git reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #181 control: a dangerous command INSIDE <(...) is still denied (no # trick needed)' \
  "$(bash_payload 'echo <(rm -rf hooks/gates/irrecoverable.py)')"
test_allow "$IRRECOVERABLE" 'GH #181 control: an ordinary process-substitution idiom with nothing dangerous still allows' \
  "$(bash_payload 'diff <(sort /etc/hosts) <(sort /etc/hosts)')"

# GH #181 round 2 (adversarial Codex pass found these before ship): 3 bugs in the first <(...)/>(...)
# recognition attempt.
test_deny "$IRRECOVERABLE" 'GH #181 round 2 finding 1: a quoted ) inside the body must not prematurely close the span' \
  "$(bash_payload 'echo <(echo ")"; rm -rf hooks/gates/irrecoverable.py)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 2 finding 1, >(...) variant' \
  "$(bash_payload 'echo >(echo ")"; rm -rf hooks/gates/irrecoverable.py)')"
test_allow "$IRRECOVERABLE" 'GH #181 round 2 finding 2: <(...) inside double quotes is inert text, must not get its body re-scanned' \
  "$(bash_payload 'echo "<(rm -rf hooks/gates/irrecoverable.py)"')"
test_allow "$IRRECOVERABLE" 'GH #181 round 2 finding 3: a pure <(...) arg to checkout is a real nonflag arg but never a real worktree pathspec' \
  "$(bash_payload 'git checkout main <(true) 2>&1')"
test_allow "$IRRECOVERABLE" 'GH #181 round 2 finding 3, two pure <(...) args, same reasoning' \
  "$(bash_payload 'git checkout HEAD <(true) <(true) 2>&1')"
test_deny "$IRRECOVERABLE" 'GH #181 round 2 control: a real 2-nonflag tree-ish+path checkout, no substitution, still denies' \
  "$(bash_payload 'git checkout HEAD~1 hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #181 round 2 control: a $(...)-derived path arg (attacker-controlled value) still counts toward checkout tree-ish+path' \
  "$(bash_payload 'git checkout main $(echo hooks/gates/irrecoverable.py) 2>&1')"

# deep-audit 2026-09-29: PSUB's exclusion landed on checkout's nonflag count only; restore's
# nearly-identical pathspec check (same "a pure PSUB token is never a real worktree pathspec"
# reasoning) was missed, so a pure <(...)/>(...) argument false-denied restore -- same failure
# class as GH #181 round 2 finding 3, one rule over.
test_allow "$IRRECOVERABLE" 'deep-audit: a pure <(...) arg to restore is a real nonflag arg but never a real worktree pathspec' \
  "$(bash_payload 'git restore <(true) 2>&1')"
test_allow "$IRRECOVERABLE" 'deep-audit: same check with >(...) (output process substitution)' \
  "$(bash_payload 'git restore >(true) 2>&1')"
test_deny "$IRRECOVERABLE" 'deep-audit control: a real pathspec arg to restore still denies (no substitution)' \
  "$(bash_payload 'git restore hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'deep-audit control: a $(...)-derived path arg (attacker-controlled value) still counts toward restore' \
  "$(bash_payload 'git restore $(echo hooks/gates/irrecoverable.py) 2>&1')"

# blind-spot-hunter (2026-09-29), whole-picture pass on the restore/PSUB fix above plus the
# already-merged checkout/PSUB exclusion (4e739ca7): 4 confirmed HIGH-severity gaps, all
# empirically baseline-checked to isolate which commit introduced each one.
# F1 (introduced by the restore/PSUB fix just above, same session): --pathspec-from-file's VALUE
# is read by git as a list of real pathspecs -- excluding a pure PSUB token from the pathspec
# count is wrong here, since the process substitution's OUTPUT (not the token itself) is the
# actual pathspec source.
test_deny "$IRRECOVERABLE" 'deep-audit F1: restore --pathspec-from-file <(...) reads real pathspecs from the fd, must still deny' \
  "$(bash_payload 'git restore --pathspec-from-file <(echo hooks/gates/irrecoverable.py) 2>&1')"
# F2 (introduced upstream by c47f624a's new _blank_redirections: a bare "<" with an empty target
# is silently deleted instead of counted, pre-dating PSUB/#181 entirely): same flag on checkout.
test_deny "$IRRECOVERABLE" 'deep-audit F2: checkout --pathspec-from-file <(...) same gap, one subcommand over' \
  "$(bash_payload 'git checkout HEAD --pathspec-from-file <(echo f) 2>&1')"
# F3/F4 (introduced by 4e739ca7's PSUB): scan is PH-stripped (line ~1269) BEFORE the "!= PSUB"
# check runs, so a glued "$(...)<(...)" token (no space -- one shlex token, "PH_char+PSUB_char")
# collapses to a value textually identical to a lone PSUB once PH is stripped, wrongly inheriting
# PSUB's "safe to exclude" treatment even though the $(...) half is attacker-controlled.
test_deny "$IRRECOVERABLE" 'deep-audit F3: restore, glued \$(...)<(...) must not collapse to excluded-PSUB after PH-stripping' \
  "$(bash_payload 'git restore $(echo "hooks/gates/irrecoverable.py :^x")<(true) 2>&1')"
test_deny "$IRRECOVERABLE" 'deep-audit F4: checkout, same glued-token collapse' \
  "$(bash_payload 'git checkout main $(echo "hooks/gates/irrecoverable.py :^x")<(true) 2>&1')"
# Controls: the fix for F1/F2 must not touch a --pathspec-from-file-less command, and the fix for
# F3/F4 must not touch a pure (unglued) PSUB token, which still correctly allows.
test_allow "$IRRECOVERABLE" 'deep-audit control: checkout with a pure (unglued) PSUB arg still allows (round 2 behavior unchanged)' \
  "$(bash_payload 'git checkout main <(true) 2>&1')"
test_allow "$IRRECOVERABLE" 'deep-audit control: restore with a pure (unglued) PSUB arg still allows' \
  "$(bash_payload 'git restore <(true) 2>&1')"

# GH #181 round 3 (adversarial Codex pass found this before ship): a body extracted from <(...)/
# >(...) is spliced back as its own statement only ONCE, after the whole scan finishes -- a
# DIFFERENT-type substitution nested inside it (a backtick inside "<(...)") was never re-examined,
# so it survived unblanked to shlex, still glued to its neighbor text and evading exact-match
# dispatch. Fixed by recursively re-scanning the extracted body (this branch only; the sibling
# "$(...)"/"${...}" branches share the identical gap, confirmed pre-existing, filed separately).
test_deny "$IRRECOVERABLE" 'GH #181 round 3: a backtick nested inside <(...) must not survive unblanked to shlex' \
  "$(bash_payload 'echo <(echo `rm -rf hooks/gates/irrecoverable.py`)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 3, >(...) variant' \
  "$(bash_payload 'echo >(echo `rm -rf hooks/gates/irrecoverable.py`)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 3, a git subcommand nested inside the backtick' \
  "$(bash_payload 'echo <(echo `git reset --hard`)')"
test_deny "$IRRECOVERABLE" 'GH #181 round 3 control: 1000-deep nested <(...) with a real rm -rf innermost fails closed, no crash/traceback' \
  "$(bash_payload "$(python3 -c "print('echo ' + '<(' * 1000 + 'rm -rf hooks/gates/irrecoverable.py' + ')' * 1000)")")"

# GH #188: bash's named-fd redirect "{var}>file" was not a recognized redirect. The outer tokenizer
# split "{fd}" into "{" "fd" "}" ("{"/"}" are window breaks), cutting the command off before a real
# pathspec (fail-open); the bash -c/eval tokenizer kept "{fd}" as one nonflag arg (over-deny).
# GH #219: whether "{fd}>" is a redirect depends on the binary (bash 4+/ksh/zsh yes; macOS sh, bash 3.2,
# dash no, where it is a literal pathspec), so both readings are checked and any deny wins. A branch
# switch with a named-fd redirect is therefore an accepted over-deny (it was allowed under #188).
test_deny "$IRRECOVERABLE" 'GH #219: {fd}>/dev/null on a branch switch denies, {fd} may be a literal pathspec (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: same (eval)' \
  "$(bash_payload 'eval "git checkout main {fd}>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: same (direct)' \
  "$(bash_payload 'git checkout main {fd}>/dev/null')"
test_deny "$IRRECOVERABLE" 'GH #219: {fd} stays a literal restore pathspec on macOS sh / bash 3.2 / dash (sh -c)' \
  "$(bash_payload 'sh -c "git restore {fd}>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: same (direct)' \
  "$(bash_payload 'git restore {fd}>x')"
test_deny "$IRRECOVERABLE" 'GH #219: zsh reads {fd}&>x as a named fd, so it hides the subcommand slot (direct)' \
  "$(bash_payload 'git {fd}&>x reset --hard')"
test_deny "$IRRECOVERABLE" 'GH #219: same (eval)' \
  "$(bash_payload 'eval "git {fd}&>x clean -fd"')"
test_allow "$IRRECOVERABLE" 'GH #219 control: a named-fd redirect on a harmless command still allows' \
  "$(bash_payload 'bash -c "git status {fd}>/dev/null"')"
test_allow "$IRRECOVERABLE" 'GH #219 control: {fd}>x before a plain branch-less log allows (direct)' \
  "$(bash_payload 'git log {fd}>x')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}> redirect does not hide a real tree-ish+path checkout (direct)' \
  "$(bash_payload 'git checkout HEAD {fd}>/dev/null hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #188 control: same, bash -c' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}>/dev/null hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188 control: a mid-word x{fd}>f is a literal pathspec "x{fd}" plus a plain redirect, not a named fd' \
  "$(bash_payload 'git checkout main x{fd}>/dev/null')"
# #208 validator round 1: ">|" (noclobber) was not an operator, so "{fd}>" matched, the target
# stopped at "|", and "|x <path>" became a pipe that cut the window before <path>.
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x does not hide a tree-ish+path checkout (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>| x (spaced target), same (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}>| x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|/dev/null -- <path>, same (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}>|/dev/null -- hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x does not hide a restore pathspec (sh -c)' \
  "$(bash_payload 'sh -c "git restore {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x, same (eval)' \
  "$(bash_payload 'eval "git checkout HEAD {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}>|x, same (sudo bash -c)' \
  "$(bash_payload 'sudo bash -c "git checkout HEAD {fd}>|x hooks/gates/irrecoverable.py"')"
test_deny "$IRRECOVERABLE" 'plain >|x does not hide a tree-ish+path checkout (was allowed on develop too)' \
  "$(bash_payload 'git checkout HEAD >|x hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'plain 2>|x, same (was allowed on develop too)' \
  "$(bash_payload 'git checkout HEAD 2>|x hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #219: {fd}>|/dev/null on a branch switch denies (literal {fd} pathspec reading, bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}>|/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #219: {fd}<>/dev/null on a branch switch denies, same (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}<>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #188 control: {fd}<>x does not hide a tree-ish+path checkout (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}<>x hooks/gates/irrecoverable.py"')"
# bash takes a {var} prefix only where an fd number is allowed: never on &> / &>>, so "{fd}&>x"
# is the literal word "{fd}" (a pathspec here) plus a redirect.
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>x is a literal {fd} pathspec, not a named fd (bash -c)' \
  "$(bash_payload 'bash -c "git checkout HEAD {fd}&>x"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>/dev/null after a branch is a second nonflag (bash -c)' \
  "$(bash_payload 'bash -c "git checkout main {fd}&>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>/dev/null is a literal restore pathspec (sh -c)' \
  "$(bash_payload 'sh -c "git restore {fd}&>/dev/null"')"
test_deny "$IRRECOVERABLE" 'GH #188: {fd}&>/dev/null, same (eval)' \
  "$(bash_payload 'eval "git checkout main {fd}&>/dev/null"')"
# A deleted redirect leaves a space, so ")" and ";" are not glued into one ");" token.
test_deny "$IRRECOVERABLE" 'deleted redirect leaves a space: (echo a)>x;rm -rf <dir> denies' \
  "$(bash_payload '(echo a)>x;rm -rf build')"
test_deny "$IRRECOVERABLE" 'deleted redirect leaves a space: (true)>/dev/null;git reset --hard denies' \
  "$(bash_payload '(true)>/dev/null;git reset --hard')"
# After an escaped char ("x\ {fd}>f") "{fd}>" is read as a redirect too: keeping "{" as text let
# the outer tokenizer break the window at "{", dropping the "-f" after it.
test_deny "$IRRECOVERABLE" 'escaped-space word before {fd}>: rm -r x\ {fd}>/dev/null -f denies' \
  "$(bash_payload 'rm -r x\ {fd}>/dev/null -f')"
test_deny "$IRRECOVERABLE" 'GH #188 control: an escaped \{fd}>x is the literal word {fd}, a second nonflag' \
  "$(bash_payload 'git checkout main \{fd}>x')"

# GH #197: -S is --staged (index only), also bundled and as a --stage abbreviation; -W still wins.
test_allow "$IRRECOVERABLE" 'GH #197: git restore -S <path> is index-only' \
  "$(bash_payload 'git restore -S hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #197: git restore -qS <path> (bundled) is index-only' \
  "$(bash_payload 'git restore -qS hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #197: git restore --stage <path> (abbreviation) is index-only' \
  "$(bash_payload 'git restore --stage hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197: git restore -S -W <path> still discards worktree changes' \
  "$(bash_payload 'git restore -S -W hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197: git restore -SW <path> (bundled) still discards worktree changes' \
  "$(bash_payload 'git restore -SW hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197: git restore -S --worktree <path> still discards worktree changes' \
  "$(bash_payload 'git restore -S --worktree hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #197 control: git restore <path> with neither flag still denies' \
  "$(bash_payload 'git restore hooks/gates/irrecoverable.py')"
# GH #189: `git restore --staged` plus -W or a --worktree abbreviation still targets the worktree.
test_deny "$IRRECOVERABLE" 'GH #189: git restore --staged -W <path> discards worktree changes' \
  "$(bash_payload 'git restore --staged -W hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #189: git restore --staged --work <path> (abbreviation) discards worktree changes' \
  "$(bash_payload 'git restore --staged --work hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #189: git restore --staged -qW <path> (bundled) discards worktree changes' \
  "$(bash_payload 'git restore --staged -qW hooks/gates/irrecoverable.py')"
test_deny "$IRRECOVERABLE" 'GH #189 control: git restore --staged --worktree <path> still denies' \
  "$(bash_payload 'git restore --staged --worktree hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #189 control: git restore --staged <path> alone (index only) allows' \
  "$(bash_payload 'git restore --staged hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #189 control: -sW is -s (source) with value W, not -W, so --staged -sW <path> allows' \
  "$(bash_payload 'git restore --staged -sW hooks/gates/irrecoverable.py')"
test_allow "$IRRECOVERABLE" 'GH #189 control: after -- every token is a pathspec, so --staged -- -Wfile allows' \
  "$(bash_payload 'git restore --staged -- -Wfile')"

# GH #249: restore's -m is --merge (no value), not a commit message flag; the -m value-skip must not eat the pathspec.
test_deny "$IRRECOVERABLE" 'GH #249: git restore -m . discards worktree changes' \
  "$(bash_payload 'git restore -m .')"
test_deny "$IRRECOVERABLE" 'GH #249: git restore -W -m file discards worktree changes' \
  "$(bash_payload 'git restore -W -m file.txt')"
test_deny "$IRRECOVERABLE" 'GH #249: git restore --conflict=merge -m . discards worktree changes' \
  "$(bash_payload 'git restore --conflict=merge -m .')"
# GH #249: -s/--source take a value, so "-s --staged" makes --staged the source and the restore still targets the worktree.
test_deny "$IRRECOVERABLE" 'GH #249: -s --staged -sHEAD file (--staged is the source value)' \
  "$(bash_payload 'git restore -s --staged -sHEAD file.txt')"
test_deny "$IRRECOVERABLE" 'GH #249: --source --staged --source=HEAD . (--staged is the source value)' \
  "$(bash_payload 'git restore --source --staged --source=HEAD .')"
test_deny "$IRRECOVERABLE" 'GH #249: -qs --staged -sHEAD file (cluster ending in s takes the next token)' \
  "$(bash_payload 'git restore -qs --staged -sHEAD file.txt')"
test_allow "$IRRECOVERABLE" 'GH #249 control: --source=HEAD --staged file (glued value, real --staged) allows' \
  "$(bash_payload 'git restore --source=HEAD --staged file.txt')"
test_allow "$IRRECOVERABLE" 'GH #249 control: -s HEAD --staged file (value is HEAD, real --staged) allows' \
  "$(bash_payload 'git restore -s HEAD --staged file.txt')"
test_deny "$IRRECOVERABLE" 'audit-0930 F3: git checkout -m . (checkout -m is --merge, no value)' \
  "$(bash_payload 'git checkout -m .')"
test_deny "$IRRECOVERABLE" 'audit-0930 F3: git checkout -m -- file discards worktree changes' \
  "$(bash_payload 'git checkout -m -- file.txt')"
test_allow "$IRRECOVERABLE" 'audit-0930 F3 control: git checkout -m <branch> is a merge-switch' \
  "$(bash_payload 'git checkout -m main')"
test_allow "$IRRECOVERABLE" 'GH #249 control: git commit -m message still skips its value' \
  "$(bash_payload 'git commit -m "restore . later"')"

# The gate correctly denies each idiom below TODAY, but no test held the deny path, so a
# mutation to the wrapper-unwrap / hooksPath / branch-delete / backstop logic survived the whole
# suite (fail-open, undetected).
test_deny  "$IRRECOVERABLE" "sudo rm -rf (wrapper unwrap)" \
  "$(bash_payload 'sudo rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo -u <user> rm -rf (issue #115: value-taking flag bypass)" \
  "$(bash_payload 'sudo -u alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo --user=<user> rm -rf (issue #115, = form)" \
  "$(bash_payload 'sudo --user=alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "env VAR=val rm -rf (env-assignment wrapper)" \
  "$(bash_payload 'env FOO=1 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "env -u VAR rm -rf (env-unset-flag wrapper)" \
  "$(bash_payload 'env -u FOO rm -rf /tmp/x')"
# GH #216: `rtk proxy <cmd>` and `rtk run` run <cmd> unfiltered, and rtk's own verbs
# (`rtk find`, `rtk git`) dispatch to the real command, so a destructive command behind any
# of them must be classified exactly as it is bare.
test_deny  "$IRRECOVERABLE" "rtk proxy rm -f -r (GH #216: rtk proxy wrapper)" \
  "$(bash_payload 'rtk proxy rm -f -r /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy rm -rf (GH #216)" \
  "$(bash_payload 'rtk proxy rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk run -c \"rm -rf\" (GH #216: rtk run -c body)" \
  "$(bash_payload 'rtk run -c "rm -rf /tmp/x"')"
test_deny  "$IRRECOVERABLE" "rtk run --command '...' (GH #216: long form)" \
  "$(bash_payload "rtk run --command 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "rtk run rm -rf (GH #216: positional args form)" \
  "$(bash_payload 'rtk run rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy find -delete (GH #216)" \
  "$(bash_payload 'rtk proxy find . -delete')"
test_deny  "$IRRECOVERABLE" "rtk find -delete (GH #216: rtk verb dispatches to find)" \
  "$(bash_payload 'rtk find . -delete')"
test_deny  "$IRRECOVERABLE" "rtk proxy git push --force (GH #216)" \
  "$(bash_payload 'rtk proxy git push --force origin main')"
test_deny  "$IRRECOVERABLE" "rtk git reset --hard (GH #216: rtk verb dispatches to git)" \
  "$(bash_payload 'rtk git reset --hard')"
test_deny  "$IRRECOVERABLE" "env rtk proxy rm -rf (GH #216: chained with env)" \
  "$(bash_payload 'env FOO=1 rtk proxy rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy env rm -rf (GH #216: env behind rtk)" \
  "$(bash_payload 'rtk proxy env rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy sudo rm -rf (GH #216: sudo behind rtk)" \
  "$(bash_payload 'rtk proxy sudo rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "rtk proxy bash -c 'rm -rf' (GH #216: shell body behind rtk)" \
  "$(bash_payload "rtk proxy bash -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "rtk run -c \"a; rm -rf\" (GH #216: rm after a separator inside the body)" \
  "$(bash_payload 'rtk run -c "echo hi; rm -rf /tmp/x"')"
# Controls: the unwrap must not turn ordinary rtk usage into a denial.
test_allow "$IRRECOVERABLE" "rtk proxy ls -la (GH #216 control)" \
  "$(bash_payload 'rtk proxy ls -la')"
test_allow "$IRRECOVERABLE" "rtk proxy rm file (GH #216 control: no -r/-f)" \
  "$(bash_payload 'rtk proxy rm /tmp/x')"
test_allow "$IRRECOVERABLE" "rtk grep foo (GH #216 control)" \
  "$(bash_payload 'rtk grep foo src')"
test_allow "$IRRECOVERABLE" "rtk find . -name x (GH #216 control)" \
  "$(bash_payload 'rtk find . -name x')"
test_allow "$IRRECOVERABLE" "rtk run -c \"ls\" (GH #216 control)" \
  "$(bash_payload 'rtk run -c "ls -la"')"
test_allow "$IRRECOVERABLE" "rtk gain (GH #216 control: rtk meta command)" \
  "$(bash_payload 'rtk gain')"
test_allow "$IRRECOVERABLE" "rtk proxy git status (GH #216 control)" \
  "$(bash_payload 'rtk proxy git status')"
# rtk run/err/test/summary join their args and run them through `sh -c` (verified live: a quoted
# `;` starts a second command), unlike `rtk proxy`, which executes its args as an argv.
test_deny  "$IRRECOVERABLE" "rtk run 'rm -rf' (GH #216: one quoted string is a shell line)" \
  "$(bash_payload "rtk run 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "rtk err 'git push --force' (GH #216)" \
  "$(bash_payload "rtk err 'git push --force origin main'")"
test_deny  "$IRRECOVERABLE" "rtk test 'git reset --hard' (GH #216)" \
  "$(bash_payload "rtk test 'git reset --hard'")"
test_deny  "$IRRECOVERABLE" "rtk summary 'find -delete' (GH #216)" \
  "$(bash_payload "rtk summary 'find . -delete'")"
test_deny  "$IRRECOVERABLE" "rtk run echo 'x;' rm -rf (GH #216: quoted separator joins into a second command)" \
  "$(bash_payload "rtk run echo 'hi;' rm -rf /tmp/x")"
test_deny  "$IRRECOVERABLE" "rtk err true 'x;' rm -rf (GH #216)" \
  "$(bash_payload "rtk err true 'x;' rm -rf /tmp/x")"
test_allow "$IRRECOVERABLE" "rtk err 'ls -la' (GH #216 control)" \
  "$(bash_payload "rtk err 'ls -la'")"
test_allow "$IRRECOVERABLE" "rtk test 'echo hi' (GH #216 control)" \
  "$(bash_payload "rtk test 'echo hi'")"
test_allow "$IRRECOVERABLE" "rtk summary 'git status' (GH #216 control)" \
  "$(bash_payload "rtk summary 'git status'")"
test_deny  "$IRRECOVERABLE" "nice -n 5 rm -rf (nice with value flag)" \
  "$(bash_payload 'nice -n 5 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "nice rm -rf (bare nice wrapper)" \
  "$(bash_payload 'nice rm -rf /tmp/x')"

# --- operator-glue / grouping-token bypass: without punctuation_chars, "echo hi;rm -rf x"
# tokenized as one glued word "hi;rm" and "(rm -rf x)" left "(" as argv0.
test_deny  "$IRRECOVERABLE" "glued semicolon, no space (was a bypass)" \
  "$(bash_payload 'echo hi;rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "glued &&, no space (was a bypass)" \
  "$(bash_payload 'echo hi&&rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "glued pipe, no space (was a bypass)" \
  "$(bash_payload 'echo hi|rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "subshell wrap, no space (was a bypass)" \
  "$(bash_payload '(rm -rf /tmp/x)')"
test_deny  "$IRRECOVERABLE" "brace group (was a bypass)" \
  "$(bash_payload '{ rm -rf /tmp/x; }')"
test_allow "$IRRECOVERABLE" "quoted semicolon stays literal (must not over-block)" \
  "$(bash_payload 'git commit -m "a;b"')"
test_deny  "$IRRECOVERABLE" "sudo -nu <user> bundled short flags (was a bypass)" \
  "$(bash_payload 'sudo -nu alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo -Sku <user> bundled short flags (was a bypass)" \
  "$(bash_payload 'sudo -Sku alice rm -rf /tmp/x')"
test_allow "$IRRECOVERABLE" "sudo -un <user>: u's value is the attached 'n', alice is the real wrapped cmd (must not over-block)" \
  "$(bash_payload 'sudo -un alice rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "xargs rm -rf (rm via xargs)" \
  "$(bash_payload 'echo /tmp/x | xargs rm -rf')"
test_deny  "$IRRECOVERABLE" "docker exec CONTAINER rm -rf (unwrap inner destructive)" \
  "$(bash_payload 'docker exec c1 rm -rf /data')"
# GH #227: shell bodies nest (`sh -c "sh -c '...'"`), xargs and find -exec hand a body to a
# shell, and `exec -a NAME` puts a value flag before the command.
test_deny  "$IRRECOVERABLE" "nested sh -c (GH #227)" \
  "$(bash_payload "sh -c \"sh -c 'rm -rf /tmp/x'\"")"
test_deny  "$IRRECOVERABLE" "three-deep bash -c (GH #227)" \
  "$(bash_payload "bash -c 'bash -c \"bash -c \\\"rm -rf /tmp/x\\\"\"'")"
test_deny  "$IRRECOVERABLE" "xargs sh -c body (GH #227)" \
  "$(bash_payload "echo a | xargs sh -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "xargs -I{} bash -c body (GH #227)" \
  "$(bash_payload "xargs -I{} bash -c 'rm -rf {}'")"
test_deny  "$IRRECOVERABLE" "find -exec sh -c body (GH #227)" \
  "$(bash_payload "find . -exec sh -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "exec -a NAME then the command (GH #227)" \
  "$(bash_payload 'exec -a foo rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "sudo exec -a NAME then the command (GH #227)" \
  "$(bash_payload 'sudo exec -a foo rm -rf /tmp/x')"
# GH #213: spaced long options on wrappers, keywords after `time`, `)` before a spawn.
test_deny  "$IRRECOVERABLE" "timeout --kill-after N DUR cmd (GH #213)" \
  "$(bash_payload 'timeout --kill-after 5 10 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "nice --adjustment N cmd (GH #213)" \
  "$(bash_payload 'nice --adjustment 5 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "stdbuf --output L cmd (GH #213)" \
  "$(bash_payload 'stdbuf --output L rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "ionice --class 3 cmd (GH #213)" \
  "$(bash_payload 'ionice --class 3 rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "time ! cmd keyword after a wrapper (GH #213)" \
  "$(bash_payload 'time ! rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "nested spawn after a case-arm ) (GH #213)" \
  "$(bash_agent_payload 'case x in x) claude -p x ;; esac' fork)"
test_allow "$IRRECOVERABLE" "timeout --kill-after N DUR benign (GH #213)" \
  "$(bash_payload 'timeout --kill-after 5 10 ls /tmp/x')"
test_allow "$IRRECOVERABLE" "nice --adjustment N benign (GH #213)" \
  "$(bash_payload 'nice --adjustment 5 ls /tmp/x')"
test_allow "$IRRECOVERABLE" "time ! benign (GH #213)" \
  "$(bash_payload 'time ! ls /tmp/x')"
test_allow "$IRRECOVERABLE" "case arm with a non-spawn command (GH #213)" \
  "$(bash_agent_payload 'case x in x) claude --version ;; esac' fork)"
test_deny  "$IRRECOVERABLE" "shell nested past the depth cap (GH #227)" \
  "$(python3 -c 'import json,shlex;b="git status"
for _ in range(8): b="sh -c "+shlex.quote(b)
print(json.dumps({"tool_name":"Bash","tool_input":{"command":b}}))')"
test_deny  "$IRRECOVERABLE" "exec -la NAME bundled value flag (GH #227)" \
  "$(bash_payload 'exec -la x rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "bash -c -- body (GH #227)" \
  "$(bash_payload "bash -c -- 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "find -name sh -exec bash -c body: shell is the word after -exec (GH #227)" \
  "$(bash_payload "find . -name sh -exec bash -c 'rm -rf {}' +")"
test_deny  "$IRRECOVERABLE" "find second -exec after an escaped semicolon (GH #227)" \
  "$(bash_payload 'find . -exec true \; -exec rm -rf {} \;')"
test_deny  "$IRRECOVERABLE" "find -ok sh -c body (GH #227)" \
  "$(bash_payload "find . -ok sh -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "xargs -I{} -- sh -c body (GH #227)" \
  "$(bash_payload "echo a | xargs -I{} -- sh -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "nested body with an ANSI-C quoted command (GH #227)" \
  "$(bash_payload "sh -c \"sh -c \$'rm -rf /tmp/x'\"")"
test_allow "$IRRECOVERABLE" "nested body with an ANSI-C quoted benign command (GH #227)" \
  "$(bash_payload "sh -c \"sh -c \$'git status'\"")"
test_allow "$IRRECOVERABLE" "find -name sh with a benign -exec (GH #227)" \
  "$(bash_payload 'find . -name sh -exec ls {} +')"
test_allow "$IRRECOVERABLE" "nested sh -c, benign body (GH #227)" \
  "$(bash_payload "sh -c \"sh -c 'ls /tmp'\"")"
test_allow "$IRRECOVERABLE" "xargs sh -c, benign body (GH #227)" \
  "$(bash_payload "xargs sh -c 'echo hi'")"
test_allow "$IRRECOVERABLE" "find -exec sh -c, benign body (GH #227)" \
  "$(bash_payload "find . -exec sh -c 'ls {}' \\;")"
test_allow "$IRRECOVERABLE" "exec -a NAME, benign command (GH #227)" \
  "$(bash_payload 'exec -a foo ls /tmp')"
# 2026-09-29 deep-audit of #227: exec's -a takes an ATTACHED name too (`exec -alpha CMD` runs CMD
# with argv0 "lpha"); only a cluster whose first `a` is its last char takes the next token.
test_deny  "$IRRECOVERABLE" "exec -alpha CMD: attached name, command still runs (audit of #227)" \
  "$(bash_payload 'exec -alpha rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "exec -aa CMD: attached name (audit of #227)" \
  "$(bash_payload 'exec -aa rm -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "exec -afooa CMD: attached name ending in a (audit of #227)" \
  "$(bash_payload 'exec -afooa git push --force origin main')"
test_allow "$IRRECOVERABLE" "exec -alpha CMD, benign command (audit of #227)" \
  "$(bash_payload 'exec -alpha ls /tmp')"
# Options after -c: bash/sh keep parsing options and take the first non-option word as the body.
test_deny  "$IRRECOVERABLE" "bash -c -e body (audit of #227)" \
  "$(bash_payload "bash -c -e 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "sh -c -x body nested (audit of #227)" \
  "$(bash_payload "sh -c \"sh -c -x 'rm -rf /tmp/x'\"")"
test_deny  "$IRRECOVERABLE" "bash -c -o pipefail body: -o takes a value (audit of #227)" \
  "$(bash_payload "bash -c -o pipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "bash -c -e, benign body (audit of #227)" \
  "$(bash_payload "bash -c -e 'git status'")"
# find -exec / xargs put a wrapper before the shell or runner.
test_deny  "$IRRECOVERABLE" "find -exec env sh -c body (audit of #227)" \
  "$(bash_payload "find . -exec env sh -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "find -exec sudo git push --force (audit of #227)" \
  "$(bash_payload 'find . -exec sudo git push --force origin main \;')"
test_deny  "$IRRECOVERABLE" "find -exec rtk run -c body (audit of #227)" \
  "$(bash_payload "find . -exec rtk run -c 'rm -rf {}' \\;")"
test_deny  "$IRRECOVERABLE" "xargs rtk run -c body (audit of #227)" \
  "$(bash_payload "echo a | xargs rtk run -c 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "xargs env sh -c body (audit of #227)" \
  "$(bash_payload "echo a | xargs env sh -c 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "find -exec env sh -c, benign body (audit of #227)" \
  "$(bash_payload "find . -exec env sh -c 'git status' \\;")"
test_allow "$IRRECOVERABLE" "xargs rtk run -c, benign body (audit of #227)" \
  "$(bash_payload "echo a | xargs rtk run -c 'git status'")"
# A shell name spelled with an empty substitution (`s$(true)h`) is still the shell, under find -exec too.
test_deny  "$IRRECOVERABLE" "find -exec s\$(true)h -c body: placeholder in the shell name (audit of #227)" \
  "$(bash_payload 'find . -exec s$(true)h -c '"'"'rm -rf /tmp/x'"'"' \;')"
test_deny  "$IRRECOVERABLE" "top-level s\$(true)h -c body (audit of #227)" \
  "$(bash_payload 's$(true)h -c '"'"'rm -rf /tmp/x'"'"'')"
# Whole-picture pass of the audit: a short-option cluster ending in o/O takes the next word as its
# value (`-eo pipefail`), including the -c cluster itself (`-ceo pipefail`).
test_deny  "$IRRECOVERABLE" "bash -c -eo pipefail body: cluster ending in o takes a value (audit of #227)" \
  "$(bash_payload "bash -c -eo pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -ceo pipefail body: the -c cluster itself takes a value (audit of #227)" \
  "$(bash_payload "bash -ceo pipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "bash -c -eo pipefail, benign body (audit of #227)" \
  "$(bash_payload "bash -c -eo pipefail 'git status'")"
# In zsh -O is a plain flag (no value), so `zsh -cO body` runs the body; only -o takes a value there.
test_deny  "$IRRECOVERABLE" "zsh -cO body: -O takes no value in zsh (audit of #227)" \
  "$(bash_payload "zsh -cO 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "zsh -ceO body (audit of #227)" \
  "$(bash_payload "zsh -ceO 'rm -rf /tmp/x'")"
# Remaining option gaps (bash getopt: every o/O in a cluster takes one following word, the -c may sit
# anywhere in the cluster, and `+e` / `+o name` are option words too; the tokenizer splits `+` off).
test_deny  "$IRRECOVERABLE" "bash -oc pipefail body: o before c (gap follow-up to #227)" \
  "$(bash_payload "bash -oc pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -Oc extglob body (gap follow-up to #227)" \
  "$(bash_payload "bash -Oc extglob 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -coo pipefail errexit body: two value flags (gap follow-up to #227)" \
  "$(bash_payload "bash -coo pipefail errexit 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -c -oo pipefail errexit body (gap follow-up to #227)" \
  "$(bash_payload "bash -c -oo pipefail errexit 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -c +e body (gap follow-up to #227)" \
  "$(bash_payload "bash -c +e 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "bash -c +o pipefail body (gap follow-up to #227)" \
  "$(bash_payload "bash -c +o pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "zsh -c +O body: -O takes no value in zsh (gap follow-up to #227)" \
  "$(bash_payload "zsh -c +O 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "sh -c \"bash -oc pipefail body\" nested (gap follow-up to #227)" \
  "$(bash_payload "sh -c \"bash -oc pipefail 'rm -rf /tmp/x'\"")"
test_allow "$IRRECOVERABLE" "bash -oc pipefail, benign body (gap follow-up to #227)" \
  "$(bash_payload "bash -oc pipefail 'git status'")"
test_allow "$IRRECOVERABLE" "bash -c +e, benign body (gap follow-up to #227)" \
  "$(bash_payload "bash -c +e 'git status'")"
# zsh, ksh and dash follow getopt: an `o` followed by more letters has them as its attached value
# (`-opipefail`), so the body is the next word; bash instead takes the next word for every `o`.
test_deny  "$IRRECOVERABLE" "zsh -c -opipefail body: attached option value (gap follow-up to #227)" \
  "$(bash_payload "zsh -c -opipefail 'rm -rf /tmp/x' ignored")"
test_deny  "$IRRECOVERABLE" "ksh -c -oerrexit body: attached option value (gap follow-up to #227)" \
  "$(bash_payload "ksh -c -oerrexit 'rm -rf /tmp/x' ignored")"
test_deny  "$IRRECOVERABLE" "zsh -c +opipefail body: attached value after a split + (gap follow-up to #227)" \
  "$(bash_payload "zsh -c +opipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "zsh -c +opipefail 'echo' then a dangerous-looking argument (gap follow-up to #227)" \
  "$(bash_payload "zsh -c +opipefail 'echo hi' 'rm -rf /tmp/x'")"
# bash's --rcfile / --init-file take a file: the word after them is an option value, not the body.
test_deny  "$IRRECOVERABLE" "bash --rcfile FILE -oc pipefail body: the file is not the body (audit 3 of #227)" \
  "$(bash_payload "bash --rcfile /dev/null -oc pipefail 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "env bash --init-file FILE -Oc extglob body (audit 3 of #227)" \
  "$(bash_payload "env bash --init-file /dev/null -Oc extglob 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "bash --rcfile FILE -oc pipefail, benign body (audit 3 of #227)" \
  "$(bash_payload "bash --rcfile /dev/null -oc pipefail 'git status'")"
# ksh93 runs a first operand that is not a readable file as the command string, no -c needed.
test_deny  "$IRRECOVERABLE" "ksh 'body' with no -c runs the string (audit 3 of #227)" \
  "$(bash_payload "ksh 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -o pipefail 'body' with no -c (audit 3 of #227)" \
  "$(bash_payload "ksh -o pipefail 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "ksh with a script operand and a benign later word (audit 3 of #227)" \
  "$(bash_payload "ksh deploy.sh 'git status'")"
# ksh joins every operand word into the command string (`ksh 'echo a' --hard` runs `echo a --hard`), and a
# -c after the operand is part of that string, not an option (blind-spot pass, audit 3 of #227).
test_deny  "$IRRECOVERABLE" "ksh operand then -c: the operand is still the command (audit 3 of #227)" \
  "$(bash_payload "ksh 'rm -rf /tmp/x' -c true")"
test_deny  "$IRRECOVERABLE" "ksh -- operand then -c (audit 3 of #227)" \
  "$(bash_payload "ksh -- 'rm -rf /tmp/x' -c true")"
test_deny  "$IRRECOVERABLE" "ksh operands joined: 'git reset' --hard (audit 3 of #227)" \
  "$(bash_payload "ksh 'git reset' --hard")"
test_allow "$IRRECOVERABLE" "ksh benign operand then -c (audit 3 of #227)" \
  "$(bash_payload "ksh 'git status' -c true")"
# -s reads commands from stdin (the operand is a positional parameter), -n and -D run nothing: the operand is not a command.
test_allow "$IRRECOVERABLE" "ksh -s operand is a positional parameter (audit 5 of #227)" \
  "$(bash_payload "ksh -s 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "ksh -n operand is not run (audit 5 of #227)" \
  "$(bash_payload "ksh -n 'rm -rf /tmp/x'")"
test_allow "$IRRECOVERABLE" "ksh -xD operand is not run (audit 5 of #227)" \
  "$(bash_payload "ksh -xD 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -sc body still runs (audit 5 of #227)" \
  "$(bash_payload "ksh -sc 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -x operand still runs (audit 5 of #227)" \
  "$(bash_payload "ksh -x 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -onounset: the n and s are the -o value (audit 5 of #227)" \
  "$(bash_payload "ksh -onounset 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -o nounset: the value word is not a flag cluster (audit 5 of #227)" \
  "$(bash_payload "ksh -o nounset 'rm -rf /tmp/x'")"
# A later + option turns the flag back off (`-n +n` runs the operand), so any + option keeps the scan.
test_deny  "$IRRECOVERABLE" "ksh -n +n operand runs (audit 5 whole-picture pass)" \
  "$(bash_payload "ksh -n +n 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "ksh -n +o noexec operand runs (audit 5 whole-picture pass)" \
  "$(bash_payload "ksh -n +o noexec 'rm -rf /tmp/x'")"
test_deny  "$IRRECOVERABLE" "env ksh -s +s operand runs (audit 5 whole-picture pass)" \
  "$(bash_payload "env ksh -s +s 'git reset --hard'")"
# Under find, `-exec` after `bash -c` is bash's option letters (e x e c), not a second find action.
test_deny  "$IRRECOVERABLE" "find -exec bash -c -exec body: -exec is a shell cluster (gap follow-up to #227)" \
  "$(bash_payload "find . -exec bash -c -exec 'rm -rf /tmp/x' \\;")"
test_deny  "$IRRECOVERABLE" "find -exec env bash -c -exec body (gap follow-up to #227)" \
  "$(bash_payload "find . -exec env bash -c -exec 'rm -rf /tmp/x' \\;")"
test_allow "$IRRECOVERABLE" "find -exec bash -c -exec, benign body (gap follow-up to #227)" \
  "$(bash_payload "find . -exec bash -c -exec 'git status' \\;")"
# A `{} +` terminator splits the window, so a second -exec starts with `+`.
test_deny  "$IRRECOVERABLE" "find -exec true {} + then a second -exec sh -c body (audit of #227)" \
  "$(bash_payload "find . -exec true {} + -exec sh -c 'rm -rf /x' sh {} +")"
test_allow "$IRRECOVERABLE" "find -exec true {} + then a benign second -exec (audit of #227)" \
  "$(bash_payload 'find . -exec true {} + -exec ls {} +')"
_timed_case "find -exec sh -c body followed by 3000 more -exec words is denied fast (audit of #227)" 2 \
  "$(python3 -c "print(\"find . -exec sh -c 'rm -rf /x' \" + '-exec ' * 3000 + '\\\\;')")"
_timed_case "3000 chained xargs env xargs is denied fast, not quadratic (audit of #227)" 2 \
  "$(python3 -c "print('echo a | xargs ' + 'env xargs ' * 3000 + 'git status')")"
test_allow "$IRRECOVERABLE" "a short xargs env xargs chain, benign (audit of #227)" \
  "$(bash_payload "echo a | xargs env xargs env git status")"
_timed_case "25 nested find -exec find stays fast and allowed (audit of #227)" 0 \
  "$(python3 -c "print('find . ' + '-exec find . ' * 25 + '-print')")"

gates_summary
