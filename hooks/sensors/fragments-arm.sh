#!/usr/bin/env bash
# fragments-arm.sh — UserPromptSubmit: arm a per-invocation marker when the
# user's prompt invokes writing-fragments (standalone /writing-fragments; the
# mattpocock-skills plugin does not load it), so a qualifying
# write shortly after can be captured as a pointer
# (hooks/sensors/fragments-capture.sh). Advisory only, silent on any doubt.
# Full design and every round-N finding this script encodes:
# docs/adr/0003-writing-fragments-pointer-capture.md.
#
# UserPromptSubmit is the mechanism that replaced an originally-planned
# PreToolUse:Skill hook -- confirmed dead for a user-typed slash command
# (never produces a Skill tool_use event at all, regardless of
# disable-model-invocation). See the ADR for the full evidence chain.
#
# Reads stdin once, to a temp file -- unlike every SessionStart hook in
# this repo, UserPromptSubmit hooks are expected to read it; there is no
# backgrounded-test-runner stdin-inheritance hang risk here the way there is
# for SessionStart under scripts/run-gauntlet.sh. A temp file, not a bash
# variable: `PAYLOAD=$(cat)` command substitution silently drops embedded
# NUL bytes (compliance-audit finding, live-reproduced 2026-09-10), which
# let a NUL-containing session_id get spliced into a different, valid-
# looking string before scripts/_lib/hook_payload.py's validation ever saw
# it. A file preserves every byte, NUL included.
#
# A non-zero exit (or exit 2) here BLOCKS the user's own prompt -- every
# failure path below is therefore a silent `exit 0`, never anything else.
set -uo pipefail
umask 077

command -v python3 >/dev/null 2>&1 || exit 0

PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fragments-arm-payload.XXXXXX" 2>/dev/null) || exit 0
cat > "$PAYLOAD_FILE" 2>/dev/null

# Cost gate: one cheap `grep -F` before the real python3 parse below --
# no longer a pure-bash check (it was, before the switch to a payload
# file above), but still far cheaper than a python3 spawn on the
# overwhelming majority of ordinary prompts. grep -F treats NUL bytes as
# opaque data (no crash), and this is a heuristic fast-path only, never a
# security boundary -- the real, validated parse happens in python3
# below, fed from this same untouched file. A false positive here is
# rechecked properly by the real regex below; a false negative is
# impossible since the literal string must appear in the JSON prompt text
# for a real match to exist at all.
if ! grep -qF 'writing-fragments' "$PAYLOAD_FILE" 2>/dev/null; then
  rm -f "$PAYLOAD_FILE" 2>/dev/null
  exit 0
fi

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../scripts/_lib/fragments-state.sh" 2>/dev/null || { rm -f "$PAYLOAD_FILE" 2>/dev/null; exit 0; }

# Single python3 call, invoked BY PATH -- never `-c` + PYTHONPATH, which
# puts the hook's own cwd (the user's project) ahead of PYTHONPATH on
# sys.path and lets a same-named hook_payload.py planted there shadow the
# real module, executing arbitrary code and forging a validated session_id
# (deep-audit finding, live-reproduced; docs/adr/0003-...). Running by path
# puts scripts/_lib/ itself first on sys.path instead.
# fragments_arm_parse.py: validates session_id via the shared predicate
# (scripts/_lib/hook_payload.py -- character-class + ./.. rejection,
# against the untruncated payload, read from $PAYLOAD_FILE so no bash
# variable capture can drop an embedded NUL first -- compliance-audit
# finding, live-reproduced 2026-09-10), matches the skill-invocation regex
# against `prompt`, and extracts an optional candidate path from whatever
# follows it in the same prompt. Output: session_id, match flag, cwd,
# candidate -- 4 NUL-separated fields (deep-audit finding, live-reproduced:
# line-numbered fields let an embedded newline in `cwd` desync every field
# after it; `read -r -d ''` reads to the next NUL, immune to embedded newlines).
SESSION_ID="" MATCHED="" CWD="" CANDIDATE=""
{
  IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' MATCHED
  IFS= read -r -d '' CWD
  IFS= read -r -d '' CANDIDATE
} < <(python3 -B "$HERE/../../scripts/_lib/fragments_arm_parse.py" < "$PAYLOAD_FILE" 2>/dev/null)
rm -f "$PAYLOAD_FILE" 2>/dev/null

[ "$MATCHED" = "1" ] && [ -n "$SESSION_ID" ] || exit 0

# Base directory: no trailing slash (the symlink-check-defeat lesson
# handoff-nudge.sh's own compliance-audit round found).
BASE="${TMPDIR:-/tmp}/mh-fragments-arm"
mkdir -p "$BASE" 2>/dev/null
[ -d "$BASE" ] || exit 0
[ ! -L "$BASE" ] || exit 0

hook_owner_ok "$BASE" || exit 0

