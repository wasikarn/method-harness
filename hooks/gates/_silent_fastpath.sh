# shellcheck shell=bash
# Sourced by the Write/Edit gate wrappers (config-write-guard.sh, secret-scan.sh, test-integrity.sh);
# not a hook itself. mh_gate_run PY DEFER_ERE reads the payload once and exits 0 with no output when
# the gate's python is provably silent, else hands python3 the same bytes and exits with its status.
#
# Proof the skip is exact: the read kept its sentinel (else python runs), the payload is at most
# 32768 bytes, ASCII, has no \u escape and matches the plain-object regex (subagent-git-guard.sh's,
# GH #326), so json.load gives a dict whose values are scalars or objects of scalars, and every
# letter, digit, "_", "-" and space in a decoded string sits literally in the raw text (JSON's other
# escapes only make " \ / and control characters).
# DEFER_ERE lists every raw text that could make that gate's python ask, journal or print, so when
# it does not match the gate exits 0 in silence. Anything else runs python3 (stderr kept).
# Bash cannot hold a NUL byte: tr maps it to \001, which is invalid raw JSON just as NUL is, so
# python fails at the same place and the plain-object regex never matches it.
# -S skips the site import (~6 ms); the gates use the stdlib only.
mh_gate_run() {
  local _input
  # export, not an `LC_ALL=C tr` prefix: bash 5.3 sometimes drops what a command substitution writes after
  # such a prefixed command, here the x (GH #610).
  _input=$(export LC_ALL=C; tr '\0' '\001'; printf x)
  # Check the x before stripping it: ${_input%x} without one scans every suffix, minutes on a large payload,
  # past the hook timeout (which allows). A read without its x may not be byte-exact, so python decides.
  if [ "${_input: -1}" = x ]; then
    _input=${_input%x}  # the x keeps trailing newlines byte-exact
    [ "${MH_GATE_NO_FASTPATH-}" = 1 ] || { _mh_silent "$2" && exit 0; }  # the gate canary sets it so python runs
  fi
  printf '%s' "$_input" | python3 -S "$1"
  exit "${PIPESTATUS[1]}"
}

_mh_s='"([ !#-[]|[]-~]|\\["\\/bfnrt])*"'                   # ASCII string, no \u
_mh_w=$'[ \t\n\r]*'                                         # JSON whitespace only
_mh_v="(${_mh_s}|-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][-+]?[0-9]+)?|true|false|null)"
_mh_o="[{]${_mh_w}(${_mh_s}${_mh_w}:${_mh_w}${_mh_v}${_mh_w}(,${_mh_w}${_mh_s}${_mh_w}:${_mh_w}${_mh_v}${_mh_w})*)?[}]"
_mh_v="(${_mh_v}|${_mh_o})"
_mh_re="^${_mh_w}[{]${_mh_w}(${_mh_s}${_mh_w}:${_mh_w}${_mh_v}${_mh_w}(,${_mh_w}${_mh_s}${_mh_w}:${_mh_w}${_mh_v}${_mh_w})*)?[}]${_mh_w}\$"

_mh_silent() {
  local LC_ALL=C  # byte-wise: the regex ranges are ASCII, non-ASCII bytes fail
  [ "${#_input}" -le 32768 ] || return 1  # the regex costs ~0.35 ms/KB; past this python is cheaper
  case $_input in *'\u'*) return 1 ;; esac  # early reject only: _mh_s refuses \u as well
  [[ $_input =~ $1 ]]
  [ $? -eq 1 ] || return 1  # a match (0) or a regex error (2) defers
  [[ $_input =~ $_mh_re ]]
}
