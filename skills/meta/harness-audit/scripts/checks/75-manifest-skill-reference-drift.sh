#!/usr/bin/env bash
# 75. Manifest skill-reference drift (harness gap-audit M12, 2026-09-20).
# `.claude-plugin/plugin.json`'s `skills` array is the canonical list of what
# actually ships -- a directory-prefix glob per entry, sometimes a whole
# bucket (`./skills/meta/`), sometimes one specific skill inside a bucket
# (`./skills/workflow/ideate/`, which covers only that one skill). README.md
# and docs/reference/codex-integration-map.md both once presented
# `mh:idea-audit` as shipped while this list excluded it (re-shipped in
# 1.1.132). This makes that cross-check mechanical instead of relying on
# remembering the manifest's exact prefixes by hand.
#
# Scope, deliberately narrow: only flags an `mh:<name>` reference where a
# REAL `skills/**/<name>/SKILL.md` exists on disk right now but isn't
# shipped -- exactly the "documented as shipped but excluded from the
# manifest" class M12 exists for. Two things this deliberately does NOT
# flag, both out of scope here:
#   - `mh:<agent-name>` (backend-architect, plan-reviewer, ...) -- agents are
#     a different manifest section/namespace entirely, not a skills/ dir.
#   - `mh:<retired-skill-name>` (handoff, orchestrate, recursive-improve,
#     ...) -- no skills/ directory exists for these any more; a name with no
#     matching directory is stale-doc drift (a separate, already-planned
#     cleanup item), not a manifest-exclusion mismatch.
# A first, broader version of this check (every `mh:<name>` in prose)
# false-positived on both of the above classes, live-reproduced during
# this check's own authoring — narrowed here rather than hand-tuned with a
# growing exception list.
#
# EXPECTED_EXCLUDED: skills that exist in the repo, are tested, and are
# intentionally documented in prose (not silently deleted) despite not
# shipping -- flagging every mention of these as a fresh "drift" finding
# would just re-punish the correctly-caveated documentation this same audit
# pass wrote. Only reverse an exclusion here if the manifest itself changes;
# see this file's own docs/reference/codex-integration-map.md entries for
# the caveat wording each mention should carry.
_MANIFEST_JSON="$CLAUDE_DIR/.claude-plugin/plugin.json"
if [ ! -f "$_MANIFEST_JSON" ]; then
  warn "no .claude-plugin/plugin.json -- can't cross-check shipped skill ids against doc/eval/test references"
else
  _skill_status=$(python3 - "$CLAUDE_DIR" "$_MANIFEST_JSON" <<'PYEOF'
import json, os, sys

claude_dir, manifest_path = sys.argv[1], sys.argv[2]
try:
    manifest = json.load(open(manifest_path))
except Exception:
    sys.exit(0)
entries = manifest.get("skills")
prefixes = [e.lstrip("./").rstrip("/") for e in entries if isinstance(e, str)] if isinstance(entries, list) else []

def loads(rel):
    """Mirrors Claude Code 2.1.284 (live probes, GH #230): the default scan loads skills/<name>; a
    manifest entry loads itself when it holds a SKILL.md, else only its direct children."""
    if rel.count("/") == 1:
        return True
    return any(rel == p or (os.path.dirname(rel) == p and not os.path.exists(os.path.join(claude_dir, p, "SKILL.md")))
               for p in prefixes)

for root, dirs, files in os.walk(os.path.join(claude_dir, "skills")):
    dirs[:] = [d for d in dirs if not d.startswith("_")]
    if "SKILL.md" not in files:
        continue
    rel = os.path.relpath(root, claude_dir)
    name = None
    try:
        with open(os.path.join(root, "SKILL.md")) as f:
            dashes = 0
            for line in f:
                line = line.rstrip("\n")
                if line.strip() == "---":
                    dashes += 1
                    if dashes >= 2:
                        break
                    continue
                if line.startswith("name:"):
                    name = line.split(":", 1)[1].strip().strip('"').strip("'")
    except Exception:
        continue
    if not name:
        continue
    shipped = loads(rel)
    print(f"{name}\t{'shipped' if shipped else 'excluded'}")
PYEOF
)
  if [ -n "$_skill_status" ]; then
    # Only pass targets that actually exist -- `grep -r` on an all-missing
    # argument list exits 2 (not just "no match"), which under this script's
    # `set -e` (it's sourced into audit.sh's own shell) silently kills the
    # ENTIRE audit run with no error message. Live-reproduced against a
    # minimal fixture with no docs/evals/tests dirs at all.
    _targets=()
    for _t in "$CLAUDE_DIR/README.md" "$CLAUDE_DIR/docs" "$CLAUDE_DIR/evals" "$CLAUDE_DIR/tests"; do
      [ -e "$_t" ] && _targets+=("$_t")
    done
    _refs=""
    if [ "${#_targets[@]}" -gt 0 ]; then
      # --exclude-dir=results skips untracked eval run output; a tracked results/ dir under docs/tests would be skipped too (none exist).
      _refs=$(/usr/bin/grep -rhoE --exclude-dir=results 'mh:[a-z][a-z0-9-]*' "${_targets[@]}" 2>/dev/null | sed 's/^mh://' | sort -u || true)
    fi
    _EXPECTED_EXCLUDED="${MANIFEST_EXPECTED_EXCLUDED:-ste-lint}"
    # One awk join (was: one awk spawn per ref). A ref with no real skill dir (agent name,
    # retired skill, typo) or only a shipped one prints nothing: out of this check's scope.
    while IFS= read -r _ref; do
      case " $_EXPECTED_EXCLUDED " in *" $_ref "*) continue ;; esac
      crit "docs/evals/tests reference 'mh:$_ref', a real skill directory that exists but is excluded from .claude-plugin/plugin.json's shipped skill list (and not a documented exception) -- either add its own documented caveat, or the exclusion needs reversing"
    done < <(awk -F'\t' 'NR==FNR{if($2=="excluded")ex[$1]=1;next} ($1 in ex){print $1}' <(printf '%s\n' "$_skill_status") <(printf '%s\n' $_refs))
    unset _ref _refs _status _EXPECTED_EXCLUDED _t _targets
  fi
  unset _skill_status
fi
unset _MANIFEST_JSON
