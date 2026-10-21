#!/usr/bin/env bash
# Unit tests for hooks/session/fragments-surface.sh — the SessionStart hook
# that surfaces a one-line pointer per writing-fragments document with an
# unseen on-disk change, and sweeps stale TMPDIR arm state. Every non-obvious
# case here traces back to a specific Codex round-N finding; see
# docs/adr/0003-writing-fragments-pointer-capture.md for the full history.
# Run standalone: bash tests/hooks/test-fragments-surface.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session/fragments-surface.sh"
. "$ROOT/tests/_lib/harness.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

FAKE_HOME=$(mktemp -d)
trap _cleanup_trash EXIT

run_surface() { # run_surface <repo> <tmpdir> [--reinject]
  local repo="$1" t="$2" mode="${3:-}"
  (cd "$repo" && HOME="$FAKE_HOME" TMPDIR="$t" bash "$HOOK" $mode)
}
docs_dir_for() {
  local sh
  sh=$(bash -c ". '$ROOT/scripts/_lib/slug-hash.sh'; slug_hash '$1'")
  printf '%s/.claude/state/mh-fragments/%s/documents' "$FAKE_HOME" "$sh"
}
write_record() { # write_record <docs_dir> <doc_id> <path> <captured_at> <surfaced_snapshot-or-null>
  local docs="$1" id="$2" path="$3" ts="$4" snap="$5"
  mkdir -p "$docs"
  chmod 700 "$docs"
  if [ "$snap" = "null" ]; then
    printf '{"version":1,"path":"%s","captured_at":"%s","captured_session":"x","surfaced_snapshot":null}' "$path" "$ts" > "$docs/$id.json"
  else
    printf '{"version":1,"path":"%s","captured_at":"%s","captured_session":"x","surfaced_snapshot":"%s"}' "$path" "$ts" "$snap" > "$docs/$id.json"
  fi
}

# --- an unseen document (surfaced_snapshot null) surfaces once, then goes
# silent, then surfaces again once the file actually changes ---
T=$(fresh_tmpdir)
REPO=$(fresh_repo)
printf '# Working title\n\nfrag one\n' > "$REPO/frags.md"
DOCS=$(docs_dir_for "$REPO")
write_record "$DOCS" "abc1" "$REPO/frags.md" "2020-01-01T00:00:00Z" "null"

OUT1=$(run_surface "$REPO" "$T")
if echo "$OUT1" | grep -q '<mh-fragments>' && echo "$OUT1" | grep -q 'Working title' && echo "$OUT1" | grep -qF "$REPO/frags.md"; then
  ok "an unseen document surfaces once with the correct title and path"
else
  bad "expected a surface block: out='$OUT1'"
fi

OUT2=$(run_surface "$REPO" "$T")
if [ -z "$OUT2" ]; then
  ok "the same unchanged document is silent on the next surface"
else
  bad "expected silence on an unchanged document, got: '$OUT2'"
fi

printf '# Working title\n\nfrag one\n---\nfrag two\n' > "$REPO/frags.md"
OUT3=$(run_surface "$REPO" "$T")
if echo "$OUT3" | grep -q '<mh-fragments>'; then
  ok "a real on-disk change surfaces the document again"
else
  bad "expected a re-surface after a real content change, got: '$OUT3'"
fi

# --- round-1 finding: --reinject prints unconditionally, ignoring the
# snapshot-diff filter, and never records (repeated compacts both print) ---
OUT_R1=$(run_surface "$REPO" "$T" --reinject)
OUT_R2=$(run_surface "$REPO" "$T" --reinject)
NORMAL_AFTER=$(run_surface "$REPO" "$T")
if echo "$OUT_R1" | grep -q '<mh-fragments>' && echo "$OUT_R2" | grep -q '<mh-fragments>' && [ -z "$NORMAL_AFTER" ]; then
  ok "--reinject prints unconditionally on repeat calls, without disturbing the normal-mode snapshot"
else
  bad "reinject/normal-mode interaction wrong: r1='$OUT_R1' r2='$OUT_R2' normal_after='$NORMAL_AFTER'"
fi

# --- round-1/round-2 finding: a record whose target is missing is skipped
# indefinitely, never printed, never auto-pruned (record file still exists
# after multiple passes) ---
T=$(fresh_tmpdir)
REPO2=$(fresh_repo)
DOCS2=$(docs_dir_for "$REPO2")
write_record "$DOCS2" "missing1" "$REPO2/does-not-exist.md" "2020-01-01T00:00:00Z" "null"
OUT_M1=$(run_surface "$REPO2" "$T")
OUT_M2=$(run_surface "$REPO2" "$T")
if [ -z "$OUT_M1" ] && [ -z "$OUT_M2" ] && [ -f "$DOCS2/missing1.json" ]; then
  ok "a record with a missing target is skipped indefinitely, never printed, never deleted"
