#!/usr/bin/env bash
# test-eval-default-enabled.sh — exercises scripts/_lib/eval-default-enabled.sh's flip/restore
# logic against a scratch copy of the manifest, never the real repo's .claude-plugin/plugin.json.
# `with_default_enabled_true` infers its repo root from its own BASH_SOURCE, so each case sources
# a fresh copy of the lib under a throwaway "$scripts/_lib/eval-default-enabled.sh" + fixture
# ".claude-plugin/plugin.json" tree, isolating it from the real manifest.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
LIB_SRC="$ROOT/scripts/_lib/eval-default-enabled.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== eval-default-enabled.sh self-test ==="

new_sandbox() {
  # $1: initial plugin.json body (one or more "defaultEnabled": ... lines)
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/scripts/_lib" "$dir/.claude-plugin"
  cp "$LIB_SRC" "$dir/scripts/_lib/eval-default-enabled.sh"
  printf '%s' "$1" > "$dir/.claude-plugin/plugin.json"
  echo "$dir"
}

# A wrapped command that is an external child (so bash defers the trapped signal until it exits,
# as with the old `sleep 3`): it touches $1 once running (flip and traps are already in place),
# then exits once $2 appears. Polling replaces a fixed 3 s sleep and the racy 0.3 s head start.
# Capped at ~10 s and stops when the sandbox is gone, so a broken wrapper leaves no orphan behind.
HOLD='sh -c '"'"'touch "$1"; i=0; while [ ! -e "$2" ] && [ -d "${2%/*}" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done'"'"' hold'
# signal_and_release <sig> <pid> <sandbox>: wait for the child to run, signal the wrapper, then
# let the child exit so the deferred trap fires.
signal_and_release() {
  local _
  for _ in $(seq 1 200); do [ -e "$3/ready" ] && break; sleep 0.05; done
  kill -"$1" "$2"
  touch "$3/go"
  wait "$2" 2>/dev/null
}

