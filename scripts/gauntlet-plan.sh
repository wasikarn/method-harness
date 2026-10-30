#!/usr/bin/env bash
# gauntlet-plan.sh <base> | <base>..<head> | -  (GH #749): which gauntlet level a change needs.
# Reads the changed paths (`git diff --no-renames --name-only <base>...HEAD`, the range as given when it
# holds `..`, or one path per line on stdin with `-`) and maps each through scripts/gauntlet-rules.txt
# at the top of this checkout. Prints, from that top:
#   level: low|medium|full    the highest level over all paths; a path no rule matches gives full
#   test: <file>              each test file the rules select (none at full: full runs every test)
#   changed: <path>           each changed path (the lint input)
#   reason: ...               one line per rule that fired, and one per unmapped path
# run-gauntlet.sh --level <level> --plan <base> runs the plan; merge-pr.sh logs it beside the full
# run's result. Exit 2 on a bad argument, a missing rules file or a failed git diff. Bash 3.2.
set -uo pipefail
[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: gauntlet-plan.sh <base> | <base>..<head> | -" >&2; exit 2; }
top=$(git rev-parse --show-toplevel) || exit 2
cd "$top" || exit 2
rules=scripts/gauntlet-rules.txt
[ -f "$rules" ] || { echo "gauntlet-plan: no $rules in $top" >&2; exit 2; }
if [ "$1" = - ]; then
  paths=$(cat)
else
  case "$1" in *..*) range=$1 ;; *) range="$1...HEAD" ;; esac
  paths=$(git diff --no-renames --name-only "$range") || { echo "gauntlet-plan: git diff $range failed" >&2; exit 2; }
fi

NL=$'\n'
best=0 tests="" fired="" reasons=""
rank() { case $1 in low) echo 1 ;; medium) echo 2 ;; full) echo 3 ;; *) echo 0 ;; esac; }
# add_once <var> <line>: append <line> to the newline list in <var> unless it is already there.
add_once() { case "$NL${!1}$NL" in *"$NL$2$NL"*) ;; *) printf -v "$1" '%s%s\n' "${!1}" "$2" ;; esac; }

while IFS= read -r p; do
  [ -n "$p" ] || continue
  hit=0
  while read -r pat lvl rest; do
    case $pat in '' | '#'*) continue ;; esac
    # shellcheck disable=SC2254 # the rule's pattern is a glob on purpose
    case $p in $pat) ;; *) continue ;; esac
    r=$(rank "$lvl")
    [ "$r" -gt 0 ] || { echo "gauntlet-plan: bad level '$lvl' in $rules for '$pat'" >&2; exit 2; }
    hit=1
    [ "$r" -le "$best" ] || best=$r
    case "$NL$fired" in *"$NL$pat$NL"*) ;; *)
      fired="$fired$NL$pat$NL"; reasons="${reasons}reason: $pat -> $lvl ($p)$NL" ;;
    esac
    # Unquoted on purpose: each test pattern expands as a glob from the top of the checkout.
    for t in $rest; do
      [ "$t" = SELF ] && t=$p
      [ -f "$t" ] && add_once tests "$t"
    done
  done <"$rules"
  [ "$hit" = 1 ] || { best=3; reasons="${reasons}reason: $p is unmapped -> full$NL"; }
done <<<"$paths"

case $best in 0 | 1) echo "level: low" ;; 2) echo "level: medium" ;; *) echo "level: full" ;; esac
[ "$best" -ge 3 ] || printf '%s' "$tests" | LC_ALL=C sort | sed 's/^/test: /'
printf '%s\n' "$paths" | awk NF | sed 's/^/changed: /'
printf '%s' "$reasons"
