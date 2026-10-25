#!/usr/bin/env bash
# test-session-start-hook.sh — .claude/hooks/session-start.sh (PR #581) installs the gauntlet's
# tools, trash-cli and a shfmt the pipe-into-grep-q scanner can read, only in cloud sessions and
# never blocks one: every case exits 0 with empty stdout (SessionStart stdout is injected into the
# model's context). PATH holds only stubs (plus the real python3 the hook runs the scanner's canary
# with), so no real apt-get, sudo, pip or shfmt ever runs.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
HOOK="${SESSION_START_HOOK:-$HERE/../../.claude/hooks/session-start.sh}"
BASH_BIN="$(command -v bash)"
PY_BIN="$(command -v python3)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_trash() { [ -n "${1:-}" ] && trash "$1" 2>/dev/null; return 0; }

ROOT_DIR="$(mktemp -d)"
[ -n "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ] || { echo "mktemp -d failed" >&2; exit 1; }
ROOT_DIR="$(cd -P "$ROOT_DIR" && pwd)"  # the hook reports pip's dir via cd -P (macOS: /var is /private/var)

# The scanner's canary `x | grep -q y` as an upstream shfmt's --to-json gives it (trimmed to the
# fields the scanner reads), and as Ubuntu 24.04's apt shfmt 3.8.0 does: the pipe's Op a number.
GOOD='{"Type":"File","Stmts":[{"Cmd":{"Type":"BinaryCmd","Op":"|","X":{"Cmd":{"Type":"CallExpr","Args":[{"Parts":[{"Type":"Lit","Value":"x"}]}]}},"Y":{"Cmd":{"Type":"CallExpr","Pos":{"Line":1},"Args":[{"Parts":[{"Type":"Lit","Value":"grep"}]},{"Parts":[{"Type":"Lit","Value":"-q"}]},{"Parts":[{"Type":"Lit","Value":"y"}]}]}}}}]}'
printf '%s\n' "$GOOD" > "$ROOT_DIR/good.json"
printf '%s\n' "${GOOD/\"|\"/12}" > "$ROOT_DIR/numeric.json"

# mk_shfmt <path> <kind>: good (upstream 3.14.1), numeric (apt 3.8.0) or old (apt 3.4.3, no --to-json).
mk_shfmt() {
  local cat; cat=$(command -v cat)
  case $2 in
    good) printf '#!/bin/sh\ncase "$*" in *--to-json*) "%s" "%s" ;; *) echo v3.14.1 ;; esac\n' "$cat" "$ROOT_DIR/good.json" ;;
    numeric) printf '#!/bin/sh\ncase "$*" in *--to-json*) "%s" "%s" ;; *) echo 3.8.0 ;; esac\n' "$cat" "$ROOT_DIR/numeric.json" ;;
    old) printf '#!/bin/sh\ncase "$*" in *--to-json*) echo "flag provided but not defined: -to-json" >&2; exit 2 ;; *) echo v3.4.3 ;; esac\n' ;;
  esac > "$1"
  chmod +x "$1"
}

