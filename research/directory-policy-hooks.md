# Directory Policy vs mh's hooks, SessionStart injection and cost logging

Ticket: wasikarn/method-harness#1004. Researched 2026-11-11.

## Sources (all primary, fetched with curl)

- [P] Anthropic Software Directory Policy: https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy (page says "Updated over 2 weeks ago"). Cited as P-1.A ... P-5.
- [C] Plugin pre-submission checklist: https://claude.com/docs/plugins/pre-submission-checklist.md, sections "Prepare for the security scan", "Choices a reviewer always checks", "Review what the plugin runs and connects to", "Hooks, skills, commands, and agents".
- [D] Publish to the directory: https://claude.com/docs/directory/publish.md.

Facts about mh are from this checkout: `hooks/hooks.json`, `hooks/session/doctrine-bootstrap.sh`, `hooks/stop/cost-tracker.sh`, `README.md`.

## Headline

The policy text never mentions hooks, SessionStart injection or cost telemetry. It has no rule that forbids any of the three. What applies is general: data collection (P-1.D/E/G), hidden instructions (P-2.G), a privacy policy (P-3.A), documentation (P-3.C) and change notification (P-3.H). The checklist says that disclosure does not make a behavior allowed: "A complete README doesn't make a behavior allowed."

Findings:

1. Deny/ask gates: allowed. Policy silent; they restrict Claude, they do not circumvent guardrails.
2. SessionStart injection of `docs/METHODOLOGY.md`: allowed with disclosure. One ambiguous clause (P-1.G) needs a documented reading.
3. Stop cost logging: allowed with disclosure. It stays on the machine and records token counts, not conversation text. P-1.E is the clause to answer in the README.
4. A mechanical risk matters more than any of the three: the scan "holds for a reviewer" hooks whose scripts call other files or use other shell variables (see "Reviewer-hold risk" below).

## Behaviour 1: deny/ask gates (PreToolUse hooks)

mh registers about a dozen PreToolUse hooks (`hooks/gates/*`). They return `permissionDecision` deny or ask. None sends data off the machine (grep of `hooks/` for curl, wget, nc, ssh, URLs, sockets found only string matches inside the gate rulesets, no network calls). None writes settings files; `config-write-guard` only asks before Claude creates or edits one.

Quoted rules that apply:

- P-1.C: "Software must not evade or enable users to circumvent Claude's safety guardrails, system instructions, or sandbox environments." The gates add friction in front of destructive commands. They do not evade a guardrail.
- C, security scan: "The security scan looks for behavior that a plugin doesn't disclose, such as sending data elsewhere, running hidden code, or changing Claude's permission settings." A gate that denies is not "changing Claude's permission settings", but a scan could pattern-match on `permissionDecision` or on `config-write-guard` reading `settings.json`. Unverified: the scan's real matching rules are not published.
- C, hooks table: "use only the hook events and hook types in the hooks reference". mh uses `command` hooks only, no HTTP hooks.

Reading: **allowed** (policy silent on hooks as such).

README must disclose: that the plugin installs PreToolUse hooks that can deny or ask on Bash, Write/Edit, Skill, Agent, TaskUpdate and RemoteTrigger calls; what each class blocks (the README already has "The gates" section); that they read the tool-call input locally and send nothing anywhere; that they never modify `settings.json` or permission rules. Add a one-line "no network access" statement.

## Behaviour 2: SessionStart injection of `docs/METHODOLOGY.md`

`hooks/session/doctrine-bootstrap.sh` cats the bundled file (3448 bytes in this checkout) to stdout inside `<doctrine>` tags, so Claude Code adds it to the session context. It reads a file shipped in the plugin, from `${CLAUDE_PLUGIN_ROOT}`. It emits plain readable text. It also emits short portability notices (`python3` or `jq` missing).

Quoted rules that apply:

- P-2.G: "Instructional Software must not contain hidden, obfuscated, or encoded instructions. All behavioral guidance must be human-readable and clearly presented." The file is human-readable Markdown, in the repo. "Clearly presented" is the open point: the user never sees the injection unless the README says so.
- P-2.F: "must not direct Claude to dynamically pull behavioral instructions from external sources for Claude to execute." Not triggered: the file is bundled, not fetched.
- P-1.G: "must not persistently store or use conversation content to build user profiles or attempt to make any changes to Claude's behavior across sessions." The injection does change Claude's behavior in every session, which is its purpose. The clause reads as tied to conversation content ("conversation content to build user profiles or attempt to make..."). Static shipped guidance is not derived from conversation content. Reading: not triggered, but the grammar is ambiguous. Unverified: no Anthropic text says whether plugin-shipped context injection counts.
- P-2 preamble: section 2 "applies to Software that provides Claude with tools or capabilities through natural language descriptions, including MCP servers, Skill folders, and similar Software". Whether a hook-injected file is "similar Software" is not stated. Unverified. The conservative course is to treat P-2.A-G as applying.
- P-2.B: descriptions "must precisely match actual functionality" and "must not include unexpected functionality". The README and plugin description must say the plugin injects doctrine at session start, or the behavior is "unexpected functionality".
- P-1.C: the file must not tell Claude to bypass its guardrails. Check this before submission (not audited here; unverified).
- C, "Choices a reviewer always checks": a hook that runs a non-shell file, or a shell script that itself runs another file, is held. `doctrine-bootstrap.sh` is a plain shell script that calls only `cat`; the hold does not apply to it.

Reading: **allowed with disclosure**.

README must disclose: that every session start injects the full text of `docs/METHODOLOGY.md` (size, about 3.4 KB, about 1k tokens; file path; that it is bundled and never fetched); that it persistently changes Claude's behavior while the plugin is enabled (instruct the user how to disable: disable the plugin); that the text is plain Markdown the user can read before installing. Add the file link.

