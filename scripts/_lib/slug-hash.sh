#!/usr/bin/env bash
# slug-hash.sh: shared <slug>-<hash> derivation for a per-project state dir,
# used by scripts/_lib/fragments-state.sh
# so every consumer lands on the same collision-free naming scheme. (The
# now-removed mh:handoff skill's own helper used this same derivation too;
# see git history.)
#
# slug = basename(realpath(root)) sanitized to [a-zA-Z0-9._-] (runs collapsed
# to a single "-", leading/trailing "-" stripped), falling back to
# "workspace" if that empties it. hash = first 16 hex chars of
# sha256(realpath(root)), shasum falling back to sha256sum.
#
# Prints "<slug>-<hash>" on stdout; returns non-zero (prints nothing) if root
# does not exist or no sha256 tool is available.
slug_hash() {
  local root="$1" real base slug hash
  real=$(cd -P "$root" 2>/dev/null && pwd) || return 1
  base=$(basename "$real")
  slug=$(printf '%s' "$base" | LC_ALL=C sed -E 's/[^a-zA-Z0-9._-]+/-/g; s/^-+//; s/-+$//')
  [ -n "$slug" ] || slug="workspace"
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | shasum -a 256 | cut -c1-16)
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | sha256sum | cut -c1-16)
  else
    return 1
  fi
  printf '%s-%s\n' "$slug" "$hash"
}
