#!/usr/bin/env bash
# test-session-start-hook.sh — .claude/hooks/session-start.sh (PR #581) installs the gauntlet's
# tools, trash-cli and shfmt >= 3.5, only in cloud sessions and never blocks one: every case exits 0
# with empty stdout (SessionStart stdout is injected into the model's context). PATH holds only
# stubs, so no real apt-get, sudo or pip ever runs.
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
#   apt-ok   apt-get that prints to stdout like real apt, logs its call, and on install creates
#            `trash` and/or a shfmt 3.8.0 for the packages named
#   apt-old  apt-ok, but its shfmt is 3.4.3 (Ubuntu 22.04's, too old)
#   apt-fail apt-get that logs its call and fails
#   pip      pip that logs its call and creates a shfmt 3.10.0
#   trash    an already-installed trash
#   shfmt    an already-installed shfmt 3.8.0; shfmt-old: 3.4.3
stub_dir() {
  local d uid=$1; shift
  d=$(mktemp -d "$ROOT_DIR/s.XXXXXX") || return 1
  printf '#!/bin/sh\necho %s\n' "$uid" > "$d/id"
  for t in "$@"; do
    case $t in
      env) ln -s "$(command -v env)" "$d/env" ;;
      sudo) printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec /usr/bin/env -i PATH="$PATH" LOG="$LOG" "$@"\n' > "$d/sudo" ;;
      apt-ok|apt-old)
        v=3.8.0; [ "$t" = apt-old ] && v=3.4.3
        printf '#!/bin/sh\necho "Reading package lists..."\necho "FE=$DEBIAN_FRONTEND $*" >> "$LOG"\ncase "$*" in *install*trash-cli*) printf "#!/bin/sh\\n" > "%s/trash"; %s +x "%s/trash" ;; esac\ncase "$*" in *install*shfmt*) printf "#!/bin/sh\\necho v%s\\n" > "%s/shfmt"; %s +x "%s/shfmt" ;; esac\n' \
          "$d" "$(command -v chmod)" "$d" "$v" "$d" "$(command -v chmod)" "$d" > "$d/apt-get" ;;
      pip) printf '#!/bin/sh\necho "PIP $*" >> "$LOG"\nprintf "#!/bin/sh\\necho 3.10.0\\n" > "%s/shfmt"; %s +x "%s/shfmt"\n' "$d" "$(command -v chmod)" "$d" > "$d/pip" ;;
      shfmt) printf '#!/bin/sh\necho v3.8.0\n' > "$d/shfmt" ;;
      shfmt-old) printf '#!/bin/sh\necho v3.4.3\n' > "$d/shfmt" ;;
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

echo "=== session-start hook: cloud-only trash-cli and shfmt install ==="

d=$(stub_dir 0 env apt-ok); run "$d" unset
if clean_exit && [ -z "$err" ] && [ -z "$log" ] && [ ! -e "$d/trash" ]; then
  ok "CLAUDE_CODE_REMOTE unset: silent no-op, apt-get never called"
else bad "unset: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env apt-ok); run "$d" false
if clean_exit && [ -z "$err" ] && [ -z "$log" ]; then
  ok "CLAUDE_CODE_REMOTE=false: silent no-op"
else bad "remote=false: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash shfmt apt-ok); run "$d" true
if clean_exit && [ -z "$err" ] && [ -z "$log" ]; then
  ok "remote, trash and shfmt >= 3.5 already present: silent, apt-get never called"
else bad "trash present: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env shfmt); run "$d" true
if clean_exit && [ "$(printf '%s\n' "$err" | wc -l)" -eq 2 ] && /usr/bin/grep -q 'no apt-get' <<<"$err" && /usr/bin/grep -q 'no `trash` command' <<<"$err"; then
  ok "remote, no apt-get: a note for apt-get and one for trash on stderr, exit 0"
else bad "no apt-get: rc=$rc out='$out' err='$err'"; fi

d=$(stub_dir 1000 env shfmt apt-ok); run "$d" true
if clean_exit && /usr/bin/grep -q 'no sudo' <<<"$err" && [ -z "$log" ]; then
  ok "remote, non-root, no sudo: one stderr warning, apt-get never called"
else bad "no sudo: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env shfmt apt-ok); run "$d" true
if clean_exit && [ "$err" = "Reading package lists..." ] && [ -x "$d/trash" ] && [ "$log" = "FE=noninteractive -q install -y trash-cli" ]; then
  ok "remote, root: one noninteractive install, no update, apt output on stderr only"
else bad "root install: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 1000 env shfmt sudo apt-ok); run "$d" true
if clean_exit && [ "$err" = "Reading package lists..." ] && [ -x "$d/trash" ] && [ "$log" = "FE=noninteractive -q install -y trash-cli" ]; then
  ok "remote, non-root via sudo: DEBIAN_FRONTEND survives sudo's env reset, apt output on stderr only"
else bad "sudo install: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env shfmt apt-fail); run "$d" true
want=$'FE=noninteractive -q install -y trash-cli\nFE=noninteractive -q update'
if clean_exit && [ "$log" = "$want" ] && /usr/bin/grep -q 'apt-get install trash-cli failed' <<<"$err"; then
  ok "remote, apt-get fails: install, then update, then one warning, exit 0"
else bad "apt fails: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash apt-ok); run "$d" true
if clean_exit && [ "$err" = "Reading package lists..." ] && [ "$("$d/shfmt" --version)" = v3.8.0 ] && [ "$log" = "FE=noninteractive -q install -y shfmt" ]; then
  ok "remote, trash present, no shfmt: apt installs shfmt alone"
else bad "shfmt only: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env apt-ok); run "$d" true
if clean_exit && [ -x "$d/trash" ] && [ -x "$d/shfmt" ] && [ "$log" = "FE=noninteractive -q install -y trash-cli shfmt" ]; then
  ok "remote, both missing: one apt call installs trash-cli and shfmt"
else bad "both missing: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash shfmt-old apt-ok pip); run "$d" true
if clean_exit && [ "$log" = "FE=noninteractive -q install -y shfmt" ] && [ "$("$d/shfmt" --version)" = v3.8.0 ] && ! /usr/bin/grep -q 'session-start:' <<<"$err"; then
  ok "remote, shfmt 3.4 present: apt upgrades it to 3.8, pip never runs, no warning"
else bad "old shfmt: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash apt-old pip); run "$d" true
want=$'FE=noninteractive -q install -y shfmt\nPIP install -q shfmt-py'
if clean_exit && [ "$log" = "$want" ] && [ "$("$d/shfmt" --version)" = 3.10.0 ]; then
  ok "remote, apt only has shfmt 3.4 (Ubuntu 22.04): pip's shfmt-py is installed after it"
else bad "apt old shfmt: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash apt-old); run "$d" true
if clean_exit && /usr/bin/grep -q 'no shfmt >= 3.5' <<<"$err"; then
  ok "remote, shfmt 3.4 from apt and no pip: one note naming shfmt >= 3.5, exit 0"
else bad "old shfmt, no pip: rc=$rc out='$out' err='$err' log='$log'"; fi

safe_trash "$ROOT_DIR"
echo "session-start hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