# stub_dir <uid> <tools...>: a fresh PATH dir with a fake `id`, the real python3, and the named stubs.
#   env      the real env (the hook runs apt-get through it)
#   sudo     mimics env_reset: drops everything but PATH and LOG, so DEBIAN_FRONTEND must be
#            passed inside the sudo call to reach apt-get
#   apt-ok   apt-get that prints to stdout like real apt, logs its call, and on install creates
#            `trash` and/or a numeric shfmt for the packages named
#   apt-fail apt-get that logs its call and fails
#   pip      pip that logs `install` (with PIP_BREAK_SYSTEM_PACKAGES) and puts a good shfmt in
#            <dir>/pipbin; `show -f shfmt-py` lists it the way real pip does (Location plus a
#            relative ../pipbin/shfmt), and fails before the install
#   pip-fail pip whose install logs its call and fails
#   trash    an already-installed trash
#   shfmt    an already-installed good shfmt; shfmt-numeric, shfmt-old: apt's 3.8.0 and 3.4.3
stub_dir() {
  local d uid=$1; shift
  d=$(mktemp -d "$ROOT_DIR/s.XXXXXX") || return 1
  printf '#!/bin/sh\necho %s\n' "$uid" > "$d/id"
  ln -s "$PY_BIN" "$d/python3"
  for t in "$@"; do
    case $t in
      env) ln -s "$(command -v env)" "$d/env" ;;
      sudo) printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec /usr/bin/env -i PATH="$PATH" LOG="$LOG" "$@"\n' > "$d/sudo" ;;
      apt-ok)
        printf '#!/bin/sh\necho "Reading package lists..."\necho "FE=$DEBIAN_FRONTEND $*" >> "$LOG"\ncase "$*" in *install*trash-cli*) printf "#!/bin/sh\\n" > "%s/trash"; %s +x "%s/trash" ;; esac\ncase "$*" in *install*shfmt*) %s "%s/shfmt" "%s/shfmt" ;; esac\n' \
          "$d" "$(command -v chmod)" "$d" "$(command -v cp)" "$ROOT_DIR/numeric.shfmt" "$d" > "$d/apt-get" ;;
      pip) mkdir -p "$d/site"
        printf '#!/bin/sh\ncase $1 in\n  show) [ -x "%s/pipbin/shfmt" ] || exit 1; printf "Name: shfmt-py\\nLocation: %s/site\\nFiles:\\n  ../pipbin/shfmt\\n  shfmt_py.dist-info/licenses/LICENSE-shfmt\\n" ;;\n  install) echo "PIP $* BSP=$PIP_BREAK_SYSTEM_PACKAGES" >> "$LOG"; %s -p "%s/pipbin"; %s "%s" "%s/pipbin/shfmt" ;;\nesac\n' \
          "$d" "$d" "$(command -v mkdir)" "$d" "$(command -v cp)" "$ROOT_DIR/good.shfmt" "$d" > "$d/pip" ;;
      pip-fail) printf '#!/bin/sh\n[ "$1" = install ] || exit 1\necho "PIP $*" >> "$LOG"\nexit 1\n' > "$d/pip" ;;
      shfmt) mk_shfmt "$d/shfmt" good ;;
      shfmt-numeric) mk_shfmt "$d/shfmt" numeric ;;
      shfmt-old) mk_shfmt "$d/shfmt" old ;;
      apt-fail) printf '#!/bin/sh\necho "Reading package lists..."\necho "FE=$DEBIAN_FRONTEND $*" >> "$LOG"\nexit 1\n' > "$d/apt-get" ;;
      trash) printf '#!/bin/sh\n' > "$d/trash" ;;
    esac
  done
  chmod +x "$d"/*
  printf '%s' "$d"
}
mk_shfmt "$ROOT_DIR/good.shfmt" good
mk_shfmt "$ROOT_DIR/numeric.shfmt" numeric

# run <stub dir> <remote value or "unset"> [PATH]: sets rc, out, err, log, envf (what the hook
# wrote to CLAUDE_ENV_FILE). PATH defaults to <dir>/pipbin before <dir>, the way Ubuntu puts
# /usr/local/bin (pip's) before /usr/bin (apt's).
run() {
  local d=$1 remote=$2 p=${3:-$1/pipbin:$1} e="$ROOT_DIR/err"
  : > "$d.log"; : > "$d.env"
  if [ "$remote" = unset ]; then
    out=$(env -u CLAUDE_CODE_REMOTE PATH="$p" LOG="$d.log" CLAUDE_ENV_FILE="$d.env" "$BASH_BIN" "$HOOK" 2>"$e" </dev/null); rc=$?
  else
    out=$(CLAUDE_CODE_REMOTE="$remote" PATH="$p" LOG="$d.log" CLAUDE_ENV_FILE="$d.env" "$BASH_BIN" "$HOOK" 2>"$e" </dev/null); rc=$?
  fi
  err=$(cat "$e"); log=$(cat "$d.log"); envf=$(cat "$d.env")
}

# clean_exit: exit 0 and empty stdout, the hook's contract in every case.
clean_exit() { [ "$rc" -eq 0 ] && [ -z "$out" ]; }
PIP_LOG="PIP install -q shfmt-py BSP=1"

echo "=== session-start hook: cloud-only trash-cli and shfmt install ==="

d=$(stub_dir 0 env apt-ok pip); run "$d" unset
if clean_exit && [ -z "$err" ] && [ -z "$log" ] && [ ! -e "$d/trash" ]; then
  ok "CLAUDE_CODE_REMOTE unset: silent no-op, apt-get and pip never called"
else bad "unset: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env apt-ok pip); run "$d" false
if clean_exit && [ -z "$err" ] && [ -z "$log" ]; then
  ok "CLAUDE_CODE_REMOTE=false: silent no-op"
else bad "remote=false: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash shfmt apt-ok pip); run "$d" true
if clean_exit && [ -z "$err" ] && [ -z "$log" ] && [ -z "$envf" ]; then
  ok "remote, trash and a usable shfmt already present: silent, apt-get and pip never called"
else bad "all present: rc=$rc out='$out' err='$err' log='$log'"; fi

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

d=$(stub_dir 0 env trash apt-ok pip); run "$d" true
if clean_exit && [ "$log" = "$PIP_LOG" ] && [ ! -e "$d/shfmt" ] && [ -z "$err" ] && [ -z "$envf" ]; then
  ok "remote, trash present, no shfmt: pip installs shfmt-py (PEP 668 override set), apt never asked for shfmt"
else bad "shfmt only: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env apt-ok pip); run "$d" true
want=$'FE=noninteractive -q install -y trash-cli\n'"$PIP_LOG"
if clean_exit && [ -x "$d/trash" ] && [ -x "$d/pipbin/shfmt" ] && [ "$log" = "$want" ]; then
  ok "remote, both missing: apt installs trash-cli alone, pip installs shfmt-py"
else bad "both missing: rc=$rc out='$out' err='$err' log='$log'"; fi

# The bug this hook once had: apt's 3.8.0 passed a version check, so pip never ran (PR #624).
d=$(stub_dir 0 env trash shfmt-numeric pip); run "$d" true
if clean_exit && [ "$log" = "$PIP_LOG" ] && [ -z "$err" ] && [ -z "$envf" ] \
  && [ "$(PATH="$d/pipbin:$d" command -v shfmt)" = "$d/pipbin/shfmt" ]; then
  ok "remote, apt's 3.8.0 (numeric Op) present: pip's shfmt-py is installed and wins on PATH"
else bad "numeric shfmt: rc=$rc out='$out' err='$err' log='$log' envf='$envf'"; fi
run "$d" true
if clean_exit && [ -z "$log" ] && [ -z "$err" ]; then
  ok "remote, second run after that install: silent no-op"
else bad "numeric shfmt, second run: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash shfmt-old pip); run "$d" true
if clean_exit && [ "$log" = "$PIP_LOG" ] && [ -z "$err" ]; then
  ok "remote, apt's 3.4 (no --to-json) present: pip's shfmt-py is installed"
else bad "old shfmt: rc=$rc out='$out' err='$err' log='$log'"; fi

# pip's directory after apt's on PATH: the hook puts it first through CLAUDE_ENV_FILE, and a later
# session (whose PATH is reset) does not reinstall, it only writes the PATH line again.
d=$(stub_dir 0 env trash shfmt-numeric pip); run "$d" true "$d:$d/pipbin"
want="export PATH=$d/pipbin:\"\$PATH\""
if clean_exit && [ "$log" = "$PIP_LOG" ] && [ "$envf" = "$want" ] && /usr/bin/grep -q "PATH finds $d/shfmt first" <<<"$err" \
  && [ "$(PATH="$d:$d/pipbin"; eval "$envf"; command -v shfmt)" = "$d/pipbin/shfmt" ]; then
  ok "remote, pip's shfmt shadowed by apt's: CLAUDE_ENV_FILE puts pip's first, one stderr note"
else bad "shadowed: rc=$rc out='$out' err='$err' log='$log' envf='$envf'"; fi
run "$d" true "$d:$d/pipbin"
if clean_exit && [ -z "$log" ] && [ "$envf" = "$want" ]; then
  ok "remote, shadowed, second run: no pip install, the PATH line is written again"
else bad "shadowed, second run: rc=$rc out='$out' err='$err' log='$log' envf='$envf'"; fi

d=$(stub_dir 0 env trash shfmt-numeric pip); run "$d" true "$d"
if clean_exit && [ "$envf" = "export PATH=$d/pipbin:\"\$PATH\"" ]; then
  ok "remote, pip's directory not on PATH at all (a --user install): CLAUDE_ENV_FILE adds it"
else bad "pip dir off PATH: rc=$rc out='$out' err='$err' log='$log' envf='$envf'"; fi

d=$(stub_dir 0 env trash shfmt-numeric pip); run "$d" true "$d:$d/pipbin"
: > "$d.log"
out=$(CLAUDE_CODE_REMOTE=true PATH="$d:$d/pipbin" LOG="$d.log" "$BASH_BIN" "$HOOK" 2>"$ROOT_DIR/err" </dev/null); rc=$?
err=$(cat "$ROOT_DIR/err")
if clean_exit && /usr/bin/grep -q "put $d/pipbin first on PATH or the gauntlet refuses" <<<"$err"; then
  ok "remote, shadowed and no CLAUDE_ENV_FILE: one note naming the directory to put first"
else bad "shadowed, no env file: rc=$rc out='$out' err='$err'"; fi

d=$(stub_dir 0 env trash shfmt-numeric); run "$d" true
if clean_exit && /usr/bin/grep -q 'no usable shfmt' <<<"$err" && /usr/bin/grep -q 'misses the race' <<<"$err"; then
  ok "remote, apt's 3.8.0 and no pip: one note with the scanner's reason, exit 0"
else bad "numeric shfmt, no pip: rc=$rc out='$out' err='$err' log='$log'"; fi

d=$(stub_dir 0 env trash pip-fail); run "$d" true
if clean_exit && [ "$log" = "PIP install -q shfmt-py" ] && /usr/bin/grep -q 'pip install shfmt-py failed' <<<"$err" \
  && /usr/bin/grep -q 'no usable shfmt' <<<"$err"; then
  ok "remote, pip install fails: a note for pip and one for shfmt, exit 0"
else bad "pip fails: rc=$rc out='$out' err='$err' log='$log'"; fi

safe_trash "$ROOT_DIR"
echo "session-start hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
