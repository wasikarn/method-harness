---
status: accepted
---

# mh captures a pointer to upstream writing-fragments' own file

`writing-fragments` (upstream, `skills/in-progress/writing-fragments/`, unregistered in matt's
own `plugin.json`) asks the user once for a save path and "remember[s] it for the rest of the
session" only — nothing preserves that path once the session ends, and its own framing ("the
novelist's diary... years of unstructured noticings") is deliberately multi-session. This is the
same friction class `docs/adr/0002-mh-controlled-handoff-path.md` solved for `mattpocock-
skills:handoff`, but the fix has to be a different mechanism: handoff's content was undetectable
by design (no template, no write-tool mandate, no path convention), so mh stopped trying to
detect it and wrote its own duplicate artifact instead. `writing-fragments`' artifact **is** the
user's actual creative work — mh must never touch, copy, or duplicate it, only capture a
**pointer** (the path) and remind the user it exists.

## Rejected: `PreToolUse:Skill`

The original design mirrored `gate:skill:codex-setup-guard` (then this repo's only
`Skill`-matcher hook, since removed, matching `tool_input.skill == "codex:setup"`). Checked against three live
transcripts (`/mattpocock-skills:implement`, `/mattpocock-skills:grilling`, `/mh:learn`) and found
dead: a **user-typed** slash command never produces a `Skill` tool_use event at all — it lands as
a plain user message carrying literal `<command-name>`/`<command-args>` tags, with zero tool call
in between. This holds regardless of `disable-model-invocation`. `PreToolUse:Skill` only ever
fires for a *model-invoked* `Skill` call, which is exactly the case `disable-model-invocation`
blocks for this skill.

## The mechanism: `UserPromptSubmit`

Confirmed real three ways: documented in the official `plugin-dev` hook-development skill; shipped
and firing in the installed `ponytail` plugin (`hooks/ponytail-mode-tracker.js`, live-verified —
its stdout only appears when `.prompt` matches `/^[/@$]ponytail/`, only possible if `.prompt`
carries the raw, un-expanded text, since expansion into `<command-name>` tags happens strictly
after this hook fires); and mh itself had this exact pattern before (`flow-nudge.sh`,
`jira-route-nudge.sh`, deleted in the v1.0.0 rebuild, recoverable from `10b6230f^`). Field name is
`prompt`, not the official docs' `user_prompt` (that names a different hook type's shell variable).

## Design

Three hooks, one sourceable library (`scripts/_lib/fragments-state.sh`), observation-only
throughout:

- **`sensor:prompt:fragments-arm`** (`UserPromptSubmit`) — on a matching prompt, arms a
  per-invocation marker plus an optional candidate-path sidecar (the typed args, if any), then
  publishes a **current-generation pointer** as the last step. May also inject a known-path nudge
  if this project already has a document on record.
- **`sensor:write:fragments-capture`** (`PostToolUse`, `Write|Edit`) — a cheap readdir gate first;
  if armed, checks whether this write plausibly targets the candidate (exact canonical-path match)
  or, absent a candidate, a heuristic (`.md`/`.markdown`, H1-required for `Write`, extension alone
  for `Edit`). On a match, claims and publishes a durable record. Never prints anything.
- **`session:fragments-surface`** / **`session:fragments-reinject`** (`SessionStart`) — surfaces a
  one-line pointer per document with an unseen on-disk change; `--reinject` (matcher `compact`)
  skips the diff filter and reprints unconditionally, since a fragments file's one stated path is
  exactly what compaction loses (the opposite inclusion from `session:handoff-nudge`'s
  compact-only scope). Also sweeps stale TMPDIR arm state.

State: `$HOME/.claude/state/mh-fragments/<slug>-<hash>/documents/<sha256(path)[:16]>.json`, one
file per document — capture only ever creates, surface only ever rewrites what it just read, so no
lock is needed for the durable tree (the same "consumed is a directory, not a state file"
principle `docs/adr/0002-...` already established).

## The riskiest part: the ephemeral marker, and why it took five review rounds to get right

`codex-review:plan` ran 5 review rounds (a 6th, over-budget round confirmed the final fix) before
approval. Each found a real, often live-reproduced bug in the TMPDIR arm-marker mechanics:

