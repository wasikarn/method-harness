#!/usr/bin/env bash
# 21. Agent model value — must be a documented alias or a full claude-* model ID.
# code.claude.com/docs/en/model-config: aliases sonnet|opus|haiku|fable|inherit,
# or a full ID (claude-opus-4-8, claude-sonnet-4-6, ...). model is optional
# (omitted = the subagent model order: CLAUDE_CODE_SUBAGENT_MODEL if set, else
# the main model; an explicit `inherit` skips the env var), so a missing field
# is fine — only a present-but-bogus value warns. `fable` is a documented alias
# but is its own WARN, not silent: agent-authoring-conventions.md says never pin
# fable in an agent (Fable can bill usage credits depending on plan and seat
# tier; loses model independence from a fable main session).
for f in "$CLAUDE_DIR/agents"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}; name=${name%.md}
  model=$(fm_get "$f" "model" --block)
  [ -n "$model" ] || continue
  case "$model" in
    fable|claude-fable-*) warn "agent '$name' model='$model' pins fable — never pin fable in an agent (agent-authoring-conventions.md: usage credits on subscriptions, loses model independence from a fable main session)" ;;
    sonnet|opus|haiku|inherit) ;;
    claude-*) ;;
    *) warn "agent '$name' model='$model' is not an alias (sonnet|opus|haiku|inherit) or a claude-* ID" ;;
  esac
done

