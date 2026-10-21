#!/usr/bin/env bash
# 35. Dead script-pointer doc-rot (skill/command/agent bodies invoke a script that does not exist)
# Matt "beware doc-rot": a surface body that tells the model to run
# `bash .../scripts/NAME.sh` (or a `python3 .../NAME.py` invocation) for a file
# that exists nowhere in the fleet is an instruct-the-model-to-run-a-missing-
# script defect — it crashes on invoke. The matt-first cut (242->87) deleted
# surfaces but left such pointers dangling; this guard is the regression fence.
#
# Scope: only EXECUTABLE invocations — a line that runs the script via `bash`,
# `sh`, `python3`, `python`, `node`, or `exec`. Descriptive prose that NAMES a
# script to say it is absent/retired (e.g. "its backing scripts/x.sh is absent")
# is deliberately not matched: the match requires an interpreter token before
# the path. WARN, not CRIT — advisory, matching the operating model (sensors
# journal; the CRIT set is reserved for the irrecoverable/tamper class).
# Build the set of every script basename that actually exists, once (was:
# one full-tree `find` per reference -- 22 traversals where 1 + array lookups do).
# No -type filter, matching the original per-reference find exactly -- a
# symlinked script resolves and executes fine, so it counts as existing too.
declare -A _known_scripts37=()
while IFS= read -r _path; do
  _known_scripts37["${_path##*/}"]=1  # find never yields a trailing slash; no basename spawn
done < <(find "$CLAUDE_DIR" \( -name '*.sh' -o -name '*.py' -o -name '*.js' \) \
            -not -path '*/.git/*' -not -path '*/.scratch/*' 2>/dev/null)

for _f in "$CLAUDE_DIR"/skills/*/SKILL.md "$CLAUDE_DIR"/skills/*/*/SKILL.md \
          "$CLAUDE_DIR"/skills/*/reference.md "$CLAUDE_DIR"/skills/*/*/reference.md \
          "$CLAUDE_DIR"/agents/*.md \
          "$CLAUDE_DIR"/docs/*.md "$CLAUDE_DIR"/docs/reference/*.md; do
  # docs/research/*.md is excluded on purpose — those are dated design/analysis
  # snapshots that correctly describe deleted surfaces as history, not doc-rot.
  [ -f "$_f" ] || continue
  # Pull interpreter-prefixed script paths: <interp> [flags] .../scripts/NAME.(sh|py|js)
  # Tolerate a ${VAR}/ or path prefix before scripts/; capture the basename.
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    # A reference resolving against an external vault (e.g. $VAULT/scripts/...,
    # ${MH_WIKI_VAULT:-...}/scripts/...) wraps llm-wiki's own scripts by design
    # — CLAUDE.md's "wrap the vault's scripts, never reimplement" constraint.
    # Those scripts live outside this repo on purpose and can never resolve via
    # `find "$CLAUDE_DIR"`; that's not doc-rot, so skip before the existence check.
    case "$_line" in
      *VAULT*) continue ;;
    esac
    _ref=$(printf '%s\n' "$_line" | grep -oE 'scripts/[A-Za-z0-9_./${}-]+\.(sh|py|js)')
    [ -z "$_ref" ] && continue
    _base=$(basename "$_ref")
    # Resolve against the pre-built whole-fleet set (a wrapper may live in any
    # skill's scripts/). Exclude .git/.scratch already applied when building it.
    if [ -z "${_known_scripts37[$_base]:-}" ]; then
      warn "dead script-pointer in ${_f#"$CLAUDE_DIR"/}: invokes '$_ref' but no '$_base' exists in the fleet (doc-rot — crashes on invoke)"
    fi
  done < <(grep -hoE '(bash|sh|python3|python|node|exec)[[:space:]]+[^|;&]*scripts/[A-Za-z0-9_./${}-]+\.(sh|py|js)' "$_f" 2>/dev/null \
             | sort -u)
done
unset _f _ref _base _known_scripts37
