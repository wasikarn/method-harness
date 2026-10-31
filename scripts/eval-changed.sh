#!/usr/bin/env bash
# eval-changed.sh [--run] [<git-ref>] — maps changed agents/skills files to their
# `claude plugin eval` tag and prints (or, with --run, executes) the case for each.
# Local-only: CI wiring was declined (no ANTHROPIC_API_KEY secret on this repo, and
# each eval run is a paid API call) — this is the developer-triggered substitute for
# "continuous evals on agent-config change" from the AI-Native SDLC playbook audit
# (docs/research/ai-native-sdlc-playbook-audit-2026-08-28.md, Round 4 gap list).
# No <ref>: diffs the working tree (staged + unstaged) against HEAD. With <ref>: diffs
# <ref>...HEAD instead, e.g. `eval-changed.sh develop` before a push.
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
  changed=$(git diff --name-only "$ref"...HEAD)
else
  changed=$(git diff --name-only HEAD; git diff --name-only --cached)
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
# Tags whose cases load an mh agent or skill through the plugin: eval sandboxes load no user
# settings, so without the defaultEnabled flip they silently score a no-plugin fallback (the
# run block in evals/README.md wraps the same five).
needs_plugin=" code-architect performance-optimizer backend-architect ideate-critic ideate "

while IFS= read -r tag; do
  # Union every allowed_tools list across all cases whose frontmatter tags: carry this tag
  # anywhere, as the CLI's --tag matches (a case dir's prefix need not be its tag: evals/perf-*
  # is performance-optimizer), instead of hardcoding a duplicate per-tag list.
  # shortcut: inline [a, b] lists only, upgrade if a case ever uses a YAML block list.
  allow=$(python3 -c "
import re, sys, pathlib
def frontmatter_list(fm, key):
    m = re.search(r'^' + key + r':\s*\[([^\]]*)\]', fm, re.M)
    return [t.strip() for t in m.group(1).split(',') if t.strip()] if m else []
tools = set()
for p in pathlib.Path('evals').glob('*/prompt.md'):
    text = p.read_text()
    fm = text.split('---')[1] if text.startswith('---') else ''
    if sys.argv[1] in frontmatter_list(fm, 'tags'):
        tools.update(frontmatter_list(fm, 'allowed_tools'))
print(','.join(sorted(tools)))
" "$tag")
  cmd=(claude plugin eval . --scaffold --tag "$tag" --runs 1 --no-publish)
  [ -n "$allow" ] && cmd+=(--allow-tools "$allow")
  wrap=0
  [[ "$needs_plugin" == *" $tag "* ]] && wrap=1
  if [ "$run" -eq 1 ]; then
    echo "== $tag =="
    if [ "$wrap" -eq 1 ]; then
      with_default_enabled_true "${cmd[@]}"
    else
      "${cmd[@]}"
    fi
  elif [ "$wrap" -eq 1 ]; then
    # The README run-block form: the helper needs bash, so a zsh user can paste it as-is.
    printf "bash -c 'source scripts/_lib/eval-default-enabled.sh && with_default_enabled_true %s'\n" "${cmd[*]}"
  else
    printf '%q ' "${cmd[@]}"; echo
  fi
done <<< "$tags"
