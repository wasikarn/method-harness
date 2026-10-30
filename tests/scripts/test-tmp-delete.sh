#!/usr/bin/env bash
# test-tmp-delete.sh — scripts/_lib/tmp_delete.py, the permanent delete for a test's own temp
# paths (GH #724). Every refusal must exit nonzero, say why on stderr and delete nothing; a
# path under the temp root is deleted. Some refusal probes name real dirs (the home, /tmp,
# the temp dir itself), so every refusal case runs the helper's main() with shutil.rmtree and
# os.unlink replaced by an exit 99: a regression fails the test instead of deleting them. Only
# the positive and symlink cases, which touch nothing outside $T, run the real helper.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
TD="$HERE/../../scripts/_lib/tmp_delete.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

T=$(mktemp -d)
[ -n "$T" ] && [ -d "$T" ] || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'python3 "$TD" "$T"' EXIT
REALHOME=$(python3 -c 'import os,pwd; print(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))')
MISSING_HOME_PROBE="$REALHOME/.mh-tmp-delete-probe-missing"

# The helper with every delete call stubbed to exit 99 (argv: helper path, then its args).
NODELETE='import importlib.util, os, shutil, sys
spec = importlib.util.spec_from_file_location("td", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
shutil.rmtree = lambda *a, **k: sys.exit(99)
os.unlink = lambda *a, **k: sys.exit(99)
sys.exit(m.main(sys.argv[2:]))'

# refused <title> <env-prefix...> -- <args...>: exit 2, "refused" on stderr, $T/keep intact.
refused() {
  local title="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  mkdir -p "$T/keep"
  local err rc
  err=$(env ${envs[@]+"${envs[@]}"} python3 -c "$NODELETE" "$TD" "$@" "$T/keep" 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && /usr/bin/grep -q 'refused' <<<"$err" && [ -d "$T/keep" ]; then
    ok "$title"
  else
    bad "$title: rc=$rc, keep dir present: $([ -d "$T/keep" ] && echo yes || echo no)"
  fi
}

echo "=== scripts/_lib/tmp_delete.py ==="

mkdir -p "$T/keep"
python3 -c "$NODELETE" "$TD" "$T/keep"; rc=$?
[ "$rc" -eq 99 ] && [ -d "$T/keep" ] && ok "the stubbed helper reaches its delete call (exit 99) and deletes nothing" \
  || bad "the delete stub did not fire: rc=$rc"

err=$(python3 "$TD" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ -n "$err" ] && ok "no argument: exit 2 with a message" || bad "no argument: rc=$rc"

refused "an empty argument is refused and nothing else is deleted" -- ""
refused "/ is refused" -- /
refused "the real home is refused" -- "$REALHOME"
refused "an ancestor of the home is refused" -- "$(dirname "$REALHOME")"
refused "a missing path under the home is refused (root check runs before the exists check)" -- "$MISSING_HOME_PROBE"
refused "an existing file outside every temp root is refused and kept" -- /usr/bin/true
[ -e /usr/bin/true ] || bad "/usr/bin/true is gone"
refused "/tmp itself is refused (a root is not strictly under itself)" -- /tmp
refused "the TMPDIR root itself is refused" -- "${TMPDIR:-/tmp}"
refused "TMPDIR=/ does not widen the roots" TMPDIR=/ -- /usr/bin/true
refused "TMPDIR=/usr does not widen the roots" TMPDIR=/usr -- /usr/bin/true
refused "TMPDIR=<home> does not widen the roots" "TMPDIR=$REALHOME" -- "$MISSING_HOME_PROBE"
refused "TMPDIR inside the home does not widen the roots" "TMPDIR=$REALHOME/Library" -- "$REALHOME/Library/.mh-tmp-delete-probe-missing"
SYSTMP=$(python3 -c 'import os,sys,subprocess; d=subprocess.run(["/usr/bin/getconf","DARWIN_USER_TEMP_DIR"],capture_output=True,text=True).stdout.strip() if sys.platform=="darwin" else ""; print(os.path.realpath(d or "/tmp"))')
refused "the parent of the system temp dir is refused" -- "$(dirname "$SYSTMP")"
refused "TMPDIR=<parent of the system temp dir> does not widen the roots" "TMPDIR=$(dirname "$SYSTMP")" -- "$(dirname "$SYSTMP")/.mh-tmp-delete-probe-missing"
refused "a fake HOME does not hide the real one" HOME="$T/fakehome" -- "$REALHOME"

# Symlinks: a link that lives under the temp root is removed as a link, its target untouched;
# a path that reaches outside through a symlinked parent is refused.
mkdir -p "$T/target"; : > "$T/target/marker"
ln -s "$T/target" "$T/link"
python3 "$TD" "$T/link"; rc=$?
[ "$rc" -eq 0 ] && [ ! -L "$T/link" ] && [ -f "$T/target/marker" ] \
  && ok "a symlink is removed as a link; its target and contents stay" \
  || bad "symlink delete: rc=$rc, link left: $([ -L "$T/link" ] && echo yes || echo no), marker: $([ -f "$T/target/marker" ] && echo yes || echo no)"
ln -s /usr/bin "$T/outlink"
refused "a path through a symlinked parent that leaves the temp root is refused" -- "$T/outlink/true"
[ -e /usr/bin/true ] || bad "/usr/bin/true is gone"

python3 "$TD" "$T/never-made"; rc=$?
[ "$rc" -eq 0 ] && ok "a missing path under the temp root is a no-op success" || bad "missing temp path: rc=$rc"

mkdir -p "$T/dir/a/b"; : > "$T/dir/a/b/f"; : > "$T/file"
python3 "$TD" "$T/dir" "$T/file"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$T/dir" ] && [ ! -e "$T/file" ] \
  && ok "a nested dir and a file under the temp root are deleted" || bad "positive delete: rc=$rc"

# scripts/_lib/tmp-delete.sh captures python3 at source time (GH #729): a python3 stub put first
# on PATH afterwards (some tests do) must not turn the cleanup into a silent no-op.
mkdir -p "$T/stub" "$T/kept"; printf '#!/bin/sh\nexit 0\n' > "$T/stub/python3"; chmod +x "$T/stub/python3"
bash -c '. "$1/../../scripts/_lib/tmp-delete.sh"; PATH="$2:$PATH"; tmp_delete "$3"' _ "$HERE" "$T/stub" "$T/kept"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$T/kept" ] \
  && ok "tmp_delete uses the python3 captured at source time, not a later PATH stub" \
  || bad "a python3 stub on PATH after sourcing skipped the delete: rc=$rc"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
