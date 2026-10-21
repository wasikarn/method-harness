#!/usr/bin/env bash
# 11. Orphaned hooks (in filesystem but not in hooks.json / settings.json)
# NOTE: this used to be wrapped in `if [ -f "$SETTINGS" ]; then ... fi`, which
# silently skipped the ENTIRE check body whenever settings.json doesn't exist
# -- true for matt-harness's own flat plugin-mode layout (this repo carries no
# settings.json at all). That meant check 11 never actually ran in real
# pre-commit/pre-push here, independent of any wiring-match precision issue.
# Found 2026-08-19 during a deep-audit falsification test. Fixed by dropping
# the file-existence gate: the per-hook `grep -q "$hook_name" "$SETTINGS"`
# below already degrades correctly to "not found" when $SETTINGS is absent
# (same pattern check 03 already relies on), so plugin-mode hooks still
# correctly skip via the hooks.json/transitive branches.
for f in "$CLAUDE_DIR/hooks"/**/*; do
  [ -f "$f" ] || continue
  case "${f#"$CLAUDE_DIR"/hooks/}" in tests/*|*__pycache__*) continue;; esac
  hook_name=${f##*/}
  # Skip hook libraries (sourced by hooks, not registered as hooks themselves).
  # The _lib.sh prefix matches the existing project scaffold convention used
  # in skills/ and agents/; install.sh's hooks glob *.{sh,py} symlinks it so
  # hook scripts can `source "$(dirname "$0")/_lib.sh"` at runtime.
  # *.md = co-located docs (JOURNAL-SCHEMA.md) — not hooks, never in settings.
  # *.json = plugin hook registry (hooks/hooks.json), not a hook script.
  # *.bak = editor/backup residue (e.g. hooks.json.test.bak from a hook-test
  # session), not a real hook — matches the F1 skip pattern in #3.
  case "$hook_name" in _*.sh|_*.py|*.bak|*.md|*.json) continue;; esac
  # Wired = settings.json (symlink mode) OR hooks/hooks.json (plugin mode) OR
  # named inside a *.sh/*.py dispatch script hooks.json itself points to
  # (transitive, one level — see hook_wired_transitively() in audit.sh,
  # shared with check 03 so the two can't drift).
  grep -q "$hook_name" "$SETTINGS" 2>/dev/null && continue
  grep -q "$hook_name" "$CLAUDE_DIR/hooks/hooks.json" 2>/dev/null && continue
  hook_wired_transitively "$hook_name" && continue
  crit "hook '$hook_name' exists in hooks/ but not wired in settings.json or hooks.json"
done

