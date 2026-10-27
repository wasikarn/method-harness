#!/usr/bin/env python3
# gate:agent:subagent-verdict-check (SubagentStop) and
# gate:agent:subagent-verdict-check-handback (PreToolUse on SubagentHandback)
# -- Tier 1 of the "auto-apply the attacker pattern via hooks?" design note
# (docs/research/nine-agent-gate-architecture-security-audit-2026-09-20.md,
# "Design note" section). One check, two delivery paths: the SubagentStop
# hook reads `last_assistant_message`; the PreToolUse hook matched on
# `SubagentHandback` reads `tool_input.message`, because on CC >= 2.1.271 in
# auto mode the report goes through that tool and `last_assistant_message`
# then holds only the closing text (code.claude.com/docs/en/hooks.md,
# SubagentStop section; GH #160). Both catch a vacuous or self-contradictory
# Rule 13 verdict object -- {"pass":true,"findings":[],
# "scope_ok":true,"unexpected_files":[]} is schema-valid but shows no
# verification work, the exact gap `checked[]` closes in prose (spawn-brief.md,
# METHODOLOGY.md) and in the 3 sibling skills' own check-verdict.py scripts.
# This makes the same rule apply automatically to every OTHER Rule 13 dispatch,
# which today has no check-verdict.py-equivalent at all (confirmed 2026-09-20:
# zero file-based consumers parse the generic contract programmatically).
#
# Stateless by design (no cross-call bookkeeping): on SubagentStop the loop
# bound is the `stop_hook_active` field Claude Code already puts on the
# payload for exactly this loop-prevention purpose, read below, not a counter
# kept here -- adding one would be the exact session-scoped-round-counter
# shape #135/#137 already rejected.
# Ruling: PreToolUse has no `stop_hook_active`. A PreToolUse deny is a
# re-prompt with no counter: the subagent gets the reason, fixes its verdict,
# and calls SubagentHandback again; an identical second handback is denied
# again. Claude Code's own per-subagent turn budget bounds that loop; this
# gate keeps no state to bound it itself, same posture as every other
# PreToolUse gate in hooks/gates/.
#
# Fail-open posture matches this repo's other subagent-scoped gates
# (subagent-git-guard, subagent-spawn-guard, task-complete-separation): the
# "verdict" here only optimizes a check that would not otherwise run at all,
# it never authorizes an irrecoverable action, so any internal failure must
# fall through to the native no-hook-installed behavior (let the subagent
# stop), never block. Per operating-model.md's stated principle: "fail open
# to the native/no-op path when the verdict only optimizes one that was
# already going to happen anyway."
import json
import sys
from typing import NoReturn

# GH #156: raise the int-string digit limit before parsing so an oversized
# unquoted int literal doesn't crash json.load() (full rationale:
# codex-setup-guard.py). hasattr-guarded: absent before Python 3.11.
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

try:
    from _journal import journal
except Exception:
    def journal(*a, **k):
        pass

GATE_ID = "gate:agent:subagent-verdict-check"
GATE_ID_HANDBACK = "gate:agent:subagent-verdict-check-handback"


def _allow(note=None) -> NoReturn:
    if note:
        print(f"[mh:gate] subagent-verdict-check: {note}", file=sys.stderr)
    sys.exit(0)


_SCAN_BUDGET = 2_000_000
_MAX_SPAN_DEPTH = 32


def _find_json_dicts(text):
    # String-aware brace matching: for each '{', walk forward tracking quote
    # state so a '{'/'}' inside a JSON string value never miscounts depth,
    # then try json.loads on the exact balanced span. Nested spans (e.g. one
    # findings[] item's own {summary, evidence} object) are found too but
    # filtered out downstream by the "has a bool `pass` key" check -- they
    # parse fine on their own, they just aren't the verdict object.
    #
    # 2026-09-21 deep-audit: the old per-"{" rescan was O(n x braces) -- 30,000
    # leading "{" before a vacuous verdict took ~15s, past the 8s SubagentStop
    # timeout, so the block was silently dropped. Now one pass per start
    # keeps a stack of open positions and pops a candidate span on each "}",
    # marking every "{" it pushed as visited; a later pass only starts at a
    # "{" that every earlier pass saw inside a string (fresh, not-in-string
    # state there, exactly what the old per-"{" rescan did). Same spans found,
    # ordinary input is one pass. `work` is charged once per char walked,
    # shared across passes and never reset (same pattern as irrecoverable.py's
    # _SPAWN_SCAN_BUDGET); on exhaustion raise so the caller takes this
    # gate's documented fail-open path fast. Validator catch, same day: a
    # first cut also charged each popped span's full length, so 1500 NESTED
    # braces cost N(N+1) and hit the budget -- a cheaper bypass than the one
    # being closed. json.loads is the only remaining super-linear cost, so a
    # span whose own nesting is deeper than _MAX_SPAN_DEPTH is never handed
    # to it (a real verdict is ~3 deep; json.loads would RecursionError near
    # 1000 anyway). `depths` mirrors `stack`: the deepest level seen inside
    # each still-open span.
    out = []
    n = len(text)
    visited = bytearray(n)
    work = 0
    for start in range(n):
        if text[start] != "{" or visited[start]:
            continue
        stack = []
        depths = []
        in_str = False
        esc = False
        j = start
        while j < n:
            work += 1
            if work > _SCAN_BUDGET:
                raise RuntimeError("verdict-scan budget exceeded")
            c = text[j]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            elif stack:
                if c == '"':
                    in_str = True
                elif c == "{":
                    stack.append(j)
                    depths.append(len(stack))
                    visited[j] = 1
                elif c == "}":
                    i = stack.pop()
                    deepest = depths.pop()
                    if depths:
                        depths[-1] = max(depths[-1], deepest)
                    if deepest - len(stack) <= _MAX_SPAN_DEPTH:
                        try:
                            obj = json.loads(text[i:j + 1])
                            if isinstance(obj, dict):
                                out.append(obj)
                        except Exception:
                            pass
            elif c == "{":
                stack.append(j)
                depths.append(1)
                visited[j] = 1
            j += 1
    return out



