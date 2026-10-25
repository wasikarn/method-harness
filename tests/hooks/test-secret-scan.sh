#!/usr/bin/env bash
# Behavioral tests for secret-scan.sh (gate:write:secret-scan).
# Run standalone: bash tests/hooks/test-secret-scan.sh
#
# No literal token-shaped secret string appears in this file -- every test
# token's variable/random portion is generated at runtime via a seeded RNG,
# so the file itself never contains a live-credential-shaped substring that
# could trip GitHub's own push-protection scanner (or this gate) when
# committed. The one exception is AWS's own publicly documented placeholder
# example (AKIAIOSFODNN7EXAMPLE), which every scanner already allowlists.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/gates/secret-scan.sh"

pass=0
fail=0

# rnd <len> <charset> <seed> -- deterministic per-run pseudo-random body text
rnd() {
  python3 -c 'import random,sys; r=random.Random(int(sys.argv[3])); print("".join(r.choice(sys.argv[2]) for _ in range(int(sys.argv[1]))))' "$1" "$2" "$3"
}

UPPER36="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
ALNUM="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
ALNUM_DASH="${ALNUM}-_"
DIGITS="0123456789"

payload_write_content() { # payload_write_content <file_path> <content>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"
}

payload_edit() { # payload_edit <file_path> <old_string> <new_string>
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]}}))' "$1" "$2" "$3"
}

check() { # check <desc> <ok:0|1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1" >&2; fail=$((fail + 1)); fi
}

echo "=== secret-scan gate ==="

FIXTURE=$(mktemp -d)
NOSIBLING=$(mktemp -d)
trap 'trash "$FIXTURE" "$NOSIBLING" 2>/dev/null || true' EXIT
export MH_GATE_JOURNAL_PATH="$FIXTURE/gate-decisions.jsonl"

asks() { # asks <content> -- the gate's stdout for a Write of <content>
  payload_write_content "$FIXTURE/scratch.txt" "$1" | bash "$GATE" 2>/dev/null
}

# --- true positives: one per vendor pattern -----------------------------

