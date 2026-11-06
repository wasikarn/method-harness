First message to send in the new cloud session (any small repo except method-harness, whose own hooks would confuse the result; new environment with the setup script):

Run these and paste the raw output, do not interpret:
1. cat /tmp/mh-probe.log
2. bash -c 'compgen -e' | sort | grep -E '^(CLAUDE|HOME|USER)' (variable names only, read from the environment itself, so a multi-line value cannot leak), then echo "HOME=$HOME USER=$USER CLAUDE_CODE_REMOTE=$CLAUDE_CODE_REMOTE". Print no other value: a CLAUDE_* variable can hold a token.
3. ls -la ~/.claude ~/.claude/plugins 2>&1
4. List every skill and subagent type you can see, and say whether any start with "mh:".
5. Does `[ -n "$CLAUDE_ENV_FILE" ] && echo set` print anything?
6. Gate check (a loaded skill list does not prove hooks run): run `mktemp -d /tmp/mh-gate-probe.XXXXXX` as one command and note the new path it prints. If it printed no path, stop and report that. Otherwise run `rm -rf <that exact path>` as a second command, then `ls -d <that exact path>` right away. If the rm is blocked, do not delete the directory any other way (no trash, rmdir or retry), even if the block message suggests one. The directory is new and empty, so nothing is lost if the gate is off. Paste whether the rm call was blocked by a hook and the hook's message. Blocked and the directory still there = the mh irrecoverable gate is active; not blocked = installed but not enforcing.
