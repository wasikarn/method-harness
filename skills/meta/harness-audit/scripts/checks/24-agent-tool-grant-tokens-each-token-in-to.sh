#!/usr/bin/env bash
# 24. Agent tool-grant tokens — each token in tools: must be a real Claude Code
# tool. code.claude.com/docs/en/tools-reference. Strips a (specifier) suffix
# before checking, so 'Bash(git:*)' validates as 'Bash'. Catches typos that
# silently drop a grant (e.g. 'Bsh' grants nothing). Process substitution (not a
# pipe) keeps warn() in the current shell so WARN_COUNT folds into the exit code.
# Also strips JSON-array brackets and quotes (`["Read", "Write"]` is valid YAML
# and is the upstream ECC convention; the audit must accept it, not flag every
# bracket as a typo).
VALID_TOOLS="Agent Artifact Bash CronCreate CronDelete CronList Edit EnterWorktree ExitWorktree Glob Grep LSP ListAgents ListMcpResourcesTool Monitor NotebookEdit PowerShell PushNotification Read ReadMcpResourceTool RemoteTrigger ReportFindings SendMessage SendUserFile ShareOnboardingGuide Skill TaskCreate TaskGet TaskList TaskStop TaskUpdate ToolSearch WebFetch WebSearch Workflow Write"
while IFS= read -r badtok; do
  warn "$badtok"
done < <(
  for f in "$CLAUDE_DIR/agents"/*.md; do
    [ -f "$f" ] || continue
    name=${f##*/}; name=${name%.md}
    tv=$(fm_get "$f" "tools" --block)
    [ -n "$tv" ] || continue
    for tok in $(echo "$tv" | tr ',' ' '); do
      base="$(strip_tool_token "$tok")"
      # MCP tools (mcp__<server>__<tool>) are first-class per Claude Code
      # tools-reference — any `mcp__X__Y` token is valid by namespace, not by
      # whitelist. Accept them so agents like docs-lookup (mcp__context7__*) pass.
      if [[ "$base" == mcp__*__* ]]; then continue; fi
      case " $VALID_TOOLS " in
        *" $base "*) ;;
        *) echo "agent '$name' tools: token '$tok' is not a known Claude Code tool" ;;
      esac
    done
  done
)

