#!/usr/bin/env bash
# eval-changed.sh [--run] [<git-ref>] — maps changed agents/skills files to their
# `claude plugin eval` tag and prints (or, with --run, executes) the case for each.
# Local-only: CI wiring was declined (no ANTHROPIC_API_KEY secret on this repo, and
# each eval run is a paid API call) — this is the developer-triggered substitute for
# "continuous evals on agent-config change" from the AI-Native SDLC playbook audit
# (docs/research/ai-native-sdlc-playbook-audit-2026-08-28.md, Round 4 gap list).
# No <ref>: diffs the working tree (staged + unstaged) against HEAD. With <ref>: diffs
# <ref>...HEAD instead, e.g. `eval-changed.sh develop` before a push. A case listed in
# evals/judge-models.tsv also gets a `--case <case> --judge-model <model>` run (GH #510).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

run=0
ref=""
for arg in "$@"; do
  case "$arg" in
    --run) run=1 ;;
    *) ref="$arg" ;;
  esac
done

if [ -n "$ref" ]; then
  changed=$(git diff --name-only "$ref"...HEAD) || { echo "eval-changed: git diff $ref...HEAD failed" >&2; exit 1; }
else
  changed=$(git diff --name-only HEAD && git diff --name-only --cached) || { echo "eval-changed: git diff against HEAD or the index failed" >&2; exit 1; }
fi

tags=$(printf '%s\n' "$changed" \
  | /usr/bin/grep -E '^(agents/[^/]+\.md|skills/[^/]+/[^/]+/)' \
  | sed -E 's#^agents/([^/]+)\.md#\1#; s#^skills/[^/]+/([^/]+)/.*#\1#' \
  | sort -u)

if [ -z "$tags" ]; then
  echo "eval-changed: no changed agent/skill files, nothing to eval." >&2
  exit 0
fi

. scripts/_lib/eval-default-enabled.sh
# Fail on a broken judge-models.tsv (or a missing reader) now, before the first paid run.
python3 scripts/_lib/eval_judge_models.py check || exit 1
# Every run loads the plugin (with_default_enabled_true): eval sandboxes load no user settings,
# so with defaultEnabled: false every case, Agent- or Skill-based, silently scores a no-plugin
# fallback (CHANGELOG 1.1.133), and a tool_used grader still passes on the failed dispatch.
rc=0

# shell_word <arg>: <arg> as one shell word, bare when it holds only safe characters, else
# single-quoted with each ' written as '\'' (a parameter expansion: $(...) would drop trailing
# newlines). print_wrapped <argv...>: the evals/README.md run-block form of
# `with_default_enabled_true <argv...>`, quoted so the pasted line runs exactly <argv...>
# (an allowed_tools entry from frontmatter can hold spaces, parens or shell syntax).
shell_word() {
  local sq="'" esc="'\\''"  # variables: quoting inside ${//} differs across bash versions (3.2)
  case "$1" in
    ''|*[!A-Za-z0-9_./:@,=+-]*) printf "'%s'" "${1//$sq/$esc}" ;;
    *) printf '%s' "$1" ;;
  esac
}
print_wrapped() {
  local inner="source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true" arg
  for arg in "$@"; do inner+=" $(shell_word "$arg")"; done
  printf 'bash -c %s\n' "$(shell_word "$inner")"
}

while IFS= read -r tag; do
  # Union every allowed_tools list across all cases whose frontmatter tags: carry this tag
  # anywhere, as the CLI's --tag matches (a case dir's prefix need not be its tag: evals/perf-*
  # is performance-optimizer), instead of hardcoding a duplicate per-tag list.
  # shortcut: inline [a, b] lists only (eval_judge_models.frontmatter_list), upgrade if a case
  # ever uses a YAML block list.
  allow=$(python3 -c "
import sys, pathlib
sys.path.insert(0, 'scripts/_lib')
from eval_judge_models import frontmatter_list
tools = set()
for p in pathlib.Path('evals').glob('*/prompt.md'):
    if sys.argv[1] in frontmatter_list('evals', p.parent.name, 'tags'):
        tools.update(frontmatter_list('evals', p.parent.name, 'allowed_tools'))
print(','.join(sorted(tools)))
" "$tag") || exit 1
  cmd=(claude plugin eval . --scaffold --tag "$tag" --runs 1 --no-publish)
  [ -n "$allow" ] && cmd+=(--allow-tools "$allow")
  if [ "$run" -eq 1 ]; then
    echo "== $tag =="
    with_default_enabled_true "${cmd[@]}" </dev/null || rc=1
  else
    # The README run-block form: the helper needs bash, so a zsh user can paste it as-is.
    print_wrapped "${cmd[@]}"
  fi
  # GH #510: a case in evals/judge-models.tsv gets its own run under its judge; the tag run
  # above still judges it with haiku, and that score of it is not the one to read. The run
  # loads the plugin (with_default_enabled_true), as its evals/README.md line does: a paid
  # judge run that scores the no-plugin fallback is wasted.
  overrides=$(python3 scripts/_lib/eval_judge_models.py for-tag "$tag") || exit 1
  while IFS=$'\t' read -r case model case_allow; do
    [ -n "$case" ] || continue
    jcmd=(claude plugin eval . --scaffold --case "$case" --judge-model "$model" --runs 1 --no-publish)
    [ -n "$case_allow" ] && jcmd+=(--allow-tools "$case_allow")
    if [ "$run" -eq 1 ]; then
      echo "== $tag: $case, judged by $model (evals/judge-models.tsv) =="
      with_default_enabled_true "${jcmd[@]}" </dev/null || rc=1
    else
      # A `:` no-op, not a `#` comment: zsh runs a pasted `#` line as a command unless
      # interactivecomments is set, and the old hint's `; read ...` then ate the judge line.
      printf ': %s\n' "$(shell_word "$case: judged by $model (evals/judge-models.tsv); read its score from the next line")"
      # The README run-block form: the helper needs bash, so a zsh user can paste it as-is.
      print_wrapped "${jcmd[@]}"
    fi
  done <<< "$overrides"
done <<< "$tags"
exit "$rc"
