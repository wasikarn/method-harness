# cost-report data model

## Contents

- Rows
- returns, verify_tokens, verify_cache_read, verify_per_return
- Eras
- Final-row lag
- Gap to Claude Code's own ledger
- Aggregation rule
- Why node

Read when changing `../scripts/cost-report-dedup.js`, `hooks/stop/cost-tracker.sh` or
`hooks/mod/cost-ledger.ts`.
The report itself needs none of this.

## Rows

The tracker appends one JSON row per (model, stream, agent_type) used in the session so far,
tagged `model_scoped: true`. Each row re-derives cumulative totals from the full transcript,
so the latest row per key is the session's current total, not an increment.

```
{ timestamp, session_id, transcript_path, model, model_scoped, dedup_usage, usage_pick,
  stream, agent_type, turns, input_tokens, output_tokens, cache_write_tokens,
  cache_write_tokens_1h, cache_read_tokens, cache_read_per_turn, returns, verify_tokens,
  verify_cache_read, verify_per_return, rate_verified, mh_version, head_commit,
  estimated_cost_usd }
```

- `stream`: `orchestrator` (the main transcript) or `subagent` (each `subagents/agent-*.jsonl`).
- `agent_type`: the Agent tool's `subagent_type` from the sibling `.meta.json`; `unknown` when
  missing; `null` on orchestrator rows.