# --- normal flip + restore on success ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
during=$(bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true cat '$sandbox/.claude-plugin/plugin.json'
")
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$during" == *'"defaultEnabled": true'* ]] && ok "flips true during the wrapped command" \
  || bad "did not flip true during the wrapped command (got: $during)"
[[ "$after" == *'"defaultEnabled": false'* ]] && ok "restores false after normal return" \
  || bad "did not restore false after normal return (got: $after)"
rm -rf "$sandbox"

# --- restores even when the wrapped command fails ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true false
" >/dev/null 2>&1
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$after" == *'"defaultEnabled": false'* ]] && ok "restores false when the wrapped command exits non-zero" \
  || bad "did not restore false after wrapped-command failure (got: $after)"
rm -rf "$sandbox"

# --- restores even under a CALLER's own `set -e` (errexit skips a function's RETURN trap
# entirely unless the wrapped command's own failure is defused first before the function itself
# returns that same failure to the caller -- the caller then legitimately stops there, same as
# for any other failing command under set -e; the property under test is only that the restore
# already happened by that point, not that the caller keeps going) ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
bash -c "
set -e
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true false
echo should-not-reach-here
" >/dev/null 2>&1
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$after" == *'"defaultEnabled": false'* ]] && ok "restores false under a caller's set -e, before errexit aborts the caller" \
  || bad "did not restore false under set -e (got: $after)"
rm -rf "$sandbox"

# --- restores once a SIGTERM'd wrapped command exits (regression: RETURN alone never fires on
# a signal, per matt-harness commit d44c31fe -> 4254f657). Bash defers a trapped signal until
# the current foreground child exits, so this proves "restored after", not "interrupted mid-run" ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true $HOLD '$sandbox/ready' '$sandbox/go'
" &
runner_pid=$!
signal_and_release TERM "$runner_pid" "$sandbox"
status=$?
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$after" == *'"defaultEnabled": false'* ]] && ok "restores false once a SIGTERM'd wrapped command exits" \
  || bad "left defaultEnabled true after SIGTERM (got: $after)"
[ "$status" -ne 0 ] && ok "SIGTERM still actually terminates the wrapper (exit $status)" \
  || bad "wrapper survived SIGTERM instead of terminating (exit $status)"
rm -rf "$sandbox"

# --- same, for SIGHUP (e.g. a closed terminal/dropped SSH session mid-eval) ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true $HOLD '$sandbox/ready' '$sandbox/go'
" &
runner_pid=$!
signal_and_release HUP "$runner_pid" "$sandbox"
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$after" == *'"defaultEnabled": false'* ]] && ok "restores false once a SIGHUP'd wrapped command exits" \
  || bad "left defaultEnabled true after SIGHUP (got: $after)"
rm -rf "$sandbox"

# --- ambiguous manifest (2 matches): flip aborts loudly instead of silently no-op'ing ---
sandbox="$(new_sandbox '{"defaultEnabled": false, "other": {"defaultEnabled": false}}')"
before=$(cat "$sandbox/.claude-plugin/plugin.json")
out=$(bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true echo ran
" 2>&1)
status=$?
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[ "$status" -ne 0 ] && ok "ambiguous manifest: with_default_enabled_true returns non-zero" \
  || bad "ambiguous manifest: exited 0 (expected a hard failure)"
[[ "$out" != *"ran"* ]] && ok "ambiguous manifest: wrapped command never runs" \
  || bad "ambiguous manifest: wrapped command ran anyway with the plugin still disabled"
[ "$after" = "$before" ] && ok "ambiguous manifest: file left untouched" \
  || bad "ambiguous manifest: file was modified despite the abort (got: $after)"
rm -rf "$sandbox"

# --- a pre-existing, unrelated "defaultEnabled": true elsewhere in the file aborts the flip too
# (regression guard: found by the blind-spot-hunter whole-picture pass 2026-09-27 -- the flip
# used to only require exactly one "false" match, so it would happily flip the real key even
# with an unrelated "true" already present; the restore step then found 2 "true" matches,
# refused to touch the file, and left defaultEnabled: true stuck in the committed manifest with
# only a WARNING, not a hard failure) ---
sandbox="$(new_sandbox '{"defaultEnabled": false, "other": {"defaultEnabled": true}}')"
before=$(cat "$sandbox/.claude-plugin/plugin.json")
out=$(bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true echo ran
" 2>&1)
status=$?
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[ "$status" -ne 0 ] && ok "pre-existing true elsewhere: with_default_enabled_true returns non-zero" \
  || bad "pre-existing true elsewhere: exited 0 (expected a hard failure)"
[[ "$out" != *"ran"* ]] && ok "pre-existing true elsewhere: wrapped command never runs" \
  || bad "pre-existing true elsewhere: wrapped command ran anyway with the plugin still disabled"
[ "$after" = "$before" ] && ok "pre-existing true elsewhere: file left untouched" \
  || bad "pre-existing true elsewhere: file was modified despite the abort (got: $after)"
rm -rf "$sandbox"

# --- missing manifest: hard error, not a silent no-op ---
sandbox="$(mktemp -d)"
mkdir -p "$sandbox/scripts/_lib"
cp "$LIB_SRC" "$sandbox/scripts/_lib/eval-default-enabled.sh"
out=$(bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true echo ran
" 2>&1)
status=$?
[ "$status" -ne 0 ] && ok "missing manifest: with_default_enabled_true returns non-zero" \
  || bad "missing manifest: exited 0 (expected a hard failure)"
[[ "$out" != *"ran"* ]] && ok "missing manifest: wrapped command never runs" \
  || bad "missing manifest: wrapped command ran anyway"
rm -rf "$sandbox"

# --- already-true manifest: no-op flip, no incorrect restore-to-false ---
sandbox="$(new_sandbox '{"defaultEnabled": true}')"
bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true true
" >/dev/null 2>&1
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$after" == *'"defaultEnabled": true'* ]] && ok "already-true manifest is left true, not incorrectly restored to false" \
  || bad "already-true manifest was incorrectly changed (got: $after)"
rm -rf "$sandbox"

# --- non-bash caller (zsh): refuses instead of silently no-op'ing with the plugin still
# disabled (BASH_SOURCE/BASH_VERSION are unset under zsh, confirmed 2026-09-26) ---
if command -v zsh >/dev/null 2>&1; then
  sandbox="$(new_sandbox '{"defaultEnabled": false}')"
  before=$(cat "$sandbox/.claude-plugin/plugin.json")
  out=$(zsh -c "
cd '$sandbox'
source scripts/_lib/eval-default-enabled.sh
with_default_enabled_true echo ran
" 2>&1)
  status=$?
  after=$(cat "$sandbox/.claude-plugin/plugin.json")
  [ "$status" -ne 0 ] && ok "zsh caller: with_default_enabled_true returns non-zero" \
    || bad "zsh caller: exited 0 (expected a hard failure)"
  [[ "$out" != *"ran"* ]] && ok "zsh caller: wrapped command never runs" \
    || bad "zsh caller: wrapped command ran anyway with the plugin still disabled"
  [ "$after" = "$before" ] && ok "zsh caller: file left untouched" \
    || bad "zsh caller: file was modified despite the refusal (got: $after)"
  rm -rf "$sandbox"
else
  echo "  SKIP: zsh not installed, skipping non-bash-caller case"
fi

# --- the manifest check is JSON-formatting-tolerant, not an exact-string grep (regression
# guard: a compact/reformatted "defaultEnabled":false with no space after the colon used to
# silently miss the grep and skip the flip entirely, re-hitting the no-plugin-fallback bug this
# helper exists to prevent). Also checks the restore is byte-exact for the REST of the file, not
# just correct on the boolean: normalizing to a fixed "defaultEnabled": true/false spacing would
# leave the file's formatting different from before the call even after a successful round trip,
# which shows up as a spurious dirty-tree diff on the real, git-tracked plugin.json (found by the
# blind-spot-hunter whole-picture pass 2026-09-27 -- the prior version of this test only checked
# for the spaced form, which baked that normalization in as if it were correct) ---
before='{"defaultEnabled":false}'
sandbox="$(new_sandbox "$before")"
during=$(bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true cat '$sandbox/.claude-plugin/plugin.json'
")
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$during" == *'"defaultEnabled":true'* ]] && ok "flips true on a compact-JSON (no-space) manifest, preserving its spacing" \
  || bad "did not flip a compact-JSON manifest, or normalized its spacing (got: $during)"
[ "$after" = "$before" ] && ok "restores a compact-JSON manifest byte-for-byte" \
  || bad "did not restore the compact-JSON manifest exactly (got: $after, want: $before)"
rm -rf "$sandbox"

# --- a caller's pre-existing TERM trap disposition survives a normal return, instead of being
# permanently cleared to default disposition (regression guard: found by mh:deep-audit
# 2026-09-26 -- the function used to unconditionally `trap - INT TERM HUP` on the way out,
# discarding whatever the caller had installed before calling it). Compares before/after `trap
# -p` output rather than asserting a literal trap string. Uses TERM, not INT: a non-interactive
# shell that inherits SIGINT as ignored (the gauntlet's own execution context does) silently
# refuses to install ANY new trap on it (documented bash behavior), so an INT-based version of
# this test can't fail in that context even when the restore logic is broken (found by the
# blind-spot-hunter whole-picture pass 2026-09-27, proven with a live mutation:
# deleting the eval-restore line kept this test green when run through the gauntlet, but red
# when run directly). TERM has no such restriction, so it actually discriminates in both contexts ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
out=$(bash -c "
trap 'echo caller-term-trap-fired' TERM
before=\$(trap -p TERM)
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true true >/dev/null 2>&1
after=\$(trap -p TERM)
[ \"\$before\" = \"\$after\" ] && echo MATCH || echo \"MISMATCH before=[\$before] after=[\$after]\"
")
[[ "$out" == "MATCH" ]] && ok "caller's pre-existing TERM trap disposition is restored after normal return" \
  || bad "caller's TERM trap disposition changed after normal return ($out)"
rm -rf "$sandbox"

# --- a caller's own set -e does not abort after with_default_enabled_true SUCCEEDS (regression
# guard: found by the blind-spot-hunter whole-picture pass 2026-09-27 -- _restore_signal_traps'
# last statement was a bare `[ -n "$prev_hup" ] && eval ...`, which returns 1 when the caller had
# no pre-existing HUP trap (the common case); that 1 became the RETURN trap's own exit status,
# which set -e treats as a command failure and aborts the caller even though the wrapped command
# and the whole flip/restore cycle succeeded) ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
out=$(bash -c "
set -e
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true true
echo REACHED
" 2>&1)
status=$?
[[ "$out" == *REACHED* ]] && [ "$status" -eq 0 ] && ok "a caller's set -e does not abort after with_default_enabled_true succeeds" \
  || bad "set -e caller aborted after a successful call (status $status, out: $out)"
rm -rf "$sandbox"

# --- the wrapped command being a shell function that declares its own `local manifest`/`local
# prev_term` etc. must not hide the real values from the restore handlers (regression guard:
# found by the blind-spot-hunter whole-picture pass 2026-09-27 -- the handlers read $manifest/
# $flipped/$prev_* by bash's normal dynamic scoping, so a SIGTERM delivered while executing
# inside a wrapped function that happens to declare a same-named local shadows the real value
# and can leave defaultEnabled: true stuck in the committed manifest with no warning) ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
bash -c "
wrapped() {
  local manifest=/nonexistent flipped=0 prev_term=''
  $HOLD '$sandbox/ready' '$sandbox/go'
}
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true wrapped
" &
runner_pid=$!
signal_and_release TERM "$runner_pid" "$sandbox"
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$after" == *'"defaultEnabled": false'* ]] && ok "restore is immune to a wrapped function's own same-named locals" \
  || bad "a wrapped function's own locals shadowed the real values (got: $after)"
rm -rf "$sandbox"

# --- traps don't leak into the caller's shell after a normal return (a later kill -TERM/-INT/
# -HUP in the SAME shell must not hit a stale trap referencing an out-of-scope $flipped) ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
out=$(bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true true >/dev/null 2>&1
trap -p RETURN INT TERM HUP
")
# Not a plain emptiness check: a caller whose own environment already ignores a signal (e.g. a
# backgrounded job under a test runner) reports it via 'trap -- \"\" SIGNAME', which is an
# inherited disposition, not a trap this function left behind -- only the function's own handler
# name is a real leak.
[[ "$out" != *"_restore_default_enabled"* ]] && ok "no _restore_default_enabled trap remains registered after a normal return" \
  || bad "a trap leaked into the caller's shell after return (trap -p: $out)"
rm -rf "$sandbox"

# --- a Ctrl-C that lands while the restore itself runs must not leave defaultEnabled true. A
# terminal Ctrl-C reaches the whole process group, the restore's python3 child included, so a
# python3 shim first on PATH sends itself SIGINT on the restore call only (its program holds
# "could not restore") before handing off to the real one. Before the fix this left true with
# no warning, 3/3, from a double Ctrl-C ~20 ms apart (attacker repro, 2026-10-31) ---
sandbox="$(new_sandbox '{"defaultEnabled": false}')"
mkdir -p "$sandbox/bin"
printf '#!/usr/bin/env bash\ncase "$*" in *"could not restore"*) kill -INT $$ ;; esac\nexec %q "$@"\n' "$(command -v python3)" >"$sandbox/bin/python3"
chmod +x "$sandbox/bin/python3"
# SIGINT reset to default first: a backgrounded test run starts with it ignored, which would make
# the shim's kill a no-op with or without the fix.
PATH="$sandbox/bin:$PATH" "$(command -v python3)" -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' bash -c "
source '$sandbox/scripts/_lib/eval-default-enabled.sh'
with_default_enabled_true true
" >/dev/null 2>&1
after=$(cat "$sandbox/.claude-plugin/plugin.json")
[[ "$after" == *'"defaultEnabled": false'* ]] && ok "restores false when SIGINT hits the restore's own python3" \
  || bad "a SIGINT during the restore left defaultEnabled true (got: $after)"
rm -rf "$sandbox"

echo
echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
