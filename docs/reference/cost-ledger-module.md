# Cost-ledger module

`hooks/mod/cost-ledger.ts` is mh's one hooks module (a Claude Code mod, GH #323). It is an
observer: it never denies, asks, rewrites or answers for core. The shell hooks stay the base:
`cost-tracker.sh`, `costs.jsonl` and every gate are unchanged, and the transcript-priced total in
`costs.jsonl` stays the authoritative session cost (GH #334, option A). The module adds three
things: a cross-check against Claude Code's own cost ledger, a per-load marker row (#444), and
in an mh checkout a cached-vs-repo version status and stale-skill toast (#442).

## What it records

After each main-loop turn (`turn.complete` with no `agentId`), it reads
`$.session.usage().cost.usd`, the session's cost as `/cost` totals it, and appends one row to
`~/.local/share/kbg/metrics/cost-ledger.jsonl`:

```
{ t, session_id, turn_id, usd, delta, reset }
```

- `usd`: the ledger's running total, as Claude Code reports it. This is the primary field.
- `delta`: `usd` minus the previous reading in this module load. The first reading counts in
  full. A drop means a new process took over the session id and its ledger started from zero, so
  `delta = usd` and `reset: true`.
- A failed read becomes `{ t, session_id, turn_id, error }`, and so does a reading that is not a
  finite number (NaN or Infinity, which JSON would write as `null`); the baseline is left alone,
  so the next row's `delta` is still measured from the last good reading. A failed append is a
  `$.ui.log` line (debug log outside a hot-reload session) and the row is lost; the next row's
  `delta` carries the growth.
- `usage()` with no `cost` (a host that keeps no ledger) writes nothing.

Subagent turns write no row; their spend shows up in the enclosing main turn's `delta`, because
the ledger covers the whole session.

Names verified against the `claude-code.d.ts` that CLI 2.1.288 writes: `turn.complete`'s input
(`TurnCompleteFields`: `turnId`, `agentId` absent on the main loop), `$.session.usage()` returning
`SessionUsage.cost?: SessionCost` with `usd: number`. `turn.step` was not used: it is a
streaming event per model request, not per turn. `session.measure` also carries `cost` and fires
after each main-thread turn, but has no turn id and was not probed under `claude -p`.

## Load marker (GH #444)

The first hook call of each module load (`session.start`, `skill.prompt` or `turn.complete`,
whichever runs first) appends one row to the same `cost-ledger.jsonl`:

```
{ t, session_id, loaded: true, cli, mh }
```

`cli` is `$.session.version().version`; `mh` is the version in `$.plugin.root`'s
`.claude-plugin/plugin.json`, the copy that actually runs. A field that cannot be read is left
out; a failed append is a `$.ui.log` line. A reload writes a second marker for the same session.
It goes to the ledger file, not `$.ui.log`, because under `claude -p` the UI log only reaches the
debug log. With modules off nothing is written, and that absence is the signal: "the kill switch
served off" reads apart from "loaded but idle" (a marker and no `usd` rows).

## Cached-vs-repo status (GH #442)

Only when the session's project root (`$.session.root()`) holds a `.claude-plugin/plugin.json`
whose `name` matches `$.plugin.name`, i.e. an mh checkout or worktree. Anywhere else it does
nothing.

- **`session.start`:** compares the cached version (`$.plugin.root`) with the repo manifest's. A
  stale cache pins one `$.ui.status` line: `mh: cache 1.1.173 is stale, repo 1.1.174 (...)`. Equal
  versions say nothing and clear any earlier line (GH #458: the engine draws every plugin status
  line warning-styled, and the ledger's load row proves the load). Equal versions do not prove
  equal content (same-version edits are no-ops), which is what the skill check is for.
- **`skill.prompt`:** finds the skill's `SKILL.md` through the cached manifest's `skills` entries
  (`<entry>/<name>/SKILL.md`, or `<entry>/SKILL.md` when the entry is the skill's own folder; a
  `plugin:` prefix on the name is dropped) and compares it byte for byte with the same path in
  the repo. A difference is one `$.ui.toast` per skill per module load saying the cached copy runs.
  A skill not in mh, or missing from the repo, gets nothing. The prompt text passes through
  untouched.

This is the in-session answer to "which mh copy runs" (`docs/reference/repo-gotchas.md`); a
`Skill()` call alone runs the cached copy and cannot confirm a repo edit.

Names verified against the `claude-code.d.ts` that CLI 2.1.289 writes, and listed by
`claude plugin validate .` 2.1.289 as the module's calls: `session.start` (`SessionStartInput`),
`skill.prompt` (`SkillPromptInput`: `skill`, `text`; result `{ text }`), `$.plugin.root` /
`$.plugin.name`, `$.session.root()`, `$.session.version()` (`SessionVersion.version`),
`$.fs.read(path)`, `$.ui.status(text)`, `$.ui.toast(text, { timeoutMs })`.

**Live evidence.** `$.plugin.root` is the folder above `.claude-plugin/`: all 297 load markers in
the operator's `cost-ledger.jsonl` (2026-10-04 to 2026-10-21, CLI up to 2.1.306) carry the `mh`
field, which is read through it. **Live probe: not run** for the other two, which rest on the
d.ts alone, because a dispatched subagent cannot start `claude -p` (mh's
`gate:bash:irrecoverable` blocks nested sessions): whether `skill.prompt`'s `skill` carries the
`mh:` prefix (both forms are handled), and that `session.start` fires under `-p`. To probe from a main
session: copy the repo to a scratch folder, set its `plugin.json` version to `0.0.1` and edit one
`SKILL.md`, run `claude -p "/mh:cost-report" --plugin-dir <copy> --debug-file <log>` from the
repo, then check for a `loaded` row in `cost-ledger.jsonl` with `mh: "0.0.1"` and the status and
toast text in the debug log.

## How cost-report reads it

`skills/meta/cost-report/scripts/cost-report-dedup.js` prints one `ledger cross-check:` line: the
transcript total vs the ledger total over the sessions present in both files, and the gap. It
recomputes each session's ledger total from the `usd` sequence in file order with the same rule
and ignores the stored `delta`, which restarts when the module reloads. The rule and the line's
three cases are in `skills/meta/cost-report/references/data-model.md`, section
"Gap to Claude Code's own ledger".

It also prints one `module loaded:` line from the load markers: `module loaded: N of M sessions
since the first load marker (<date>); ...`, where M counts the `costs.jsonl` sessions whose last
row is at or after the first marker (older sessions predate it) and N those with a marker. With no
marker at all it prints `module loaded: no load marker (...)`. Marker rows carry no `usd` and are
not counted in the no-finite-usd warning.

## When modules are off

Nothing is written, and nothing else changes: no status line, no toast, no marker. cost-report
prints `ledger cross-check: no ledger data (...)`, not zero and not an error, and the session is
missing from the `module loaded:` count. Modules are off on CLIs
before 2.1.287, under `--bare`, `--safe-mode`, `disableAllHooks`, `allowManagedHooksOnly`,
`allowManagedModsOnly`, in an untrusted workspace, and when Anthropic's remote switch serves off.
A reload after such a flip drops the module mid-session.

## Turning it off

There is no mh-only switch. Claude Code's own switches stop it: `--safe-mode` for one session,
or `"disableAllHooks": true`, which also stops mh's shell hooks and gates. Disabling `mh` in
`/plugin` stops all of mh. A mh-only switch (a `userConfig` field) is easy to add if anyone needs
it.

## Minimum CLI

The module needs Claude Code 2.1.287 or later (code.claude.com `plugins/mods/overview`). This is
documentation only: `plugin.json` has no field for a minimum version. On older CLIs the
`modules` key is harmless: `claude plugin validate` 2.1.261 accepts it (checked 2026-10-03), and a 2.1.240 runtime ran the command hooks and ignored the module (#323).

## Rules for this file

- **One module per plugin.** Claude Code refuses a second `modules` entry. Any later module
  feature joins this file.
- **Never a gate.** A module fails open whenever modules are off, so deny and ask logic stays in
  shell hooks (#323's keep/port table).
- **Tests.** `tests/mods/cost-ledger.test.ts` runs under `claude plugin test .` from the repo
  root, with Claude Code's mods test kit. `tests/hooks/test-cost-ledger-module.sh` wraps it for
  the gauntlet and prints `SKIP` on a CLI with no `plugin test`. `tsc` is not run (the repo has
  no TypeScript toolchain); `claude plugin validate` reads the module source.
- Loading the plugin from a folder (`--plugin-dir`) makes the engine write
  `.claude-plugin/types/` there; it carries its own `.gitignore`.

## Known limits

- Spend after the last main-loop turn (a background subagent that ends after it, any request
  Claude Code makes after that turn) is not read.
- A new process whose first reading is above the old total reads as growth, not a reset, so the
  ledger total runs low for that session.
- The baseline lives in a module variable, so after a reload the first row's `delta` equals
  `usd`. The report's recomputation is unaffected.
- The report skips a row whose `usd` is not a finite number (a hand edit, a file from before the
  writer refused NaN/Infinity) and says how many in a `warning:` line. If that row was the
  session's last, the spend since the previous reading is missing from the ledger total.
- Two live processes writing rows under one session id at once (not verified to happen; a double
  `--resume` is the likely shape) interleave their `usd` sequences. A switch to the lower one reads
  as a reset and a switch back as growth from it, so the ledger total runs high: rows
  `1.0, 0.2, 1.1, 0.3` read $2.40 where the two processes' finals sum to $1.40.

## Observer contract check

`scripts/check-observer-contract.sh` (GH #443) runs in the gauntlet's validate layer and fails
when the module stops being an observer. It reads `claude plugin validate --json`, whose notes on
the `hooks/hooks.json` entry list what the module hooks and which `$.` calls it makes
(`./mod/cost-ledger.ts hooks: turn.complete`, `... calls: $.process.run, ...`; shape checked on
2.1.289). Every hook must be an observer event (`turn.complete`, `session.start`, `skill.prompt`), and no call may be an ask/deny/permission surface
(`$.ui.ask`). Deny and rewrite are return values (`{ deny }`, `next({ ...e })`), which the notes
cannot show, so a static scan of the source (comments stripped) covers them. A missing hooks note
fails, so a CLI output change shows up instead of passing silently. Without the `claude` CLI only
the static scan runs. Test: `tests/scripts/test-observer-contract.sh`, with a known-bad module
under `tests/scripts/fixtures/observer-contract/bad/`.
