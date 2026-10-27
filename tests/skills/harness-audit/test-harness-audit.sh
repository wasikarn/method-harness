#!/usr/bin/env bash
# test-harness-audit.sh: self-test for harness-audit (maker-grades-own-work guard).
#
# audit.sh's fragment integrity guard catches LOST checks, not SILENT ones. Each
# known-bad fixture below is paired with a clean one; the matching check must
# FIRE on bad and stay SILENT on good. Per-check fixtures cover 04, 05, 20, 22, 28, 29, 54,
# 70, 71, 72, 73, 74 (five fixtures, two added 2026-09-21), 75, 76, 77, 78, 79, 80, 81, 82, 83; the fleet-bad / fleet-good pair covers every other check with at
# least one defect per check (43 is driven by the env ceiling, not a planted defect).
# check-73-bad-missing-command-field and check-73-bad-args-fingerprint-mismatch (below) are
# deep-audit fixes, 2026-09-10: a Codex-primary fresh-context checker found the original check
# 73 silently passed a handler missing its "command" field, and never compared the "args" field
# (a real, documented command-hook field, exec form) -- both independently reproduced before fix.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

HERE="$(cd -P "$(dirname "$0")" && pwd)"
AUDIT="$HERE/../../../skills/meta/harness-audit/scripts/audit.sh"
FIX="$HERE/known-bad"
# shellcheck source=../../../scripts/_lib/codex-state-path.sh
. "$HERE/../../../scripts/_lib/codex-state-path.sh"

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  PASS: $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

CRIT_FOUND=0
WARN_FOUND=0
INFO_FOUND=0
OUT=""
run_check() {
  local id="$1" root="$2" out c w i
  shift 2
  out=$(bash "$AUDIT" "$root" --only "$id" "$@" 2>/dev/null || true)
  OUT="$out"
  # A missing fixture dir, a crash, or a bad invocation produces no "=== Summary" block and
  # empty Critical:/Warnings:/Info: lines -- which used to parse as a silent 0/0/0, letting
  # expect_silent pass on a fixture that never actually ran (mh:deep-audit F2, 2026-09-24).
  # -1 fails every expect_* function's own condition (silent needs ==0, warn/crit need >=1),
  # so one guard here covers every caller instead of touching each expect_* individually.
  if ! /usr/bin/grep -q '^=== Summary' <<<"$out"; then
    bad "run_check $id $root: audit produced no '=== Summary' block (missing fixture, crash, or bad args) -- forcing failure"
    CRIT_FOUND=-1; WARN_FOUND=-1; INFO_FOUND=-1
    return
  fi
  c=$(printf '%s\n' "$out" | sed -n 's/^Critical: //p')
  w=$(printf '%s\n' "$out" | sed -n 's/^Warnings: //p')
  i=$(printf '%s\n' "$out" | sed -n 's/^Info: *//p')
  CRIT_FOUND="${c:-0}"
  WARN_FOUND="${w:-0}"
  INFO_FOUND="${i:-0}"
}
# expect <id> <fixture> <crit-cond> <warn-cond> <label>: run and assert.
expect_silent() {
  run_check "$1" "$FIX/$2" "${@:3}"
  if [ "$CRIT_FOUND" -eq 0 ] && [ "$WARN_FOUND" -eq 0 ]; then ok "check-$1 $2 silent"
  else bad "check-$1 $2 not silent (crit=$CRIT_FOUND warn=$WARN_FOUND)"; fi
}
# Grep is scoped to INFO lines only (audit.sh:150 prints "  INFO I<n>: <msg>") -- same fixture-
# path/name confound as expect_warn_match if matched against the whole $OUT (see that comment).
expect_silent_match() {
  run_check "$1" "$FIX/$2"
  if [ "$CRIT_FOUND" -eq 0 ] && [ "$WARN_FOUND" -eq 0 ] && /usr/bin/grep -E '^ *INFO ' <<<"$OUT" | /usr/bin/grep -E "$3" >/dev/null; then ok "check-$1 $2 silent and reports '$3'"
  else bad "check-$1 $2 not silent or missing '$3' (crit=$CRIT_FOUND warn=$WARN_FOUND)"; fi
}
# expect_info_only <id> <fixture> <regex>: fails open as INFO AND names the specific branch, not
# just any INFO (the same "not just any WARN" distinction as expect_warn_match; $3 used to be a
# decorative label only, never actually grepped -- any INFO firing at all made this pass).
expect_info_only() {
  run_check "$1" "$FIX/$2"
  if [ "$CRIT_FOUND" -eq 0 ] && [ "$WARN_FOUND" -eq 0 ] && [ "$INFO_FOUND" -ge 1 ] && /usr/bin/grep -E '^ *INFO ' <<<"$OUT" | /usr/bin/grep -E "$3" >/dev/null; then ok "check-$1 $2 fails open as INFO ($3)"
  else bad "check-$1 $2 did not fail open as INFO ($3) (crit=$CRIT_FOUND warn=$WARN_FOUND info=$INFO_FOUND)"; fi
}
expect_warn() {
  run_check "$1" "$FIX/$2" "${@:3}"
  if [ "$WARN_FOUND" -ge 1 ] && [ "$CRIT_FOUND" -eq 0 ]; then ok "check-$1 $2 fires WARN (warn=$WARN_FOUND)"
  else bad "check-$1 $2 did NOT fire WARN (crit=$CRIT_FOUND warn=$WARN_FOUND)"; fi
}
# expect_warn_match <id> <fixture> <regex>: WARN fires AND names the specific defect, not just any WARN.
# Grep is scoped to WARN lines only (audit.sh:149 prints "  WARN W<n>: <msg>") -- matching the
# whole $OUT would also match audit.sh:160's "Root: <fixture-path>" line, which leaks the fixture
# dir's own name (e.g. check-21-bad-fable-pin) into the output regardless of the WARN text itself.
expect_warn_match() {
  run_check "$1" "$FIX/$2"
  if [ "$WARN_FOUND" -ge 1 ] && [ "$CRIT_FOUND" -eq 0 ] && /usr/bin/grep -E '^ *WARN ' <<<"$OUT" | /usr/bin/grep -E "$3" >/dev/null; then ok "check-$1 $2 fires WARN and reports '$3'"
  else bad "check-$1 $2 did not fire WARN or missing '$3' (crit=$CRIT_FOUND warn=$WARN_FOUND)"; fi
}
expect_crit() {
  run_check "$1" "$FIX/$2" "${@:3}"
  if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-$1 $2 fires CRIT (crit=$CRIT_FOUND)"
  else bad "check-$1 $2 did NOT fire CRIT (crit=$CRIT_FOUND warn=$WARN_FOUND)"; fi
}