def _verdict_reasons(msg):
    # Shared by both events: the list of reasons a verdict in `msg` is vacuous
    # or self-contradictory, [] when there is nothing to block on.
    if not isinstance(msg, str) or not msg.strip():
        return []

    if len(msg) > 200_000:
        # ponytail: a message this long is not an ordinary verdict reply
        # anyway. Skip the check rather than risk the 8s timeout (fail-open on
        # timeout is safe here, but cheaper to just skip).
        return []

    # A subagent that correctly declined to guess is never a vacuous pass --
    # this is a valid, non-guessing response and must never be blocked
    # (spawn-brief.md's own escalation return; same precedent every
    # check-verdict.py script in this repo already follows).
    if "NEEDS-DECISION" in msg:
        return []

    try:
        candidates = _find_json_dicts(msg)
        verdicts = [c for c in candidates if isinstance(c.get("pass"), bool)]
        # 2026-09-21 deep-audit: the same verdict printed twice (a draft echoed
        # verbatim as the final) is one verdict, not two "distinct" ones -- dedupe
        # by canonical JSON before the ambiguity check below.
        seen, uniq = set(), []
        for v in verdicts:
            k = json.dumps(v, sort_keys=True)
            if k not in seen:
                seen.add(k)
                uniq.append(v)
        verdicts = uniq
    except Exception as e:
        _allow(f"verdict-scan crashed, allowing ({e})")

    if len(verdicts) == 0:
        # Not a Rule 13 verdict-shaped response at all (most subagents: Explore,
        # research, a builder reporting its edits) -- nothing to check.
        return []

    if len(verdicts) > 1:
        # Two or more distinct pass-bearing objects (a decoy example quoted
        # ahead of the real verdict) -- ambiguous. Never block on uncertainty;
        # this mirrors check-verdict.py's own "reject as ambiguous" rule, but a
        # hook's only two moves are allow/block, and blocking on genuine
        # ambiguity risks false-positive friction on ordinary prose that happens
        # to quote a JSON example. Allow, noted for visibility.
        _allow(f"{len(verdicts)} distinct pass-bearing objects found, ambiguous -- allowing without a check")

    v = verdicts[0]
    reasons = []

    if v.get("pass") is True:
        checked = v.get("checked")
        findings = v.get("findings")
        checked_empty = not isinstance(checked, list) or len(checked) == 0
        findings_empty = not isinstance(findings, list) or len(findings) == 0
        if checked_empty and findings_empty:
            reasons.append(
                "pass:true but no findings[] and no checked[] evidence -- cite at least one "
                "checkable fact (a file:line you read, a command you ran) in checked[] even on "
                "a clean pass; an empty checked[] is not verified, same as a missing field "
                "(docs/reference/spawn-brief.md, docs/METHODOLOGY.md Rule 13)"
            )
        if v.get("scope_ok") is False:
            reasons.append(
                "pass:true but scope_ok:false -- these are self-contradictory; scope_ok:false "
                "means an unexpected file or an owned file the diff never touched, which cannot "
                "coexist with an overall pass"
            )
        unexpected = v.get("unexpected_files")
        if isinstance(unexpected, list) and len(unexpected) > 0:
            reasons.append(
                f"pass:true but unexpected_files has {len(unexpected)} entr"
                + ("y" if len(unexpected) == 1 else "ies")
                + " -- reconcile or explain the scope mismatch before reporting pass"
            )
    return reasons


def _reason_text(reasons):
    return (
        "Your returned verdict is self-contradictory or vacuous: "
        + "; ".join(reasons)
        + ". Re-check your own work and return a corrected verdict object with real evidence, "
          "not a redo of the same claim."
    )


try:
    d = json.load(sys.stdin)
except Exception as e:
    _allow(f"unparseable stdin, allowing ({e})")

if not isinstance(d, dict):
    _allow("non-object payload, allowing")

event = d.get("hook_event_name")

if event == "SubagentStop":
    if d.get("stop_hook_active") is True:
        # Already re-prompted once this stop; never block a second time in a row.
        sys.exit(0)
    reasons = _verdict_reasons(d.get("last_assistant_message"))
    if not reasons:
        sys.exit(0)
    journal(GATE_ID, d.get("agent_type"), "deny", d.get("session_id"))
    print(json.dumps({"decision": "block", "reason": _reason_text(reasons)}))
    sys.exit(0)

if event == "PreToolUse":
    if d.get("tool_name") != "SubagentHandback":
        sys.exit(0)
    tool_input = d.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.exit(0)
    # code.claude.com/docs/en/hooks.md, SubagentStop section (CC >= 2.1.271):
    # "The report is that call's `message` input, which a PreToolUse or
    # PostToolUse hook matched on SubagentHandback receives as
    # tool_input.message."
    reasons = _verdict_reasons(tool_input.get("message"))
    if not reasons:
        sys.exit(0)
    journal(GATE_ID_HANDBACK, d.get("tool_name"), "deny", d.get("session_id"))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": _reason_text(reasons)}}))
    sys.exit(0)

# Any other event, or none at all: nothing to check.
sys.exit(0)
