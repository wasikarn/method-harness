# method-harness

The Claude Code harness (`mh@wasikarn`) and its doctrine: what gates deny computationally,
what stays advice, and how it composes third-party plugins instead of duplicating them.

## Language

**Fragments pointer**:
The durable JSON record `sensor:write:fragments-capture` writes at `$HOME/.claude/state/
mh-fragments/` when a write plausibly targets a document from upstream's `writing-fragments` skill —
a path, a capture timestamp, and a surfaced-snapshot, never the document's own content.
`docs/adr/0003-writing-fragments-pointer-capture.md`.
_Avoid_: "fragments cache" or "fragments backup," which imply mh stores a copy of the content; it
never does.

**Armed** (fragments state):
The state a session enters when `sensor:prompt:fragments-arm` matches a prompt invoking
`writing-fragments`: a uniquely-suffixed TMPDIR marker plus an optional candidate-path sidecar,
made visible to `sensor:write:fragments-capture` only once a current-generation pointer is
published as the last step of arming.
_Avoid_: "armed" for the durable state tree — it only ever describes this ephemeral, per-invocation
TMPDIR marker, never a fragments pointer record.

**Surfaced snapshot**:
The size+mtime pair a fragments pointer record stores for what `session:fragments-surface` most
recently showed the user. A record surfaces again only once the target's current snapshot differs
from this stored value — the mechanism is self-quiescing, with no timer, counter, or mute command.
_Avoid_: "last seen," which implies a timestamp; it's a content-change signal, not a clock.