echo "=== harness-audit self-test ==="

# Check 04: agent bucket enum. Typos WARN; case variants, quoting, and trailing
# whitespace are not typos; whitespace-only is "missing", exactly one WARN.
expect_warn   04 check-04-bad-bucket-enum
expect_silent 04 check-04-good-bucket-enum
expect_silent 04 check-04-good-bucket-case-insensitive
expect_silent 04 check-04-good-bucket-trailing-whitespace
expect_silent 04 check-04-good-bucket-quoted
expect_warn   04 check-04-bad-bucket-missing
run_check 04 "$FIX/check-04-bad-bucket-whitespace-only"
if [ "$WARN_FOUND" -eq 1 ]; then
  ok "check-04 bad-bucket-whitespace-only fires exactly 1 WARN (missing, not unrecognized)"
else
  bad "check-04 bad-bucket-whitespace-only fired warn=$WARN_FOUND (want exactly 1)"
fi

# Check 32: reviewer read-only invariant, bucket-field path. fleet-bad's
# bad-reviewer.md already covers the name-substring path; this pair proves the
# 2026-09-20 fix — an unmatched name with bucket: review/analysis must still
# fire CRIT on a Write/Edit grant, and stay silent when read-only.
expect_crit   32 check-32-bad-bucket
expect_silent 32 check-32-good-bucket

# Check 05: trigger-pattern clause. WARN when a routing-length description has
# no "Use when" clause; silent at the desc_len==20 boundary.
expect_warn   05 check-05-bad-no-trigger
expect_silent 05 check-05-good-with-trigger
expect_silent 05 check-05-good-boundary-desc-len-20

# Check 20: description length (>1536 chars WARN) and the duplicate-surface twin.
expect_warn   20 check-20-bad-long-desc
expect_silent 20 check-20-good-short-desc
expect_warn   20 check-20-bad-duplicate-surface
expect_silent 20 check-20-good-duplicate-distinct

# Check 22: hooks/hooks.json event/type/matcher validity (plugin mode; used to
# be gated on settings.json and passed vacuously in the plugin repo).
expect_warn   22 check-22-bad-hooks-json
expect_silent 22 check-22-good-hooks-json

# Check 28: strict YAML frontmatter on the bucketed 2-level path.
expect_crit   28 check-28-bad-malformed-yaml
expect_silent 28 check-28-good-valid-yaml

# Check 29: agents/*.md descriptions are scanned; NEVER joins the imperative list.
run_check 29 "$FIX/check-29-bad"
if [ "$INFO_FOUND" -ge 1 ] && [ "$CRIT_FOUND" -eq 0 ]; then
  ok "check-29 bad fixture (NEVER in agent description) fires INFO (info=$INFO_FOUND)"
else
  bad "check-29 bad fixture did NOT fire INFO (crit=$CRIT_FOUND warn=$WARN_FOUND info=$INFO_FOUND)"
fi

# Check 29 WARN branch: an injection phrase in a description fires WARN; a plain one is silent.
expect_warn 29 check-29-bad-injection
run_check 29 "$FIX/check-29-good"
if [ "$CRIT_FOUND" -eq 0 ] && [ "$WARN_FOUND" -eq 0 ] && [ "$INFO_FOUND" -eq 0 ]; then ok "check-29 good silent (no INFO either)"
else bad "check-29 good not silent (crit=$CRIT_FOUND warn=$WARN_FOUND info=$INFO_FOUND)"; fi

# Check 70: stray top-level entries (gitignored working-tree clutter). WARN on a
# leftover `*-workspace/` dir; silent when the root holds only keep-list entries (the committed
# .graphifyignore among them, PR #658).
expect_warn   70 check-70-bad-stray-entry
expect_silent 70 check-70-good-clean-root