# Arm marker: every invocation gets its own uniquely-named marker
# (mktemp -d's random suffix), so no two invocations -- however they
# overlap in time or however one of them fails -- can ever share a name to
# collide over (round-3 finding: a fixed-name marker/claim let `mv` nest a
# new claim inside an old one instead of failing). Kept empty (nothing
# written inside it) so rmdir/rename against it never fails on "not empty."
MARKER=$(mktemp -d "$BASE/${SESSION_ID}.XXXXXX" 2>/dev/null) || exit 0
SUFFIX="${MARKER##*.}"

# Candidate sidecar, a sibling FILE sharing the same unique suffix -- never
# nested inside the marker (a round-2 finding: storing it as a file inside
# the marker directory broke every rmdir call). Written -- fully, including
# leaving it absent when no candidate was typed -- before the pointer
# publish below, which is the step that makes this generation visible to
# Hook 2 at all (round-4 finding: a generation must never be selectable
# before its candidate, if any, has finished writing).
if [ -n "$CANDIDATE" ]; then
  printf '%s' "$CANDIDATE" > "${MARKER}.candidate" 2>/dev/null
fi

# Current-generation pointer, published LAST -- only after the marker and
# its optional candidate are both fully written. A plain file (never a
# directory), so `mv` onto it always replaces atomically with no risk of
# the directory-nesting hazard a fixed-name marker/claim had in earlier
# rounds (round-4 finding: Hook 2 must select only the ONE generation this
# pointer names, never fall back to scanning for any other marker).
LOCKDIR="$BASE/${SESSION_ID}.lock"
POINTER="$BASE/${SESSION_ID}.current"
TMP_PTR=$(mktemp "$BASE/.ptr.XXXXXX" 2>/dev/null) || { rmdir "$MARKER" 2>/dev/null; rm -f "${MARKER}.candidate" 2>/dev/null; exit 0; }
printf '%s' "$SUFFIX" > "$TMP_PTR" 2>/dev/null
if fragments_lock_acquire "$LOCKDIR"; then
  mv "$TMP_PTR" "$POINTER" 2>/dev/null
  fragments_lock_release "$LOCKDIR"
else
  # Lock still contended after the bounded retry (round-5 finding: the
  # pointer sweep and a fresh publish share this lock). Arming must never
  # hang or silently fail outright -- publish anyway. The residual (a sweep
  # racing this exact publish, unowned by a live process) is accepted and
  # bounded, same posture as the rest of this design.
  mv "$TMP_PTR" "$POINTER" 2>/dev/null
fi

# Best-effort known-path injection below: never blocks arming above, and
# any failure here (no git repo, no existing record) is silent. An empty
# $CWD must fail closed here, not fall back to hook_repo_root's own
# ambient-cwd resolution -- that would scope this to whatever directory the
# hook process happens to run in, not this payload's project.
[ -n "$CWD" ] || exit 0
ROOT=$(hook_repo_root "$CWD") || exit 0

DOCS_DIR=$(fragments_docs_dir "$ROOT" 2>/dev/null) || exit 0
[ -d "$DOCS_DIR" ] || exit 0

# Most-recently-captured record on file for this project, if any -- read
# via python3 so a malformed record can never crash this script. -I (deep-
# audit finding, live-reproduced with a planted glob.py): this is stdlib-
# only, and `-c` alone puts the hook's own cwd first on sys.path, letting a
# same-named glob.py/json.py/os.py planted there shadow the real module and
# run arbitrary code -- -I drops cwd (and site-packages) from sys.path.
KNOWN=$(python3 -I -c '
import glob, json, os, sys
docs_dir = sys.argv[1]
best = None
for f in glob.glob(os.path.join(docs_dir, "*.json")):
    try:
        with open(f) as fh:
            rec = json.load(fh)
    except Exception:
        continue
    if not isinstance(rec, dict):
        continue
    path = rec.get("path")
    captured_at = rec.get("captured_at")
    if not isinstance(path, str) or not path:
        continue
    key = captured_at if isinstance(captured_at, str) else ""
    if best is None or key > best[1]:
        best = (path, key)
if best:
    print(best[0])
' "$DOCS_DIR" 2>/dev/null)
[ -n "$KNOWN" ] || exit 0
[ -f "$KNOWN" ] && [ ! -L "$KNOWN" ] || exit 0

TITLE=$(hook_md_title "$KNOWN")

SAFE_PATH=$(fragments_sanitize "$KNOWN" "path" 0)
SAFE_TITLE=$(fragments_sanitize "$TITLE" "title" 120)
[ -n "$SAFE_PATH" ] && [ -n "$SAFE_TITLE" ] || exit 0

printf '<mh-fragments-known>\n' 2>/dev/null
printf 'A writing-fragments file already exists for this project: %s ("%s").\n' "$SAFE_PATH" "$SAFE_TITLE" 2>/dev/null
printf 'Offer to continue there before asking the user where to save. Advisory only -- the user decides.\n' 2>/dev/null
printf '</mh-fragments-known>\n' 2>/dev/null

exit 0
