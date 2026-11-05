#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $ and quotes in test payload strings are intentional
# GH #912: zsh precommand words, =word, repeat N, a globbed command word and glob qualifiers must not hide
# the real command from gate:bash:irrecoverable. Asks the gate for a verdict only; no command here is run.
# Run standalone: bash tests/hooks/test-gates-zsh-precommand.sh
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/_lib/gates-harness.sh"

echo "=== irrecoverable gate: zsh precommand shapes (GH #912) ==="
_rm='rm -rf ~'
for _c in "noglob $_rm" "nocorrect $_rm" "- $_rm" "=rm -rf ~" "repeat 1 $_rm" "repeat 2 noglob $_rm" \
  "noglob nocorrect $_rm" "command noglob $_rm" "sudo noglob $_rm" "noglob =rm -rf ~" \
  "/bin/r? -rf ~" "/bin/r* -rf ~" "/bin/[r]m -rf ~" "noglob /bin/r? -rf ~" "repeat 1 /bin/r? -rf ~" \
  "ls *(e:'rm -rf ~':)" "ls *(e['rm -rf ~'])" "ls *(e{'rm -rf ~'})" \
  "ls *(.e:'rm -rf ~':)" "ls *(N.e:'rm -rf ~':)" "ls *(om[1]e:'rm -rf ~':)" "/bin/[^x]m -rf ~" \
  "/usr/bin/redis-c?i flushall" "ls *(e:'rm -rf ~':N)" "ls *(e['rm -rf ~']N)" "ls *(e:'true':e:'rm -rf ~':)" "ls *(Fe:'rm -rf ~':)" "ls *(e:'rm -rf ~':F)" "/usr/bin/gchmo? -R 777 ." "/usr/bin/mariadb-admi? drop app" "/usr/bin/gi? trash ~" \
  "noglob git push --force origin HEAD:develop" "nocorrect git reset --hard HEAD~3" \
  "/usr/bin/en? rm -rf ~" "noglob /usr/bin/en? rm -rf ~" "/usr/bin/nohu? rm -rf ~" "/bin/z?h -c 'rm -rf ~'"; do
  test_deny "$IRRECOVERABLE" "GH #912: $_c" "$(bash_payload "$_c")"
done
test_ask "$IRRECOVERABLE" "GH #912: a command word with a glob matching over 12 programs could be any" "$(bash_payload '/bin/*o* -rf ~')"

for _c in 'ls *.py' 'echo =foo' 'repeat 3 echo hi' 'noglob git push origin HEAD:feat/x' '/bin/l? -la' \
  'noglob find . -name *.py' 'noglob rm a.txt' 'grep -e x file' "ls *(e:'true':)" 'ls *(.)' \
  '[ -f x ] && echo ok' '[[ -n x ]] && echo ok' 'nocorrect ls' '- ls' '=ls -la' 'repeat 2 noglob ls *.py'; do
  test_allow "$IRRECOVERABLE" "GH #912 control: $_c" "$(bash_payload "$_c")"
done
for _c in "rm -rf ~" "command rm -rf ~" "eval 'rm -rf ~'" "builtin rm -rf ~"; do
  test_deny "$IRRECOVERABLE" "GH #912 control (denied before): $_c" "$(bash_payload "$_c")"
done
gates_summary