aws1="AKIA$(rnd 16 "$UPPER36" 1)"
out=$(asks "$aws1"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "AWS access key (AKIA) -> ask" "$ok"

aws2="ASIA$(rnd 16 "$UPPER36" 2)"
out=$(asks "$aws2"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "AWS session key (ASIA) -> ask" "$ok"

anthropic="sk-ant-api03-$(rnd 40 "$ALNUM_DASH" 3)"
out=$(asks "$anthropic"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Anthropic key -> ask" "$ok"

openai="sk-proj-$(rnd 25 "$ALNUM_DASH" 4)T3BlbkFJ$(rnd 25 "$ALNUM_DASH" 5)"
out=$(asks "$openai"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "OpenAI key (marker-anchored) -> ask" "$ok"

ghp="ghp_$(rnd 36 "$ALNUM" 6)"
out=$(asks "$ghp"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "GitHub ghp_ token -> ask" "$ok"

ghu="ghu_$(rnd 36 "$ALNUM" 7)"
out=$(asks "$ghu"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "GitHub ghu_ token (round-2 addition) -> ask" "$ok"

ghr="ghr_$(rnd 36 "$ALNUM" 8)"
out=$(asks "$ghr"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "GitHub ghr_ token (round-2 addition) -> ask" "$ok"

ghfine="github_pat_$(rnd 82 "${ALNUM}_" 9)"
out=$(asks "$ghfine"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "GitHub fine-grained PAT -> ask" "$ok"

gitlab="glpat-$(rnd 20 "$ALNUM_DASH" 10)"
out=$(asks "$gitlab"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "GitLab PAT -> ask" "$ok"

hf="hf_$(rnd 34 "$ALNUM" 11)"
out=$(asks "$hf"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "HuggingFace token -> ask" "$ok"

slack="xoxb-$(rnd 12 "$DIGITS" 12)-$(rnd 12 "$DIGITS" 13)-$(rnd 24 "$ALNUM" 14)"
out=$(asks "$slack"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Slack token -> ask" "$ok"

stripe_test="sk_test_$(rnd 24 "$ALNUM" 15)"
out=$(asks "$stripe_test"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Stripe sk_test_ -> ask" "$ok"

stripe_live="rk_live_$(rnd 24 "$ALNUM" 16)"
out=$(asks "$stripe_live"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Stripe rk_live_ -> ask" "$ok"

stripe_prod="sk_prod_$(rnd 24 "$ALNUM" 17)"
out=$(asks "$stripe_prod"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Stripe sk_prod_ (round-2 correction: gitleaks covers prod too) -> ask" "$ok"

google="AIza$(rnd 35 "$ALNUM_DASH" 18)"
out=$(asks "$google"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Google API key -> ask" "$ok"

npmtok="npm_$(rnd 36 "$ALNUM" 19)"
out=$(asks "$npmtok"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "npm token -> ask" "$ok"

pypitok="pypi-AgEIcHlwaS5vcmc$(rnd 50 "$ALNUM_DASH" 20)"
out=$(asks "$pypitok"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "PyPI token -> ask" "$ok"

pem=$'-----BEGIN RSA PRIVATE KEY-----\n'"$(rnd 60 "${ALNUM}+/=" 21)"
out=$(asks "$pem"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "PEM private key with a real base64 body line -> ask" "$ok"

awsE="AKIA$(rnd 16 "$UPPER36" 22)"
out=$(payload_edit "$FIXTURE/scratch.txt" "placeholder" "$awsE" | bash "$GATE" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Edit new_string introduces AWS key -> ask" "$ok"

# --- Codex round-4 regression: AWS/Anthropic capture group must exist ----
# (an earlier draft omitted it entirely; match.group(1) would have raised
# IndexError -> outer fail-open -> total, silent bypass for both vendors.)
awsCG="AKIA$(rnd 16 "$UPPER36" 23)"
out=$(asks "$awsCG"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "AWS key reaches the placeholder-check path without an IndexError -> ask" "$ok"

anthropicCG="sk-ant-api03-$(rnd 40 "$ALNUM_DASH" 24)"
out=$(asks "$anthropicCG"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "Anthropic key reaches the placeholder-check path without an IndexError -> ask" "$ok"

# --- placeholder filter: fully specified round-2 algorithm ---------------

awsExample="AKIAIOSFODNN7EXAMPLE"
out=$(asks "$awsExample"); ok=1; [ -z "$out" ] && ok=0
check "AWS published example token (exact-match list) -> silent" "$ok"

awsAllSame="AKIA$(printf 'X%.0s' $(seq 1 16))"
out=$(asks "$awsAllSame"); ok=1; [ -z "$out" ] && ok=0
check "100% repeated-char body -> silent (placeholder)" "$ok"

ascBody=$(python3 -c "print(''.join(chr(65+i) for i in range(16)))")
awsAscending="AKIA${ascBody}"
out=$(asks "$awsAscending"); ok=1; [ -z "$out" ] && ok=0
check "100% ascending-run body -> silent (placeholder)" "$ok"

descBody=$(python3 -c "print(''.join(chr(90-i) for i in range(16)))")
awsDescending="AKIA${descBody}"
out=$(asks "$awsDescending"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "100% DEscending-run body -> still asks (algorithm is ascending-only, round-2 spec)" "$ok"

# --- Codex round-1 regression: substring word-check bypass stays closed --

sampleBypass="AKIA$(rnd 5 "$UPPER36" 25)SAMPLE$(rnd 5 "$UPPER36" 26)"
out=$(asks "$sampleBypass"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "realistic token containing substring SAMPLE -> still asks (round-1 bypass stays closed)" "$ok"

yourBypass="AKIA$(rnd 4 "$UPPER36" 27)YOUR$(rnd 8 "$UPPER36" 28)"
out=$(asks "$yourBypass"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "realistic token containing substring YOUR -> still asks (round-1 bypass stays closed)" "$ok"

# --- Codex round-2 regression: a short coincidental run isn't 90% --------

shortRun="AKIA$(rnd 6 "$UPPER36" 29)789$(rnd 7 "$UPPER36" 30)"
out=$(asks "$shortRun"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "short 3-char coincidental ascending run inside random body -> still asks (90% threshold holds)" "$ok"

# --- precision: patterns that must NOT match ------------------------------

pkLive="pk_live_$(rnd 24 "$ALNUM" 31)"
out=$(asks "$pkLive"); ok=1; [ -z "$out" ] && ok=0
check "Stripe pk_live_ (publishable key) -> silent (dropped from pattern list)" "$ok"

pemNoBody="-----BEGIN RSA PRIVATE KEY-----"
out=$(asks "$pemNoBody"); ok=1; [ -z "$out" ] && ok=0
check "PEM header with no base64 body line -> silent" "$ok"

openaiNoMarker="sk-$(rnd 48 "$ALNUM_DASH" 32)"
out=$(asks "$openaiNoMarker"); ok=1; [ -z "$out" ] && ok=0
check "sk- token without the OpenAI T3BlbkFJ marker -> silent" "$ok"

awsShort="AKIA$(rnd 15 "$UPPER36" 33)"
out=$(asks "$awsShort"); ok=1; [ -z "$out" ] && ok=0
check "AWS body one char SHORT (15 not 16) -> silent" "$ok"

ghpShort="ghp_$(rnd 35 "$ALNUM" 34)"
out=$(asks "$ghpShort"); ok=1; [ -z "$out" ] && ok=0
check "GitHub token body one char SHORT (35 not 36) -> silent" "$ok"

# Validator-flagged coverage gap: only the SHORT boundary was tested above.
# One char LONG proves the trailing \b word-boundary guard is intact -- a
# regression that dropped it could let a 17-char run match the first 16
# chars anyway, which this test would catch.
awsLong="AKIA$(rnd 17 "$UPPER36" 39)"
out=$(asks "$awsLong"); ok=1; [ -z "$out" ] && ok=0
check "AWS body one char LONG (17 not 16) -> silent (\\b boundary guard intact)" "$ok"

# --- suppression: same-line marker only, and it's journaled ---------------

: > "$MH_GATE_JOURNAL_PATH"
suppressedTok1="AKIA$(rnd 16 "$UPPER36" 35)"
out=$(asks "${suppressedTok1}  # gitleaks:allow"); ok=1; [ -z "$out" ] && ok=0
check "gitleaks:allow on the match's own line -> silent" "$ok"
ok=1; /usr/bin/grep -q '"decision": "allow-suppressed"' "$MH_GATE_JOURNAL_PATH" && ok=0
check "suppressed match is journaled as allow-suppressed" "$ok"
ok=1; /usr/bin/grep -qF "$suppressedTok1" "$MH_GATE_JOURNAL_PATH" || ok=0
check "journal row never contains the actual matched token" "$ok"

# GH #378: suppressed matches are journaled as ONE row per payload carrying the match count, written
# before the ask row. jrows prints the journal as "<decision>:<count or ->" per row, in order.
jrows() {
  python3 -c '
import json, sys
print(" ".join("%s:%s" % (r.get("decision"), r.get("count", "-")) for r in map(json.loads, open(sys.argv[1]))))' "$MH_GATE_JOURNAL_PATH" 2>/dev/null
}
ok=1; [ "$(jrows)" = "allow-suppressed:1" ] && ok=0
check "one suppressed match -> one allow-suppressed row with count 1" "$ok"

: > "$MH_GATE_JOURNAL_PATH"
cntTok1="AKIA$(rnd 16 "$UPPER36" 43)"; cntTok2="AKIA$(rnd 16 "$UPPER36" 44)"; cntTok3="AKIA$(rnd 16 "$UPPER36" 45)"
out=$(asks "${cntTok1} ${cntTok2} # gitleaks:allow"$'\n'"${ghp} // pragma: allowlist secret"$'\n'"${cntTok3}")
ok=1; [ "$(jrows)" = "allow-suppressed:3 ask:-" ] && /usr/bin/grep -q 'AWS access/session key (line 3)\.' <<<"$out" && ok=0
check "3 suppressed matches on 2 lines + 1 real -> one allow-suppressed row (count 3), then the ask row" "$ok"

: > "$MH_GATE_JOURNAL_PATH"
out=$(asks "${cntTok3}")
ok=1; [ "$(jrows)" = "ask:-" ] && ok=0
check "no suppressed match -> no allow-suppressed row, only the ask row" "$ok"

: > "$MH_GATE_JOURNAL_PATH"
suppressedTok2="AKIA$(rnd 16 "$UPPER36" 36)"
out=$(asks "${suppressedTok2} // pragma: allowlist secret"); ok=1; [ -z "$out" ] && ok=0
check "pragma: allowlist secret on the match's own line -> silent" "$ok"

markerTok="AKIA$(rnd 16 "$UPPER36" 37)"
out=$(asks $'# gitleaks:allow\n'"${markerTok}")
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "marker on the PREVIOUS line (not the match's own line) -> still asks" "$ok"

nextTok="AKIA$(rnd 16 "$UPPER36" 40)"
out=$(asks "${nextTok}"$'\n# gitleaks:allow')
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "marker on the NEXT line (not the match's own line) -> still asks" "$ok"

lineTok1="AKIA$(rnd 16 "$UPPER36" 41)"; lineTok2="AKIA$(rnd 16 "$UPPER36" 42)"
out=$(asks $'a\r\nb\n\n'"x ${lineTok1}"$'\n'"${lineTok2} # gitleaks:allow"$'\n'"${lineTok1}")
ok=1; /usr/bin/grep -q 'AWS access/session key (line 4); AWS access/session key (line 6)\.' <<<"$out" && ok=0
check "line numbers count CRLF and blank lines, skip the suppressed line (4 and 6)" "$ok"

out=$(asks $'x\n'"$pem")
ok=1; /usr/bin/grep -q 'Private key (line 2)\.' <<<"$out" && ok=0
check "a PEM key spanning lines 2-3 is reported at its first line (2)" "$ok"

# The marker check is cached per line: a suppressed line 2 must not leak onto line 1 for a later pattern.
out=$(asks "${aws1} ${npmtok}"$'\n'"${ghp} # gitleaks:allow")
ok=1; /usr/bin/grep -q 'AWS access/session key (line 1); npm (line 1)\.' <<<"$out" && ok=0
check "per-line marker check: line 1 stays unsuppressed for every pattern when line 2 is suppressed" "$ok"

# --- reason hygiene: the ask reason never contains the actual token -------

hygieneTok="AKIA$(rnd 16 "$UPPER36" 38)"
out=$(asks "$hygieneTok")
if /usr/bin/grep -qF "$hygieneTok" <<<"$out"; then ok=1; else ok=0; fi
check "ask reason never contains the actual matched token" "$ok"
ok=1; /usr/bin/grep -q "AWS access/session key" <<<"$out" && ok=0
check "ask reason names the vendor label" "$ok"

# --- timing: line numbering stays linear ----------------------------------
# A timed-out hook allows the write. Line numbers were counted from the start of the text for
# every match, and the suppress-marker check read the whole line for every match, so 40,000
# matches in 2 MB ran past the 8 s hook timeout on 40,000 lines and on one line alike (M3 Pro).
# Linear now: well under 1 s. The 4 s limit leaves room for a CI runner about 1.5x slower.
# GH #378: the "suppressed" shape is 199,999 suppressed lines plus one real token (7.8 MB). One
# journal row per suppressed match took 10.3 s, so the write went through without the ask.
timed_scan() { # timed_scan <lines|oneline|suppressed> -- prints "<seconds> <stdout>" for a big Write
  python3 - "$GATE" "$1" "$UPPER36" <<'PY'
import json, os, random, signal, subprocess, sys, time
gate, shape, cs = sys.argv[1], sys.argv[2], sys.argv[3]
r = random.Random(40000)
if shape == "suppressed":
    toks = ["AKIA" + "".join(r.choices(cs, k=16)) for _ in range(200000)]
    text = "\n".join("k = " + t + " # gitleaks:allow" for t in toks[:-1]) + "\nk = " + toks[-1]
else:
    toks = ["AKIA" + "".join(r.choice(cs) for _ in range(16)) for _ in range(40000)]
pad = "x" * 24  # about 2 MB either way
if shape == "lines":
    text = "\n".join("k = " + t + " # " + pad for t in toks)
elif shape == "oneline":
    text = " ".join(t + " " + pad + "yyyyy" for t in toks)
p = json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/x/big.txt", "content": text}})
t = time.time()
# Own process group, killed whole on timeout: a python child left running would keep journaling.
proc = subprocess.Popen(["bash", gate], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, start_new_session=True)
try:
    out = proc.communicate(p.encode(), timeout=8)[0].decode()
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.communicate()
    out = "TIMEOUT"
print("%.2f %s" % (time.time() - t, out))
PY
}
res=$(timed_scan lines); secs=${res%% *}
ok=1; awk -v s="$secs" 'BEGIN { exit !(s < 4) }' && /usr/bin/grep -q '(line 5); plus 39995 more' <<<"$res" && ok=0
check "40,000 matches on 40,000 lines (2 MB): asks with exact line numbers in ${secs}s (< 4 s)" "$ok"
res=$(timed_scan oneline); secs=${res%% *}
ok=1; awk -v s="$secs" 'BEGIN { exit !(s < 4) }' && /usr/bin/grep -q 'AWS access/session key (line 1)\.' <<<"$res" && ok=0
check "40,000 matches on one 2 MB line: asks, line 1, in ${secs}s (< 4 s)" "$ok"
: > "$MH_GATE_JOURNAL_PATH"
res=$(timed_scan suppressed); secs=${res%% *}
ok=1; awk -v s="$secs" 'BEGIN { exit !(s < 4) }' && /usr/bin/grep -q 'AWS access/session key (line 200000)\.' <<<"$res" && ok=0
check "199,999 suppressed lines + 1 real token (7.8 MB): asks, line 200000, in ${secs}s (< 4 s)" "$ok"
ok=1; [ "$(jrows)" = "allow-suppressed:199999 ask:-" ] && ok=0
check "199,999 suppressed matches journal one counted row, then the ask row" "$ok"

# --- error path / canary sanity -------------------------------------------

for p in '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
         '{"tool_name":"Bash","agent_id":"canary","tool_input":{"command":"git status"}}' \
         '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts","old_string":"a","new_string":"b"}}' \
         '{"tool_name":"Write","tool_input":{"file_path":"src/app.ts","content":"x"}}' \
         '{"tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"in_progress"}}'; do
  out=$(printf '%s' "$p" | bash "$GATE" 2>"$FIXTURE/canary-err"); rc=$?
  err=$(cat "$FIXTURE/canary-err")
  ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ] && ok=0
  check "gate-canary payload allows cleanly, empty stdout+stderr: ${p:0:45}..." "$ok"
done

out=$(printf 'not json' | bash "$GATE" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "non-JSON stdin -> exit 0, no output (fail open)" "$ok"

cp "$GATE" "$NOSIBLING/secret-scan.sh"
# Captured to a variable first, then fed via a here-string -- NOT piped
# directly from the python3 generator. The .sh wrapper exits before ever
# invoking python3 on this path (missing sibling), so it never drains
# stdin; piping straight in lets the generator's BrokenPipeError (SIGPIPE)
# exit non-zero and, under this file's own `pipefail`, override the gate's
# real exit 0. Documented gotcha, not a bug in the gate itself.
noSiblingPayload=$(payload_write_content "$FIXTURE/x.txt" "hello")
err=$(bash "$NOSIBLING/secret-scan.sh" <<<"$noSiblingPayload" 2>&1 >/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -qi "allowing" <<<"$err" && ok=0
check "missing sibling .py -> allow with a stderr note" "$ok"

# --- the bash fast path (_silent_fastpath.sh) must defer every payload python could ask on ---
# A \u escape can spell a vendor prefix without the raw text containing it.
out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"/a/b.py","content":"k = \\u0041KIA%s"}}' "$(rnd 16 "$UPPER36" 7)" | bash "$GATE" 2>/dev/null)
ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "\\u-escaped AKIA prefix -> ask (fast path defers on \\u)" "$ok"

# Over the fast path's size cap, a secret in the tail still reaches python.
big="$(python3 -c 'print("x = 1\n" * 7000)')"$'\n'"AKIA$(rnd 16 "$UPPER36" 8)"
out=$(asks "$big"); ok=1; /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "secret at the end of a 42 KB Write -> ask" "$ok"

# bash 5.3 can drop what a command substitution writes after an `LC_ALL=C cmd` in it, so the fast path's
# sentinel x can go missing (GH #610), and stripping a suffix that is not there scanned every position:
# minutes on a large Write, past the 8 s hook timeout, which allows. This printf drops the x every time.
key="AKIA$(rnd 16 "$UPPER36" 9)"
out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":"x = 1\n" * 100000 + sys.argv[2]}}))' "$FIXTURE/scratch.txt" "$key" \
  | timeout 8 bash -c 'printf() { [ "$1" = x ] || builtin printf "$@"; }; . "$0"' "$GATE" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "fast-path sentinel lost, 600 KB Write with a key at the end -> ask inside the hook timeout (rc $rc)" "$ok"

# --- JSON depth: an extra key nested past the decoder's limit raises RecursionError ---
# The Write carries no token-shaped text, so only the depth branch can ask on it.
# depth 500, not 1000: Python <=3.11 overflows near 986.
deepen() { python3 -c 'import sys; s = sys.stdin.read().rstrip(); n = int(sys.argv[1]); print(s[:-1] + ", \"x\": " + "[" * n + "]" * n + "}")' "$1"; }
out=$(payload_write_content "$FIXTURE/scratch.txt" "x = 1" | deepen 1000000 | bash "$GATE" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "JSON depth 1e6, clean Write -> ask (payload not checked)" "$ok"
out=$(payload_write_content "$FIXTURE/scratch.txt" "x = 1" | deepen 500 | bash "$GATE" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && ok=0
check "JSON depth 500, clean Write -> still parses, exit 0, no output" "$ok"
. "$ROOT/tests/_lib/memerr.sh"
out=$(payload_write_content "$FIXTURE/scratch.txt" "x = 1" | memerr "$GATE" 2>/dev/null); rc=$?
ok=1; [ "$rc" -eq 0 ] && /usr/bin/grep -q '"permissionDecision": "ask"' <<<"$out" && ok=0
check "json.load MemoryError, clean Write -> ask (payload not checked)" "$ok"
err=$(printf '{"tool_name":"Write","tool_input":{' | bash "$GATE" 2>&1 >/dev/null); rc=$?
out=$(printf '{"tool_name":"Write","tool_input":{' | bash "$GATE" 2>/dev/null)
ok=1; [ "$rc" -eq 0 ] && [ -z "$out" ] && /usr/bin/grep -q "internal error, allowing" <<<"$err" && ok=0
check "truncated JSON -> still allows with the internal-error note (only depth asks)" "$ok"

# Drift guard: secret-scan.sh's fast path lists one literal per PATTERNS entry. A new pattern
# needs its literal added there, or the fast path skips python for it; then bump this count.
n=$(python3 -c 'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); print([len(a.value.elts) for a in t.body if isinstance(a, ast.Assign) and getattr(a.targets[0], "id", "") == "PATTERNS"][0])' "$ROOT/hooks/gates/secret-scan.py")
ok=1; [ "$n" = 13 ] && ok=0
check "secret-scan.py has 13 PATTERNS (got $n): on a change, update the literal list in secret-scan.sh" "$ok"

echo ""
total=$((pass + fail))
echo "=== $pass/$total passed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
