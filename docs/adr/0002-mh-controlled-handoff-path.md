---
status: deprecated
---

# mh writes its own handoff, at a path it controls

*Deprecated 2026-09-18: `mh:handoff` and its two `SessionStart` hooks were removed in v1.1.94 —
a composer-not-creator violation given upstream's existence. mh now defers to
`mattpocock-skills:handoff` directly and ships nothing of its own here. This ADR stays for the
rejected-design record below.*

`mattpocock-skills:handoff` compacts a session into a Markdown document, but its own
instructions name no write tool and no output path or filename — only "save to the temporary
directory of the user's OS." The user has to find and retype that path in the next session,
which is the exact friction this decision removes.

mh ships its own gated skill, `mh:handoff` (`skills/workflow/handoff/`), that writes to
`$HOME/.claude/state/mh-handoffs/<slug>-<hash>/`, scoped to the git repo root. A 4th
`SessionStart` hook, `session:handoff-surface`, inlines any unread document automatically —
no path for the user to ever see or type, unless they want the manual fallback the skill
echoes once at write time.

## Rejected: detecting the upstream skill's writes

The original design was a `PostToolUse` hook that would recognise a handoff file as
`mattpocock-skills:handoff` wrote it — by content signature, temp-dir path, or both — snapshot
it, and replay it at the next `SessionStart`. Two rounds of adversarial review (Codex) refined
that design considerably (a content snapshot instead of a pointer, per-project scoping, at-least-
once dedup semantics, budget allocation order) before reading the upstream skill's own source
killed the premise entirely:

- The skill's `SKILL.md` is 17 lines with **no template file**. Its one mandated element is
  prose — `Include a "suggested skills" section` — with no heading level or capitalisation
  specified; the skill's own author documents renders it two different ways.
- It **never names a write tool**. It names "the Skill tool" explicitly one line later, so the
  omission is meaningful — a `Write`-only matcher could silently miss a `Bash` heredoc.
- It prescribes **no path and no filename** at all, and on macOS `$TMPDIR` and `/tmp` are
  entirely separate trees requiring four prefixes to canonicalise.

Detection could therefore only ever be a heuristic with silent-miss modes — no template to match
exactly, no tool guaranteed, no path convention to anchor on. Writing mh's own handoff at a path
mh controls removes the need to detect anything at all, and with it every piece of the snapshot,
digest, TOCTOU-guard, and dedup machinery the detection design had accumulated.

## Consequences

- **Cost accepted**: the user types `/mh:handoff`, not `/handoff` — upstream's
  `disable-model-invocation: true` means no skill can invoke it programmatically, so mh cannot
  delegate to it and must author its own handoff-content guidance instead. Plain `/handoff`
  still works exactly as it does today; it simply isn't auto-surfaced.
- **No new hook-event type.** The surfacer is mh's 4th `SessionStart` hook, an event mh already
  uses — unlike the rejected design, which would have been mh's first-ever `PostToolUse` hook.