# Check 71: paired Codex plugin's review-gate state. The state file's path is
# content-addressed by the fixture's own absolute path (sha256 of its
# realpath), so it can't be pre-committed to git -- written fresh here with
# the same helper the check itself uses, under a throwaway MH_CODEX_DATA_DIR
# so this never touches the real, shared ~/.claude/plugins/data/.
CODEX_TMP=$(mktemp -d)
trap 'trash "$CODEX_TMP" 2>/dev/null || true' EXIT
setup_codex_state() {
  local fixture="$1" gate="$2" path
  export MH_CODEX_DATA_DIR="$CODEX_TMP/$fixture"
  path=$(codex_state_path "$FIX/$fixture") || { bad "check-71 $fixture: codex_state_path failed"; return 1; }
  mkdir -p "$(dirname "$path")"
  printf '{"config":{"stopReviewGate":%s}}' "$gate" > "$path"
}
setup_codex_state check-71-bad-review-gate-on true
expect_warn   71 check-71-bad-review-gate-on
setup_codex_state check-71-good-review-gate-off false
expect_silent 71 check-71-good-review-gate-off
# A string "false" is not the boolean false: it must read as unknown (info), not ON (warn).
setup_codex_state check-71-good-review-gate-off '"false"'
expect_silent 71 check-71-good-review-gate-off
unset MH_CODEX_DATA_DIR

# Check 21: agent model value. fable is a documented alias but a discouraged pin
# (agent-authoring-conventions.md) -- must WARN by name, not silently pass as valid.
# Regex is 'pins fable' (the check's own fixed wording), not bare 'fable' -- the fixture's
# `model: fable` field always makes the WARN's interpolated `model='$model'` contain "fable"
# regardless of whether the explanatory prose survives, so a bare 'fable' pattern can't tell a
# gutted or removed WARN branch apart from a working one (attacker-agent catch, 2026-09-25).
expect_warn_match 21 check-21-bad-fable-pin 'pins fable'
# claude-fable-* is a second pattern in the same fable|claude-fable-* case arm (a full model ID,
# not the bare alias) -- its own fixture, so dropping or misordering that pattern below the
# earlier claude-* catch-all is independently caught.
expect_warn_match 21 check-21-bad-fable-full-id-pin 'pins fable'

# Check 72: Codex effort-set drift. A fake plugin cache carries the plugin's
# VALID_REASONING_EFFORTS line; the fixture doc either matches it or not.
mkdir -p "$CODEX_TMP/cache/scripts"
printf 'const VALID_REASONING_EFFORTS = new Set(["none", "minimal", "low", "medium", "high", "xhigh"]);\n' > "$CODEX_TMP/cache/scripts/codex-companion.mjs"
export MH_CODEX_CACHE_DIR="$CODEX_TMP/cache"
expect_warn   54 check-54-bad-effort-max
expect_warn   72 check-72-bad-effort-drift
expect_warn   72 check-72-bad-effort-missing
expect_silent_match 72 check-72-good-effort-set 'matches the installed plugin'
# Normalisation: doc order and plugin quote style must not read as drift.
expect_silent_match 72 check-72-good-effort-reordered 'matches the installed plugin'
printf "const VALID_REASONING_EFFORTS = new Set(['none', 'minimal', 'low', 'medium', 'high', 'xhigh']);\n" > "$CODEX_TMP/cache/scripts/codex-companion.mjs"
expect_silent_match 72 check-72-good-effort-set 'matches the installed plugin'
# Fail-open branches: plugin layout changed, doc missing, plugin not installed -> INFO only.
printf 'export const nothing = 1;\n' > "$CODEX_TMP/cache/scripts/codex-companion.mjs"
expect_info_only 72 check-72-good-effort-set 'VALID_REASONING_EFFORTS not found'
printf 'const VALID_REASONING_EFFORTS = new Set(["none", "minimal", "low", "medium", "high", "xhigh"]);\n' > "$CODEX_TMP/cache/scripts/codex-companion.mjs"
expect_info_only 72 check-72-info-no-doc 'spawn-brief.md missing'
MH_CODEX_CACHE_DIR="$CODEX_TMP/nonexistent" expect_info_only 72 check-72-good-effort-set 'codex@openai-codex not installed'
unset MH_CODEX_CACHE_DIR
# Without the override the check must find the newest versioned cache dir itself (sort -V:
# 1.0.10 beats 1.0.9); the older dir carries a smaller set so a wrong pick fires a false WARN.
_c72_home="$CODEX_TMP/home"
for _v in 1.0.9 1.0.10; do mkdir -p "$_c72_home/.claude/plugins/cache/openai-codex/codex/$_v/scripts"; done
printf 'const VALID_REASONING_EFFORTS = new Set(["low", "medium", "high"]);\n' > "$_c72_home/.claude/plugins/cache/openai-codex/codex/1.0.9/scripts/codex-companion.mjs"
cp "$CODEX_TMP/cache/scripts/codex-companion.mjs" "$_c72_home/.claude/plugins/cache/openai-codex/codex/1.0.10/scripts/codex-companion.mjs"
HOME="$_c72_home" expect_silent_match 72 check-72-good-effort-set 'codex/1\.0\.10/'
HOME="$_c72_home" expect_warn 72 check-72-bad-effort-drift

