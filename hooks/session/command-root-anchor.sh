#!/usr/bin/env bash
# command-root-anchor.sh — matcher-less SessionStart hook
#
# Commands are single markdown files with no official ${CLAUDE_COMMAND_DIR}
# variable. To keep command bash blocks from relying on repo-relative paths
# (which break when the plugin runs in a foreign project CWD), this hook
# bridges the hook-only ${CLAUDE_PLUGIN_ROOT} variable into the session as
# MH_PLUGIN_ROOT via CLAUDE_ENV_FILE.
#
# Command markdown should reference bundled scripts with:
#   bash "${MH_PLUGIN_ROOT}/scripts/..."
#   python3 "${MH_PLUGIN_ROOT}/scripts/..."
#   PYTHONPATH="${MH_PLUGIN_ROOT}" python3 -c "from scripts.task_board_lib import ..."
#
# This is the only place the hook-only ${CLAUDE_PLUGIN_ROOT} is intentionally
# exported to the broader session; command bodies should not name
# ${CLAUDE_PLUGIN_ROOT} directly.
#
# Restored 2026-07-01: deleted in the v0.6.0 "reset: rebuild from scratch" cut
# (c4521023) without recreating this export, leaving ~17 files' worth of
# ${MH_PLUGIN_ROOT} references pointing at an unset variable. Fails safe:
# exits 0 silently if plugin root or env file is unavailable.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$ROOT" ] || exit 0
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

# Normalize: strip trailing slash so command prose can always use
# "${MH_PLUGIN_ROOT}/scripts/..." without producing double slashes.
ROOT="${ROOT%/}"

# GH #783: Claude Code keeps one sessionstart-hook-<n>.sh per hook position and
# does not clear them on resume; after a plugin update shifts the hook order, a
# stale sibling sourced later would win with the old root. Drop the export from
# the other regular files in that dir (atomic temp+mv); any problem leaves the
# file alone.
ENV_DIR="$(dirname "$CLAUDE_ENV_FILE")"
for f in "$ENV_DIR"/sessionstart-hook-*.sh; do
  [ "$f" -ef "$CLAUDE_ENV_FILE" ] && continue
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  /usr/bin/grep -q '^export MH_PLUGIN_ROOT=' "$f" || continue
  tmp="$(mktemp "$ENV_DIR/.mh-anchor.XXXXXX")" || continue
  if /usr/bin/grep -v '^export MH_PLUGIN_ROOT=' "$f" > "$tmp"; [ "$?" -le 1 ] && mv -f "$tmp" "$f"; then :
  else unlink "$tmp" 2>/dev/null; fi  # fallback: temp may already be gone
done

printf 'export MH_PLUGIN_ROOT=%q\n' "$ROOT" >> "$CLAUDE_ENV_FILE"
