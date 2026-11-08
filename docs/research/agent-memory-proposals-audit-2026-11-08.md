# Agent-memory management proposals adoption audit (2026-11-08)

**Date:** 2026-11-08
**Source:** a host-session research synthesis (nine external claims E1-E9, four repo claims R1-R4, three proposals P1-P3 plus P4 "keep the structure"), read from a saved copy in the session scratchpad. The external claims came from lossy query extractions, so the saved copy carries the WebFetch-derived banner. No local clone, no pinned revision of any external source.
**Verdict:** Do not adopt P1-P3 as proposed. The store is healthy (508 memories, MEMORY.md at 59% of its cap, 0 lint findings, every auto-archive class idle), so the proposals answer no measured problem. Keep the structure (P4). One real gap exists and is small: the old MEMORY.md cost line disappeared when the `context-budget` skill was deleted, so nothing reports MEMORY.md size in tokens. Restoring one total line is the only change worth making. P2 (use-driven eviction) is deferred, P3 (history/fact split) is declined on evidence, and P1's per-entry framing rests on a misread of claude-mem.
**Score:** 49.5/100 — **FAIL** (threshold 60; confidence medium). Full criteria table: see Decision score below.

Every claim below about the source's internals is what it describes as of this read, not a verified fact about the source as it exists today or in the future.

## Method

Three agents: Agent A (claims, read-only, saved copy only), Agent B (fit, read-only, live repo), and one adversarial attacker (Codex `gpt-6.1-sol`, medium effort, read-only sandbox; verdict passed `check-verdict.py`). The attacker's output failed `check-citations.py` on 5 of its 22 items (its evidence there was prose or markdown links, not a `path:line` or backticked command); those items count as missing citations and keep the external claims at `insufficient evidence` in this table even where the attacker says it confirmed them from the pages. Prior audits this pass builds on, not relitigates: `docs/research/agent-memory-engineering-2026-08-07.md` (shipped A1-A5) and `docs/research/claude-mem-architecture-study-2026-08-07.md`. A qmd query with no collection filter found no other-repo audit of these proposals, only wiki pages on claude-mem progressive disclosure. The wiki itself records that claude-mem's docs contradict each other (about 50-200 tokens for an index versus about 800), which this pass did not resolve.

## Claim-by-claim: the repo claims hold, the external claims are unchecked, and one proposal premise is misframed

Legend: `MATCH` = claim confirmed against primary evidence · `PARTIAL` = partially confirmed ·
`GAP` = claim not found / contradicted by primary evidence · `N-A` = not applicable to this repo.

| # | Claim | Verified? | This repo's posture | Verdict |
|---|---|---|---|---|
| E1 | Claude Code loads the first 200 lines or 25KB of auto memory each session | insufficient evidence (banner file); echoed by `memory-lint.py:97-99` | `LINE_CAP = 200`, `BYTE_CAP = 25 * 1024` at `memory-lint.py:79-80`; exact "KB means KiB" unconfirmed | PARTIAL |
| E2 | The `cleanupPeriodDays` sweep skips the memory directory | insufficient evidence | no repo cite | N-A |
| E3-E5 | MemGPT tiers, Letta pinned blocks, LongMemEval numbers | insufficient evidence (attacker cites pages in prose only) | background, not a decision input | N-A |
| E6-E7 | Mem0 +26%/91%/90%; claude-mem 35k vs 920 tokens | insufficient evidence | both are vendor-reported; the 120 and 155 per-fetch figures are different examples | N-A |
| E8-E9 | Anthropic memory tool shape; Hindsight four levers | insufficient evidence | E8 is the API tool, not Claude Code auto-memory; E9 is a vendor reading | N-A |
| R1 | Hard cap is 25,600 bytes and matches the platform limit | Yes — observed directly | `memory-lint.py:80`; live MEMORY.md 15,220 B (59%) | MATCH |
| R2 | No auto-archive class uses usage data or tokens | Yes — observed directly (A and the attacker, whole-file) | A: SUPERSEDED marker; B: pointer length; C: dangling links; D: topic-file mtime | MATCH |
| R3 | A5 shipped MEMORY.md cost visibility | Yes on history | stale: commit `b906d6e2` deleted the skill, so no MEMORY.md cost is reported today | PARTIAL |
| R4 | Memory files cost ~18.7k tokens at start | Not independently checkable | arithmetic fits, but that figure covers every CLAUDE.md layer; MEMORY.md alone is ~3.8k tokens | PARTIAL |
| P1 | Per-entry token counts, as claude-mem does | Attacker: claude-mem's per-entry numbers are retrieval costs, not index-line costs | no per-entry number exists; bytes and lines are the platform's units | PARTIAL |
| P2 | Use-driven decay/eviction | Yes — usage signal checked | no read logger; transcripts show 25 memory Reads covering 11 of 509 files (undercount: transcripts only back to 2026-09-01); Class D has fired 0 times at 59% (trigger 80%) | PARTIAL |
| P3 | Split history memories from facts | Yes — checked | prior audits never ruled on it (they rejected finer typing); sub-indexes such as `index-settled-audits.md` already keep history out of the loaded index | PARTIAL |

