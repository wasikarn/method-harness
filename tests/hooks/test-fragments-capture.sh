#!/usr/bin/env bash
# Unit tests for hooks/sensors/fragments-capture.sh — the PostToolUse
# (Write|Edit) hook that records a durable pointer when an armed session's
# write plausibly targets a writing-fragments document. Every non-obvious
# case here traces back to a specific Codex round-N finding; see
# docs/adr/0003-writing-fragments-pointer-capture.md for the full history.
# Run standalone: bash tests/hooks/test-fragments-capture.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/sensors/fragments-capture.sh"
ARM_HOOK="$ROOT/hooks/sensors/fragments-arm.sh"
. "$ROOT/tests/_lib/harness.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

FAKE_HOME=$(mktemp -d)
trap _cleanup_trash EXIT

docs_dir_for() {
  local root="$1" sh
  sh=$(bash -c ". '$ROOT/scripts/_lib/slug-hash.sh'; slug_hash '$root'")
  printf '%s/.claude/state/mh-fragments/%s/documents' "$FAKE_HOME" "$sh"
}
arm() { # arm <session_id> <tmpdir> <repo> [prompt-suffix]
  local sid="$1" t="$2" repo="$3" suffix="${4:-}"
  printf '{"session_id":"%s","cwd":"%s","prompt":"/writing-fragments %s"}' "$sid" "$repo" "$suffix" \
    | HOME="$FAKE_HOME" TMPDIR="$t" bash "$ARM_HOOK" >/dev/null 2>/dev/null
}
capture() { # capture <session_id> <tmpdir> <repo> <tool_name> <file_path> <content-or-empty>
  local sid="$1" t="$2" repo="$3" tool="$4" fp="$5" content="${6:-}"
  if [ "$tool" = "Write" ]; then
    printf '{"session_id":"%s","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$sid" "$repo" "$fp" "$content" \
      | HOME="$FAKE_HOME" TMPDIR="$t" bash "$HOOK"
  else
    printf '{"session_id":"%s","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' "$sid" "$repo" "$fp" \
      | HOME="$FAKE_HOME" TMPDIR="$t" bash "$HOOK"
  fi
}

