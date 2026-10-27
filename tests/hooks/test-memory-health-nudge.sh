#!/usr/bin/env bash
# memory-health-nudge unit tests. Isolates a fake $HOME and a fake project
# cwd so real ~/.claude/projects state is never touched; the hook derives its memory dir from `pwd -P` (physical path,
# slashes -> dashes) the same way memory-lint.py's own memory_dir() does, so
# fixtures must be planted at that exact computed path.
# Run standalone: bash tests/hooks/test-memory-health-nudge.sh
set -uo pipefail
# The linked-worktree row below runs git init/worktree; a pre-push hook env has GIT_DIR set and would hijack them.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session/memory-health-nudge.sh"

source "$ROOT/tests/_lib/harness.sh"
trap _cleanup_trash EXIT
# A missing TMPDIR makes mktemp print "" and `trash ""` trashes the cwd: stop before FAKE_HOME and the
# rest are built on "", and let _cleanup_trash (which drops empties) do the trashing.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kbg-memory-health-nudge-test.XXXXXX") || exit 1
track_trash "$TMP"

pass=0
fail=0

PROJECT_DIR="$TMP/project"
FAKE_HOME="$TMP/home"
mkdir -p "$PROJECT_DIR" "$FAKE_HOME/.claude/state"

PHYSPWD=$(cd "$PROJECT_DIR" && pwd -P)
ENC=$(printf '%s' "$PHYSPWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
MEMDIR="$FAKE_HOME/.claude/projects/$ENC/memory"

init_memdir() {
  tmp_delete "$MEMDIR" || true
  mkdir -p "$MEMDIR"
}

write_memory() {
  local filename="$1" description="$2"
  cat > "$MEMDIR/$filename" <<EOF
---
name: ${filename%.md}
description: "$description"
metadata:
  type: project
---
n/a
EOF
}

run_hook() {
  # Clear the mtime-based skip-cache before every call so each scenario runs
  # for real, rather than depending on fixture writes landing in a later
  # mtime tick than the previous call's cache touch.
  rm -f "$FAKE_HOME/.claude/state"/memory-lint-cache-* 2>/dev/null
  ( cd "$PROJECT_DIR" && CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$FAKE_HOME" bash "$HOOK" )
}

run_hook_no_cache_clear() {
  # Deliberately does NOT clear the cache first — for testing what happens
  # across consecutive "sessions" against the same unmodified store, which
  # is the exact scenario the cache-persistence regression test below needs.
  ( cd "$PROJECT_DIR" && CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$FAKE_HOME" bash "$HOOK" )
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if command grep -qF "$needle" <<<"$haystack"; then
    echo "  ✅ CONTAINS \"$needle\": $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ EXPECTED \"$needle\" in output but it was absent: $desc" >&2
    echo "     --- output ---" >&2
    printf '%s\n' "$haystack" | sed 's/^/     /' >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if command grep -qF "$needle" <<<"$haystack"; then
    echo "  ❌ UNEXPECTED \"$needle\" in output: $desc" >&2
    echo "     --- output ---" >&2
    printf '%s\n' "$haystack" | sed 's/^/     /' >&2
    fail=$((fail + 1))
  else
    echo "  ✅ ABSENT \"$needle\": $desc"
    pass=$((pass + 1))
  fi
}

echo "=== memory-health-nudge hook (SessionStart) ==="
echo ""

echo "--- baseline behavior ---"

init_memdir
# A lone unlinked memory trips the ORPHAN check by itself — cross-link two
# files so the store is genuinely clean (0 findings), not just index-clean.
cat > "$MEMDIR/topic-a.md" <<'EOF'
---
name: topic-a
description: "a fully indexed topic"
metadata:
  type: project
---
see [[topic-b]]
EOF
cat > "$MEMDIR/topic-b.md" <<'EOF'
---
name: topic-b
description: "another fully indexed topic"
metadata:
  type: project
---
see [[topic-a]]
EOF
printf '%s\n' \
  "- [topic-a](topic-a.md) — a fully indexed topic" \
  "- [topic-b](topic-b.md) — another fully indexed topic" > "$MEMDIR/MEMORY.md"
OUT=$(run_hook)
assert_not_contains "clean store stays fully silent" "[memory-lint]" "$OUT"

tmp_delete "$FAKE_HOME/.claude/projects" || true
OUT=$(run_hook)
assert_not_contains "no memory dir at all stays silent" "[memory-lint]" "$OUT"

echo ""
echo "--- UNINDEXED findings surface raw, no triage line ---"

init_memdir
write_memory "topic-a.md" "a fully indexed topic"
printf '%s\n' \
  "- [topic-a](topic-a.md) — a fully indexed topic" \
  "see [[missing-thing]] for more" > "$MEMDIR/MEMORY.md"
OUT=$(run_hook)
assert_contains "dangling link fires the main block" \
  "[memory-lint] The memory store has findings" "$OUT"

init_memdir
write_memory "plain-target.md" "unindexed and unreachable"
: > "$MEMDIR/MEMORY.md"
OUT=$(run_hook)
assert_contains "raw UNINDEXED finding surfaces" \
  "UNINDEXED: plain-target.md" "$OUT"
assert_not_contains "no triage line (triage mode removed)" \
  "UNINDEXED triage" "$OUT"

echo ""
echo "--- cache persistence: a dirty store keeps firing across sessions, a clean one doesn't ---"

init_memdir
rm -f "$FAKE_HOME/.claude/state"/memory-lint-cache-* 2>/dev/null
cat > "$MEMDIR/topic-a.md" <<'EOF'
---
name: topic-a
description: "has a dangling link, unresolved across every run below"
metadata:
  type: project
---
see [[nonexistent-target-xyz]]
EOF
printf '%s\n' "- [topic-a](topic-a.md) — has a dangling link" > "$MEMDIR/MEMORY.md"
OUT1=$(run_hook_no_cache_clear)
assert_contains "run 1: unresolved finding fires the nudge" \
  "[memory-lint] The memory store has findings" "$OUT1"
OUT2=$(run_hook_no_cache_clear)
# Regression test for the 2026-08-17 fix: the cache used to be touched after
# EVERY successful run, dirty or clean — so a real, still-unresolved finding
# fired once and then went silent on every later session until some
# unrelated file in $MEMDIR happened to get a newer mtime. Nothing changed
# between run 1 and run 2 here on purpose; the finding must still fire.
assert_contains "run 2 (nothing changed, finding still unresolved): must still fire, not go silent" \
  "[memory-lint] The memory store has findings" "$OUT2"
OUT3=$(run_hook_no_cache_clear)
assert_contains "run 3: still fires — confirms it's not a one-tick fluke" \
  "[memory-lint] The memory store has findings" "$OUT3"

# Once the store is genuinely clean, the cache should resume its normal job
# (skip the python3 rescan on an unchanged store) rather than rescan forever.
init_memdir
rm -f "$FAKE_HOME/.claude/state"/memory-lint-cache-* 2>/dev/null
write_memory "topic-a.md" "a fully indexed topic"
write_memory "topic-b.md" "another fully indexed topic"
cat > "$MEMDIR/topic-a.md" <<'EOF'
---
name: topic-a
description: "a fully indexed topic"
metadata:
  type: project
---
see [[topic-b]]
EOF
cat > "$MEMDIR/topic-b.md" <<'EOF'
---
name: topic-b
description: "another fully indexed topic"
metadata:
  type: project
---
see [[topic-a]]
EOF
printf '%s\n' \
  "- [topic-a](topic-a.md) — a fully indexed topic" \
  "- [topic-b](topic-b.md) — another fully indexed topic" > "$MEMDIR/MEMORY.md"
run_hook_no_cache_clear >/dev/null
CACHE_FILE=$(find "$FAKE_HOME/.claude/state" -name 'memory-lint-cache-*' 2>/dev/null | head -1)
if [ -n "$CACHE_FILE" ] && [ -f "$CACHE_FILE" ]; then
  echo "  ✅ PRESENT: a clean run still writes the cache (fast-path preserved)"
  pass=$((pass + 1))
else
  echo "  ❌ MISSING: a clean run should still write the cache" >&2
  fail=$((fail + 1))
fi

echo ""
echo "--- M9 (2026-09-20): a crashed memory-lint.py surfaces one line, never silent ---"

FAKE_PLUGIN="$TMP/fakeplugin"
mkdir -p "$FAKE_PLUGIN/skills/meta/memory-lint/scripts" "$FAKE_PLUGIN/scripts/_lib"
# The real resolver, not a fake one -- only memory-lint.py itself needs to be
# faked to exercise the crash-handling path below; ENC/MEMDIR resolution must
# still succeed for the hook to ever reach that far.
cp "$ROOT/scripts/_lib/memory-dir.py" "$FAKE_PLUGIN/scripts/_lib/memory-dir.py"
cat > "$FAKE_PLUGIN/skills/meta/memory-lint/scripts/memory-lint.py" <<'EOF'
#!/usr/bin/env python3
raise RuntimeError("boom")
EOF

init_memdir
write_memory "topic-a.md" "a fully indexed topic"
: > "$MEMDIR/MEMORY.md"
rm -f "$FAKE_HOME/.claude/state"/memory-lint-cache-* 2>/dev/null
OUT=$( cd "$PROJECT_DIR" && CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" HOME="$FAKE_HOME" bash "$HOOK" )
assert_contains "crash surfaces one advisory line, not silence" \
  "[memory-lint] session-start check crashed" "$OUT"

CACHE_FILE=$(find "$FAKE_HOME/.claude/state" -name 'memory-lint-cache-*' 2>/dev/null | head -1)
if [ -z "$CACHE_FILE" ] || [ ! -f "$CACHE_FILE" ]; then
  echo "  ✅ ABSENT: a crashed run is never cached, so it keeps firing until fixed"
  pass=$((pass + 1))
else
  echo "  ❌ UNEXPECTED: a crashed run must not write the cache" >&2
  fail=$((fail + 1))
fi

echo ""
echo "--- H6 (2026-09-20): memory-audit-commit.sh's failure marker surfaces here, never silent ---"

init_memdir
write_memory "topic-a.md" "a fully indexed topic"
printf '%s\n' "- [topic-a](topic-a.md) — a fully indexed topic" > "$MEMDIR/MEMORY.md"
rm -f "$FAKE_HOME/.claude/state"/memory-lint-cache-* 2>/dev/null
# Per-attempt, PID-suffixed marker naming (2026-09-28) -- this test's own PID
# suffix is arbitrary, it just needs to match the glob memory-health-nudge.sh
# scans (memory-audit-commit-fail-$ENC-*).
FAILMARKER="$FAKE_HOME/.claude/state/memory-audit-commit-fail-$ENC-999901"
printf 'acquisition_ts=0\ngit commit failed (exit 1): fatal: unable to auto-detect email address\n' > "$FAILMARKER"
OUT=$(run_hook)
assert_contains "commit-failure marker surfaces its own line" \
  "[memory-lint] the memory store's auto-commit failed" "$OUT"
assert_contains "the captured git stderr is included verbatim" \
  "unable to auto-detect email address" "$OUT"

rm -f "$FAILMARKER"
OUT=$(run_hook)
assert_not_contains "marker cleared (by memory-audit-commit.sh) -> nudge stops firing" \
  "auto-commit failed" "$OUT"

echo ""
echo "--- a marker of a project whose ENC extends this one (proj vs proj-v2) never surfaces here ---"
OTHER_MARKER="$FAKE_HOME/.claude/state/memory-audit-commit-fail-$ENC-v2-999903"
printf 'acquisition_ts=0\ngit commit failed (exit 1): other project marker\n' > "$OTHER_MARKER"
OUT=$(run_hook)
assert_not_contains "ENC-v2's marker is not shown in ENC's session" \
  "auto-commit failed" "$OUT"
rm -f "$OTHER_MARKER"

echo ""
echo "--- autoMemoryDirectory: the nudge lints the configured store, not the default path ---"
AMD_PROJECT="$TMP/amdproject"
AMD_MEMDIR="$TMP/amd-memory"
mkdir -p "$AMD_PROJECT/.claude" "$AMD_MEMDIR"
printf '{"autoMemoryDirectory": "%s"}\n' "$AMD_MEMDIR" > "$AMD_PROJECT/.claude/settings.json"
printf -- '---\nname: amd-orphan\ndescription: "unindexed"\nmetadata:\n  type: project\n---\nn/a\n' > "$AMD_MEMDIR/amd-orphan.md"
: > "$AMD_MEMDIR/MEMORY.md"
rm -f "$FAKE_HOME/.claude/state"/memory-lint-cache-* 2>/dev/null
OUT=$( cd "$AMD_PROJECT" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_PROJECT_DIR_NAME CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$FAKE_HOME" bash "$HOOK" 2>&1 )
assert_contains "configured autoMemoryDirectory store is linted" \
  "UNINDEXED: amd-orphan.md" "$OUT"

echo ""
echo "--- GH #328: from a linked worktree, the marker named with the resolver's ENC still surfaces ---"
# memory-audit-commit.sh names markers with memory-dir.py --enc, which keys off
# git-common-dir, so every linked worktree shares the main checkout's ENC. The
# plain project dir above is not a git repo, so both encodings coincide there.
WT_REPO="$TMP/wtrepo"
WT_DIR="$TMP/wtrepo-wt"
git init -q "$WT_REPO"
git -C "$WT_REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$WT_REPO" worktree add -q "$WT_DIR" 2>/dev/null
WT_ENC=$(cd "$WT_DIR" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_PROJECT_DIR_NAME HOME="$FAKE_HOME" python3 "$ROOT/scripts/_lib/memory-dir.py" --enc)
WT_PWD_ENC=$(cd "$WT_DIR" && pwd -P | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
if [ -n "$WT_ENC" ] && [ "$WT_ENC" != "$WT_PWD_ENC" ]; then
  echo "  ✅ fixture: the resolver's ENC differs from the worktree's pwd -P encoding"; pass=$((pass + 1))
else
  echo "  ❌ fixture: expected two different encodings, got resolver=<$WT_ENC> pwd=<$WT_PWD_ENC>" >&2; fail=$((fail + 1))
fi
WT_MARKER="$FAKE_HOME/.claude/state/memory-audit-commit-fail-$WT_ENC-999902"
printf 'acquisition_ts=1700000000.5\ngit commit failed (exit 1): worktree marker\n' > "$WT_MARKER"
OUT=$( cd "$WT_DIR" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_PROJECT_DIR_NAME CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$FAKE_HOME" bash "$HOOK" 2>&1 )
assert_contains "linked worktree: the resolver-ENC marker surfaces" \
  "[memory-lint] the memory store's auto-commit failed" "$OUT"
assert_contains "linked worktree: the marker's diagnostic line is shown" \
  "worktree marker" "$OUT"
assert_not_contains "the machine-read acquisition_ts line stays out of model context" \
  "acquisition_ts=" "$OUT"
rm -f "$WT_MARKER"

echo ""
echo "--- (2026-09-21) the H6 marker surfaces even when the lint gates would exit early ---"
# memory-audit-commit.sh needs neither python3 nor CLAUDE_PLUGIN_ROOT to write
# the marker, so this hook must show it before either gate. PATH holds only
# what the marker path itself needs (cat) and no python3 -- same trick as
# tests/hooks/test-doctrine-bootstrap.sh.
printf 'git commit failed (exit 1): fatal: unable to auto-detect email address\n' > "$FAILMARKER"
noop_bin=$(mktemp -d "$TMP/nobin.XXXXXX")
ln -s /bin/cat "$noop_bin/cat"
ln -s /usr/bin/find "$noop_bin/find"
ln -s /usr/bin/head "$noop_bin/head"
OUT=$( cd "$PROJECT_DIR" && CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$FAKE_HOME" PATH="$noop_bin" /bin/bash "$HOOK" 2>&1 )
assert_contains "python3 missing from PATH: the auto-commit-failed line still prints" \
  "[memory-lint] the memory store's auto-commit failed" "$OUT"
OUT=$( cd "$PROJECT_DIR" && CLAUDE_PLUGIN_ROOT='' HOME="$FAKE_HOME" bash "$HOOK" 2>&1 )
assert_contains "CLAUDE_PLUGIN_ROOT empty: the auto-commit-failed line still prints" \
  "[memory-lint] the memory store's auto-commit failed" "$OUT"
rm -f "$FAILMARKER"

echo ""
echo "--- (2026-09-21) unset / relative HOME: skip silently, never crash under set -u or write into cwd ---"
before=$(ls -A "$PROJECT_DIR" | wc -l | tr -d ' ')
OUT=$( cd "$PROJECT_DIR" && env -u HOME CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" </dev/null 2>&1 ); rc=$?
after=$(ls -A "$PROJECT_DIR" | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ -z "$OUT" ] && [ "$before" = "$after" ]; then
  echo "  ✅ unset HOME -> rc 0, silent, nothing written into cwd"; pass=$((pass + 1))
else
  echo "  ❌ unset HOME should exit 0 silently (rc=$rc out=<$OUT> before=$before after=$after)" >&2; fail=$((fail + 1))
fi
# Discriminating relative-HOME case: plant a dirty store where HOME=rel WOULD
# resolve (cwd/rel/...). An unguarded hook lints it (prints findings) and
# mkdirs rel/.claude/state inside the project cwd; the guard must do neither.
REL_MEMDIR="$PROJECT_DIR/rel/.claude/projects/$ENC/memory"
mkdir -p "$REL_MEMDIR"
printf -- '---\nname: plain-target\ndescription: "unindexed"\nmetadata:\n  type: project\n---\nn/a\n' > "$REL_MEMDIR/plain-target.md"
: > "$REL_MEMDIR/MEMORY.md"
OUT=$( cd "$PROJECT_DIR" && HOME=rel CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" </dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$OUT" ] && [ ! -d "$PROJECT_DIR/rel/.claude/state" ]; then
  echo "  ✅ relative HOME -> rc 0, silent, no rel/.claude/state in cwd, planted dirty store never linted"; pass=$((pass + 1))
else
  echo "  ❌ relative HOME should exit 0 silently without touching cwd (rc=$rc out=<$OUT>)" >&2; fail=$((fail + 1))
fi
tmp_delete "$PROJECT_DIR/rel" || true

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
