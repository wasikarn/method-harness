## Action mode (`--auto-archive`)

Mechanical fold of verbose/closed entries per the **A3 rubric** (the classes below), plus a
**Class D fallback valve** for a store shape A/B/C structurally can't catch. This engine is the
canonical home of the trim workflow: the three `--auto-archive` invocations below.

- **<2KB delta per session for A/B/C** — never collapse the whole store; trim only the worst. Class D is the deliberate exception: it's a last-resort valve for a store shape A/B/C structurally can't catch (many small terse entries, no verbose outlier), so its delta can be larger.
- **<30 min elapsed** — if it takes longer, the store is unhealthy in ways trim won't fix
- **Reversible** — A moves via `mv` (never `rm`); B/C rewrite in place; D deindexes only (removes the MEMORY.md pointer line, backing file untouched — recoverable via git history, `qmd`, or re-adding the line by hand)

| Class | Trigger | Action | Safety |
|---|---|---|---|
| **A — stale-superseded** | MEMORY.md pointer has `**SUPERSEDED**` marker + topic has 0 surviving inbound `[[wikilinks]]` | `mv <topic> _archive/<date>/` + collapse pointer to 1-line stub | Always safe (marker = user intent) |
| **B — near-budget-collapse** | MEMORY.md >80% cap + pointer ≥250 chars + topic >5KB + pointer ≥ 1.2x first paragraph | Replace pointer with ~80-char stub + add `supersedes:` note in topic | Editorial; review each rewrite |
| **C — dangling-link-rewrite** | Surviving file's `[[wikilink]]` resolves to nothing or to `_archive/` | Rewrite `[[X]]` → `[[<ledger>]]` | Mechanical when target is already-archived |
| **D — count-fold** | Index still ≥80% of cap after A's and B's planned edits (D always runs; only that threshold gates it) | Deindex oldest pointer lines by topic-file **mtime**, any type, until back under 65% of cap | Dry-run/confirm gated, same as A/B/C — but ranks by "hasn't been edited," which can catch a stable, correct, evergreen reference for the wrong reason. Review the dry-run list before confirming. |

> **Source of truth:** the thresholds above (≥250 chars, >5KB, ≥1.2×, 200L/25KB cap, Class D's 80%/65% fold band) are enforced in `scripts/memory-lint.py` (`class_a_stale_superseded` / `class_b_near_budget_collapse` / `class_c_dangling_link_rewrite` / `class_d_count_fold`). Update this table when the code changes — this prose mirrors the code, it does not define it.

Default for `--auto-archive` is dry-run with confirm prompt; `--yes` skips the prompt (use for CI/scripts). `--json` produces machine-readable output (mode-aware: detector JSON for plain lint, action-plan JSON for `--auto-archive --dry-run`).

### Trim workflow (plan / apply / status)

Three `--auto-archive` invocations, run in order:

1. **plan** — `--auto-archive --dry-run --json` → the action plan (what would move, projected before/after size) without touching the store. Never skip straight to apply: drift the plan review and you `mv` entries you meant to keep.
2. **apply** — `--auto-archive --yes` → executes the reversible `mv`s (collapsed pointers stay grep-able in `_archive/`; never `rm`).
3. **status** — `python3 "${CLAUDE_SKILL_DIR}/scripts/memory-lint.py"` (detector mode) → current finding count + load-budget %; run before and after an apply to read the size delta.

Reach for trim when MEMORY.md is over its 200-line / 25KB cap or after a big session; for routine link/index checks the default detector is enough.
