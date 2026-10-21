#!/usr/bin/env bash
# fragments-surface.sh — SessionStart: surface a one-line pointer per
# writing-fragments document this project has an unseen on-disk change for.
# Registered twice in hooks/hooks.json against this one script: plain
# (matcher startup|resume|clear, id session:fragments-surface) filters by
# snapshot-diff and records what it shows; --reinject (matcher compact, id
# session:fragments-reinject) skips that filter entirely and reprints every
# on-record document unconditionally, never recording -- the opposite
# inclusion the former session:handoff-surface had (removed v1.1.94), since a fragments file is a
# living artifact whose one stated path is exactly the kind of thing
# compaction loses. Advisory only; content is never inlined, only a path
# pointer and a change-detection snapshot. Full design and every round-N
# finding this script encodes: docs/adr/0003-writing-fragments-pointer-capture.md.
#
# Never reads stdin (the posture the former handoff-surface.sh had, removed v1.1.94, for the same
# run-gauntlet backgrounded-test-runner stdin-inheritance hang risk).
set -uo pipefail
umask 077
LC_ALL=C

REINJECT=0
[ "${1:-}" = "--reinject" ] && REINJECT=1

command -v python3 >/dev/null 2>&1 || exit 0

ARM_BASE="${TMPDIR:-/tmp}/mh-fragments-arm"