1. **Injection safety** (round 1, corrected round 2): a value read back into an injected context
   block must be treated as fully untrusted. Round 1 sanitized only the title, reasoning a path is
   "a validated filesystem path, not free text" — round 2 live-disproved that (only NUL and `/`
   are actually forbidden in a path component; a path can legitimately contain a literal newline
   and injection-shaped text simultaneously). Fixed with one shared sanitizer
   (`fragments_sanitize`) applied identically to both fields at every injection site: any control
   character or literal `<`/`>` redacts the **entire** field, never a partial escape.
2. **Post-compact suppression** (round 1): the snapshot-diff rule as first written would silently
   suppress the post-compact reminder whenever the underlying file hadn't changed since the last
   surface — exactly backwards, since the point of reinjecting after a compact is that *context*
   was lost, not that the file changed. Fixed: `--reinject` mode bypasses the diff filter entirely.
3. **A fixed-name marker collides with itself** (round 3, live-reproduced): `mv src dst` when
   `dst` already exists **as a directory** doesn't fail, it nests `src` *inside* `dst` — the same
   bug class `docs/adr/0002-...` already documented once for `handoff-surface.sh`'s own `mv -n`
   calls, missed here on a first pass despite that precedent. A session-scoped, fixed-name claim
   target let an in-flight claim and a fresh re-arm collide and corrupt both. Fixed: every arm
   marker is `mktemp -d "$BASE/${SESSION_ID}.XXXXXX"` — structurally unique per invocation, so no
   two invocations can ever share a name to collide over.
4. **Stale-generation reselection** (round 4, reasoned through live by Codex): unique naming closed
   the collision, but the *selection* rule built on top of it — "the newest live marker by mtime"
   via glob — let a **claimed** generation drop out of the glob (renamed to `.claimed`), making an
   **older, still-unclaimed** generation "newest" again among what remained; a later write could
   then capture a second, unwanted document against a generation the user had already moved past.
   Separately, a generation became glob-visible before its candidate sidecar finished writing.
   Fixed: a **current-generation pointer** (`$SESSION_ID.current`, a plain file, published only
   after the marker and its candidate are both fully written) — Hook 2 reads only what the pointer
   names, with no fallback scan of any kind.
5. **The pointer sweep races the pointer publish** (round 5, live-reproduced): the pointer's name
   is fixed and reused per session (unlike the other three entry forms), so sweeping it by its own
   age has a real TOCTOU — a fresh arm can republish the same-named pointer between the sweep's
   staleness check and its `rm`. Fixed: a short `mkdir`-based lock (`$SESSION_ID.lock`, the same
   atomic primitive the claim step already relies on) shared between the pointer publish and the
   pointer sweep; the sweep re-reads the pointer's age *inside* the lock immediately before
   deleting. If the lock can't be acquired after a bounded retry, arming proceeds anyway (must
   never hang) and the sweep skips that one pointer for this pass (skip is always the safe
   default) — a narrow, self-healing residual, not engineered around further.
6. **The lock itself needs sweeping too** (caught before implementation, not by Codex): a process
   killed while holding the lock leaves it orphaned forever, permanently defeating both future
   `mkdir` attempts and the pointer sweep that depends on it. Fixed: the sweep clears every stale
   `.lock` directory (age-only, unconditional — nothing legitimately holds a lock for anywhere
   near the arm window) in a first pass, strictly before it ever tries to acquire one in a second
   pass.
7. **The sweep's own glob missed dotfiles** (deep-audit finding, live-reproduced post-ship): the
   TMPDIR arm-state sweep used a bare `*` glob, which bash never matches against dot-prefixed
   names — an orphaned `.ptr.XXXXXX` (fragments-arm.sh's own pointer-publish scratch file, left
   behind if a process is killed between its creation and rename) was invisible to the sweep
   forever, contradicting the hook's own "sweeps stale TMPDIR arm state" description. Fixed:
   `dotglob` added, scoped to just the sweep block. **Left as an accepted, out-of-scope residual**
   (same finding, lower severity): the durable `documents/` tree's own atomic-rewrite scratch
   files (`.rec.XXXXXX` in `fragments-surface.sh`, `.doc.XXXXXX` in `fragments-capture.sh`) have
   no sweep mechanism of any kind — an orphan there is inert clutter (nothing ever globs it back
   in), not a correctness hazard, and building a second sweep for a durable, low-volume,
   per-project tree is disproportionate machinery for what it would prevent.