- `rate_verified: false`: model matched no rate-table entry, priced at the Sonnet rate.
- Advisor-tool calls (GH #324): each `advisor_message` iteration is priced on its own model
  (usually `claude-fable-5-1`) and lands in that model's row on the same stream and
  `agent_type`. It adds tokens and cost but not `turns`, and `cache_read_per_turn` uses the
  executor's cache reads only. Counted once per (message id, iteration) across all of a
  session's files; a zeroed background-session copy adds nothing.
- Ledgers written before 2026-11-13 can hold `{ timestamp, session_id, codex_invocations }` rows.
  The tracker no longer writes them and the report skips them.
- Older rows carry fields from retired schemas; unknown keys are ignored.
- `cost-report-dedup.js`'s `csv` mode's header and column order must be kept in sync with any
  spend field added here (the CSV is a spend export: the handoff fields below, `rate_verified`,
  `mh_version` and `head_commit` are not in it on purpose) (deep-audit finding, 2026-09-25: `cache_write_tokens_1h` shipped in the row
  but not in the CSV for one commit, so the CSV silently dropped every 1h-write token while
  `estimated_cost_usd`, computed independently, stayed correct — a gap that looks like nothing
  is wrong until someone reads the CSV specifically).

## `returns`, `verify_tokens`, `verify_cache_read`, `verify_per_return` (restored 2026-09-20)

Handoff cost: main's own tokens spent reading a subagent's result, re-reading files to verify
it, and deciding — the cost the validation chain never priced. A subagent's return does not
arrive as the Agent tool_result (that only says "Async agent launched"); it lands later as a
`user` line whose string content starts `<task-notification>` and whose `<task-id>` is the
subagent's file id (`agent-<id>.jsonl`). `cost-tracker.sh`'s `build_verify_map` opens a window
at each such line and closes it at the next notification, the first assistant line carrying an
Agent `tool_use` (counted — deciding to dispatch is part of the handoff), or EOF; every
assistant line inside contributes input + cache_write + output to `v` and cache_read to `c`.
`cache_write` counts as fresh input because under prompt caching raw `input_tokens` is ~2 per
turn — leaving it out would report the cost as near zero. Fail-open: any parse error gives an
empty map, so rows keep `returns: 0`, `verify_tokens: null` rather than vanishing. Not in the
dedup key (derived per file, not a population split). On the orchestrator row the fields cover
every return in the session. This was first shipped in `6603c384` (2026-09-04) grouped by the
`role` tag, then both were deleted together in `2cac98c8`; this restore deliberately keeps
`role` out (tracked separately, see the harness gap-audit's M14) and reports one combined
"all subagents" line instead of a per-role breakdown. Rows before this restore carry none of
these fields and the Handoff cost section skips them.

## Eras

| marker | rows | effect |
|---|---|---|
| no `stream` | before 2026-08-07 | orchestrator-only; no subagent spend recorded |
| no `dedup_usage` | before 2026-09-04 | usage summed once per JSONL content-block line: turns, tokens, and cost about 2.4x high |
| `dedup_usage` without `usage_pick: "last"` | v0.68.639 to v0.68.640 | first line per `message.id` kept, a streaming placeholder: `output_tokens` and cost about 39% low |
| `dedup_usage: true, usage_pick: "last"` | v0.68.641+ | one count per API response, final output count |
| no `cache_write_tokens_1h` | before the #162 fix (1.1.118, 2026-09-25) | `cache_write_tokens` is every cache-write token, mispriced entirely at the 5-minute rate. Full-corpus measurement on this machine, 2026-09-25 (not a sample): of 183,970 `cache_creation` usage lines, 99.30% of cache-write tokens were 1-hour-TTL, 0.70% 5-minute — so `estimated_cost_usd` on these rows undercounts cache-write cost, not just theoretically |
| `cache_write_tokens_1h` present, `> 0` | after the #162 fix (1.1.118), real 1h writes seen | `cache_write_tokens` is 5-minute-TTL writes only; `cache_write_tokens_1h` is the 1-hour-TTL subset, priced separately and correctly. Historical rows are not backfilled |
| `cache_write_tokens_1h` present, `== 0` | after the #162 fix, no 1h writes OR a pre-breakdown transcript | Not distinguishable from this field alone. The flat-field fallback (no `cache_creation` breakdown object at all) exists for defensive/older-shape compatibility; on this machine it has never fired: every local line with nonzero cache-write tokens (175,524 of them) carries the breakdown object |
| `mh_version: "1.1.118"` rows, multi-iteration turns only | pushed to `develop` as commit `dc3e654b`, permanent history | That version's `raw_records()`/`scan_transcript()` read `.message.usage.cache_creation` directly. On a multi-tool-round-trip turn, that top-level object is a copy of `.message.usage.iterations[0]`'s own `cache_creation`, not a sum across `.message.usage.iterations[]` — unlike the flat `cache_creation_input_tokens` field, which does sum across iterations. Confirmed on 2,604 real local lines: top-level flat matched the true (iteration-summed) total 98.7% of the time; the top-level breakdown matched it only 0.9%. No live Stop hook ran this version: the installed plugin went from 1.1.117 to 1.1.119 |
| `mh_version: "1.1.119"`+ rows | after the same-day follow-up fix | Both extraction sites now bind `(.message.usage.iterations // []) as $its` and, when non-empty, anchor `cache_write_tokens_1h` to `min(sum of iteration 1h tokens, top-level flat)` and derive `cache_write_tokens` as the remainder — one mechanism closing three gaps a naive per-iteration sum reopened (`mh:blind-spot-hunter`, same day): an iteration missing its own `cache_creation` object no longer zeroes the whole row (it now falls through to the flat total instead of vanishing under the nonzero filter); a Claude Code background-session transcript that copies one `message.id` across sibling files with every top-level counter zeroed except `iterations` no longer manufactures real dollars on the zeroed copies (anchors to the copy's own zero flat); and an `advisor_message` iteration billing a *different* model can no longer push a row's total above its own top-level flat, bounding — though not perfectly attributing — the misattribution risk |
| single-iteration rows before the #163 remainder fix | before issue #163 | On a turn with no `iterations` array, `cache_write_tokens`/`cache_write_tokens_1h` were read straight off the breakdown's two fields with no reconciliation against the flat field — a mismatch would be priced at neither rate, not just theoretically dropped (`mh:blind-spot-hunter` follow-up on #162, filed as #163, citing a 0.55%/~603K-token estimate). A direct scan of 118,591 real single-iteration breakdown lines on this machine (2026-09-25) found zero mismatches, so that estimate didn't reproduce here — the fix landed as a defensive floor regardless, mirroring the multi-iteration branch: `cache_write_tokens_1h = min(e1h, flat)`, `cache_write_tokens = flat - that` |
| `claude-opus-5-5` rows, `mh_version` before `1.1.116` | 2026-09-23 to 2026-09-25 (129 raw rows across 8 sessions in `costs.jsonl` on this machine, confirmed 2026-09-25; 7 of 1512 latest/deduped rows) | Before 1.1.116 added the missing `opus-5-5` branch to `rate()`, `claude-opus-5-5` matched the old bare `opus` test and priced at the Opus 5 rate ($5/$25) instead of the correct $4/$20 — with `rate_verified: true`, which reads as confirmed-correct and gives no signal these rows are wrong. `cost-report-dedup.js` flags this by comparing `mh_version` numerically (not string-lexically) against `1.1.116`; a row with no `mh_version` at all can't be placed on either side and isn't flagged |
| rows before the GH #324 fix | before 2026-10-02 | Advisor-tool calls were never priced: a response's top-level usage excludes its `advisor_message` iterations, and nothing re-added them. Over 25 cleanly ended sessions on this machine (2026-10-02) they were about 11% of Claude Code's own `cost-state` total. Not backfilled. Some advisor calls leave no iteration in any transcript (a `server_tool_use` advisor block with no matching iteration, about 7% more), so no transcript scan can price those |

No legacy era is rewritten. The report prints a `note:` line for each of the three token-count
and cache-write-split eras present; the no-`stream` era shows as a missing section instead.

A row with `error: "jq_failed"` (and no token fields) is the tracker's sentinel for a jq pass
that died; the report never aggregates it, and prints one `warning:` line per session with the
row count and the session id prefix (2026-09-21). `returns per orchestrator turn` divides by
the turns of every orchestrator row carrying `verify_per_return`, including zero-return rows.

## Final-row lag (GH #329)

A session's latest row can trail its transcript, for two reasons:

- **Read before flush.** Stop could fire before Claude Code flushed the turn's final response,
  so the last row came up one response short (67 of 235 sessions on this machine, 2026-10-02;
  6 more were short for other reasons, such as a kill). A later Stop repairs earlier turns, so only the session's last turn was
  ever lost. Since the fix the hook waits until the transcript stops growing
  (`MH_COST_TRACKER_SETTLE_S`, default 1 s) and reads again if it grew during the scan. Rows
  written before the fix keep the gap; it is not backfilled.
- **Killed mid-tool.** A turn killed during a tool call never fires Stop, so its spend stays
  unrecorded. A `SessionEnd` re-run was considered and left out: a plugin's `SessionEnd` hook
  gets a 1.5 s budget that its own `timeout` cannot raise, too short to rescan a large transcript, and it would not cover a kill
  either.

## Gap to Claude Code's own ledger (GH #334)

Claude Code writes `cost-state` lines into the main transcript: `totalCostUSD`, plus per-model
`modelUsage` (tokens and `costUSD`), cumulative from the process start. They appear in pairs at a few
points per session, not every turn (the trigger was not identified), so the last one can trail
the transcript's end. In 1 of 346 sessions the total reset to near zero when a new process
(new `startTime`) took over the same session id, so a reader must not assume it only grows. It breaks spend down by model only, with no field saying which kind of request
spent it.

Attribution over the 25 most recent cleanly ended sessions on this machine (2026-10-02; the
last `cost-state` line within 15 lines of the end; ledger at least $5; ledger total $1,504).
The transcript was priced with this tracker's rate table, all cache writes at the 1-hour rate
(99.3% of writes are 1-hour, so the error is under 1%):

| part | $ | share |
|---|---|---|
| executor responses in the transcripts (all that rows held before #324) | 1,087 | 72% |
| `advisor_message` iterations in the transcripts (priced since #324) | 168 | 11% |
| advisor calls with no iteration in any transcript | 108 | 7% |
| other spend on the executor models with no transcript line | 141 | 9% |

| session | ledger | executor | advisor | advisor blocks / iterations | no-iteration advisor | other |
|---|---|---|---|---|---|---|
| 30223e32 | 331.5 | 227.4 | 75.2 | 44 / 44 | 1.0 | 28.0 |
| 6f444787 | 217.3 | 135.3 | 11.6 | 23 / 6 | 27.8 | 42.6 |
| 3ee810d0 | 178.6 | 155.8 | 18.9 | 16 / 9 | 6.5 | -2.6 |
| a91ba587 | 135.4 | 84.0 | 13.5 | 14 / 7 | 18.9 | 19.0 |
| 9226c634 | 102.0 | 77.5 | 16.7 | 15 / 14 | 4.2 | 3.7 |
| e7c0ebca | 55.0 | 40.5 | 0.0 | 3 / 0 | 5.4 | 9.1 |
| 2ff6e790 | 29.8 | 16.5 | 0.0 | 5 / 0 | 8.1 | 5.3 |

- **No-iteration advisor calls.** The ledger's fable spend beyond the transcript tracks the
  sessions where `server_tool_use` advisor blocks outnumber recorded `advisor_message`
  iterations. Where the two counts match (30223e32, 44 / 44), the remainder is about $1. These
  calls leave no tokens in any transcript, so no scan can price them.
- **Other spend.** On the executor models the ledger carries millions of uncached input tokens
  where the transcripts hold almost none (claude-opus-5-5 over 40 sessions: 6.2M vs 24K). It
  also carries more output and cache-read tokens. These are requests that write no transcript
  line. Likely sources are the auto-mode classifier, prompt suggestions, away summaries,
  compaction and title generation (haiku). They cannot be split further from local data: the
  ledger has no request-type field and the local telemetry files hold no API events. The ledger
  also files `claude-opus-5-5[1m]` under its own key.
- The share for the `cost-state` total depends on how advisor-heavy a session is: 52% to 99%
  per session before #324. A small negative "other" (3ee810d0, -$2.6, 1.5%) is within the
  cache-write pricing approximation above.

**Decision (GH #334, option A plus a cross-check).** The transcript rows stay the authoritative
session cost: every per-model, per-stream and per-agent figure comes from them, and they capture
about 83% of the ledger since #324. cost-tracker and `costs.jsonl` are unchanged. The ledger is
read live instead, as a cross-check, by mh's hooks module (`hooks/mod/cost-ledger.ts`,
`docs/reference/cost-ledger-module.md`).

### Ledger rows and the cross-check line

The module appends `{ t, session_id, turn_id, usd, delta, reset }` to `cost-ledger.jsonl` beside
`costs.jsonl` after each main-loop turn; `usd` is `$.session.usage().cost.usd`, the running total
`/cost` shows. A row with `error` marks a turn whose reading failed or was not a finite number.

The report recomputes each session's ledger total from the `usd` sequence in file order: the
first reading counts in full, growth adds the difference, and a drop (a new process) adds the new
reading in full. The stored `delta` is not used, because it restarts when the module reloads. The
report then prints one line after `total:`:

- **Data on both sides:** `ledger cross-check: transcript $X vs ledger $Y over N sessions;
  unattributed $Z (P% of ledger)`. Only sessions present in both files count; sessions on one
  side only are listed as `left out: A transcript-only, B ledger-only`, never added.
- **No ledger rows** (no file, or only `error` or load-marker rows): `ledger cross-check: no
  ledger data (...)`. Modules were off, the CLI is older than 2.1.287, or no turn has ended yet.
  Not zero.
- **Error rows** add a `warning:` line with their count; the ledger total may then run low.
- **Rows whose `usd` is not a finite number** (`null`, a string, missing; `null` is how JSON writes
  NaN and Infinity) are skipped and counted in their own `warning:` line. They are never read as
  $0: a $0 reading is a reset, which adds the next reading in full.

Load-marker rows (`{ t, session_id, loaded: true, cli, mh }`, GH #444, one per module load and session id, so a `/clear` gets its own) carry
no `usd` and feed a separate line before the cross-check line: `module loaded: N of M sessions
since the first load marker (<date>)`, M being the `costs.jsonl` sessions whose last row is at or
after the first marker, or `module loaded: no load marker (...)` when there is none. A session with
spend and no marker ran with modules off.

`tests/skills/test-cost-report.sh` pins the three cases and the recompute rule with fixtures whose
wrong answers (summed stored deltas, last or max `usd`, an unchanged reading taken as a reset)
differ from the right one.

## Aggregation rule

For each session with any `model_scoped` row: take the latest row per
(`session_id`, `stream`, `model`, `agent_type`) and sum across keys. A row with no `stream`
counts as `stream: "orchestrator"`, not a fourth bucket. A session with no `model_scoped` row
falls back to its single latest row. Days bucket by local calendar day.

Every element of that key exists because dropping it double-counted real spend: a streamless
legacy row plus a same-model orchestrator row overcounted one session by $8.07 on 2026-08-07,
and two agent types on one model would collapse into one bucket. `tests/skills/test-cost-report.sh`
pins each element with fixtures whose wrong answers differ from the right one.

## Why node

Report and CSV logic live in one bundled file so macOS, Linux, and Windows run the same code
with no `jq` or `sqlite3` dependency, and the test runs that file directly.