# --- unarmed session: readdir gate keeps this silent and non-capturing ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
printf '# T\nfrag\n' > "$REPO/x.md"
OUT=$(capture "unarmed" "$T" "$REPO" Write "$REPO/x.md" '# T\\nfrag\\n' 2>"$T/err")
DOCS=$(docs_dir_for "$REPO")
if [ -z "$OUT" ] && [ ! -s "$T/err" ] && [ -z "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "an unarmed session's write is silent, nothing captured"
else
  bad "unarmed write should not capture: out='$OUT' json='$(find "$DOCS" -name '*.json' 2>/dev/null)'"
fi

# --- candidate present, exact canonical match -> captured, marker cleaned up ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c1" "$T" "$REPO" "$REPO/frags.md"
printf '# Title\nfrag one\n' > "$REPO/frags.md"
capture "c1" "$T" "$REPO" Write "$REPO/frags.md" '# Title\\nfrag one\\n' >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
REC=$(find "$DOCS" -name '*.json' 2>/dev/null | head -n1)
MARKERS_LEFT=$(find "$T/mh-fragments-arm" -maxdepth 1 -name 'c1.*' ! -name 'c1.current' 2>/dev/null)
if [ -n "$REC" ] && [ ! -s "$T/err" ] && [ -z "$MARKERS_LEFT" ]; then
  ok "candidate present + exact match: captured, marker fully cleaned up"
else
  bad "expected a capture with cleanup: rec='$REC' leftover='$MARKERS_LEFT' err='$(cat "$T/err")'"
fi

# --- candidate present, a DIFFERENT file written -> no heuristic fallback,
# never captured, marker stays armed ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c2" "$T" "$REPO" "$REPO/frags.md"
printf '# Unrelated\nfrag\n' > "$REPO/README.md"
capture "c2" "$T" "$REPO" Write "$REPO/README.md" '# Unrelated\\nfrag\\n' >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
MARKER=$(find "$T/mh-fragments-arm" -maxdepth 1 -type d -name 'c2.*' 2>/dev/null)
# NOTE: $DOCS existing as a directory is NOT itself proof of a capture --
# fragments-arm.sh's own best-effort known-path lookup calls
# fragments_docs_dir too, which creates the (empty) documents/ dir as a
# side effect of just checking for an existing record. The only real proof
# of a capture is a *.json file inside it.
if [ -z "$(find "$DOCS" -name '*.json' 2>/dev/null)" ] && [ -n "$MARKER" ] && [ ! -s "$T/err" ]; then
  ok "candidate present + unrelated write: no heuristic fallback, not captured, still armed"
else
  bad "expected no capture with candidate mismatch: json='$(find "$DOCS" -name '*.json' 2>/dev/null)' marker='$MARKER'"
fi
# the real candidate path still captures afterward
printf '# Title\nfrag\n' > "$REPO/frags.md"
capture "c2" "$T" "$REPO" Write "$REPO/frags.md" '# Title\\nfrag\\n' >/dev/null 2>/dev/null
DOCS=$(docs_dir_for "$REPO")
if [ -d "$DOCS" ] && [ -n "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "a later write to the actual candidate path still captures"
else
  bad "the real candidate write should still have captured after the mismatch"
fi

# --- no candidate, heuristic tier: Write with H1 to a .md file captures ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c3" "$T" "$REPO"
printf '# Heuristic\nfrag\n' > "$REPO/notes.md"
capture "c3" "$T" "$REPO" Write "$REPO/notes.md" '# Heuristic\\nfrag\\n' >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
if [ -d "$DOCS" ] && [ -n "$(find "$DOCS" -name '*.json' 2>/dev/null)" ] && [ ! -s "$T/err" ]; then
  ok "no candidate, Write with H1 to .md: heuristic tier captures"
else
  bad "expected heuristic capture: docs_exists=$([ -d "$DOCS" ] && echo yes || echo no)"
fi

# --- no candidate, Edit to any .md file captures too -- an accepted,
# explicitly-named false-positive risk of the heuristic tier ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c4" "$T" "$REPO"
printf 'no h1 here\n' > "$REPO/README.md"
capture "c4" "$T" "$REPO" Edit "$REPO/README.md" >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
if [ -d "$DOCS" ] && [ -n "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "no candidate, Edit to unrelated .md: heuristic tier captures (accepted gap)"
else
  bad "expected the accepted-gap heuristic capture on an Edit .md"
fi

# --- no candidate, Write WITHOUT an H1 to a .md file does not capture ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c5" "$T" "$REPO"
printf 'no h1\n' > "$REPO/notes.md"
capture "c5" "$T" "$REPO" Write "$REPO/notes.md" 'no h1\\n' >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
if [ ! -d "$DOCS" ] || [ -z "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "no candidate, Write without an H1: not captured"
else
  bad "a Write without an H1 should not pass the heuristic tier"
fi

# --- non-.md write never captures regardless of candidate ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c6" "$T" "$REPO"
printf 'const x = 1;\n' > "$REPO/index.js"
capture "c6" "$T" "$REPO" Write "$REPO/index.js" 'const x = 1;\\n' >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
if [ ! -d "$DOCS" ] || [ -z "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "a non-.md write never captures"
else
  bad "a .js write should never be captured by the heuristic"
fi

# --- round-4 regression: arm A, then arm B (re-invoke), claim B via a
# capture -- a LATER write must never fall back to capturing against A,
# since the pointer only ever names one generation at a time ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c7" "$T" "$REPO" "$REPO/a.md"
arm "c7" "$T" "$REPO" "$REPO/b.md"
printf '# B\nfrag\n' > "$REPO/b.md"
capture "c7" "$T" "$REPO" Write "$REPO/b.md" '# B\\nfrag\\n' >/dev/null 2>/dev/null
DOCS=$(docs_dir_for "$REPO")
COUNT_AFTER_B=$(find "$DOCS" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
printf '# A\nfrag\n' > "$REPO/a.md"
capture "c7" "$T" "$REPO" Write "$REPO/a.md" '# A\\nfrag\\n' >/dev/null 2>"$T/err"
COUNT_AFTER_A_ATTEMPT=$(find "$DOCS" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT_AFTER_B" -eq 1 ] && [ "$COUNT_AFTER_A_ATTEMPT" -eq 1 ] && [ ! -s "$T/err" ]; then
  ok "round-4 regression: arm A -> arm B -> claim B -> write A does not capture against the superseded A"
else
  bad "stale generation A was reselected: after_b=$COUNT_AFTER_B after_a_attempt=$COUNT_AFTER_A_ATTEMPT"
fi

# --- an expired marker (older than the arm window) is swept and never
# captures ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c8" "$T" "$REPO" "$REPO/frags.md"
MARKER=$(find "$T/mh-fragments-arm" -maxdepth 1 -type d -name 'c8.*' 2>/dev/null | head -n1)
OLD_TS=$(( $(date +%s) - 3600 ))
touch -t "$(date -r "$OLD_TS" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$OLD_TS" +%Y%m%d%H%M.%S)" "$MARKER" 2>/dev/null
printf '# Title\nfrag\n' > "$REPO/frags.md"
capture "c8" "$T" "$REPO" Write "$REPO/frags.md" '# Title\\nfrag\\n' >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
if [ ! -d "$DOCS" ] || [ -z "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "an expired marker (past the arm window) is swept, never captures"
else
  bad "an expired marker should never capture: docs='$(find "$DOCS" -name '*.json' 2>/dev/null)'"
fi

# --- deep-audit regression: a RELATIVE typed candidate ("./frags.md") must
# anchor on the payload's own cwd, not whatever cwd the hook process
# happens to run in -- live-reproduced capturing nothing when the two
# diverge before this fix ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c9" "$T" "$REPO" "./frags.md"
printf '# Title\nfrag\n' > "$REPO/frags.md"
OUT9=$( (cd /tmp && printf '{"session_id":"c9","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/frags.md","content":"# Title\\nfrag\\n"}}' "$REPO" "$REPO" \
  | HOME="$FAKE_HOME" TMPDIR="$T" bash "$HOOK") 2>"$T/err")
DOCS=$(docs_dir_for "$REPO")
if [ -n "$(find "$DOCS" -name '*.json' 2>/dev/null)" ] && [ ! -s "$T/err" ]; then
  ok "a relative candidate path anchors on the payload's cwd, captures even when the hook process's own cwd differs"
else
  bad "relative candidate did not capture: out='$OUT9' docs='$(find "$DOCS" -name '*.json' 2>/dev/null)'"
fi

# --- hook_entry_age direction regression: a stat failure while checking
# the marker's age must NEVER be treated as "ancient" (which would sweep
# away a live, still-in-window marker on a transient stat glitch). It must
# skip this one write and leave the marker armed for a retry. Honesty-
# verified: red against the pre-fix `|| echo 0` fallback (which computed a
# huge age and rmdir'd the live marker here), green after switching to
# hook_entry_age's fail-nothing-guessed contract. ---
STATSHIM=$(fresh_tmpdir)
cat > "$STATSHIM/stat" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STATSHIM/stat"

T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c10" "$T" "$REPO" "$REPO/frags.md"
MARKER=$(find "$T/mh-fragments-arm" -maxdepth 1 -type d -name 'c10.*' 2>/dev/null | head -n1)
printf '# Title\nfrag\n' > "$REPO/frags.md"

printf '{"session_id":"c10","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/frags.md","content":"# Title\\nfrag\\n"}}' "$REPO" "$REPO" \
  | HOME="$FAKE_HOME" TMPDIR="$T" PATH="$STATSHIM:$PATH" bash "$HOOK" >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
if [ -d "$MARKER" ] && [ -z "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "a stat failure during the age check skips this write and leaves the marker armed, never sweeps it"
else
  bad "stat failure should skip+preserve, not sweep: marker_exists=$([ -d "$MARKER" ] && echo yes || echo no) docs='$(find "$DOCS" -name '*.json' 2>/dev/null)'"
fi

# The marker must still be usable normally once stat works again.
capture "c10" "$T" "$REPO" Write "$REPO/frags.md" '# Title\\nfrag\\n' >/dev/null 2>"$T/err2"
if [ -n "$(find "$DOCS" -name '*.json' 2>/dev/null)" ]; then
  ok "the preserved marker still captures normally once the stat glitch is gone"
else
  bad "preserved marker did not capture on retry: err='$(cat "$T/err2" 2>/dev/null)'"
fi

# --- deep-audit finding, live-reproduced: fragments_capture_parse.py must
# be invoked BY PATH (never `-c` + PYTHONPATH). This hook's own readdir
# gate is TMPDIR-global, so it runs the parse for every Write/Edit in every
# project once anything anywhere is armed -- a decoy hook_payload.py
# planted in ANY such project's cwd could shadow the real module under the
# old `-c`+PYTHONPATH invocation. Confirmed live on that pre-fix version:
# the decoy's forged session_id was actually used. Run the hook from a cwd
# containing exactly that decoy and assert the real armed session (c11)
# still captures correctly, with no hijacked record and no decoy stderr. ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c11" "$T" "$REPO" "$REPO/frags.md"
printf '# Title\nfrag\n' > "$REPO/frags.md"
DECOY_CWD=$(fresh_tmpdir)
cat > "$DECOY_CWD/hook_payload.py" <<'PYEOF'
import sys
def validate_session_id(v):
    print("PWNED", file=sys.stderr)
    return "hijacked-session-id"
PYEOF
OUT=$( (cd "$DECOY_CWD" && printf '{"session_id":"c11","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/frags.md","content":"# Title\\nfrag\\n"}}' "$REPO" "$REPO" \
  | HOME="$FAKE_HOME" TMPDIR="$T" bash "$HOOK") 2>"$T/err" )
DOCS=$(docs_dir_for "$REPO")
if [ -n "$(find "$DOCS" -name '*.json' 2>/dev/null)" ] && ! /usr/bin/grep -q 'PWNED' "$T/err"; then
  ok "a decoy hook_payload.py in the hook's own cwd is never imported (shadow-import closed)"
else
  bad "decoy shadow-import not closed: docs='$(find "$DOCS" -name '*.json' 2>/dev/null)' stderr='$(cat "$T/err")'"
fi

# --- deep-audit finding, live-reproduced: an embedded newline in `cwd`
# used to desync fragments-capture.sh's line-numbered field extraction --
# HAS_H1 and FILE_PATH shifted, corrupting the write target. Now
# NUL-delimited (fragments_capture_parse.py + read -r -d '' in the hook).
# Exercises the parser + the hook's own read idiom directly, not the full
# hook flow, since a real dir with a literal newline in its path is not
# something fresh_repo can construct. ---
PAYLOAD_NL=$(python3 -c '
import json
print(json.dumps({"session_id":"nl-sid","tool_name":"Write","cwd":"/tmp/a\nb",
                   "tool_input":{"file_path":"/tmp/a\nb/frags.md","content":"# Title\n"}}))
')
{
  IFS= read -r -d '' SID_NL
  IFS= read -r -d '' TOOL_NL
  IFS= read -r -d '' CWD_NL
  IFS= read -r -d '' H1_NL
  IFS= read -r -d '' FP_NL
} < <(printf '%s' "$PAYLOAD_NL" | python3 -B "$ROOT/scripts/_lib/fragments_capture_parse.py" 2>/dev/null)
if [ "$SID_NL" = "nl-sid" ] && [ "$TOOL_NL" = "Write" ] && [ "$CWD_NL" = "$(printf '/tmp/a\nb')" ] \
   && [ "$H1_NL" = "1" ] && [ "$FP_NL" = "$(printf '/tmp/a\nb/frags.md')" ]; then
  ok "an embedded newline in cwd no longer desyncs HAS_H1/FILE_PATH (NUL-delimited fields)"
else
  bad "newline-in-cwd field desync: sid='$SID_NL' tool='$TOOL_NL' cwd='$CWD_NL' h1='$H1_NL' file_path='$FP_NL'"
fi

# --- deep-audit finding, live-reproduced against the NUL-delimited fix
# itself (fresh-context validator round, not the original checker): an
# unstripped NUL byte inside `cwd` forges a fake field boundary in the
# NUL-delimited protocol, letting a crafted payload spoof HAS_H1/FILE_PATH
# to values the parser never actually computed. Now every field has
# embedded NULs stripped before the join. ---
PAYLOAD_INJ=$(python3 -c '
import json
z = chr(0)
cwd_with_nul = "/tmp" + z + "1" + z + "/tmp/forged.md"
print(json.dumps({"session_id":"inj-sid","tool_name":"Write","cwd":cwd_with_nul,
                   "tool_input":{"file_path":"/tmp/actual.txt","content":"no heading"}}))
')
{
  IFS= read -r -d '' SID_INJ
  IFS= read -r -d '' TOOL_INJ
  IFS= read -r -d '' CWD_INJ
  IFS= read -r -d '' H1_INJ
  IFS= read -r -d '' FP_INJ
} < <(printf '%s' "$PAYLOAD_INJ" | python3 -B "$ROOT/scripts/_lib/fragments_capture_parse.py" 2>/dev/null)
if [ "$SID_INJ" = "inj-sid" ] && [ "$TOOL_INJ" = "Write" ] && [ "$H1_INJ" = "0" ] && [ "$FP_INJ" = "/tmp/actual.txt" ]; then
  ok "an embedded NUL in cwd can no longer forge HAS_H1/FILE_PATH (NUL stripped before the join)"
else
  bad "NUL field-injection not closed: sid='$SID_INJ' tool='$TOOL_INJ' cwd='$CWD_INJ' h1='$H1_INJ' file_path='$FP_INJ'"
fi

# --- compliance-audit finding, live-reproduced end-to-end against the real
# hook: a RAW NUL byte on stdin used to get silently dropped by
# `PAYLOAD=$(cat)`'s command substitution, splicing "foo\0bar" into the
# different, valid-looking string "foobar" before validation ever saw it --
# letting a write whose real payload named an invalid session_id get
# captured under an unrelated, genuinely-armed "foobar" session instead of
# being rejected outright. Arm a real "foobar" session, then submit a
# capture payload whose true session_id contains a raw NUL; it must not be
# treated as belonging to "foobar". A bash variable can't hold a NUL
# either, so write the raw bytes to a file and pipe that file in. ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "foobar" "$T" "$REPO" "$REPO/frags.md"
printf '# Title\nfrag one\n' > "$REPO/frags.md"
RAW_PAYLOAD="$T/raw-nul-payload.json"
python3 -c '
import sys
z = chr(0)
body = (
    "{\"session_id\":\"foo" + z + "bar\",\"cwd\":\"" + sys.argv[1] + "\","
    "\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"" + sys.argv[1] + "/frags.md\","
    "\"content\":\"# Title\\\\nfrag one\\\\n\"}}"
)
sys.stdout.buffer.write(body.encode())
' "$REPO" > "$RAW_PAYLOAD"
HOME="$FAKE_HOME" TMPDIR="$T" bash "$HOOK" < "$RAW_PAYLOAD" >/dev/null 2>"$T/err"
DOCS=$(docs_dir_for "$REPO")
REC=$(find "$DOCS" -name '*.json' 2>/dev/null | head -n1)
STILL_ARMED=$(find "$T/mh-fragments-arm" -maxdepth 1 -name 'foobar.*' ! -name 'foobar.current' 2>/dev/null)
if [ -z "$REC" ] && [ -n "$STILL_ARMED" ]; then
  ok "a raw NUL byte in session_id is rejected, not spliced into the genuinely-armed 'foobar' session (PAYLOAD_FILE ingress)"
else
  bad "raw-NUL session_id splice not closed: rec='$REC' still_armed='$STILL_ARMED'"
fi

# --- a successful capture also removes this session's .current pointer, so the
# next Write/Edit exits at the readdir gate without spawning python (a leftover
# pointer kept the gate open: 11 ms -> 72 ms per Write/Edit, 2026-10-22) ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c12" "$T" "$REPO" "$REPO/frags.md"
printf '# Title\nfrag one\n' > "$REPO/frags.md"
capture "c12" "$T" "$REPO" Write "$REPO/frags.md" '# Title\\nfrag one\\n' >/dev/null 2>"$T/err"
PY_SHIM="$T/pyshim"; mkdir -p "$PY_SHIM"
printf '#!/bin/sh\necho spawn >> "%s/py.log"\nexec "%s" "$@"\n' "$T" "$(command -v python3)" > "$PY_SHIM/python3"
chmod +x "$PY_SHIM/python3"
printf '{"session_id":"c12","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/other.md","content":"x"}}' "$REPO" "$REPO" \
  | PATH="$PY_SHIM:$PATH" HOME="$FAKE_HOME" TMPDIR="$T" bash "$HOOK" >/dev/null 2>&1
if [ ! -e "$T/mh-fragments-arm/c12.current" ] && [ ! -e "$T/py.log" ]; then
  ok "a successful capture removes the .current pointer; the next Write spawns no python"
else
  bad "pointer left or python spawned: current=$(ls "$T/mh-fragments-arm" 2>/dev/null | tr '\n' ' ') py=$(cat "$T/py.log" 2>/dev/null | wc -l)"
fi

# --- an expired arm window also removes the .current pointer ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c13" "$T" "$REPO" "$REPO/frags.md"
for m in "$T/mh-fragments-arm"/c13.*; do
  case "$m" in *.current|*.candidate) ;; *) touch -t 200001010000 "$m" ;; esac
done
printf '# Title\nfrag one\n' > "$REPO/frags.md"
capture "c13" "$T" "$REPO" Write "$REPO/frags.md" '# Title\\nfrag one\\n' >/dev/null 2>"$T/err"
if [ ! -e "$T/mh-fragments-arm/c13.current" ] && [ -z "$(ls -A "$T/mh-fragments-arm" 2>/dev/null)" ]; then
  ok "an expired arm window sweeps the marker and the .current pointer"
else
  bad "expiry left entries: $(ls -A "$T/mh-fragments-arm" 2>/dev/null | tr '\n' ' ')"
fi

# --- a pointer a fresh arm replaced mid-run is kept: drop_pointer only removes
# the generation it read. A `date` shim (called after the pointer is read, before
# the expiry sweep) stands in for the fresh arm rewriting <sid>.current ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
arm "c14" "$T" "$REPO" "$REPO/frags.md"
for m in "$T/mh-fragments-arm"/c14.*; do
  case "$m" in *.current|*.candidate) ;; *) touch -t 200001010000 "$m" ;; esac
done
DATE_SHIM="$T/dateshim"; mkdir -p "$DATE_SHIM"
printf '#!/bin/sh\nprintf fresh > "%s/mh-fragments-arm/c14.current"\nexec "%s" "$@"\n' "$T" "$(command -v date)" > "$DATE_SHIM/date"
chmod +x "$DATE_SHIM/date"
printf '{"session_id":"c14","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/frags.md","content":"x"}}' "$REPO" "$REPO" \
  | PATH="$DATE_SHIM:$PATH" HOME="$FAKE_HOME" TMPDIR="$T" bash "$HOOK" >/dev/null 2>&1
if [ "$(cat "$T/mh-fragments-arm/c14.current" 2>/dev/null)" = "fresh" ]; then
  ok "drop_pointer keeps a pointer that names a different (fresh) generation"
else
  bad "a fresh generation's pointer was dropped: $(ls -A "$T/mh-fragments-arm" 2>/dev/null | tr '\n' ' ')"
fi

echo "hooks/fragments-capture: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
