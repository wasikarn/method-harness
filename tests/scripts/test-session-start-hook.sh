#!/usr/bin/env bash
# test-session-start-hook.sh — .claude/hooks/session-start.sh (PR #581) installs trash-cli only in
# cloud sessions and never blocks one: every case exits 0 with empty stdout (SessionStart stdout is
# injected into the model's context). PATH holds only stubs, so no real apt-get or sudo ever runs.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
HOOK="$HERE/../../.claude/hooks/session-start.sh"
BASH_BIN="$(command -v bash)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_trash() { [ -n "${1:-}" ] && trash "$1" 2>/dev/null; return 0; }

ROOT_DIR="$(mktemp -d)"
[ -n "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ] || { echo "mktemp -d failed" >&2; exit 1; }

# stub_dir <uid> <tools...>: a fresh PATH dir with a fake `id` and the named stubs.
#   env      the real env (the hook runs apt-get through it)
#   sudo     mimics env_reset: drops everything but PATH and LOG, so DEBIAN_FRONTEND must be
#            passed inside the sudo call to reach apt-get
#   apt-ok   apt-get that prints to stdout like real apt, logs its call, creates `trash` on install
#   apt-fail apt-get that logs its call and fails
#   trash    an already-installed trash
stub_dir() {
  local d uid=$1; shift
  d=$(mktemp -d "$ROOT_DIR/s.XXXXXX") || return 1
  printf '#!/bin/sh\necho %s\n' "$uid" > "$d/id"
  for t in "$@"; do
    case $t in
      env) ln -s "$(command -v env)" "$d/env" ;;
      sudo) printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec /usr/bin/env -i PATH="$PATH" LOG="$LOG" "$@"\n' > "$d/sudo" ;;
      apt-ok) printf '#!/bin/sh\necho "Reading package lists..."\necho "FE=$DEBIAN_FRONTEND $*" >> "$LOG"\ncase "$*" in *install*) printf "#!/bin/sh\\n" > "%s/trash"; %s +x "%s/trash" ;; esac\n' "$d" "$(command -v chmod)" "$d" > "$d/apt-get" ;;
      apt-fail) printf '#!/bin/sh\necho "Reading package lists..."\necho "FE=$DEBIAN_FRONTEND $*" >> "$LOG"\nexit 1\n' > "$d/apt-get" ;;
      trash) printf '#!/bin/sh\n' > "$d/trash" ;;
    esac
  done
  chmod +x "$d"/*
  printf '%s' "$d"
}

# run <stub dir> <remote value or "unset">: sets rc, out, err, log.
run() {
  local d=$1 remote=$2 e="$ROOT_DIR/err"
  : > "$d.log"
  if [ "$remote" = unset ]; then
    out=$(env -u CLAUDE_CODE_REMOTE PATH="$d" LOG="$d.log" "$BASH_BIN" "$HOOK" 2>"$e" </dev/null); rc=$?
  else
    out=$(CLAUDE_CODE_REMOTE="$remote" PATH="$d" LOG="$d.log" "$BASH_BIN" "$HOOK" 2>"$e" </dev/null); rc=$?
  fi
  err=$(cat "$e"); log=$(cat "$d.log")
}

# clean_exit: exit 0 and empty stdout, the hook's contract in every case.
clean_exit() { [ "$rc" -eq 0 ] && [ -z "$out" ]; }

echo "=== session-start hook: cloud-only trash-cli install ==="

d=$(stub_dir 0 env apt-ok); run "$d" unset
if clean_exit && [ -z "$err" ] && [ -z "$log" ] && [ ! -e "$d/trash" ]; then
  ok "CLAUDE_CODE_REMOTE unset: silent no-op, apt-get never called"
else bad "unset: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env apt-ok); run "$d" false
if clean_exit && [ -z "$err" ] && [ -z "$log" ]; then
  ok "CLAUDE_CODE_REMOTE=false: silent no-op"
else bad "remote=false: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash apt-ok); run "$d" true
if clean_exit && [ -z "$err" ] && [ -z "$log" ]; then
  ok "remote, trash already present: silent, apt-get never called"
else bad "trash present: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env); run "$d" true
if clean_exit && [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ] && /usr/bin/grep -q 'no apt-get' <<<"$err"; then
  ok "remote, no apt-get: one stderr warning, exit 0"
else bad "no apt-get: rc=$rc out='$out' err='$err'"; fi

d=$(stub_dir 1000 env apt-ok); run "$d" true
if clean_exit && /usr/bin/grep -q 'no sudo' <<<"$err" && [ -z "$log" ]; then
  ok "remote, non-root, no sudo: one stderr warning, apt-get never called"
else bad "no sudo: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env apt-ok); run "$d" true
if clean_exit && [ "$err" = "Reading package lists..." ] && [ -x "$d/trash" ] && [ "$log" = "FE=noninteractive -q install -y trash-cli" ]; then
  ok "remote, root: one noninteractive install, no update, apt output on stderr only"
else bad "root install: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 1000 env sudo apt-ok); run "$d" true
if clean_exit && [ "$err" = "Reading package lists..." ] && [ -x "$d/trash" ] && [ "$log" = "FE=noninteractive -q install -y trash-cli" ]; then
  ok "remote, non-root via sudo: DEBIAN_FRONTEND survives sudo's env reset, apt output on stderr only"
else bad "sudo install: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env apt-fail); run "$d" true
want=$'FE=noninteractive -q install -y trash-cli\nFE=noninteractive -q update'
if clean_exit && [ "$log" = "$want" ] && /usr/bin/grep -q 'apt-get install trash-cli failed' <<<"$err"; then
  ok "remote, apt-get fails: install, then update, then one warning, exit 0"
else bad "apt fails: rc=$rc out='$out' err='$err' log='$log'"; fi

safe_trash "$ROOT_DIR"
echo "session-start hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