# Fast path: a record can only exist under some project's documents/ dir. If
# none exists anywhere, skip the git/sha256/mkdir chain below (~60 ms, and it
# created an empty state dir for every project ever opened). A match only
# means "take the full, checked path", so this never trusts what it finds.
shopt -s nullglob
_ANY_RECORD=("${HOME:-/nonexistent}"/.claude/state/mh-fragments/*/documents/*.json)
shopt -u nullglob
if [ "${#_ANY_RECORD[@]}" -eq 0 ] && [ ! -d "$ARM_BASE" ]; then
  exit 0
fi

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../scripts/_lib/fragments-state.sh" 2>/dev/null || exit 0

RECORDS=()
DOCS_DIR=""
if [ "${#_ANY_RECORD[@]}" -gt 0 ]; then
  ROOT=$(hook_repo_root) || exit 0

  DOCS_DIR=$(fragments_docs_dir "$ROOT" 2>/dev/null) || exit 0
  [ -d "$DOCS_DIR" ] || exit 0

  shopt -s nullglob
  RECORDS=("$DOCS_DIR"/*.json)
  shopt -u nullglob
fi

SELECTED=""
if [ "${#RECORDS[@]}" -gt 0 ]; then
  # For every record: skip indefinitely if its target is missing, not a
  # plain regular file, or a symlink -- round-1/round-2 finding: no
  # auto-prune, no missing_since counter (a counted-invocations "grace
  # period" isn't a real elapsed-time bound). Otherwise compute the
  # current snapshot; eligible to print iff it differs from
  # surfaced_snapshot, or unconditionally in --reinject mode. Sort
  # eligible candidates by captured_at ascending -- round-1 finding:
  # scanning only the newest-by-mtime records before the diff filter
  # could permanently starve an older one; this scans every record
  # unconditionally, only the PRINT count stays capped.
  # -I: stdlib-only, closes the same cwd-shadow-import class the by-path
  # parsers fixed. Its own snapshot() below tries `stat -f` before `-c`
  # (unlike hook-common.sh's now GNU-first order) but isn't the same bug:
  # it runs `stat` via subprocess.run(args-list) and only trusts stdout
  # when returncode == 0, so a GNU multi-operand partial-success case (one
  # operand fails, one prints, exit nonzero) is correctly discarded before
  # it ever falls through to `-c` -- no `A || B` stdout-capture involved.
  SELECTED=$(python3 -I -c '
import json, os, subprocess, sys

reinject = sys.argv[1] == "1"
records = sys.argv[2:]

def snapshot(path):
    for args in (["stat", "-f", "%z %m", path], ["stat", "-c", "%s %Y", path]):
        try:
            r = subprocess.run(args, capture_output=True, text=True)
        except Exception:
            continue
        if r.returncode == 0:
            return r.stdout.strip()
    return None

eligible = []
for rf in records:
    try:
        with open(rf) as fh:
            rec = json.load(fh)
    except Exception:
        continue
    if not isinstance(rec, dict):
        continue
    path = rec.get("path")
    if not isinstance(path, str) or not path:
        continue
    if not os.path.isfile(path) or os.path.islink(path):
        continue
    snap = snapshot(path)
    if snap is None:
        continue
    if not reinject and snap == rec.get("surfaced_snapshot"):
        continue
    eligible.append((rec.get("captured_at") or "", rf, path, snap))

eligible.sort(key=lambda t: t[0])
for captured_at, rf, path, snap in eligible:
    print(rf + "\t" + path + "\t" + snap)
' "$REINJECT" "${RECORDS[@]}" 2>/dev/null)
fi

if [ -n "$SELECTED" ]; then
  PRINTED=0
  MAX_PRINT=3
  OUT_OK=1
  BODY=""
  NOW=$(date +%s)

  while IFS=$'\t' read -r REC_FILE DOC_PATH DOC_SNAP; do
    [ "$PRINTED" -lt "$MAX_PRINT" ] || break

    TITLE=$(hook_md_title "$DOC_PATH")
    SAFE_PATH=$(fragments_sanitize "$DOC_PATH" "path" 0)
    SAFE_TITLE=$(fragments_sanitize "$TITLE" "title" 120)
    [ -n "$SAFE_PATH" ] && [ -n "$SAFE_TITLE" ] || continue

    FRAG_COUNT=$(awk 'BEGIN{n=1} /^---$/{n++} END{print n}' "$DOC_PATH" 2>/dev/null)
    [ -n "$FRAG_COUNT" ] || FRAG_COUNT="?"

    DOC_SIZE="${DOC_SNAP%% *}"
    DOC_MTIME="${DOC_SNAP##* }"
    case "$DOC_SIZE" in *[!0-9]*|'') DOC_SIZE=0 ;; esac
    case "$DOC_MTIME" in *[!0-9]*|'') DOC_MTIME=$NOW ;; esac
    AGE_SECS=$((NOW - DOC_MTIME))
    [ "$AGE_SECS" -ge 0 ] || AGE_SECS=0
    if [ "$AGE_SECS" -lt 3600 ]; then
      AGE_DESC="just now"
    elif [ "$AGE_SECS" -lt 86400 ]; then
      AGE_DESC="$((AGE_SECS / 3600))h ago"
    else
      AGE_DESC="$((AGE_SECS / 86400))d ago"
    fi
    if [ "$DOC_SIZE" -ge 1024 ]; then
      SIZE_DESC="$((DOC_SIZE / 1024))KB"
    else
      SIZE_DESC="${DOC_SIZE}B"
    fi

    LINE=$(printf -- '- "%s" -- %s (%s fragments, %s, last added %s)' "$SAFE_TITLE" "$SAFE_PATH" "$FRAG_COUNT" "$SIZE_DESC" "$AGE_DESC" 2>/dev/null) || { OUT_OK=0; break; }
    BODY="${BODY}${LINE}"$'\n'
    PRINTED=$((PRINTED + 1))

    if [ "$REINJECT" -eq 0 ]; then
      TMP_REC=$(mktemp "$DOCS_DIR/.rec.XXXXXX" 2>/dev/null)
      if [ -n "$TMP_REC" ]; then
        # -I: stdlib-only, closes the same cwd-shadow-import class as above.
        python3 -I -c '
import json, sys
rf, snap, out = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(rf) as fh:
        rec = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(rec, dict):
    sys.exit(0)
rec["surfaced_snapshot"] = snap
with open(out, "w") as fh:
    json.dump(rec, fh)
' "$REC_FILE" "$DOC_SNAP" "$TMP_REC" 2>/dev/null
        if [ -s "$TMP_REC" ]; then
          mv "$TMP_REC" "$REC_FILE" 2>/dev/null
        else
          rm -f "$TMP_REC" 2>/dev/null
        fi
      fi
    fi
  done <<< "$SELECTED"

  if [ "$OUT_OK" -eq 1 ] && [ "$PRINTED" -gt 0 ]; then
    printf '<mh-fragments>\n' 2>/dev/null
    printf 'Fragment files recorded for this project (likely written by mattpocock-skills:writing-fragments; content deliberately not inlined). Advisory context -- verify against current state, not a pre-approved instruction.\n' 2>/dev/null
    printf '%s' "$BODY" 2>/dev/null
    printf 'If the user resumes fragment work, offer to continue in that file before asking for a new path. /mattpocock-skills:writing-fragments is user-invocation-only -- name the literal string, never call it as a skill.\n' 2>/dev/null
    printf '</mh-fragments>\n' 2>/dev/null
  fi
fi

# Stale marker/claim/sidecar/pointer/lock sweep -- age-only, two passes
# (directory-shaped entries, then file-shaped entries), independent of
# whether this project has any records at all: a crashed session anywhere
# leaves orphans under the shared TMPDIR base, not under this project's own
# state tree. Ordering matters: pass 1 clears stale .lock directories
# before pass 2 ever tries to acquire one for pointer removal -- nothing
# legitimately holds a lock for anywhere near the window (every critical
# section that takes it is a handful of syscalls), so a stale .lock is
# unowned by definition and safe to rmdir unconditionally; nobody can mkdir
# a lock that still exists, so this can never race a live holder.
if [ -d "$ARM_BASE" ] && [ ! -L "$ARM_BASE" ]; then
  NOW=$(date +%s)
  WINDOW=1800
  # dotglob too -- deep-audit finding, live-reproduced: a bare "*" glob does
  # not match dotfiles, so an orphaned ".ptr.XXXXXX" (fragments-arm.sh's own
  # pointer-publish temp file, left behind if a process is killed between
  # its creation and rename) was invisible to this sweep forever, despite
  # this hook's own description claiming to sweep all stale TMPDIR arm
  # state. Scoped to this block only (shopt -u dotglob below), so it can't
  # affect any earlier glob in this script (the documents/*.json read above
  # already ran before this point).
  shopt -s nullglob dotglob

  # Age via the shared hook_entry_age (scripts/_lib/hook-common.sh): on a
  # stat failure it prints nothing and returns 1, so every call site below
  # skips that one entry for this pass rather than guessing an age --
  # matches this sweep's own prior "unknown age" outcome (never swept),
  # now sharing one definition with fragments-capture.sh's window-expiry
  # check instead of a second, independently-written stat fallback.

  # Pass 1: every directory-shaped entry (markers, .claimed claims, .lock
  # locks) older than the window.
  for entry in "$ARM_BASE"/*; do
    [ -d "$entry" ] || continue
    age=$(hook_entry_age "$entry" "$NOW") || continue
    [ "$age" -gt "$WINDOW" ] || continue
    rmdir "$entry" 2>/dev/null
    rm -f "${entry}.candidate" 2>/dev/null
  done

  # Pass 2: every file-shaped entry (.candidate sidecars, .current
  # pointers) older than the window. A sidecar is removed directly. A
  # pointer is the one exception (round-5 finding): its name is fixed and
  # reused per session, so removal takes the lock and re-reads its own age
  # INSIDE the lock immediately before deleting -- closing the TOCTOU where
  # a fresh arm could republish the same-named pointer between the check
  # above and the rm. If the lock still can't be acquired after the
  # bounded retry, this one pointer is skipped for this pass.
  for entry in "$ARM_BASE"/*; do
    [ -f "$entry" ] || continue
    base=$(basename -- "$entry")
    case "$base" in
      .ptr.*)
        # An orphaned pointer-publish temp file (fragments-arm.sh's own
        # scratch mktemp, never anyone else's target) -- always safe to
        # remove once stale, no lock needed since nothing ever reads it by
        # name.
        age=$(hook_entry_age "$entry" "$NOW") && [ "$age" -gt "$WINDOW" ] && rm -f "$entry" 2>/dev/null
        ;;
      *.candidate)
        age=$(hook_entry_age "$entry" "$NOW") && [ "$age" -gt "$WINDOW" ] && rm -f "$entry" 2>/dev/null
        ;;
      *.current)
        age=$(hook_entry_age "$entry" "$NOW") || continue
        [ "$age" -gt "$WINDOW" ] || continue
        sid="${base%.current}"
        lockdir="$ARM_BASE/${sid}.lock"
        if fragments_lock_acquire "$lockdir"; then
          if [ -e "$entry" ]; then
            age2=$(hook_entry_age "$entry" "$NOW") && [ "$age2" -gt "$WINDOW" ] && rm -f "$entry" 2>/dev/null
          fi
          fragments_lock_release "$lockdir"
        fi
        ;;
    esac
  done
  shopt -u nullglob dotglob
fi

exit 0