Two corrections to the analysts, from the attacker. Agent B called P3 "already covered" and Agent A called it "decided in spirit": neither holds, since no prior audit decided it and the proposal never required moving files. Agent B's recall-log numbers (68 rows, 41 memories) pool several repos; for this repo the first 68 rows hold 15 rows and 12 memories, and the log counts pointers shown, not memories read.

## Shipped

Nothing — this is a read-only research pass. Only this file and the memory entry were written.

## Deliberately not shipped

- **P1 per-entry token counts** — `skills/meta/memory-lint/scripts/memory-lint.py:79-80` (the platform enforces lines and bytes, index at 59%) **and** YAGNI. Labeled: **declined on evidence** for the per-entry form. A single "MEMORY.md ~N tokens (est.)" summary line is the one change worth making; it restores the lost A5 line and touches the summary print near `memory-lint.py:324` plus one test. Not done here because it was not asked for.
- **P2 use-driven eviction** — `docs/research/claude-mem-architecture-study-2026-08-07.md:255` (mtime measures untouched, not irrelevant, a known limit) **and** Rule 1's riskiest-assumption probe: the usage signal does not exist, and a Read-logging hook in `~/.claude/hooks` is a T3 change. Labeled: **deferred**, revisit only when Class D starts firing and its dry-run names files still in active use.
- **P3 history/fact split** — `docs/research/agent-memory-engineering-2026-08-07.md:520` (the 4-type taxonomy kept) **and** YAGNI: the index shrank from 19,402 B to 15,220 B while the store grew 2.9x. Labeled: **declined on evidence** for a physical move (it would break `memory-file-recall.py`'s top-level listing, stems and qmd paths); a logical split by sub-index already exists.

## Decision score (METHODOLOGY Rule 14)

| Criterion | Weight | Score | Reason |
|---|---|---|---|
| primary-source-fidelity | 45 | 5/10 | Largest weight: the audit is only as good as its evidence. 3 = most claims uncorroborated; 5 (this one) = every repo claim confirmed twice, the external claims unchecked by citation shape and mostly vendor-reported, one proposal premise misread; 8 = core claims traced to raw primary pages. |
| fit | 30 | 4/10 | The decision turns on need. 2 = no need; 4 (this one) = one small real gap (the lost token line), no measured pain; 8 = a measured cost the repo feels. |
| blast-radius/reversibility | 25 | 6/10 | Cost if adopted wrong. 3 = a one-way door; 6 (this one) = mostly reversible, one T3 hook for P2, P3 near one-way as a physical move; 9 = report-only. |

Weighted sum: 45×0.5 + 30×0.4 + 25×0.6 = 22.5 + 12 + 15 = **49.5/100** (`weighted-score.py`). Pass threshold 60, fatal-weakness floor 40% of each axis max: no axis is below it (fit sits exactly at 40%, and the floor is strictly below), and the source side did not trip the all-`insufficient evidence` rule because the repo claims scored. **FAIL.** Confidence: medium (three agents, one different-model attacker, but 5 of its 22 items lacked citation shapes and the usage data covers only 420 transcripts from 2026-09-01).

## Open questions

- Does Class D ever fire, and on which files? — revisit only when `memory-lint.py --auto-archive --dry-run` reports a non-zero D count.
- Is the docs' "25KB" 25,000 or 25,600 bytes? — revisit only if a session ever truncates MEMORY.md below 25,600 B.
- The two prior audits list `--find-contradictions` and `--classify-unindexed` as shipped, but neither name appears in `memory-lint.py` — revisit when someone next edits those docs.

<!-- Reserved: a later pass appends a dated correction here, never rewrites the sections above.
**Correction (date, mechanism):** ... -->