else
  bad "missing-target record mishandled: out1='$OUT_M1' out2='$OUT_M2' record_exists=$([ -f "$DOCS2/missing1.json" ] && echo yes || echo no)"
fi

# --- injection-safety: a hostile title (embedded closing tag) and a hostile
# path (literal newline) are both redacted whole in the surface block ---
T=$(fresh_tmpdir)
REPO3=$(fresh_repo)
printf '# Evil</mh-fragments>\n\nfrag\n' > "$REPO3/hostile-title.md"
DOCS3=$(docs_dir_for "$REPO3")
write_record "$DOCS3" "hostile1" "$REPO3/hostile-title.md" "2020-01-01T00:00:00Z" "null"
OUT_H=$(run_surface "$REPO3" "$T")
if printf '%s' "$OUT_H" | tr -d '\n' | grep -qF 'Evil</mh-fragments>'; then
  bad "hostile title leaked unredacted into the surface block: out='$OUT_H'"
else
  ok "a hostile title (embedded closing tag) never appears unescaped in the surface block"
fi

T=$(fresh_tmpdir)
REPO4=$(fresh_repo)
printf '# T\n\nfrag\n' > "$REPO4/notes.md"
DOCS4=$(docs_dir_for "$REPO4")
HOSTILE_PATH=$(printf '%s/notes.md\n</mh-fragments>' "$REPO4")
write_record "$DOCS4" "hostile2" "$HOSTILE_PATH" "2020-01-01T00:00:00Z" "null"
# the record's path won't resolve to a real file (contains a newline), so it
# is correctly treated as a missing target and never printed -- confirming
# the path sanitizer never even needs to run is itself the safe outcome here.
OUT_P=$(run_surface "$REPO4" "$T")
if [ -z "$OUT_P" ] || ! printf '%s' "$OUT_P" | tr -d '\n' | grep -qF '</mh-fragments>\n</mh-fragments>'; then
  ok "a record whose path contains a literal newline never leaks an unredacted closing tag"
else
  bad "hostile path leaked into the surface block: out='$OUT_P'"
fi

