#!/usr/bin/env bash
# eval-default-enabled.sh — run a command with this repo's own defaultEnabled forced true.
#
# Sourced (not executed) by callers. `claude plugin eval` sandboxes load no user settings
# (docs/en/plugin-evals.md "how runs are isolated"), so this repo's own
# .claude-plugin/plugin.json defaultEnabled: false (a deliberate opt-in choice for real
# installs) means the sandbox never loads mh's agents/skills at all -- every case silently
# scores a no-plugin fallback instead of the real ones, with no error (confirmed empirically
# 2026-09-26: identical with/without scores, plus the CLI's own runtime warning).
#
# Functions:
#   with_default_enabled_true <command...>
#       Flip defaultEnabled to true in .claude-plugin/plugin.json (repo root inferred from
#       this file's own location), run <command...>, restore defaultEnabled to false once
#       <command...> returns (any exit code) or the process is interrupted (INT/TERM/HUP).
#       No-op flip/restore if defaultEnabled is already true. A missing manifest, invalid JSON,
#       an ambiguous manifest (more than one defaultEnabled key, or a pre-existing true match
#       that would make the restore target ambiguous), or a shell other than bash (this relies
#       on BASH_SOURCE/BASH_VERSION -- silently a no-op under zsh/sh, confirmed 2026-09-26), is
#       a hard error: refuses to run <command...> rather than silently doing so with the plugin
#       still disabled.
#
# shellcheck shell=bash

with_default_enabled_true() {
  if [ -z "${BASH_VERSION:-}" ]; then
    echo "eval-default-enabled: must run under bash (BASH_SOURCE/BASH_VERSION are unset here) -- wrap the call in 'bash -c ...', don't source this from zsh/sh directly" >&2
    return 1
  fi

  # __ede_-prefixed names, not generic ones (manifest/flipped/prev_int/...): the restore
  # handlers below are called from a trap that can fire while bash's call stack is still inside
  # the WRAPPED command, if that command is a shell function. Bash resolves a bare variable name
  # by dynamic scope, so a wrapped function that happens to declare `local manifest=...` (or
  # flipped/prev_int/prev_term/prev_hup) for its own unrelated purpose would silently shadow the
  # real value and could leave defaultEnabled: true stuck in the committed manifest with no
  # warning. A prefix this distinctive is not a realistic accidental collision (found by the
  # blind-spot-hunter whole-picture pass 2026-09-27).
  local lib_dir root __ede_manifest __ede_flipped=0 __ede_rc __ede_current_enabled
  local __ede_prev_int __ede_prev_term __ede_prev_hup
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "$lib_dir/../.." && pwd)"
  __ede_manifest="$root/.claude-plugin/plugin.json"

  if [ ! -f "$__ede_manifest" ]; then
    echo "eval-default-enabled: ERROR no manifest at $__ede_manifest -- not running the wrapped command" >&2
    return 1
  fi

  # JSON-parsed, not a literal-string grep: a reformatted manifest (no space after the colon,
  # different indentation) still parses to the same boolean and must not silently skip the flip.
  # Errors are diagnosed here (specific reason on stderr from python) rather than guessed by bash.
  __ede_current_enabled="$(python3 -c "
import json, sys
p = '$__ede_manifest'
try:
    with open(p) as f:
        d = json.load(f)
except json.JSONDecodeError as e:
    print(f'eval-default-enabled: ERROR {p} is not valid JSON: {e}', file=sys.stderr)
    sys.exit(1)
if not isinstance(d, dict):
    print(f'eval-default-enabled: ERROR {p} top level is not a JSON object', file=sys.stderr)
    sys.exit(1)
print('false' if d.get('defaultEnabled') is False else 'true')
")" || {
    echo "eval-default-enabled: not running the wrapped command" >&2
    return 1
  }

  if [ "$__ede_current_enabled" = "false" ]; then
    if ! python3 -c "
