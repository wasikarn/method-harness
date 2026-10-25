#!/usr/bin/env bash
# Runs the hooks module's unit tests (tests/mods/*.test.ts, for hooks/mod/cost-ledger.ts) with
# Claude Code's own mods test kit: `claude plugin test <plugin root>` runs every *.test.ts under
# it against the engine, the plugin loaded from hooks/hooks.json's "modules" entry.
# A CLI without `plugin test` (before mods, e.g. 2.1.261) prints the parent help and
# exits 0, so the subcommand is detected by its own help text; without it this suite says it
# skipped, loudly, rather than passing as if it ran. Reference: docs/reference/cost-ledger-module.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if ! command -v claude >/dev/null; then
  echo "SKIP: claude CLI not on PATH; the cost-ledger module tests did not run"
  exit 0
fi
if ! /usr/bin/grep -q "Run a mod's tests" <<<"$(claude plugin test --help 2>&1)"; then
  echo "SKIP: claude $(claude --version 2>&1 | head -1) has no 'plugin test' (mods need 2.1.287+); the cost-ledger module tests did not run"
  exit 0
fi

echo "=== cost-ledger hooks module (claude plugin test) ==="
claude plugin test "$ROOT"