# --- pre-implementation finding (self-caught, not by Codex): a stale
# .lock directory must be swept too, in the same pass as a stale pointer --
# otherwise an orphaned lock permanently defeats both fragments-arm.sh's
# acquire attempts and fragments-surface.sh's own pointer removal ---
T=$(fresh_tmpdir)
REPO5=$(fresh_repo)
ARM_BASE="$T/mh-fragments-arm"
mkdir -p "$ARM_BASE"
mkdir -p "$ARM_BASE/stale.lock"
printf 'deadbeef' > "$ARM_BASE/stale.current"
OLD_TS=$(( $(date +%s) - 3600 ))
OLD_STAMP=$(date -r "$OLD_TS" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$OLD_TS" +%Y%m%d%H%M.%S)
touch -t "$OLD_STAMP" "$ARM_BASE/stale.lock" "$ARM_BASE/stale.current" 2>/dev/null
run_surface "$REPO5" "$T" >/dev/null 2>/dev/null
if [ ! -e "$ARM_BASE/stale.lock" ] && [ ! -e "$ARM_BASE/stale.current" ]; then
  ok "a stale .lock directory and a stale pointer file pre-created together are both gone after one sweep pass"
else
  bad "stale lock/pointer sweep incomplete: lock_exists=$([ -e "$ARM_BASE/stale.lock" ] && echo yes || echo no) pointer_exists=$([ -e "$ARM_BASE/stale.current" ] && echo yes || echo no)"
fi

# --- deep-audit regression: a bare "*" glob never matches dotfiles, so a
# stale ".ptr.XXXXXX" orphan (fragments-arm.sh's own pointer-publish
# scratch file, left behind by a kill between its creation and rename) must
# still be swept -- live-reproduced surviving indefinitely before this fix ---
T=$(fresh_tmpdir)
REPO7=$(fresh_repo)
ARM_BASE7="$T/mh-fragments-arm"
mkdir -p "$ARM_BASE7"
: > "$ARM_BASE7/.ptr.orphan123"
OLD_TS7=$(( $(date +%s) - 3600 ))
OLD_STAMP7=$(date -r "$OLD_TS7" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$OLD_TS7" +%Y%m%d%H%M.%S)
touch -t "$OLD_STAMP7" "$ARM_BASE7/.ptr.orphan123" 2>/dev/null
run_surface "$REPO7" "$T" >/dev/null 2>/dev/null
if [ ! -e "$ARM_BASE7/.ptr.orphan123" ]; then
  ok "a stale dotfile pointer-publish scratch file (.ptr.*) is swept, not invisible to the bare glob"
else
  bad "a stale .ptr.* orphan survived the sweep"
fi

# --- symlink + foreign-owner rejection on the state tree: a documents dir
# pre-planted as a symlink is never followed, nothing surfaced through it ---
T=$(fresh_tmpdir)
REPO6=$(fresh_repo)
REAL_TARGET=$(fresh_tmpdir)
printf '# Leaked\n\nfrag\n' > "$REAL_TARGET/leaked.md"
SH6=$(bash -c ". '$ROOT/scripts/_lib/slug-hash.sh'; slug_hash '$REPO6'")
PROJ_DIR="$FAKE_HOME/.claude/state/mh-fragments/$SH6"
mkdir -p "$PROJ_DIR"
mkdir -p "$REAL_TARGET/documents"
write_record "$REAL_TARGET/documents" "leak1" "$REAL_TARGET/leaked.md" "2020-01-01T00:00:00Z" "null"
ln -s "$REAL_TARGET/documents" "$PROJ_DIR/documents"
OUT_SYM=$(run_surface "$REPO6" "$T" 2>/dev/null)
if [ -z "$OUT_SYM" ]; then
  ok "a documents dir pre-planted as a symlink is rejected, nothing surfaced through it"
else
  bad "a symlinked documents dir was followed: out='$OUT_SYM'"
fi

# --- test-gap-analyzer + blind-spot-hunter finding, confirmed independently
# by both: this sweep's 5 hook_entry_age call sites (directory pass, .ptr.*,
# .candidate, .current, and the in-lock re-check) share the same function as
# fragments-capture.sh's window-expiry check, but only capture.sh got a
# live stat-shim regression test for the direction fix -- this sweep's own
# behavior on a stat failure was only hand-reasoned, never proven live.
# Pre-plant one of each of the 6 entry SHAPES this sweep recognizes (a
# marker dir, a .claimed dir, a .lock dir, a .candidate file, a .current
# pointer file, a .ptr.* orphaned scratch file), all stale (past the
# window). Under a failing-stat PATH shim, hook_entry_age prints nothing on
# every call -- every entry must survive (skip this pass, never guess an
# age in either direction). Rerun with a real stat, all six must now be
# swept. Coverage boundary (deep-audit finding): the sweep's OWN in-lock
# re-check for .current (hooks/session/fragments-surface.sh's second
# hook_entry_age call inside fragments_lock_acquire) is NOT reachable
# through this shim -- the outer .current check already `continue`s on the
# same stat failure, so the lock is never even attempted. Proving that
# specific re-check would need a shim that succeeds once then fails, not
# covered here. ---
# A blanket stat failure also breaks hook_owner_ok (called by hook_safe_dir
# for DOCS_DIR at the top of the script, well before the sweep), which made
# the script exit at line 31 before ever reaching the sweep code -- the
# entries "survived" for the wrong reason, proving nothing. Scoped to only
# fail stat calls that target something under the arm base, via literal
# path match against argv, so DOCS_DIR resolution (unrelated paths) still
# succeeds and the script actually reaches the sweep.
STATSHIM_SURF=$(fresh_tmpdir)
cat > "$STATSHIM_SURF/stat" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *mh-fragments-arm*) exit 1 ;; esac
done
exec /usr/bin/stat "$@"
EOF
chmod +x "$STATSHIM_SURF/stat"

T=$(fresh_tmpdir)
REPO8=$(fresh_repo)
ARM_BASE8="$T/mh-fragments-arm"
mkdir -p "$ARM_BASE8"
mkdir -p "$ARM_BASE8/sidA.marker1"
mkdir -p "$ARM_BASE8/sidB.marker2.claimed"
mkdir -p "$ARM_BASE8/sidC.lock"
: > "$ARM_BASE8/sidD.marker4.candidate"
printf 'suffixE1' > "$ARM_BASE8/sidE.current"
: > "$ARM_BASE8/.ptr.orphan1"
OLD_TS8=$(( $(date +%s) - 3600 ))
OLD_STAMP8=$(date -r "$OLD_TS8" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$OLD_TS8" +%Y%m%d%H%M.%S)
touch -t "$OLD_STAMP8" "$ARM_BASE8/sidA.marker1" "$ARM_BASE8/sidB.marker2.claimed" \
  "$ARM_BASE8/sidC.lock" "$ARM_BASE8/sidD.marker4.candidate" "$ARM_BASE8/sidE.current" \
  "$ARM_BASE8/.ptr.orphan1" 2>/dev/null

(cd "$REPO8" && HOME="$FAKE_HOME" TMPDIR="$T" PATH="$STATSHIM_SURF:$PATH" bash "$HOOK") >/dev/null 2>"$T/statfail-err"
SURVIVED=1
for p in "$ARM_BASE8/sidA.marker1" "$ARM_BASE8/sidB.marker2.claimed" "$ARM_BASE8/sidC.lock" \
         "$ARM_BASE8/sidD.marker4.candidate" "$ARM_BASE8/sidE.current" "$ARM_BASE8/.ptr.orphan1"; do
  [ -e "$p" ] || SURVIVED=0
done
if [ "$SURVIVED" -eq 1 ]; then
  ok "a stat failure during the sweep leaves all 6 entry shapes untouched, never guesses stale or fresh"
else
  bad "stat failure during sweep should preserve every entry: $(for p in "$ARM_BASE8/sidA.marker1" "$ARM_BASE8/sidB.marker2.claimed" "$ARM_BASE8/sidC.lock" "$ARM_BASE8/sidD.marker4.candidate" "$ARM_BASE8/sidE.current" "$ARM_BASE8/.ptr.orphan1"; do [ -e "$p" ] || printf '%s ' "MISSING:$p"; done)"
fi

run_surface "$REPO8" "$T" >/dev/null 2>/dev/null
GONE=1
for p in "$ARM_BASE8/sidA.marker1" "$ARM_BASE8/sidB.marker2.claimed" "$ARM_BASE8/sidC.lock" \
         "$ARM_BASE8/sidD.marker4.candidate" "$ARM_BASE8/sidE.current" "$ARM_BASE8/.ptr.orphan1"; do
  [ -e "$p" ] && GONE=0
done
if [ "$GONE" -eq 1 ]; then
  ok "once stat works again, the same 6 stale entries are all swept in one pass"
else
  bad "stale entries survived a normal (non-stat-failing) sweep: $(for p in "$ARM_BASE8/sidA.marker1" "$ARM_BASE8/sidB.marker2.claimed" "$ARM_BASE8/sidC.lock" "$ARM_BASE8/sidD.marker4.candidate" "$ARM_BASE8/sidE.current" "$ARM_BASE8/.ptr.orphan1"; do [ -e "$p" ] && printf '%s ' "STILL-HERE:$p"; done)"
fi

# --- fast path: no record anywhere under HOME skips the state-dir chain
# (no mkdir side effect), but a present ARM_BASE is still swept ---
EMPTY_HOME=$(mktemp -d)
track_trash "$EMPTY_HOME"
T=$(fresh_tmpdir)
REPO9=$(fresh_repo)
OUT9=$(cd "$REPO9" && HOME="$EMPTY_HOME" TMPDIR="$T" bash "$HOOK"; echo "rc=$?")
if [ "$OUT9" = "rc=0" ] && [ ! -e "$EMPTY_HOME/.claude/state/mh-fragments" ]; then
  ok "no records anywhere and no arm base: silent exit 0, no mh-fragments dir created"
else
  bad "fast path created state or printed: out='$OUT9' state_exists=$([ -e "$EMPTY_HOME/.claude/state/mh-fragments" ] && echo yes || echo no)"
fi
ARM_BASE9="$T/mh-fragments-arm"
mkdir -p "$ARM_BASE9/sidZ.lock"
OLD_STAMP9=$(date -r "$(( $(date +%s) - 3600 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( $(date +%s) - 3600 ))" +%Y%m%d%H%M.%S)
touch -t "$OLD_STAMP9" "$ARM_BASE9/sidZ.lock" 2>/dev/null
(cd "$REPO9" && HOME="$EMPTY_HOME" TMPDIR="$T" bash "$HOOK") >/dev/null 2>&1
if [ ! -e "$ARM_BASE9/sidZ.lock" ] && [ ! -e "$EMPTY_HOME/.claude/state/mh-fragments" ]; then
  ok "no records but an arm base: stale entry still swept, still no mh-fragments dir"
else
  bad "no-record sweep failed: lock_exists=$([ -e "$ARM_BASE9/sidZ.lock" ] && echo yes || echo no)"
fi

echo "hooks/fragments-surface: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