import re
p = '$__ede_manifest'
s = open(p).read()
n_false = len(re.findall(r'\"defaultEnabled\"\s*:\s*false', s))
assert n_false == 1, f'expected exactly one defaultEnabled: false in {p}, found {n_false}'
n_true = len(re.findall(r'\"defaultEnabled\"\s*:\s*true', s))
assert n_true == 0, f'found {n_true} pre-existing defaultEnabled: true in {p} -- ambiguous restore target'
m = re.search(r'\"defaultEnabled\"(\s*):(\s*)false', s)
s2 = s[:m.start()] + f'\"defaultEnabled\"{m.group(1)}:{m.group(2)}true' + s[m.end():]
open(p, 'w').write(s2)
"; then
      echo "eval-default-enabled: ERROR failed to flip defaultEnabled in $__ede_manifest -- not running the wrapped command (would silently re-hit the no-plugin-fallback bug)" >&2
      return 1
    fi
    __ede_flipped=1
    echo "eval-default-enabled: temporarily set defaultEnabled: true in $__ede_manifest (restored once the wrapped command returns, or on INT/TERM/HUP)" >&2
  fi

  _restore_default_enabled() {
    [ "$__ede_flipped" -eq 1 ] || return 0
    # A terminal Ctrl-C reaches the whole process group, this python3 child included: killed
    # mid-restore, it left true in the tracked manifest with no warning (a double Ctrl-C ~20 ms
    # apart, 3/3). Ignored signals stay ignored in the child, so the write always finishes; a
    # signal that lands in this window is dropped, and every caller resets the traps right after.
    trap '' INT TERM HUP
    python3 -c "
import re, sys
p = '$__ede_manifest'
s = open(p).read()
m = re.search(r'\"defaultEnabled\"(\s*):(\s*)true', s)
n = len(re.findall(r'\"defaultEnabled\"\s*:\s*true', s))
if m and n == 1:
    s2 = s[:m.start()] + f'\"defaultEnabled\"{m.group(1)}:{m.group(2)}false' + s[m.end():]
    open(p, 'w').write(s2)
else:
    print(f'eval-default-enabled: WARNING could not restore defaultEnabled: false in {p} (found {n} matches) -- fix manually', file=sys.stderr)
" && __ede_flipped=0
    return 0
  }
  # Capture whatever signal traps the CALLER already had before we install our own, so we can
  # put them back instead of permanently clearing them to default disposition -- a caller that
  # wraps this call inside its own trap-based cleanup (e.g. a sweep script's EXIT trap) must get
  # its INT/TERM/HUP handling back afterward, not lose it silently.
  __ede_prev_int="$(trap -p INT)"
  __ede_prev_term="$(trap -p TERM)"
  __ede_prev_hup="$(trap -p HUP)"
  _restore_signal_traps() {
    trap - INT TERM HUP
    [ -n "$__ede_prev_int" ] && eval "$__ede_prev_int"
    [ -n "$__ede_prev_term" ] && eval "$__ede_prev_term"
    [ -n "$__ede_prev_hup" ] && eval "$__ede_prev_hup"
    # Explicit, not left to the last `[ -n ... ] && eval ...` above: that list's own exit status
    # (1 whenever the caller had no pre-existing trap of that kind -- the common case) would
    # otherwise become this function's return value, and a caller's `set -e` treats that as a
    # failure and aborts even though nothing actually went wrong (found by the blind-spot-hunter
    # whole-picture pass 2026-09-27: a successful with_default_enabled_true call still killed a
    # `set -e` caller with no error text).
    return 0
  }
  # RETURN alone only fires on normal function return -- it doesn't fire if a signal kills the
  # wrapped command mid-run, and it doesn't fire under a CALLER's `set -e` (errexit skips the
  # function's own RETURN trap and terminates the process outright). Two defenses: (1) `"$@" ||
  # rc=$?` keeps the wrapped command's own failure from ever triggering errexit, so control
  # always reaches `return "$rc"` and fires RETURN normally; (2) INT/TERM/HUP are trapped
  # separately, restore, then re-raise the same signal. If the caller's own restored trap does
  # not itself exit the process, the process survives the signal -- re-raising only re-delivers
  # it under whatever disposition is now in effect, it does not force termination. Every trap
  # also clears itself and reinstates whatever the caller had before, so nothing leaks into or
  # vanishes from the caller's shell.
  trap '_restore_default_enabled; trap - RETURN; _restore_signal_traps' RETURN
  trap '_restore_default_enabled; _restore_signal_traps; kill -INT $$' INT
  trap '_restore_default_enabled; _restore_signal_traps; kill -TERM $$' TERM
  trap '_restore_default_enabled; _restore_signal_traps; kill -HUP $$' HUP

  "$@" || __ede_rc=$?
  return "${__ede_rc:-0}"
}