# 73: hooks.json <-> hook-registry.json id/description drift. Five distinct bad fixtures,
# not one, because count-mismatch and stray-key alone leave the command-fingerprint and
# defensive-parsing branches untested (round-2 Codex review on the plan that added this check).
expect_silent 73 check-73-good-registry-synced
expect_warn   73 check-73-bad-length-mismatch
expect_warn   73 check-73-bad-stray-metadata-key
expect_warn   73 check-73-bad-command-mismatch
expect_warn   73 check-73-bad-malformed-structure
expect_warn   73 check-73-bad-duplicate-id
expect_warn   73 check-73-bad-missing-command-field
expect_warn   73 check-73-bad-args-fingerprint-mismatch

# Check 74: subagent-scoped gate agent_id presence-check invariant (harness
# gap-audit, 2026-09-20). A truthiness regression in any of the four files
# must fire CRIT; a missing file must also fire CRIT (can't verify the
# invariant); all four present and correct must stay silent.
expect_silent 74 check-74-good-all-present
expect_crit   74 check-74-bad-truthiness-regression
expect_crit   74 check-74-bad-missing-file
# (2026-09-21 deep-audit) the check used to strip only # comments, so the idiom
# inside a docstring passed, and it accepted one match for irrecoverable.py,
# which has three _nested_spawn call sites to keep in step (the third since GH #245).
expect_crit   74 check-74-bad-docstring-only
expect_crit   74 check-74-bad-one-site-regressed

# Check 75: manifest skill-reference drift (harness gap-audit M12, 2026-09-20).
# "bar" is a real skill dir excluded from its fixture plugin.json's skills
# list -- referencing it with the mh: prefix (as if shipped) must fire CRIT;
# describing it without that prefix must stay silent.
expect_crit   75 check-75-bad-excluded-referenced
expect_silent 75 check-75-good-clean
expect_silent 75 check-75-good-flat
expect_crit   75 check-75-bad-too-deep-referenced

# Check 78: a skill no plugin.json skills entry covers never loads (GH #211).
expect_crit   78 check-78-bad-unregistered
expect_silent 78 check-78-good-registered
expect_silent 78 check-78-good-allowlisted
expect_silent 78 check-78-good-flat
expect_crit   78 check-78-bad-bucket-skillmd
expect_crit   78 check-78-bad-too-deep
expect_crit   78 check-78-bad-marketplace-skills
expect_silent 78 check-78-good-marketplace-plain
expect_crit   78 check-78-bad-under-skill-entry

# Check 79: prose facts pinned to the tree (GH #388). Each bad fixture is the good one with one
# defect; the regex names the fact so a WARN from a different row cannot pass the assert.
expect_silent     79 check-79-good-facts-match
expect_warn_match 79 check-79-bad-gate-table-missing-row 'README.md gate table lacks gate:x:b'
expect_warn_match 79 check-79-bad-skill-count 'Skills \(2\).*tree has 1'
expect_warn_match 79 check-79-bad-agent-count '2-agent fleet.*tree has 1'
expect_warn_match 79 check-79-bad-phrase-vanished 'pinned phrase vanished.*Agents'
expect_warn_match 79 check-79-bad-version-mismatch 'version 1.0.1.*1.0.0'
expect_warn_match 79 check-79-bad-gate-count 'gate count 3.*registry has 2'
expect_warn_match 79 check-79-bad-check-table 'check table lacks 03'
expect_info_only  79 check-79-info-no-sources 'README.md absent, skill count pin skipped'

# Check 80: external skill references resolve (GH #394). A fake HOME carries the plugin caches.
# mattpocock-skills has two versions: 1.9.0 ships writing-fragments in its manifest, the newer
# 1.10.0 keeps it on disk (in-progress/) but out of plugin.json skills[] -- so the bad fixture's
# reference only dangles if the check picks the newest version numerically and reads the manifest,
# not the disk. codex has no skills[] (default scan: commands/, agents/, skills/<n>/).
H80="$CODEX_TMP/home80"
MP80="$H80/.claude/plugins/cache/mattpocock/mattpocock-skills"
mkdir -p "$MP80/1.9.0/.claude-plugin" "$MP80/1.10.0/.claude-plugin" \
  "$MP80/1.10.0/skills/engineering/tdd" "$MP80/1.10.0/skills/in-progress/writing-fragments"