8. **The window-expiry sweep's stat-failure direction disagreed with itself** (caught while
   extracting the shared `scripts/_lib/hook-common.sh` lib): `fragments-capture.sh`'s shipped
   v1.1.66 age-check used `|| echo 0` — `mtime=0` (the Unix epoch) against a real `$NOW`
   computes an *ancient* age, sweeping a live, in-window marker on a transient `stat` failure —
   while `fragments-surface.sh`'s `entry_age()` used `|| echo "$NOW"`, computing an age of `0`,
   i.e. "just created," so it never swept an orphan at all on the same failure. The two agreed
   on nothing: one treated a stat glitch as "definitely gone," the other as "definitely still
   there," and shared no code, so nobody could have noticed the two hooks disagreeing without
   reading both side by side. `hook_entry_age <path> <now>` fixes the shared direction by
   refusing to guess at all: it prints nothing and returns 1 on a stat failure, and both callers
   treat that as "skip this pass, don't sweep, don't capture" — never destructive, never a
   guessed age in either direction. Honesty-verified: a stat-shim regression test in
   `tests/hooks/test-fragments-capture.sh` is red against the pre-fix `|| echo 0` fallback (it
   sweeps the live marker) and green after.
9. **`PAYLOAD=$(cat)` silently dropped a raw NUL byte before `hook_payload.py`'s own docstring
   claim ("validated against the untruncated value, before it ever crosses into bash") actually
   held** (compliance-audit finding, live-reproduced against the real hooks, 2026-09-10): bash
   command substitution doesn't just corrupt an embedded NUL, it deletes it and splices the
   surrounding bytes together — `foo\0bar` on stdin became the bash variable `foobar`, a
   different, charset-valid session_id, before `validate_session_id` ever ran. In
   `fragments-capture.sh` this let a write whose real payload named an invalid session_id get
   silently captured under an unrelated, genuinely-armed session sharing that spliced name
   instead of being rejected outright. `handoff-nudge.sh` was never affected (it pipes stdin
   straight into `hook_payload.py`, no bash variable in between). Fixed in both `fragments-arm.sh`
   and `fragments-capture.sh` by capturing stdin to a temp file instead of a bash variable, and
   feeding that file directly to the parser — every byte, NUL included, survives intact.
   Honesty-verified: end-to-end regression tests in `tests/hooks/test-fragments-arm.sh` and
   `test-fragments-capture.sh` are red against the pre-fix `PAYLOAD=$(cat)` capture and green
   after.

A process killed between claim and publish is an accepted, bounded, self-healing loss — not
engineered around with crash-recovery machinery — matching `handoff-nudge.sh`'s own posture: the
atomic claim prevents a *duplicate* capture, it does not make a lost one recoverable. A fresh
re-invocation creates an entirely independent, differently-suffixed generation with no
relationship to the abandoned one.

## Consequences

- **Cost accepted**: same as mh's former handoff wrapper (removed in v1.1.94) — `disable-model-invocation: true` means mh can only
  relay a suggestion in prose, never invoke the skill itself.
- **No content ever inlined.** Every surface line is a path, title, count, size, and age — never
  the fragments themselves. The two injection call sites (the known-path nudge, the surface block)
  share one sanitizer so they can't drift apart on this.
- **Heuristic-tier false positives are a named, accepted gap**, not a bug: absent a typed
  candidate, an `Edit` to any `.md` file — including an unrelated one — passes the plausibility
  check. There is no signal available in that case to tell an unrelated Markdown edit apart from a
  real fragments append.
- **A Bash-mediated append is invisible to this design entirely** — upstream never mandates a
  write tool, the same class of accepted blind spot `config-write-guard.sh` already documents for
  itself.
- **No mute/forget escape hatch** (operator confirmed): the snapshot-diff rule already goes silent
  once a file stops changing; deleting a record's JSON file by hand is the only removal path.
- **Env-var overrides dropped from the original plan.** The plan proposed
  `MH_FRAGMENTS_STATE_DIR`/`MH_FRAGMENTS_ARM_WINDOW` test knobs; the shipped tests achieve full
  isolation via `HOME`/`TMPDIR` injection alone (the same pattern `tests/hooks/test-handoff-
  nudge.sh` already uses), so neither variable is actually read by any script — added per
  `docs/reference/env-vars.md`'s own rule against documenting a knob nothing reads.
