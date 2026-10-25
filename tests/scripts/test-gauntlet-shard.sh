#!/usr/bin/env bash
# test-gauntlet-shard.sh — GH #400: CI splits the test layer across runners
# with GAUNTLET_SHARD=i/N. Every test file must land in exactly one shard for
# N=1..6, the two heaviest files must not share a shard, and with no shard set
# the listing must be every test file (today's behaviour). Extracts
# hook_test_files() and check_shard() only; never runs the gauntlet (recursion).
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GAUNTLET="$ROOT/scripts/run-gauntlet.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

echo "=== gauntlet shard split (GH #400) ==="
body=$(sed -n '/^hook_test_files()/,/^}/p' "$GAUNTLET")
check=$(sed -n '/^check_shard()/,/^}/p' "$GAUNTLET")
[ -n "$body" ] || { echo "  FAIL: hook_test_files() not found in run-gauntlet.sh" >&2; exit 1; }
[ -n "$check" ] || { echo "  FAIL: check_shard() not found in run-gauntlet.sh" >&2; exit 1; }
list() { (cd "$ROOT" && shard="$1" bash -c "$body
  hook_test_files"); }

# No shard: every test file on disk, found independently of the globs.
want=$(cd "$ROOT" && find tests \( -name "test-*.sh" -o -name "test_*.py" \) | LC_ALL=C sort)
full=$(list "")
if [ "$(printf '%s\n' "$full" | LC_ALL=C sort)" = "$want" ]; then
  ok "no shard set: the listing is every test file"
else
  bad "no shard set: the listing differs from the files on disk"
fi

# The two largest files by bytes (the split's own proxy for run time) must land apart.
read -r big1 big2 < <(cd "$ROOT" && printf '%s\n' "$full" | while IFS= read -r t; do
  printf '%s %s\n' "$(wc -c <"$t" | tr -d ' ')" "$t"; done | LC_ALL=C sort -k1,1nr -k2,2 | head -n 2 | cut -d' ' -f2 | tr '\n' ' ')
for n in 1 2 3 4 5 6; do
  all=""; empty=0; order=0; gates=0; guard=0
  i=1
  while [ "$i" -le "$n" ]; do
    s=$(list "$i/$n")
    [ -n "$s" ] || empty=1
    # A shard keeps glob order, so the log reads like a serial run.
    [ "$(printf '%s\n' "$full" | /usr/bin/grep -xF -f <(printf '%s\n' "$s"))" = "$s" ] || order=1
    /usr/bin/grep -qxF "$big1" <<<"$s" && gates=$i
    /usr/bin/grep -qxF "$big2" <<<"$s" && guard=$i
    all="$all$s"$'\n'
    i=$((i + 1))
  done
  got=$(printf '%s' "$all" | LC_ALL=C sort)
  if [ "$got" = "$want" ]; then
    ok "N=$n: every test file is in exactly one shard"
  else
    bad "N=$n: shards do not partition the files (missing or duplicated: $(diff <(printf '%s\n' "$got") <(printf '%s\n' "$want") | /usr/bin/grep '^[<>]' | tr '\n' ' '))"
  fi
  [ "$empty" -eq 0 ] && ok "N=$n: no shard is empty" || bad "N=$n: a shard is empty"
  [ "$order" -eq 0 ] && ok "N=$n: each shard keeps glob order" || bad "N=$n: a shard is out of glob order"
  if [ "$n" -ge 2 ]; then
    if [ "$gates" -ne 0 ] && [ "$gates" -ne "$guard" ]; then
      ok "N=$n: the two largest files ($big1, $big2) are on different shards"
    else
      bad "N=$n: the two largest files $big1 (shard $gates) and $big2 (shard $guard) share a shard"
    fi
  fi
done

# check_shard() accepts i/N with 1<=i<=N and rejects anything else loudly.
for v in "" 1/1 2/5 5/5; do
  if (shard="$v" bash -c "$check
    check_shard") 2>/dev/null; then ok "check_shard accepts '$v'"; else bad "check_shard rejects '$v'"; fi
done
for v in 3 0/2 3/2 1/ /2 1/2/3 a/2 1/x; do
  if (shard="$v" bash -c "$check
    check_shard") 2>/dev/null; then bad "check_shard accepts '$v'"; else ok "check_shard rejects '$v'"; fi
done

echo "self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
