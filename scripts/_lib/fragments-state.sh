#!/usr/bin/env bash
# fragments-state.sh — sourceable lib shared by hooks/sensors/fragments-arm.sh,
# hooks/sensors/fragments-capture.sh, and hooks/session/fragments-surface.sh,
# so the state layout, sanitizer, and lock discipline can't drift apart
# between the three hooks. Not a CLI -- source it, don't execute it.
#
# Storage: $HOME/.claude/state/mh-fragments/<slug>-<hash>/documents/
#          <sha256(path)[:16]>.json
# <slug>-<hash> from slug_hash() (scripts/_lib/slug-hash.sh), scoped to the
# git repo root, so two different repos never collide. (The now-removed mh:handoff skill's
# handoff-path.sh used the same derivation too; see git history.)
#
# The durable state tree gets the same symlink+ownership defense the
# ephemeral TMPDIR arm marker needs (docs/adr/0003-writing-fragments-
# pointer-capture.md, round-1 finding) -- every directory in the chain is
# checked, not just the base. That defense (hook_safe_dir/hook_owner_ok)
# lives in scripts/_lib/hook-common.sh.

_FRAGMENTS_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Guarded (deep-audit finding, live-reproduced): an unguarded `.` reports
# only its own LAST statement's exit status, so a failed inner source here
# was invisible to every caller's own `. fragments-state.sh 2>/dev/null ||
# exit 0` guard -- sourcing would "succeed" while hook_repo_root et al were
# never actually defined, and the caller would crash instead of exiting.
. "$_FRAGMENTS_LIB_DIR/slug-hash.sh" || return 1
. "$_FRAGMENTS_LIB_DIR/hook-common.sh" || return 1

# fragments_state_dir <root>: this project's mh-fragments dir
# ($HOME/.claude/state/mh-fragments/<slug>-<hash>), ensuring every level of
# the chain exists and passes the symlink/ownership check. Prints nothing
# and returns 1 on any failure (no sha256 tool, root doesn't exist, a
# hijacked directory anywhere in the chain).
fragments_state_dir() {
  local root="$1" slughash base proj
  slughash=$(slug_hash "$root") || return 1
  base="$HOME/.claude/state/mh-fragments"
  hook_safe_dir "$base" || return 1
  proj="$base/$slughash"
  hook_safe_dir "$proj" || return 1
  printf '%s\n' "$proj"
}

# fragments_docs_dir <root>: <project-dir>/documents, same chain-of-checks
# discipline as fragments_state_dir.
fragments_docs_dir() {
  local root="$1" proj docs
  proj=$(fragments_state_dir "$root") || return 1
  docs="$proj/documents"
  hook_safe_dir "$docs" || return 1
  printf '%s\n' "$docs"
}

# fragments_sanitize <value> <label> [maxlen]: redacts the ENTIRE value
# (never a partial escape) if it contains any control character or a
# literal '<' or '>'. Applied identically to both the path and the title at
# every place either is printed (hook 1's known-path injection, hook 3's
# surface block) -- defined once here so the two call sites can't drift
# apart. Only NUL and '/' are actually forbidden in a path component, so a
# path can legitimately contain a literal newline and injection-shaped text
# simultaneously -- it gets the exact same treatment as the title, not a
# lighter one. A clean value is still truncated to maxlen (0 = no limit).
fragments_sanitize() {
  local value="$1" label="$2" maxlen="${3:-0}"
  # -I: stdlib-only, closes the same cwd-shadow-import class as the
  # by-path parsers (deep-audit finding, live-reproduced elsewhere in this
  # sweep with a planted glob.py) -- this function runs in every hook's
  # own cwd, called at every point a path or title is printed.
  python3 -I -c '
import re, sys
value, label, maxlen = sys.argv[1], sys.argv[2], int(sys.argv[3])
if re.search(r"[\x00-\x1f\x7f<>]", value):
    print("[" + label + " redacted -- contains control/markup characters]")
else:
    if maxlen > 0 and len(value) > maxlen:
        value = value[:maxlen] + "..."
    print(value)
' "$value" "$label" "$maxlen" 2>/dev/null
}

# fragments_lock_acquire <lock-dir>: bounded-retry mkdir-based lock -- the
# same atomic test-and-set primitive the claim step in fragments-capture.sh
# already relies on, not a new dependency (flock isn't reliably portable
# across this repo's target shells). Contention is expected only between
# fragments-arm.sh's pointer publish and fragments-surface.sh's stale-
# pointer removal, both very short critical sections, so this budget is
# generous, not tight. Prints nothing; returns 0 on success, 1 if still
# held after the retry budget -- callers must have a defined behavior for
# both outcomes (see docs/adr/0003-... "Pointer publish/sweep lock").
fragments_lock_acquire() {
  local dir="$1" attempts_left=5
  while [ "$attempts_left" -gt 0 ]; do
    mkdir "$dir" 2>/dev/null && return 0
    sleep 0.04
    attempts_left=$((attempts_left - 1))
  done
  return 1
}

fragments_lock_release() {
  rmdir "$1" 2>/dev/null
  return 0
}