printf '{"skills":["./skills/engineering/tdd","./skills/in-progress/writing-fragments"]}\n' > "$MP80/1.9.0/.claude-plugin/plugin.json"
printf '{"skills":["./skills/engineering/tdd"]}\n' > "$MP80/1.10.0/.claude-plugin/plugin.json"
printf -- '---\nname: tdd\n---\n' > "$MP80/1.10.0/skills/engineering/tdd/SKILL.md"
printf -- '---\nname: writing-fragments\n---\n' > "$MP80/1.10.0/skills/in-progress/writing-fragments/SKILL.md"
CX80="$H80/.claude/plugins/cache/openai-codex/codex/1.0.6"
mkdir -p "$CX80/commands" "$CX80/agents" "$CX80/skills/gpt-prompting"
printf 'x\n' > "$CX80/commands/setup.md"
printf 'x\n' > "$CX80/agents/codex-rescue.md"
printf 'x\n' > "$CX80/skills/gpt-prompting/SKILL.md"
HOME="$H80" expect_silent     80 check-80-good-resolves
HOME="$H80" expect_warn_match 80 check-80-bad-dangling "README.md:3: 'mattpocock-skills:writing-fragments'"
HOME="$H80" expect_warn_match 80 check-80-bad-dangling "x.md:1: 'mh:gone'"
HOME="$H80" expect_warn_match 80 check-80-bad-dangling "x.md:1: 'codex:nope'"
# The deprecated-ADR skip reads the frontmatter only: an accepted ADR whose body quotes a
# "status: deprecated" line is still checked (good side: check-80-good-resolves' 0001-old.md).
HOME="$H80" expect_warn_match 80 check-80-bad-deprecated-in-body "0002-live.md:8: 'mh:gone'"
# 0003's closing --- carries a trailing blank (the point of the row); an editor that trims it would
# turn the row into a copy of 0002 and pass for nothing.
[ "$(sed -n 3p "$FIX/check-80-bad-deprecated-in-body/docs/adr/0003-live-trailing-blank.md")" = '--- ' ] \
  || { echo "FAIL: check-80 fixture 0003 lost the trailing blank on its closing ---" >&2; fail=1; }
HOME="$H80" expect_warn_match 80 check-80-bad-deprecated-in-body "0003-live-trailing-blank.md:8: 'mh:gone'"
# CI: no plugin cache at all. mh references still resolve against the tree; the external
# namespaces are an INFO skip, never a WARN.
mkdir -p "$CODEX_TMP/home80-empty"
HOME="$CODEX_TMP/home80-empty" expect_info_only 80 check-80-good-resolves 'mattpocock-skills.*not installed'

HOME="$CODEX_TMP/home80-empty" expect_warn_match 80 check-80-bad-dangling "x.md:1: 'mh:gone'"

# Check 81: reference file over 100 lines needs a Contents heading.
expect_warn_match 81 check-81-bad 'fx/ref.md is over 100 lines'
expect_warn_match 81 check-81-bad-fenced 'fx/ref.md is over 100 lines'
expect_silent     81 check-81-good
expect_warn_match 81 check-81-edge-101 'fx/ref.md is over 100 lines'
expect_silent     81 check-81-edge-100

# Check 82: unknown top-level frontmatter key (Claude Code ignores one silently).
expect_warn_match 82 check-82-bad-skill-typo "frontmatter key 'disable-model-invocaton'"
expect_warn_match 82 check-82-bad-agent-key "agents/fx.md: frontmatter key 'tool'"
expect_silent     82 check-82-good

# Check 83: SKILL.md over 18,000 bytes, the ~5,000-token part re-attached after compaction.
expect_warn_match 83 check-83-bad 'fx/SKILL.md is 18001 bytes'
expect_silent     83 check-83-good-edge

# Check 76: measurement coverage status freshness (harness gap-audit M14,
# 2026-09-20). Shallow on purpose -- WARN, not CRIT -- for the retired
# harness-coverage mechanism's lazy replacement.
expect_silent 76 check-76-good-populated
expect_warn   76 check-76-bad-missing-row
expect_warn   76 check-76-bad-file-missing

# Check 77: description word count (>25 WARN) and third-person voice (first/second-person
# pronoun WARN) -- skill-authoring-conventions.md's own cap, distinct from check 20's
# 1536-char runtime-truncation limit. Two independent trigger conditions, each fixture
# isolates one (mh:deep-audit gap, 2026-09-24: the check shipped with no fixture at all).
expect_warn   77 check-77-bad-long-desc
expect_warn   77 check-77-bad-pronoun
expect_silent 77 check-77-good-clean

# run_check's completion guard (mh:deep-audit F2, 2026-09-24): a missing fixture dir used to
# parse as a silent CRIT=0/WARN=0, letting expect_silent pass on a fixture that never ran.
# Isolate run_check's own internal bad() line so this meta-test contributes exactly one
# pass/fail verdict, not two.
_fail_before=$fail
run_check 77 "$FIX/check-77-DOES-NOT-EXIST"
fail=$_fail_before
if [ "$CRIT_FOUND" = "-1" ] && [ "$WARN_FOUND" = "-1" ] && [ "$INFO_FOUND" = "-1" ]; then
  ok "run_check forces failure on a missing fixture dir instead of a silent 0/0/0"
else
  bad "run_check completion guard did not fire on a missing fixture dir (crit=$CRIT_FOUND warn=$WARN_FOUND info=$INFO_FOUND)"
fi

