#!/usr/bin/env bash
# Gate: ask when a Write/Edit introduces a new vendor-specific,
# live-credential-shaped token (AWS, Anthropic, OpenAI, GitHub, GitLab,
# HuggingFace, Slack, Stripe secret/restricted, Google API key, npm, PyPI, or
# a PEM private key) that isn't a placeholder or same-line-suppressed.
#
# ASK, not DENY: docs/reference/operating-model.md reserves DENY for the
# literal irrecoverable set. A pasted secret in a working-tree file is
# reversible -- it can still be edited out. There is currently no other
# backstop: git-hooks/pre-commit and pre-push have zero secret-content
# scanning, so this gate is the ONLY mechanism that catches an accidental
# paste. Accepted, undisclosed-by-design gaps: MultiEdit, Bash-mediated
# writes (echo/sed -i), and Codex-rescue writes all bypass this gate with no
# other backstop -- same accepted-gap posture as config-write-guard.sh's own
# MultiEdit exclusion.
#
# Fail OPEN on any internal error (missing python3, missing sibling script,
# any exception inside secret-scan.py) -- this gate's verdict is advisory on
# a write that was already happening, and it runs on every Write/Edit in
# every host project that loads this plugin, so a single internal bug must
# never turn into an ask on every write everywhere.
#
# Sourced from `mh:idea-audit`'s Round-4 re-scan of Anthropic's "AI-Native
# SDLC playbook" (2026-09-28), which confirmed zero secret-content scanning
# existed anywhere in the hook fleet. A near-identical gate of this same name
# existed before the 2026-06-27 rebuild (retired `_lib.sh` architecture); its
# vendor-prefix pattern idea is reused, its DENY-with-no-bypass behavior and
# 20-char token preview are not.
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[mh:gate] python3 not found -- secret-scan cannot run; allowing" >&2
  exit 0
fi

case $0 in */*) _gdir="${0%/*}" ;; *) _gdir=. ;; esac  # not $(dirname): saves a fork
_py="$_gdir/secret-scan.py"
if [ ! -r "$_py" ]; then
  echo "[mh:gate] internal error: sibling script secret-scan.py missing or unreadable -- allowing (secret-scan is ask-only, fails open)" >&2
  exit 0
fi

# Fast path (_silent_fastpath.sh): every PATTERNS entry in secret-scan.py needs one of these
# case-sensitive literals, so a payload with none of them cannot match, ask or journal.
# Keep this list in step with PATTERNS (tests/hooks/test-secret-scan.sh checks one hit per pattern).
if [ -r "$_gdir/_silent_fastpath.sh" ] && . "$_gdir/_silent_fastpath.sh"; then
  mh_gate_run "$_py" 'AKIA|ASIA|sk-ant-|T3BlbkFJ|gh[pousr]_|github_pat_|glpat-|hf_|xox[baprs]-|[sr]k_(test|live|prod)_|AIza|npm_|pypi-AgEIcHlwaS5vcmc|PRIVATE KEY'
fi
python3 -S "$_py"