- **Publish is atomic, in two steps.** The skill `Write`s into a `staging/` dir (a name `mktemp`
  reserves atomically, with the `X`'s literally trailing — BSD/macOS `mktemp` only randomises a
  *trailing* run of them, confirmed live after a first attempt with trailing characters after
  the `X`'s produced an unrandomised, colliding name), invisible to the hook's `handoff-*.md`
  glob on two independent counts (a leading dot, and no `.md` extension until published). The
  helper then does one `mv -n` into `pending/` — same filesystem, so the hook only ever sees a
  complete file, never a partial write. `mv -n` reports success even when it silently refuses to
  overwrite an existing destination, so every publish and consume step verifies the postcondition
  (source actually gone) rather than trusting the exit code alone. That postcondition alone proves
  the source is gone, not that the destination is the plain file expected: if something else
  creates a directory at the destination between the precheck and the `mv`, plain `mv -n` moves
  the source *into* it instead of failing, and the earlier revision reported that directory as a
  successfully published path (a compliance audit reproduced this deterministically with a shimmed
  `mv`). Publish now also checks the destination is a plain regular file, not a symlink, right
  after the move, and fails loud if not — the same check also catches the staged path having been
  swapped for a symlink between its own check and the `mv` (a symlink source produces a symlink
  destination). `umask 077` is set before any `mkdir`/`mktemp` call in both scripts, so newly
  created directories and files are owner-only by construction rather than depending on an
  explicit `chmod` running successfully afterward; every `chmod` call in the publish helper is
  also now checked and fails loud on error, instead of being silently discarded. The surfacer's
  own `pending/` → `consumed/` move carries the identical plain-regular-file check after its own
  `mv -n` — a deep-audit pass found the first revision of that fix had only landed on the publish
  side, leaving the consume side open to the same directory-collision race (and to a `chmod` on
  whatever actually landed there instead of the intended file).
- **Consumed is a directory, not a state file.** `mv -n` from `pending/` to `consumed/` is the
  entire mechanism — no lock file, no digest index, no JSON state. Consumed files are kept, not
  reaped, doubling as handoff history.
- **Scoped per project, keyed on git repo root** (falling back to physical cwd outside a repo),
  hashed (`scripts/_lib/slug-hash.sh`) —
  a bare directory-name slug can collide (`.../a-b` and `.../a/b` under a naive `/`→`-` replace).
- **Multiple pending documents: budget allocation and display order are separate axes.**
  Aggregate budget — bytes *and* lines, both 3× the per-file cap — is allocated **oldest-first**
  (`ls -trd`, since `mktemp`'s random suffix isn't chronologically sortable by filename, and the
  `-d` keeps a directory that happens to match the glob as one listed entry rather than expanding
  its contents), so an old pending handoff can never be starved out by a steady stream of newer
  ones; the documents actually selected are then **displayed newest-first**, the more useful
  reading order. A document cut by the per-file cap (~300 lines/~15KB) is truncated *and shown* —
  truncation still counts as delivery, so it's consumed, with the notice pointing at the full
  archived copy. A document either aggregate axis never got to at all stays pending, since
  consumed strictly requires having been shown. (An earlier revision only tracked an aggregate
  *byte* budget; a compliance audit against this ADR found no aggregate line budget existed at
  all, so several documents at exactly the per-file line cap but well under the byte cap would all
  be shown and consumed with no line-based ceiling — fixed by tracking both dimensions together,
  breaking the allocation loop if either would be exceeded.) A third, independent cap bounds the
  **count** of documents selected per invocation (10) regardless of bytes/lines — a stream of many
  tiny documents could otherwise all fit the byte/line aggregates while still costing real overhead
  (one header line printed per document).
- **Delivery is best-effort, recoverable from archive — stated precisely, not oversold.** Nothing
  moves to `consumed/` until it has printed successfully: a genuine read failure, an empty file,
  or a real output-write failure all leave the document pending for retry. The read path is
  bounded to `MAX_BYTES+1` regardless of actual file size (a single pathological long line can't
  balloon memory), byte-exact under any locale (`LC_ALL=C`, not a character-count bash substring,
  which mis-truncated multibyte content at 3× the intended length in an earlier revision), and
  preserves trailing bytes through capture with a sentinel (plain `$()` silently strips trailing
  newlines, which broke the exact-length truncation check in another earlier revision — a
  50-line/15-byte-cap fixture with a trailing newline at the boundary reproduced it live). Every
  `printf` in the print loop, and the `basename` calls that feed it, are checked and redirected
  away from stderr explicitly — a closed-stdout scenario otherwise leaks a shell-builtin error
  message to stderr even though the script's own logic correctly detects the failure and aborts
  the print. The one gap none of this closes: if the hook process is killed by Claude Code's own timeout *during* the
  brief, budget-capped move phase after printing has already completed, some files could be
  archived without the caller having received that output. No later signal exists in the hook
  architecture to build an acknowledgment on, and that would be disproportionate machinery for an
  advisory nudge — mitigated by keeping the whole invocation small enough to normally finish in a
  fraction of the 10-second hook timeout, not solved by pretending the mechanism guarantees more
  than it does. **A second, separate residual gap, named rather than engineered around: two
  sessions starting at nearly the same moment in the same project can both read and print the
  same pending document** — no lock guards the read-print-archive sequence. Both delivery attempts
  are legitimate (each is a genuinely fresh session that hasn't seen the content yet), so this is
  duplicate delivery, not corruption; a flock-style mutex would close it but adds a hang/deadlock
  risk to a hook whose one hard contract is to never block session start, which is a worse trade
  for an advisory nudge than an occasional repeat.
- **Never a symlink.** Both the publish step and the surfacer explicitly reject anything that
  isn't a plain regular file (`-f` alone follows symlinks; `! -L` is required too) — a symlink
  planted in `pending/` pointing at an arbitrary real file must never get its content silently
  inlined into session context. The enumeration itself must also never expand a directory that
  happens to match the glob: `ls -trd`, not `ls -tr`, on `pending/handoff-*.md` — a matching
  directory's children were otherwise listed as bare basenames and resolved relative to the hook's
  own cwd rather than `pending/`, letting the hook read and archive an unrelated file that
  happened to share a name there (a compliance audit reproduced this live against a throwaway git
  repo used as cwd).
- **Content is read once into memory, then archived separately — a snapshot guard closes the gap
  between them.** The surfacer reads and prints from an in-memory buffer captured at allocation
  time, then moves the *on-disk* file to `consumed/` afterward; if nothing else legitimately
  touches `pending/` after publish this never matters, but nothing in the design actually
  guarantees that. A compliance audit flagged the gap: if the file changed between the read and
  the move, the archived copy could differ from what was actually printed. Each candidate now
  captures a size+mtime snapshot at read time and re-checks it immediately before the move; a
  mismatch leaves the file pending (it gets re-read fresh next session) instead of archiving a
  document that might not match what the caller saw. A deep-audit pass then found the guard's own
  failure mode: when `stat` itself is unavailable, both the read-time and move-time snapshots fell
  back to the same empty string, which compared equal regardless of whether the content had
  actually changed — the guard failed open in exactly the scenario it exists for. Each fallback is
  now a distinct literal instead of a shared empty one, so a `stat` failure at either point always
  mismatches and fails closed.
- **A fifth `SessionStart` hook nudges the *write* side, since the first four only ever read
  what already exists.** `session:handoff-nudge` fires once per session, only on `matcher:
  "compact"`, and suggests to the model (via injected `additionalContext`, not directly to the
  user — `mh:handoff` is `disable-model-invocation: true`, so the model can only relay the
  suggestion in its own reply) that this would be a good moment to run `/mh:handoff`. `session_id`
  is the key for "once per session"; it is delivered on every hook event's stdin including
  `SessionStart` per the official docs (`code.claude.com/docs/en/hooks`'s common-input-fields
  list), confirmed independently by the paired `codex@openai-codex` plugin's own `SessionStart`
  handler reading the same field. This is the one `SessionStart` hook in this repo that reads
  stdin — every other one avoids it only because none of them need anything it carries. The claim
  is one atomic `mkdir` on a `${TMPDIR:-/tmp}/mh-handoff-nudge/<session_id>` marker (no trailing
  slash on the base — a trailing-slash path silently defeats a `[ -L ]` symlink check, reproduced
  live during plan review), and the nudge prints only if that `mkdir` succeeds: this prevents a
  *duplicate* claim, nothing more. It does not make a lost print recoverable (if the print itself
  fails after a successful claim, that session's one nudge is gone), and if `$TMPDIR` is cleared
  or rotates mid-session the marker can vanish and the session may nudge again — both accepted,
  best-effort, not a guarantee, same posture as the read side above. `session_id` is validated as
  a real, non-empty JSON string before use (a `null`/boolean/number value stringifies into
  something that would otherwise pass a bare character-class regex) and rejected outright if it is
  `.`, `..`, or contains anything outside `[A-Za-z0-9._-]`. A compliance audit against this plan
  (Codex-primary, independently reproduced) found the character-class check had moved to the wrong
  side of a mangling boundary: it originally ran in bash, *after* `$(...)` command substitution had
  already stripped a trailing newline or silently dropped an embedded NUL byte (the latter also
  leaking a bash warning to stderr) from whatever `session_id` python3 had printed — so a value
  containing either could still produce a claimed, truncated marker instead of being rejected. Fixed
  by moving the character-class and reserved-value check into python3 itself, against the untruncated
  string, so nothing outside the safe set ever crosses into bash for command substitution to mangle
  in the first place. The same audit found the ownership/symlink recheck (`stat`, then `id -u`) and
  the claim `mkdir` were two separate syscalls with a window between them — something could swap the
  base directory for a symlink in that gap — and that an `id -u` failure leaked to stderr unredirected.
  Fixed with a post-claim recheck: after the `mkdir` succeeds, the symlink and ownership checks run
  once more, and a mismatch rolls the claim back (`rmdir`) and exits silently rather than trusting the
  precondition alone — the same "verify the postcondition" posture already used for `mv -n` above.