# Fleet pair: every check without a per-check fixture. fleet-bad plants one defect per
# check; fleet-good is a complete clean fleet and doubles as the fake plugin cache for
# 02/03 (loadability = present under --plugin-cache). 43 is driven by the env ceiling.
GOOD="$FIX/fleet-good"
# The cache is a copy, not the fixture itself: passing fleet-good as its own cache would make
# 02/03 pass with the checks gutted. A decoy cache (populated, holding none of the fleet)
# proves they still discriminate; an empty cache would only WARN "unverified". 02/03 also
# read HOME's symlink farm, so they run under an empty HOME (not the full run: python3 loses
# user-site PyYAML without the real HOME and check 28 WARNs). 43 runs with the ceiling pinned.
CACHE="$CODEX_TMP/cache-copy"; cp -R "$GOOD" "$CACHE"
DECOY="$CODEX_TMP/decoy-cache"; mkdir -p "$DECOY/agents" "$DECOY/skills/meta/unrelated"
EMPTY_HOME="$CODEX_TMP/empty-home"; mkdir -p "$EMPTY_HOME"
# Pinned, not emptied: an empty value falls through to $HOME/.claude/settings.json
# (skillListingBudgetFraction), which made the full runs below machine-dependent.
export SLASH_COMMAND_TOOL_CHAR_BUDGET=100000
for id in 02 03; do
  HOME="$EMPTY_HOME" expect_crit   "$id" fleet-bad  --plugin-cache "$CACHE"
  HOME="$EMPTY_HOME" expect_silent "$id" fleet-good --plugin-cache "$CACHE"
  HOME="$EMPTY_HOME" expect_crit   "$id" fleet-good --plugin-cache "$DECOY"
done
# Cloud audit 2026-10-23 F6: with no cache, a ~/.claude/skills (or agents) dir holding only plain dirs,
# as a cloud session ships it, is not a symlink farm: one WARN, not a CRIT per component. One symlink in
# the dir makes it a farm again, and the missing links stay CRIT.
NO_CACHE="$CODEX_TMP/no-cache"
PLAIN_HOME="$CODEX_TMP/plain-farm-home"; mkdir -p "$PLAIN_HOME/.claude/skills/synced" "$PLAIN_HOME/.claude/agents/synced"
LINK_HOME="$CODEX_TMP/link-farm-home"; mkdir -p "$LINK_HOME/.claude/skills" "$LINK_HOME/.claude/agents"
ln -s "$CODEX_TMP" "$LINK_HOME/.claude/skills/other"; ln -s "$CODEX_TMP" "$LINK_HOME/.claude/agents/other.md"
for id in 02 03; do
  HOME="$PLAIN_HOME" expect_warn "$id" fleet-good --plugin-cache "$NO_CACHE"
  HOME="$LINK_HOME"  expect_crit "$id" fleet-good --plugin-cache "$NO_CACHE"
