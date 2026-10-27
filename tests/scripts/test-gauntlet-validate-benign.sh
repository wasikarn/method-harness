#!/usr/bin/env bash
# test-gauntlet-validate-benign.sh — regression: Claude Code 2.1.289's strict plugin validate
# warns "CLAUDE.md at the plugin root is not loaded as project context" and --strict turns it
# into an error, so every pre-push failed (CI pins 2.1.287 and stayed green). That one warning
# is intentional here (docs/METHODOLOGY.md ships via hooks). run_validate() must accept a strict
# failure whose only warning is that line, and fail on anything else. A stub `claude` on PATH
# plays each scenario; the real CLI is never run.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
GAUNTLET="$HERE/../../scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
safe_tmp_delete() { [ -n "${1:-}" ] && python3 "$HERE/../_lib/tmp_delete.py" "$1"; return 0; }

echo "=== run_validate tolerates only the plugin-root CLAUDE.md warning ==="
BODY=$(sed -n '/^validate_strict_tolerant()/,/^}/p;/^run_validate()/,/^}/p' "$GAUNTLET")
BIN=$(mktemp -d)
if [ -z "$BODY" ] || [ -z "$BIN" ]; then
  bad "could not extract run_validate() or create the stub dir"
else
  # SCENARIO picks the stub's behaviour; the stub sees --strict as $3 of `plugin validate`.
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
strict=0; for a in "$@"; do [ "$a" = --strict ] && strict=1; done
warn='  ❯ root: CLAUDE.md at the plugin root is not loaded as project context. To ship context with your plugin, use a skill instead.'
other='  ❯ hooks: some other warning'
case "$SCENARIO" in
  clean) echo "✔ Validation passed"; exit 0 ;;
  benign)
    if [ "$strict" = 1 ]; then printf '⚠ Found 1 warning:\n\n%s\n\n✘ Validation failed (--strict treats warnings as errors)\n' "$warn"; exit 1; fi
    printf '⚠ Found 1 warning:\n\n%s\n\n✔ Validation passed with warnings\n' "$warn"; exit 0 ;;
  benign-plus-other)
    if [ "$strict" = 1 ]; then printf '⚠ Found 2 warnings:\n\n%s\n%s\n\n✘ Validation failed (--strict treats warnings as errors)\n' "$warn" "$other"; exit 1; fi
    printf '⚠ Found 2 warnings:\n\n%s\n%s\n' "$warn" "$other"; exit 0 ;;
  other)
    if [ "$strict" = 1 ]; then printf '⚠ Found 1 warning:\n\n%s\n\n✘ Validation failed (--strict treats warnings as errors)\n' "$other"; exit 1; fi
    printf '⚠ Found 1 warning:\n\n%s\n' "$other"; exit 0 ;;
  hard-error) printf '✘ Validation failed: manifest invalid\n'; exit 1 ;;
esac
STUB
  chmod +x "$BIN/claude"
  run() { PATH="$BIN:$PATH" SCENARIO="$1" bash -c "$BODY
run_validate" >/dev/null 2>&1; }
  run clean && ok "a clean validate passes" || bad "a clean validate failed"
  run benign && ok "strict failing only on the CLAUDE.md warning passes" || bad "the benign-only warning still fails the gauntlet"
  run benign-plus-other && bad "a second warning next to the benign one was accepted" || ok "the benign warning plus another warning fails"
  run other && bad "a different warning was accepted" || ok "a different warning fails"
  run hard-error && bad "a hard error was accepted" || ok "a hard error fails"
fi
safe_tmp_delete "$BIN"

echo "  ($pass passed, $fail failed)"
[ "$fail" -eq 0 ]
