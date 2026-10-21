#!/usr/bin/env bash
# test-observer-contract.sh — GH #443: scripts/check-observer-contract.sh passes the real
# hooks/mod/cost-ledger.ts and fails a known-bad module (extra hooks, $.ui.ask, a deny, a rewrite),
# naming each violation. Runs the real `claude plugin validate`; without the CLI only the static
# layer runs, and the hook/call rows are skipped.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
CHECK="$ROOT/scripts/check-observer-contract.sh"
BAD="$HERE/fixtures/observer-contract/bad"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== observer contract on hooks/mod/cost-ledger.ts ==="
out="$(bash "$CHECK" "$ROOT" 2>&1)" && ok "the real module passes" || bad "the real module failed: $out"

out="$(bash "$CHECK" "$BAD" 2>&1)" && bad "the known-bad module passed" || ok "the known-bad module fails"
expect() { case "$out" in *"$1"*) ok "names: $1" ;; *) bad "missing '$1' in: $out" ;; esac; }
expect "deny/ask/rewrite in source:"
expect "deny:"
expect "next({"
if command -v claude >/dev/null; then
  expect "registers tool.call{tool=Bash}"
  expect "registers prompt.submit"
  expect "calls \$.ui.ask"
else
  echo "  SKIP: hook/call rows (no claude CLI)"
fi

# A rewrite the old line grep missed: next( split across lines, or an object passed by name.
# The temp dir has no manifest, so only the static rows are asserted, not the exit code.
# static: run the check with a failing `claude` stub (an exported function, found by command -v),
# skipping a ~0.7 s `claude plugin validate` whose result these rows never read.
static() ( claude() { return 1; }; export -f claude; bash "$CHECK" "$1" 2>&1 )
T=$(mktemp -d) || exit 1
trap 'trash "$T"' EXIT
mkdir -p "$T/multi/hooks/mod" "$T/var/hooks/mod"
cat > "$T/multi/hooks/mod/cost-ledger.ts" <<'EOF'
export default (on) => {
  on('turn.complete', async ($, e, next) => {
    return next(
      { ...e, prompt: 'x' }
    )
  })
}
EOF
cat > "$T/var/hooks/mod/cost-ledger.ts" <<'EOF'
export default (on) => {
  on('turn.complete', async ($, e, next) => {
    const r = { ...e, text: 'x' }; return next(r)
  })
}
EOF
out="$(static "$T/multi")"
case "$out" in *"rewrite in source: L3: next({ ...e, prompt:"*) ok "multi-line object arg flagged" ;; *) bad "multi-line object arg not flagged: $out" ;; esac
out="$(static "$T/var")"
case "$out" in *"rewrite in source: L3: next(r)"*) ok "variable arg flagged" ;; *) bad "variable arg not flagged: $out" ;; esac

# Deep-audit: a next() call inside a template literal's ${...} is code, not string text.
mkdir -p "$T/tpl/hooks/mod" "$T/tplok/hooks/mod"
cat > "$T/tpl/hooks/mod/cost-ledger.ts" <<'EOF'
export default (on) => {
  on('turn.complete', async ($, e, next) => {
    const forwarded = `${next({ ...e, text: 'x' })}`; return forwarded
  })
}
EOF
cat > "$T/tplok/hooks/mod/cost-ledger.ts" <<'EOF'
export default (on) => {
  on('turn.complete', async ($, e, next) => {
    const note = `plain text mentions next({ ...e }) and ${e.id}`; return next(e)
  })
}
EOF
out="$(static "$T/tpl")"
case "$out" in *"rewrite in source: L3: next({ ...e, text:"*) ok "next() inside a template interpolation flagged" ;; *) bad "template interpolation not flagged: $out" ;; esac
out="$(static "$T/tplok")"
case "$out" in *"in source"*) bad "template text (not an interpolation) flagged: $out" ;; *) ok "next() named in template text is not flagged" ;; esac

echo "  ($pass passed, $fail failed)"
[ "$fail" -eq 0 ]