done
# Check 02 bootstrap (GH #204): a skill absent from the base ref (default origin/develop) passes as
# INFO, since the plugin cache is built from committed state and cannot hold it yet. A skill already
# on the base ref, or a repo with no base ref, stays CRIT. Repos are built here (not fixtures under
# known-bad/) because the rule needs the audited dir to be its own git toplevel.
f1_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
# mk_f1_repo <dir> <skill-on-base:0|1> <base-ref:0|1>: base commit, then newskill in the working tree.
mk_f1_repo() {
  mkdir -p "$1/skills/meta/newskill"
  ( cd "$1" && f1_git init -q && : > skills/.keep
    if [ "$2" = 1 ]; then printf -- '---\nname: newskill\ndescription: Use when testing F1.\n---\n' > skills/meta/newskill/SKILL.md; fi
    f1_git add skills && f1_git commit -q -m base
    if [ "$3" = 1 ]; then f1_git update-ref refs/remotes/origin/develop HEAD; fi
    printf -- '---\nname: newskill\ndescription: Use when testing F1.\n---\n' > skills/meta/newskill/SKILL.md )
}
F1_NEW="$CODEX_TMP/f1-new"; mk_f1_repo "$F1_NEW" 0 1
HOME="$EMPTY_HOME" run_check 02 "$F1_NEW" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -eq 0 ] && /usr/bin/grep -E '^ *INFO ' <<<"$OUT" | /usr/bin/grep 'newskill' >/dev/null; then ok "check-02 skill new vs base ref passes as INFO (no symlink needed)"
else bad "check-02 skill new vs base ref did not pass as INFO (crit=$CRIT_FOUND info=$INFO_FOUND)"; fi
F1_OLD="$CODEX_TMP/f1-old"; mk_f1_repo "$F1_OLD" 1 1
HOME="$EMPTY_HOME" run_check 02 "$F1_OLD" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 skill already on base ref stays CRIT"
else bad "check-02 skill already on base ref did not fire CRIT (crit=$CRIT_FOUND)"; fi
# Hook context: pre-commit/pre-push export GIT_DIR/GIT_INDEX_FILE for the outer repo; the check must ignore them.
# GIT_DIR names a repo whose base ref already holds the skill, so a check that honoured it would read CRIT.
GIT_DIR="$F1_OLD/.git" GIT_INDEX_FILE="$CODEX_TMP/no-such-index" HOME="$EMPTY_HOME" run_check 02 "$F1_NEW" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -eq 0 ] && [ "$INFO_FOUND" -ge 1 ]; then ok "check-02 new-skill INFO survives exported GIT_DIR/GIT_INDEX_FILE"
else bad "check-02 new-skill INFO broke under exported GIT_DIR (crit=$CRIT_FOUND info=$INFO_FOUND)"; fi
# Toplevel guard: the same new skill audited from a subdirectory of a git repo gets no exemption.
F1_SUB="$CODEX_TMP/f1-sub"; mk_f1_repo "$F1_SUB" 0 1; mkdir -p "$F1_SUB/sub" && mv "$F1_SUB/skills" "$F1_SUB/sub/skills"
HOME="$EMPTY_HOME" run_check 02 "$F1_SUB/sub" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 toplevel guard: audited subdir gets no exemption"
else bad "check-02 toplevel guard missing: subdir new skill did not fire CRIT (crit=$CRIT_FOUND)"; fi
# Error is not absence: base commit resolves but its skills tree object is gone (shallow/partial clone).
F1_BROKEN="$CODEX_TMP/f1-broken"; mk_f1_repo "$F1_BROKEN" 1 1
_t=$(f1_git -C "$F1_BROKEN" rev-parse origin/develop:skills); mv "$F1_BROKEN/.git/objects/${_t:0:2}/${_t:2}" "$CODEX_TMP/f1-broken-tree"
HOME="$EMPTY_HOME" run_check 02 "$F1_BROKEN" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 git error on the base tree fails closed (CRIT)"
else bad "check-02 git error on the base tree read as absent (crit=$CRIT_FOUND)"; fi
F1_NOREF="$CODEX_TMP/f1-noref"; mk_f1_repo "$F1_NOREF" 0 0
HOME="$EMPTY_HOME" run_check 02 "$F1_NOREF" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 no base ref fails closed (CRIT)"
else bad "check-02 no base ref did not fail closed (crit=$CRIT_FOUND)"; fi
# Override: HARNESS_AUDIT_BASE_REF replaces origin/develop. A repo with no origin/develop but a branch
# at the base commit passes only through the override; an unresolvable override fails closed even where
# origin/develop would have passed.
F1_ALT="$CODEX_TMP/f1-alt"; mk_f1_repo "$F1_ALT" 0 0; f1_git -C "$F1_ALT" branch f1base
HARNESS_AUDIT_BASE_REF=f1base HOME="$EMPTY_HOME" run_check 02 "$F1_ALT" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -eq 0 ] && [ "$INFO_FOUND" -ge 1 ]; then ok "check-02 HARNESS_AUDIT_BASE_REF names the base ref (INFO without origin/develop)"
else bad "check-02 HARNESS_AUDIT_BASE_REF override not honoured (crit=$CRIT_FOUND info=$INFO_FOUND)"; fi
HARNESS_AUDIT_BASE_REF=refs/heads/no-such-ref HOME="$EMPTY_HOME" run_check 02 "$F1_NEW" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 unresolvable HARNESS_AUDIT_BASE_REF fails closed (CRIT)"
else bad "check-02 unresolvable HARNESS_AUDIT_BASE_REF did not fail closed (crit=$CRIT_FOUND)"; fi
# Cache-sha base (GH #211): with no override, the base is the gitCommitSha installed_plugins.json records
# for the audited cache. A skill merged to origin/develop but absent from that commit stays INFO (the cache
# cannot hold it yet); one already on that commit is a real gap. A missing, unresolvable or non-matching
# entry falls back to origin/develop.
F1_CS="$CODEX_TMP/f1-cs"; mk_f1_repo "$F1_CS" 0 0
F1_CS_BASE=$(f1_git -C "$F1_CS" rev-parse HEAD)
( cd "$F1_CS" && f1_git add skills && f1_git commit -q -m addskill && f1_git update-ref refs/remotes/origin/develop HEAD )
F1_CS_TIP=$(f1_git -C "$F1_CS" rev-parse HEAD)
mk_cs_home() { # <dir> <sha> <installPath>
  mkdir -p "$1/.claude/plugins"
  printf '{"version":2,"plugins":{"mh@x":[{"installPath":"%s","gitCommitSha":"%s"}]}}' "$3" "$2" > "$1/.claude/plugins/installed_plugins.json"
}
HOME="$EMPTY_HOME" run_check 02 "$F1_CS" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 skill merged to origin/develop, no installed_plugins entry: CRIT (control)"
else bad "check-02 cache-sha control did not fire CRIT (crit=$CRIT_FOUND)"; fi
mk_cs_home "$CODEX_TMP/home-cs1" "$F1_CS_BASE" "$DECOY"
HOME="$CODEX_TMP/home-cs1" run_check 02 "$F1_CS" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -eq 0 ] && [ "$INFO_FOUND" -ge 1 ]; then ok "check-02 skill absent from the cache's build commit passes as INFO"
else bad "check-02 cache-sha base not used (crit=$CRIT_FOUND info=$INFO_FOUND)"; fi
mk_cs_home "$CODEX_TMP/home-cs2" "$F1_CS_TIP" "$DECOY"
HOME="$CODEX_TMP/home-cs2" run_check 02 "$F1_CS" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 skill on the cache's build commit but not in the cache stays CRIT"
else bad "check-02 skill on the cache commit did not fire CRIT (crit=$CRIT_FOUND)"; fi
mk_cs_home "$CODEX_TMP/home-cs3" "0000000000000000000000000000000000000000" "$DECOY"
HOME="$CODEX_TMP/home-cs3" run_check 02 "$F1_CS" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 unresolvable cache sha falls back to origin/develop (CRIT)"
else bad "check-02 unresolvable cache sha did not fall back (crit=$CRIT_FOUND)"; fi
mk_cs_home "$CODEX_TMP/home-cs4" "$F1_CS_BASE" "$CODEX_TMP/other-cache"
HOME="$CODEX_TMP/home-cs4" run_check 02 "$F1_CS" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 installed_plugins entry for another cache is ignored (CRIT)"
else bad "check-02 used a non-matching installed_plugins entry (crit=$CRIT_FOUND)"; fi
HARNESS_AUDIT_BASE_REF=origin/develop HOME="$CODEX_TMP/home-cs1" run_check 02 "$F1_CS" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-02 HARNESS_AUDIT_BASE_REF outranks the cache sha"
else bad "check-02 cache sha outranked HARNESS_AUDIT_BASE_REF (crit=$CRIT_FOUND)"; fi
# Check 03 shares the base-commit exemption (GH #211): a new agent absent from the base is INFO, one already
# on the base but missing from the cache stays CRIT, and no base ref fails closed.
mk_a3_repo() { # <dir> <agent-on-base:0|1> <base-ref:0|1>
  mkdir -p "$1/agents"
  ( cd "$1" && f1_git init -q && : > agents/.keep
    if [ "$2" = 1 ]; then printf -- '---\nname: newagent\ndescription: Use when testing.\n---\n' > agents/newagent.md; fi
    f1_git add agents && f1_git commit -q -m base
    if [ "$3" = 1 ]; then f1_git update-ref refs/remotes/origin/develop HEAD; fi
    printf -- '---\nname: newagent\ndescription: Use when testing.\n---\n' > agents/newagent.md )
}
A3_NEW="$CODEX_TMP/a3-new"; mk_a3_repo "$A3_NEW" 0 1
HOME="$EMPTY_HOME" run_check 03 "$A3_NEW" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -eq 0 ] && /usr/bin/grep -E '^ *INFO ' <<<"$OUT" | /usr/bin/grep 'newagent' >/dev/null; then ok "check-03 agent new vs base ref passes as INFO"
else bad "check-03 agent new vs base ref did not pass as INFO (crit=$CRIT_FOUND info=$INFO_FOUND)"; fi
A3_OLD="$CODEX_TMP/a3-old"; mk_a3_repo "$A3_OLD" 1 1
HOME="$EMPTY_HOME" run_check 03 "$A3_OLD" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-03 agent already on base ref stays CRIT"
else bad "check-03 agent already on base ref did not fire CRIT (crit=$CRIT_FOUND)"; fi
A3_NOREF="$CODEX_TMP/a3-noref"; mk_a3_repo "$A3_NOREF" 0 0
HOME="$EMPTY_HOME" run_check 03 "$A3_NOREF" --plugin-cache "$DECOY"
if [ "$CRIT_FOUND" -ge 1 ]; then ok "check-03 no base ref fails closed (CRIT)"
else bad "check-03 no base ref did not fail closed (crit=$CRIT_FOUND)"; fi
for id in 07 08 09 11 17 18 19 23 32 33; do
  expect_crit   "$id" fleet-bad  --plugin-cache "$CACHE"
  expect_silent "$id" fleet-good --plugin-cache "$CACHE"
