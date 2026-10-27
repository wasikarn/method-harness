#!/usr/bin/env bash
# test-codex-resolve-model.sh -- scripts/_lib/codex-resolve-model.py against a fixture catalog in a
# throwaway CODEX_HOME, never the real ~/.codex.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/../../scripts/_lib/codex-resolve-model.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
t() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# got <expected-slug> <resolver args...>: exits 0 AND prints exactly the slug
got() { out="$(python3 "$RESOLVE" "${@:2}" 2>/dev/null)"; rc=$?; [ "$rc" -eq 0 ] && [ "$out" = "$1" ]; }
ok_with() { [ "$1" -eq 0 ] && [ "$2" = "$3" ]; }
fails_with() { [ "$1" -ne 0 ] && [ -z "$2" ] && grep -q "$4" "$3"; }
clean_error() { [ "$1" -ne 0 ] && [ -z "$2" ] && [ -s "$3" ] && ! grep -q Traceback "$3"; }

T="$(mktemp -d)" || exit 1
trap 'python3 "$HERE/../_lib/tmp_delete.py" "$T"' EXIT
export CODEX_HOME="$T"
cat > "$T/models_cache.json" <<'JSON'
{"models": [
 {"slug":"gpt-9-sol","priority":1,"visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]},
 {"slug":"gpt-8-sol","priority":3,"visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"xhigh"}]},
 {"slug":"gpt-hidden-sol","priority":0,"visibility":"hide","supported_reasoning_levels":[{"effort":"medium"}]},
 {"slug":"gpt-5-terra","priority":8,"visibility":"list","supported_reasoning_levels":[{"effort":"medium"}]}
]}
JSON

echo "=== codex-resolve-model.py ==="
out="$(python3 "$RESOLVE" sol)"; rc=$?
t "best visible model of the tier (hidden priority-0 entry skipped)" ok_with "$rc" "$out" gpt-9-sol
t "tier is case-insensitive; a supported effort keeps the best model" got gpt-9-sol Sol --effort medium
t "an effort the best model lacks falls to the next model that lists it" got gpt-8-sol sol --effort xhigh
t "another tier resolves on its own" got gpt-5-terra terra

out="$(python3 "$RESOLVE" sol --effort ultra 2>"$T/err")"; rc=$?
t "no model lists the effort: exit non-zero, no stdout, reason on stderr" fails_with "$rc" "$out" "$T/err" ultra
out="$(python3 "$RESOLVE" astra 2>"$T/err")"; rc=$?
t "unknown tier: exit non-zero, no stdout, reason on stderr" fails_with "$rc" "$out" "$T/err" astra

echo '{not json' > "$T/models_cache.json"
out="$(python3 "$RESOLVE" sol 2>"$T/err")"; rc=$?
t "malformed catalog: clean error, no traceback" clean_error "$rc" "$out" "$T/err"
python3 "$HERE/../_lib/tmp_delete.py" "$T/models_cache.json"
out="$(python3 "$RESOLVE" sol 2>"$T/err")"; rc=$?
t "missing catalog: clean error" fails_with "$rc" "$out" "$T/err" catalog

# fail closed on odd input
cat > "$T/models_cache.json" <<'JSON'
{"models": [{"slug":"gpt-9-sol","priority":1,"visibility":"list","supported_reasoning_levels":[{"effort":"medium"}]}]}
JSON
out="$(python3 "$RESOLVE" sol --effort "" 2>"$T/err")"; rc=$?
t "empty --effort is refused, not treated as no effort" fails_with "$rc" "$out" "$T/err" effort
for body in '{"models": null}' '{"models": 3}' '[1,2]'; do
  printf '%s' "$body" > "$T/models_cache.json"
  out="$(python3 "$RESOLVE" sol 2>"$T/err")"; rc=$?
  t "catalog $body: clean error, no traceback" clean_error "$rc" "$out" "$T/err"
done
cat > "$T/models_cache.json" <<'JSON'
{"models": [{"slug":"gpt-9-sol","priority":1,"visibility":"list","supported_reasoning_levels":3}]}
JSON
out="$(python3 "$RESOLVE" sol --effort medium 2>"$T/err")"; rc=$?
t "supported_reasoning_levels of the wrong type: clean error, no traceback" clean_error "$rc" "$out" "$T/err"
cat > "$T/models_cache.json" <<'JSON'
{"models": [
 {"slug":"gpt-bool-sol","priority":false,"visibility":"list","supported_reasoning_levels":[{"effort":"medium"}]},
 {"slug":"gpt-retiring-sol","priority":0,"visibility":"list","upgrade":{"model":"gpt-ok-sol"},"supported_reasoning_levels":[{"effort":"medium"}]},
 {"slug":"gpt-ok-sol","priority":2,"visibility":"list","supported_reasoning_levels":[{"effort":"medium"}]}]}
JSON
t "a boolean priority and a retiring model (upgrade.model set) are not chosen" got gpt-ok-sol sol

# "retiring" means upgrade.model is a non-empty string; the live catalog carries "upgrade": null
for u in 'null' '{}' '""' '{"model":""}'; do
  # a single entry, so only the retiring rule can make it unresolvable
  printf '{"models": [{"slug":"gpt-only-sol","priority":1,"visibility":"list","upgrade":%s,"supported_reasoning_levels":[{"effort":"medium"}]}]}' "$u" > "$T/models_cache.json"
  t "upgrade $u is not retiring" got gpt-only-sol sol
done
printf '{"models": [{"slug":"gpt-only-sol","priority":1,"visibility":"list","upgrade":{"model":"x-nova"},"supported_reasoning_levels":[{"effort":"medium"}]}]}' > "$T/models_cache.json"
out="$(python3 "$RESOLVE" sol 2>"$T/err")"; rc=$?
t "a lone entry with upgrade.model set is retiring: refused for that reason" fails_with "$rc" "$out" "$T/err" "no visible 'sol' model"

# an empty tier must not match a slug that ends in "-"
cat > "$T/models_cache.json" <<'JSON'
{"models": [{"slug":"gpt-invalid-","priority":0,"visibility":"list","supported_reasoning_levels":[{"effort":"medium"}]}]}
JSON
out="$(python3 "$RESOLVE" "" 2>"$T/err")"; rc=$?
t "empty tier is refused, not matched against a slug ending in a dash" fails_with "$rc" "$out" "$T/err" tier

echo "===$pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
