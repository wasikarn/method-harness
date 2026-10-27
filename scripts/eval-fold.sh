#!/usr/bin/env bash
# eval-fold.sh <agent> [--run] [--runs N] [-j N] [--keep] [-- <extra claude plugin eval args>]
# Fold-vs-keep eval for one agent (evals/README.md "Fold-vs-keep"): builds two throwaway
# plugins from the repo's tracked files in a temp dir -- kept (as shipped) and folded (the
# agent's text as a main-loop skill, the agent removed) -- and runs the agent's tagged cases
# against each with --ablation none, then prints a per-case, per-run comparison.
# Default (no --run): build both, `claude plugin validate` each, print example eval commands,
# remove the temp dir (--keep leaves it, so the printed commands still work). No model calls.
# --run executes them (paid). Never writes the repo's own manifest,
# agents/ or skills/; results land in evals/results/fold-<agent>-<timestamp>/ (gitignored).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
root="$(pwd)"

agent="" run=0 runs=2 jobs=1 keep=0 extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=1 ;;
    --keep) keep=1 ;;
    --runs) runs="${2:?--runs needs a number}"; shift ;;
    -j) jobs="${2:?-j needs a number}"; shift ;;
    --) shift; extra=("$@"); break ;;
    -*) echo "eval-fold: unknown flag $1" >&2; exit 2 ;;
    *) agent="$1" ;;
  esac
  shift
done
[ -n "$agent" ] || { echo "usage: eval-fold.sh <agent> [--run] [--runs N] [-j N] [--keep] [-- args]" >&2; exit 2; }
case "$runs" in ''|*[!0-9]*) echo "eval-fold: --runs must be a number" >&2; exit 2 ;; esac
[ "$runs" -ge 2 ] || { echo "eval-fold: --runs must be at least 2 (one run cannot tell a flip from noise)" >&2; exit 2; }

tmp="$(mktemp -d)" || exit 1
if [ "$keep" -eq 1 ]; then
  echo "eval-fold: kept temp dir: $tmp"
else
  trap 'trash "$tmp"' EXIT
fi
allow="$(python3 scripts/_lib/eval-fold.py build "$root" "$agent" "$tmp")" || exit 1

for arm in kept folded; do
  claude plugin validate "$tmp/$arm/.claude-plugin/plugin.json" >"$tmp/validate-$arm.out" 2>&1 \
    || { cat "$tmp/validate-$arm.out" >&2; echo "eval-fold: $arm plugin failed validation" >&2; exit 1; }
  echo "eval-fold: $arm plugin validates ($tmp/$arm)"
done

out="$root/evals/results/fold-$agent-$(date +%Y%m%dT%H%M%S)"
status=0
if [ "$run" -eq 0 ] && [ "$keep" -eq 1 ]; then
  echo "eval-fold: example commands (the temp dir stays, so these run as printed):"
elif [ "$run" -eq 0 ]; then
  echo "eval-fold: example commands only (the temp dir is removed on exit; use --keep to run them by hand, or --run):"
fi
for arm in kept folded; do
  # --trust-plugin: the temp dir is new every run, so the first-run trust prompt would always fire;
  # its contents are this repo's own tracked files.
  cmd=(claude plugin eval "$tmp/$arm" --scaffold --trust-plugin --ablation none --tag "$agent"
    --runs "$runs" -j "$jobs" --no-publish --output-dir "$out/$arm")
  [ -n "$allow" ] && cmd+=(--allow-tools "$allow")
  cmd+=(${extra[@]+"${extra[@]}"})  # bash 3.2: a bare empty "${extra[@]}" trips set -u
  if [ "$run" -eq 1 ]; then
    echo "== $agent: $arm =="
    "${cmd[@]}" || status=1  # a below-threshold case exits 1; still compare what ran
  else
    printf '%q ' "${cmd[@]}"; echo
  fi
done

if [ "$run" -eq 0 ]; then
  echo "eval-fold: dry run; nothing was evaluated. Add --run to pay for it."
  exit 0
fi
for arm in kept folded; do
  [ -f "$out/$arm/aggregate-result.json" ] || { echo "eval-fold: no $out/$arm/aggregate-result.json" >&2; exit 1; }
done
python3 scripts/_lib/eval-fold.py compare "$out/kept/aggregate-result.json" "$out/folded/aggregate-result.json" \
  | tee "$out/compare.txt" || exit 1
exit "$status"