done
for id in 10 21 24 35 41 42 54; do
  expect_warn   "$id" fleet-bad
  expect_silent "$id" fleet-good
done
SLASH_COMMAND_TOOL_CHAR_BUDGET=10     expect_warn   43 fleet-bad
SLASH_COMMAND_TOOL_CHAR_BUDGET=100000 expect_silent 43 fleet-good
# A HOME whose settings.json sets a tiny skillListingBudgetFraction must not leak into 43.
TINY_HOME="$CODEX_TMP/tiny-home"; mkdir -p "$TINY_HOME/.claude"
printf '{"skillListingBudgetFraction":0.00001}\n' > "$TINY_HOME/.claude/settings.json"
HOME="$TINY_HOME" expect_silent 43 fleet-good
# Full run on the clean fleet: proves the fixture is a whole fleet, not just silent per check,
# and that the vacuous-surface guard stays quiet when agents/, skills/, hooks/ all exist.
full=$(bash "$AUDIT" "$GOOD" --plugin-cache "$CACHE" 2>/dev/null || true)
if /usr/bin/grep -q '^Critical: 0$' <<<"$full" && /usr/bin/grep -q '^Warnings: 0$' <<<"$full"; then
  ok "fleet-good full run: 0 CRIT, 0 WARN"
else
  bad "fleet-good full run not clean: $(printf '%s\n' "$full" | /usr/bin/grep -E 'CRIT|WARN' | head -3)"
fi
# Vacuous-surface guard: a fleet with no hooks/ dir must say so in a full run (green-because-empty).
NOHOOKS="$CODEX_TMP/nohooks"
mkdir -p "$NOHOOKS" && cp -R "$GOOD/agents" "$GOOD/skills" "$NOHOOKS/"
# Capture first: under pipefail, grep -q closing the pipe early hands the audit a SIGPIPE.
nohooks_out=$(bash "$AUDIT" "$NOHOOKS" --plugin-cache "$CACHE" 2>/dev/null || true)
if /usr/bin/grep -q "no hooks/ dir" <<<"$nohooks_out"; then
  ok "vacuous-surface guard names the missing hooks/ dir"
else
  bad "vacuous-surface guard silent on a fleet with no hooks/ dir"
fi

echo ""
echo "self-test: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