## Behaviour 3: Stop hook cost logging

`hooks/stop/cost-tracker.sh` runs on each Stop. It reads the session transcript (`transcript_path` from the hook payload), sums token usage per model and agent type, prices it, and appends rows to `~/.local/share/kbg/metrics/costs.jsonl`. Row fields seen in the script: timestamp, session_id, transcript_path, model, agent type, token counts, cost, mh plugin version, HEAD commit of the cwd. It copies no prompt or response text. It makes no network call. It refuses to append through a symlink. It passes the hook payload through unchanged. Related local writers: `skill-usage-telemetry.sh` (`skill-usage.jsonl`, invocation counts) and `memory-audit-commit.sh` (git commit in the user's auto-memory store, opt-in).

Quoted rules that apply:

- P-1.E: "Software must only collect data from the user's context that is necessary to perform their function. Software must not collect extraneous conversation data, even for logging purposes." The hook parses the transcript but keeps usage numbers and ids. Cost accounting is the stated function. Reading: not extraneous conversation data, provided the rows stay content-free. The clause says "even for logging purposes", so a reviewer will look at exactly this.
- P-1.D: "Software must prioritize protecting user privacy and the privacy interests of third parties." Local-only storage with a symlink guard supports this.
- P-1.G: "must not persistently store ... conversation content to build user profiles". The ledger is persistent. It holds usage metadata, not content; `session_id` and `transcript_path` identify a session but build no profile. Reading: not triggered. `skill-usage.jsonl` records which skills a user calls over time; this is the nearest thing to a usage profile. It is local and carries no content, but disclose it.
- P-3.A: "Developers of Software that collects user data or connects to a remote service must provide a clear, accessible privacy policy link explaining data collection, usage, and retention." The data never leaves the machine, so whether this "collects user data" is arguable. A short privacy section linked from the listing removes the question. Unverified whether a policy link is required for local-only logging.
- P-3.H: "Developers must notify Anthropic of material changes to their Software's ... data practices". Any later change to what the ledger records, or any move to remote reporting, must be notified.
- C, security scan: "sending data elsewhere" and "Sends data to an undisclosed destination" are scan categories. mh sends nothing, so this does not fire. It would fire if a future version uploaded costs.
- C, credential rule: "Don't read a credential that is already set in the user's environment ... and send it to a server". Not applicable (no credentials read, no network).

Reading: **allowed with disclosure**.

README must disclose: the exact path `~/.local/share/kbg/metrics/costs.jsonl` and the other two files under the same directory; the list of fields written; that no prompt, response or file content is written; that nothing is transmitted; that the log is append-only and never rotated, with how to delete it; that the hook reads the full session transcript locally to compute totals; that `memory-audit-commit.sh` commits inside the user's memory directory (and that it needs a pre-existing git repo). Add a privacy-policy section linked from the listing. State that remote reporting is not present and will be notified under P-3.H if ever added.

## Reviewer-hold risk (mechanical checks, from [C])

These are not policy violations. They send a version to an Anthropic reviewer before it can go live.

- "Keep launchers, package installs, shell variables other than `${CLAUDE_PLUGIN_ROOT}`, command substitutions, and calls to other files in the plugin out of each script that a hook or an MCP server runs. Held for a reviewer. Finding: Scripts the validator couldn't follow."
  - `cost-tracker.sh` uses `$HOME`, command substitutions (`$(date ...)`, `$(printf ... | jq ...)`) and `git -C`. Expect a hold.
  - Gate wrappers `hooks/gates/*.sh` hand off to `*.py` files. [C] "A program the validator can't read through ... runs a non-shell file from the plugin ... that file is held." Expect a hold for every Python gate.
- "In the command of a hook ... write each path in full from `${CLAUDE_PLUGIN_ROOT}`, with no other variable, command substitution, wildcard, or inline program such as `python3 -c`" blocks. The hook commands in `hooks/hooks.json` all read `bash "${CLAUDE_PLUGIN_ROOT}/hooks/..."`, which meets this. Not checked inside each script for `python3 -c` (that rule applies to the hook command, not to script bodies; unverified for script bodies).
- "Keep every file that isn't an image or font under 256 KiB" and "512 files or fewer": held. `hooks/gates/irrecoverable.py` and `subagent-git-guard.py` look large (the grep reached line 5650); verify sizes before submitting (not measured here).
- "Hold isn't a rejection": "A hold isn't a rejection. The scan can raise the same hold again on each new version." mh ships a release on every merge, so each version would be re-held.

## Items marked unverified

- Whether P-2 (Instructional Software) covers hooks and injected files. The policy defines it by "tools or capabilities through natural language descriptions".
- Whether P-1.G's "changes to Claude's behavior across sessions" can reach static plugin-shipped doctrine.
- Whether a privacy-policy link is required for local-only logging.
- The scan's actual matching rules for "changing Claude's permission settings" and "undisclosed" behavior. [C] gives categories and example titles only.
- Whether the plugin's Python gate files exceed the 256 KiB limit.
- Whether METHODOLOGY.md contains any text that could read as circumventing guardrails (not audited).
- No primary source says how a reviewer weighs a hold for hooks of this size; the page says only that a reviewer reads the held version.

## Recommendation for the README (input to #1008)

Add a "What runs, what is written, what is sent" section: (1) hooks list by event with one line each; (2) the SessionStart injection with file link; (3) local files written and their fields; (4) "Nothing leaves your machine. No network calls."; (5) how to disable or delete. Keep the plugin description matching this (P-2.B).
