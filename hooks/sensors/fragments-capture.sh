#!/usr/bin/env bash
# fragments-capture.sh — PostToolUse (Write|Edit): if this session is armed
# (hooks/sensors/fragments-arm.sh) and this write plausibly targets a
# writing-fragments document, record a durable pointer to it. Never touches,
# copies, or inlines the document's own content -- only a path pointer and a
# change-detection snapshot. Silent by default; MH_FRAGMENTS_DEBUG=1 traces
# each decision point to stderr (why a capture did or didn't fire) without
# touching stdout or the tool result. Advisory only, silent on any doubt.
# Full design: docs/adr/0003-writing-fragments-pointer-capture.md.
set -uo pipefail
umask 077

dbg() { [ "${MH_FRAGMENTS_DEBUG:-}" = "1" ] && printf 'fragments-capture: %s\n' "$1" >&2; }

BASE="${TMPDIR:-/tmp}/mh-fragments-arm"

# Readdir gate before anything else, before stdin is even read: one
# opendir, zero subprocesses, in the overwhelming majority of invocations
# (no session anywhere is armed). Deliberately not session-scoped at this
# stage -- scoping here would require parsing stdin first, exactly the cost
# this gate exists to skip.
shopt -s nullglob
set -- "$BASE"/*
[ $# -gt 0 ] || exit 0
shopt -u nullglob

command -v python3 >/dev/null 2>&1 || { dbg "python3 not found"; exit 0; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../scripts/_lib/fragments-state.sh" 2>/dev/null || { dbg "fragments-state.sh lib missing"; exit 0; }

# Read stdin to a temp file, not a bash variable -- `PAYLOAD=$(cat)`
# command substitution silently drops embedded NUL bytes (compliance-audit
# finding, live-reproduced 2026-09-10), which let a NUL-containing
# session_id get spliced into a different, valid-looking string before
# validation ever saw it. A file preserves every byte, NUL included.
PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fragments-capture-payload.XXXXXX" 2>/dev/null) || exit 0
cat > "$PAYLOAD_FILE" 2>/dev/null

# Parse once, invoked BY PATH -- never `-c` + PYTHONPATH: this hook's
# readdir gate is TMPDIR-global, not project-scoped, so it runs the parse
# for every Write/Edit in every project once ANY session anywhere is armed
# -- a same-named hook_payload.py planted in any one of those cwds could
# shadow the real module under `-c`'s cwd-first sys.path (deep-audit
# finding, live-reproduced; docs/adr/0003-...). Running by path closes it.
# fragments_capture_parse.py: validated session_id (shared predicate,
# scripts/_lib/hook_payload.py -- against the untruncated payload, read
# from $PAYLOAD_FILE so no bash variable capture can drop an embedded NUL
# first), tool_name, cwd, whether content starts with an H1 (Write only --
# Edit payloads carry old_string/new_string, not content), file_path -- 5
# NUL-separated fields (deep-audit finding, live-reproduced: line-numbered
# fields let an embedded newline in `cwd` desync every field after it;
# `read -r -d ''` reads to the next NUL, immune to embedded newlines).
SESSION_ID="" TOOL_NAME="" CWD="" HAS_H1="" FILE_PATH=""
{
  IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' TOOL_NAME
  IFS= read -r -d '' CWD
  IFS= read -r -d '' HAS_H1
  IFS= read -r -d '' FILE_PATH
} < <(python3 -B "$HERE/../../scripts/_lib/fragments_capture_parse.py" < "$PAYLOAD_FILE" 2>/dev/null)
rm -f "$PAYLOAD_FILE" 2>/dev/null

[ -n "$SESSION_ID" ] || { dbg "payload parse failed or empty session_id"; exit 0; }
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) dbg "tool_name '$TOOL_NAME' is not Write/Edit"; exit 0 ;;
esac
[ -n "$FILE_PATH" ] || { dbg "empty file_path"; exit 0; }

# Find this session's live marker via the current-generation pointer, not a
# glob (round-4 finding: "newest live marker by mtime" let a claimed
# generation drop out of the glob, making an older, already-superseded
# marker reselectable). No fallback to scanning for any other marker.
POINTER="$BASE/${SESSION_ID}.current"
[ -f "$POINTER" ] && [ ! -L "$POINTER" ] || { dbg "this session is not armed (no pointer)"; exit 0; }
SUFFIX=$(head -c 64 -- "$POINTER" 2>/dev/null)
case "$SUFFIX" in
  '') dbg "pointer file is empty"; exit 0 ;;
  *[!A-Za-z0-9]*) dbg "pointer suffix has invalid characters"; exit 0 ;;
esac

MARKER="$BASE/${SESSION_ID}.${SUFFIX}"

# Disarm the pointer too once this generation is done: a leftover
# <sid>.current keeps the readdir gate open, so every later Write/Edit paid a
# python parse (11 ms -> 72 ms). Under the arm lock, and only if the pointer
# still names this generation (a fresh arm may have replaced it).
drop_pointer() {
  fragments_lock_acquire "$BASE/$SESSION_ID.lock" || return 0
  [ -f "$POINTER" ] && [ ! -L "$POINTER" ] && [ "$(head -c 64 -- "$POINTER" 2>/dev/null)" = "$SUFFIX" ] \
    && rm -f "$POINTER" 2>/dev/null
  fragments_lock_release "$BASE/$SESSION_ID.lock"
}
[ -d "$MARKER" ] && [ ! -L "$MARKER" ] || { dbg "marker dir missing for suffix $SUFFIX"; exit 0; }

# Window-expiry sweep, scoped to exactly the one generation the pointer
# names -- there is never another candidate marker to consider. On a stat
# failure, hook_entry_age prints nothing and returns 1 -- this must NEVER
# guess an age, since guessing "ancient" would sweep away a live marker on
# a transient stat glitch (the direction fragments-surface.sh's own sweep
# already took the other way; unified here to "skip this write, don't
# sweep, don't guess" for both).
NOW=$(date +%s)
AGE=$(hook_entry_age "$MARKER" "$NOW") || { dbg "could not stat marker age"; exit 0; }
if [ "$AGE" -gt 1800 ]; then
  dbg "arm window expired (age=${AGE}s > 1800s), sweeping"
  rmdir "$MARKER" 2>/dev/null
  rm -f "${MARKER}.candidate" 2>/dev/null
  drop_pointer
  exit 0
fi

CANDIDATE_FILE="${MARKER}.candidate"

# Plausibility check. Candidate present -> match iff file_path resolves to
# the same canonical path as the candidate text; no heuristic fallback runs
# at all in this case. Candidate absent -> fall back to the heuristic
# (round-1/2/3 findings: this is the only tier where an unrelated .md/H1
# write is accepted, a named gap, not a bug).
CANONICAL_TARGET=""
if [ -f "$FILE_PATH" ] || [ -e "$FILE_PATH" ]; then
  CANONICAL_TARGET=$(cd -P -- "$(dirname -- "$FILE_PATH")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename -- "$FILE_PATH")")
fi
[ -n "$CANONICAL_TARGET" ] || CANONICAL_TARGET="$FILE_PATH"

MATCH=0
if [ -s "$CANDIDATE_FILE" ] && [ ! -L "$CANDIDATE_FILE" ]; then
  CAND_TEXT=$(cat -- "$CANDIDATE_FILE" 2>/dev/null)
  CAND_RESOLVED="$CAND_TEXT"
  # ~ expansion for a typed "~/notes/x.md" candidate -- the shell never
  # expands the sidecar file's own contents, so this is done explicitly.
  # shellcheck disable=SC2088  # this is a case PATTERN match, not a tilde
  # left unexpanded inside a quoted expansion -- $HOME is used on the RHS.
  case "$CAND_TEXT" in
    '~/'*) CAND_RESOLVED="$HOME/${CAND_TEXT#~/}" ;;
    '~') CAND_RESOLVED="$HOME" ;;
  esac
  # A relative candidate (e.g. "./frags.md", typed with no leading /) must
  # anchor on the payload's own $CWD, not this process's ambient cwd -- the
  # two are not guaranteed to be the same thing, and ROOT resolution above
  # already uses $CWD as its source of truth for exactly this reason.
  # Deep-audit finding, live-reproduced: without this, a relative candidate
  # silently failed to match a real write to the exact intended file.
  case "$CAND_RESOLVED" in
    /*) : ;;
    *) [ -n "$CWD" ] && CAND_RESOLVED="$CWD/$CAND_RESOLVED" ;;
  esac
  if [ -e "$CAND_RESOLVED" ]; then
    CAND_CANONICAL=$(cd -P -- "$(dirname -- "$CAND_RESOLVED")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename -- "$CAND_RESOLVED")")
  else
    CAND_CANONICAL="$CAND_RESOLVED"
  fi
  [ -n "$CAND_CANONICAL" ] && [ "$CAND_CANONICAL" = "$CANONICAL_TARGET" ] && MATCH=1
else
  # Heuristic tier: absolute path, .md/.markdown extension, not under
  # $HOME/.claude/ or $CLAUDE_PLUGIN_ROOT, H1-required for Write, extension
  # alone sufficient for Edit.
  case "$CANONICAL_TARGET" in
    /*) : ;;
    *) CANONICAL_TARGET="" ;;
  esac
  case "$CANONICAL_TARGET" in
    *.md|*.markdown) : ;;
    *) CANONICAL_TARGET="" ;;
  esac
  if [ -n "$CANONICAL_TARGET" ]; then
    CLAUDE_DIR_REAL=$(cd -P -- "$HOME/.claude" 2>/dev/null && pwd)
    PLUGIN_ROOT_REAL=""
    [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && PLUGIN_ROOT_REAL=$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd)
    case "$CANONICAL_TARGET" in
      "$CLAUDE_DIR_REAL"/*) CANONICAL_TARGET="" ;;
    esac
    if [ -n "$PLUGIN_ROOT_REAL" ]; then
      case "$CANONICAL_TARGET" in
        "$PLUGIN_ROOT_REAL"/*) CANONICAL_TARGET="" ;;
      esac
    fi
  fi
  if [ -n "$CANONICAL_TARGET" ]; then
    case "$TOOL_NAME" in
      Write) [ "$HAS_H1" = "1" ] && MATCH=1 ;;
      Edit)  MATCH=1 ;;
    esac
  fi
fi

if [ "$MATCH" -ne 1 ]; then
  dbg "no match: candidate=$([ -s "$CANDIDATE_FILE" ] && echo present || echo absent) target=$CANONICAL_TARGET"
  exit 0
fi

# Claim: rename $MARKER -> ${MARKER}.claimed. Since $MARKER already carries
# this invocation's own unique mktemp suffix, ${MARKER}.claimed can never
# coincide with any other invocation's claim name, so this rename can never
# land on a pre-existing directory (round-3 finding, closed structurally by
# round-3's per-invocation unique naming). Exactly one concurrent process
# wins; losers see the source gone and exit before ever attempting a
# publish. The pointer itself is never touched here -- it still names the
# same suffix, so a later write that reads it will find $MARKER gone and
# correctly treat this generation as no-longer-armed, never falling back to
# any other generation.
CLAIMED="${MARKER}.claimed"
mv "$MARKER" "$CLAIMED" 2>/dev/null || { dbg "lost claim race for $MARKER"; exit 0; }

# Publish: create-only, the exact --publish sequence the former handoff-path.sh used (removed v1.1.94).
# Project root must be resolved to the git repo root (matching
# fragments-arm.sh, as the former handoff-path.sh did) before scoping -- using the raw cwd
# directly would scope this record to a subdirectory instead of the
# project root whenever the write happened from one. An empty $CWD must
# fail closed, not fall back to hook_repo_root's own ambient-cwd
# resolution -- that would scope this record to whatever directory the
# hook process happens to run in, not this payload's project.
ROOT=""
[ -n "$CWD" ] && ROOT=$(hook_repo_root "$CWD" 2>/dev/null)
DOCS_DIR=""
[ -n "$ROOT" ] && DOCS_DIR=$(fragments_docs_dir "$ROOT" 2>/dev/null)
if [ -z "$DOCS_DIR" ]; then
  dbg "could not resolve docs dir for root '$ROOT'"
  mv "$CLAIMED" "$MARKER" 2>/dev/null
  exit 0
fi

# -I: stdlib-only, closes the same cwd-shadow-import class fixed for the
# by-path parser (see its own header comment) for this inline call too.
DOC_ID=$(python3 -I -c '
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])
' "$CANONICAL_TARGET" 2>/dev/null)
[ -n "$DOC_ID" ] || { dbg "doc_id hash failed"; mv "$CLAIMED" "$MARKER" 2>/dev/null; exit 0; }

DEST="$DOCS_DIR/$DOC_ID.json"
if [ -e "$DEST" ]; then
  # Already captured -- nothing to overwrite, never clobber an existing
  # surfaced_snapshot. Counts as success.
  dbg "already captured at $DEST"
  rm -f "${MARKER}.candidate" 2>/dev/null
  rmdir "$CLAIMED" 2>/dev/null
  exit 0
fi

TMP_DOC=$(mktemp "$DOCS_DIR/.doc.XXXXXX" 2>/dev/null)
if [ -z "$TMP_DOC" ]; then
  dbg "mktemp failed in $DOCS_DIR"
  mv "$CLAIMED" "$MARKER" 2>/dev/null
  exit 0
fi

CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# -I: stdlib-only, same cwd-shadow-import closure as above.
python3 -I -c '
import json, sys
path, sid, ts, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
doc = {"version": 1, "path": path, "captured_at": ts, "captured_session": sid, "surfaced_snapshot": None}
with open(out, "w") as f:
    json.dump(doc, f)
' "$CANONICAL_TARGET" "$SESSION_ID" "$CAPTURED_AT" "$TMP_DOC" 2>/dev/null
if [ ! -s "$TMP_DOC" ]; then
  dbg "json write to $TMP_DOC failed or empty"
  rm -f "$TMP_DOC" 2>/dev/null
  mv "$CLAIMED" "$MARKER" 2>/dev/null
  exit 0
fi

if [ -e "$DEST" ]; then
  # Lost a race to another writer for the same path -- fine, already
  # captured.
  dbg "lost publish race for $DEST, already captured"
  rm -f "$TMP_DOC" 2>/dev/null
  rm -f "${MARKER}.candidate" 2>/dev/null
  rmdir "$CLAIMED" 2>/dev/null
  exit 0
fi
mv -n "$TMP_DOC" "$DEST" 2>/dev/null
if [ -e "$TMP_DOC" ]; then
  # mv -n silently no-op'd -- genuine publish failure. Restore this exact
  # invocation's arm (sidecar untouched) so a later qualifying write in the
  # same window can retry it.
  dbg "mv -n to $DEST no-op'd, publish failed"
  rm -f "$TMP_DOC" 2>/dev/null
  mv "$CLAIMED" "$MARKER" 2>/dev/null
  exit 0
fi
if [ -f "$DEST" ] && [ ! -L "$DEST" ]; then
  chmod 600 "$DEST" 2>/dev/null
fi

# Success: fully and correctly disarmed for this invocation.
dbg "captured $DEST"
rm -f "${MARKER}.candidate" 2>/dev/null
rmdir "$CLAIMED" 2>/dev/null
drop_pointer

exit 0
