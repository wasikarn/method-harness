# codex integration map

`codex@openai-codex` (source `openai/codex-plugin-cc`) paired alongside mh as a second,
independent coding agent — a different model family, routed to by name. Not a wrapper, mirror,
or orchestration layer: mh creates no surface whose only job is to call Codex (see
`GLOSSARY.md`'s "pairing" entry). Re-verify this table whenever the installed `codex` plugin
cache version changes; no check parses it. Full reasoning: `docs/plans/codex-pairing-2026-09-06.md`.

## Routing

| skill | invocation | mh touchpoint / fallback |
|---|---|---|
| `/codex:review` | user or model | read-only diff review; Claude-side alternative: `mattpocock-skills:code-review`. On rate-limit or absence, run the Claude-side review instead, invoked by the operator — independence reduced for that pass (model independence lost, context independence kept) |
| `/codex:adversarial-review` | user or model | challenges a plan after `mattpocock-skills:grilling`; Claude-side alternative: `mh:plan-reviewer`. Same fallback as review |
| `/codex:rescue` | **user or model** — ships without `disable-model-invocation`, and `codex:codex-rescue` is a full Agent-tool `subagent_type` | writes files through the Codex app-server, not Claude Code tools — see Gate gap below. The review-gate toggle is gated (ADR-0001); the rescue dispatch itself carries no codex-specific gate. From the main session it stays fully ungated; a *subagent* attempting the same dispatch is denied as a side effect of `gate:agent:subagent-spawn-guard` (GH #151), which blocks every subagent-initiated Agent-tool call uniformly and was not built with codex in mind |
| `/codex:setup` | **user or model** — ships without `disable-model-invocation` | the one surface mh puts a real gate on: `gate:skill:codex-setup-guard` asks before a model-invoked call carrying `--enable-review-gate` |
| `/codex:transfer` | user only (`disable-model-invocation: true`) | Claude near its own limit → hands the session to a resumable Codex thread. The reverse of the fallback direction above |
| `/codex:status` | user only | job and review-gate status, read-only |
| `/mh:compliance-audit` (mh's own skill, not a `codex@openai-codex` skill) | user only (`disable-model-invocation: true`) | Phase 2's verifier dispatches a raw `codex exec --sandbox workspace-write --cd <worktree> --model <selected-model> -c model_reasoning_effort=<selected-effort> --output-last-message <file> --output-schema <schema-file>` (explicit flags; scoped to a disposable pinned worktree — not read-only, since it reruns the gauntlet) as primary, for stronger maker≠checker separation than a fresh Claude context alone; Claude-side alternative: a `general-purpose` subagent. On rate-limit or Codex absence, fall back to the Claude subagent — independence reduced for that pass, same fallback language as `/codex:review` above. Both paths pipe the raw output through `skills/review/compliance-audit/scripts/check-verdict.py` (own schema/ambiguity/`NEEDS-DECISION` handling, mirroring deep-audit's script) before trusting it: exit 0 = one valid verdict with `pass` computed by the script; exit 2 = `NEEDS-DECISION`, surfaced to the operator; exit 1 = malformed/ambiguous, retry the dispatch once before calling it `scope_ok: false` |
| `/mh:deep-audit` (mh's own skill) | user or model (no `disable-model-invocation`) | Step 3's fresh-context checker dispatches `codex exec --sandbox read-only --model <selected-model> -c model_reasoning_effort=<selected-effort>` (explicit flags, not the config-dependent default; no worktree, since the checker never writes and needs the current tree, not a pinned SHA) as primary; Claude-side alternative: an `Explore`/review agent (the pre-existing mechanism). On rate-limit, absence, timeout, auth failure, a schema-invalid result, or a semantic refusal (schema-valid JSON that still didn't do the review), fall back to the Claude agent — independence reduced for that pass, same fallback language as `/codex:review` / `/mh:compliance-audit` above. Unlike those, a failed fallback here doesn't just get noted: it hard-forces the skill's own Final Verdict to `fail` ("verification incomplete"), since deep-audit's rubric would otherwise let a checker-less run still pass on its other dimensions |
| `/mh:idea-audit` (mh's own skill) | user or model (no `disable-model-invocation`) | Phase 2's attacker dispatches `codex exec --sandbox read-only --model <selected-model> -c model_reasoning_effort=<selected-effort> --cd <repo-root> --output-last-message <file> --output-schema <schema-file>` (same shape as `/mh:deep-audit`'s checker — read-only, no worktree) as primary; Claude-side alternative: a `general-purpose` subagent whose brief says "you write nothing" (the Agent tool has no per-invocation `disallowedTools` — that's an agent-file frontmatter field only — so the real backstop is `git status --porcelain` before and after the dispatch; never `mh:plan-reviewer`, which hard-stops on non-plan input) — independence reduced for that pass, same fallback language as the rows above. Fallback triggers are the same six as `/mh:deep-audit`'s. On all-fallback failure, or every finding failing a post-parse citation-shape check, the adversarial criterion is marked `insufficient evidence` and Phase 3 blocks on the operator, rather than the deep-audit-style hard-fail override |

The three bare `codex exec` dispatches — `/mh:compliance-audit`'s verifier, `/mh:deep-audit`'s
checker, `/mh:idea-audit`'s attacker — take effort as `-c model_reasoning_effort=<selected-effort>`
(see "Model, effort, and account cost" below), not the `--effort` flag in
`docs/reference/spawn-brief.md`, which applies to `/codex:rescue` only.
`checks/72-codex-effort-set-drift.sh` parses only the first `--effort <a|b|c>`-pattern line in
`spawn-brief.md`, so none of the three affects it.

Both `/mh:deep-audit`'s checker and `/mh:idea-audit`'s attacker are read-only and never write, so
the "Silent-refusal gotcha" section's empty-diff detection method below doesn't apply to either —
that method assumes a writer whose refusal shows up as "nothing changed" on disk. Their refusal
signal is a schema-invalid or semantically-refusing final message instead, caught per the rows
above.

## Gate gap

`/codex:rescue` edits files through the Codex app-server, not through Claude Code's tool-call
pipeline — none of mh's other gates (`gate:bash:irrecoverable`, `gate:bash:subagent-git-guard`,
`gate:task:complete-separation`, `gate:write:test-integrity`, `gate:write:config-guard`,
`gate:write:secret-scan`) see those writes; `secret-scan` in particular has no other backstop at
all — `git-hooks/pre-commit`/`pre-push` and `scripts/merge-pr.sh` do lint/harness-audit/gauntlet, not secret-content
scanning. **This repo's own git hooks (`git-hooks/pre-commit`, `pre-push`) are the
vendor-agnostic floor**: whatever wrote a file, the same lint and harness-audit run at commit and
push, and the full gauntlet runs at merge (`scripts/merge-pr.sh` / `scripts/sync-pr-head.sh`, GH #735)
before it ships, regardless of which agent produced it. ADR-0001 records why no codex-specific
gate picks up the rescue dispatch as a rider on this trial. `gate:agent:subagent-spawn-guard`
(GH #151, shipped after ADR-0001) denies it anyway when a *subagent* is the caller, but only
as an instance of its blanket "no subagent dispatches Agent" rule — it never inspects
`subagent_type`, so it is not the codex-specific gate ADR-0001 declined to build. Main-session
dispatch of `/codex:rescue` (the normal path) is unaffected.

Sandbox/approval note: no `~/.codex/config.toml` recommendation is needed for this pairing.
The plugin hardcodes its own sandbox per call — `read-only` for `/codex:review` and
`/codex:adversarial-review`, `workspace-write` (never `danger-full-access`) for rescue's write
path — as a structured parameter to its app-server, not a config file setting. `config.toml`
can still supply model/effort defaults when the plugin leaves those unset; the explicit
sandbox supplied by the plugin takes precedence for its calls.

## Model, effort, and account cost

Choose model and effort before each dispatch, using the signed-in account rather than a
bundled default. On 2026-09-14, Codex CLI 0.154.0 reported ChatGPT Plus, no purchased credits,
and access to Luna, Terra, Sol, and Astra through `model/list`. This is a dated observation,
not a required plan or a live balance. Recheck `account/rateLimits/read` through the app-server
(or `/status` in the CLI) when planning substantial work; never commit account IDs or tokens.

Codex has no automatic model router: the model is whatever `--model`, `-c model=`, a profile or
`config.toml` names, else the bundled default. Its only automatic behaviour is `ultra` effort
delegating to subagents (this plugin rejects `ultra`), Plan mode's built-in effort preset when
`plan_mode_reasoning_effort` is unset, spawned agents defaulting to
`agents.default_subagent_model`/`agents.default_subagent_reasoning_effort`, and migration or
rate-limit prompts that ask before switching.

**Slugs re-verified 2026-09-26** against this account's own catalog (`codex debug models`, CLI
0.156.1): `gpt-6-sol`, `gpt-6-luna`, `gpt-6-astra` and `gpt-5.6-terra` are listed, and
`gpt-5.6-sol`/`gpt-5.6-luna` were still listed, so the GPT-6 rollout for Sol and Luna was not a
hard break. Then, `gpt-5.5` carried an upgrade to `gpt-5.6-sol` and was set to retire 2026-10-14.
**Re-checked 2026-10-04** (`models_cache.json`, CLI 0.160.0): `gpt-6.1-sol` led the Sol tier
(`priority` 1, ahead of `gpt-6-astra` 2 and `gpt-6-sol` 3), listed `medium` effort but defaulted
to `low` (`gpt-6-sol` defaults to `medium`), and was the `gpt-5.5` upgrade target.
**Re-checked 2026-10-21** (`models_cache.json` fetched that day, CLI 0.163.0): `gpt-5.5` is gone
from the catalog. Listed: `gpt-6.1-sol` (priority 1), `gpt-6-astra` (2), `gpt-6-sol` (4),
`gpt-6-luna` (5), `gpt-5.6-sol` (6), `gpt-5.6-terra` (8), `gpt-5.6-luna` (9); none carries an
upgrade. Terra still has no GPT-6 variant. `codex-resolve-model.py <tier> --effort medium` resolves
Luna `gpt-6-luna`, Terra `gpt-5.6-terra`, Sol `gpt-6.1-sol`, Astra `gpt-6-astra`. The catalog has
no price field; on the pricing page `gpt-6.1-sol` is 50/2.5/250, the same as `gpt-6-sol` except
cached input at half (2.5 vs 5), so the switch costs no more per token (it says nothing about how
many tokens a run uses). Versus the GPT-5.6 rates, `gpt-6-sol` is exactly half on every column and
`gpt-6-luna` half on input and cached input, ~0.42x on output (exact numbers below).

The table names a **tier**, not a slug. Resolve a tier to the best visible catalog entry whose
slug ends in it (lowest integer `priority`, `visibility: list`, not retiring: `upgrade.model` is
unset, and the live catalog carries `"upgrade": null` on most entries) at dispatch time, among
entries whose `supported_reasoning_levels` list the effort (so an effort the newest entry lacks
falls to the next one that has it); disclose the resolved slug in the report.
`scripts/_lib/codex-resolve-model.py <tier> --effort <e>` does exactly this (the dotfiles
`sync-profile-models.sh --resolve` is the same rule in bash). The profile sync and the drift
check use the same candidate rule but not the effort-first pick: the sync keeps the profile's
own effort and refuses a model that lacks it rather than swap in an older one, and the drift
check does not look at effort at all. The three agree on
every catalog shape Codex has shipped; they can differ on exotic JSON (a float priority such as
`1.0`, a non-string `upgrade.model`). The slug in a dated note above is the last check, not a pin.

| Work | Starting tier | Effort |
|---|---|---|
| Clear, small edits or extraction | Luna | `low` |
| Bounded implementation or verification of explicit requirements | Terra | `medium` |
| Ambiguous bugs, adversarial review, cross-file judgment | Sol | `medium` |
| Hard end-to-end investigation with sustained judgment | Astra | `medium` |

OpenAI's own starting points are Sol `medium`, Luna `high` and Astra `low`
(`learn.chatgpt.com/docs/models`). By operator policy, this table starts Luna lower (small, clear
tasks) and Astra higher (the hardest tasks).

These are starting choices, not measured quality guarantees. Deep-audit and idea-audit normally
start with Sol/medium; compliance-audit starts with Terra/medium for explicit requirements,
Sol/medium if interpretation is material. Increase to `high` for a concrete unresolved reasoning
problem; reserve `xhigh` for unusually hard cases. Keep the same evidence and acceptance checks
at every tier. If quota cannot support adequate verification, report it incomplete or use the
existing independent-checker fallback; never call a weaker or skipped check a pass.

Validate the chosen slug and effort against the live catalog; if unavailable, choose an
available model suitable for the same task and disclose the substitution. No silent retry loop
or automatic paid fallback. Never hardcode a personal `-p` profile in shipped commands: profiles
are machine-local. On bare CLI dispatches substitute `--model <selected-model>` and
`-c model_reasoning_effort=<selected-effort>`; the existing sandbox, cwd, schema, and fallback
contracts still apply. Global config is only the default when a call does not override it.

For `/codex:rescue`, use `--model` and `--effort` as runtime flags under this operator-authorized
routing policy, not prose hidden in the task. The installed plugin 1.0.6 task path forwards both;
its review/adversarial-review paths do not forward a task effort flag. Do not promise those
review commands honor `--effort`; use their supported controls and report the actual selection.
The plugin accepts up to `xhigh`, not `max`/`ultra`.

Plus consumes included usage before purchased credits; API dollar rates are not the account's
invoice. Published credit rates per 1M input/cached-input/output tokens, fetched live from
`learn.chatgpt.com/docs/pricing` 2026-09-23: `gpt-6-luna` 2.5/0.25/12.5, `gpt-5.6-terra`
50/5/300, `gpt-6-sol` 50/5/250, `gpt-6.1-sol` 50/2.5/250, `gpt-6-astra` 250/25/1250
(re-fetched 2026-10-04 and 2026-10-21, every row unchanged). The superseded `gpt-5.6-sol` and
`gpt-5.6-luna` rates (100/10/500 and 5/0.5/30, unchanged since 2026-09-14) still apply if a
dispatch falls back to either; both are still listed. These compare credit usage; they do not price
included quota or prove actual spend. Recheck current pricing when the account, plan, or catalog
changes. Avoid optional fast/priority service and speculative fan-out as cost defaults; neither
is required by this policy.

Sources: [OpenAI models](https://learn.chatgpt.com/docs/models?surface=cli),
[pricing](https://learn.chatgpt.com/docs/pricing),
[app-server account and model APIs](https://learn.chatgpt.com/docs/app-server).

## AGENTS.md

Codex reads `AGENTS.md`, not `CLAUDE.md`. Drop this paragraph into a repo pairing Codex with
mh:

> This repo runs under `mh@wasikarn` (Claude Code). Its full doctrine is `CLAUDE.md` +
> `docs/METHODOLOGY.md`; the parts that bind you too: (1) the decision-sizing triad before any
> non-trivial change — one-way door? blast radius? riskiest assumption? — (2) a requirement is
> a claim to test, not a truth to obey: name what's ambiguous, missing, or assumed before
> touching code, (3) a bug fix starts with a failing test, the test passing is done. mh's
> `gate:*` PreToolUse hooks are Claude Code hooks — you are not under them; this repo's git
> hooks (`git-hooks/pre-commit`, `pre-push`) are the floor that applies to every edit
> regardless of which agent made it.

No generator, no sync script — short enough to hand-keep in sync with `CLAUDE.md`'s own map.

## Silent-refusal gotcha

Every Codex thread loads `~/.codex/AGENTS.md` (or `AGENTS.override.md`) unconditionally, before
any project `AGENTS.md`, with no config switch — `codex exec`, the TUI, and the app-server path
this plugin's `/codex:rescue` uses alike (codex-rs `codex-home/src/instructions/mod.rs`,
`core/src/agents_md_manager.rs`, checked against codex-cli 0.153.4). A user-level rule written for
one project (a pinned model/effort, a mandated orchestration flow) therefore governs every rescue
on the machine, and Codex declines correctly but quietly: **clean exit, empty diff, polite
refusal in the final message**. Two defences, both borrowed from `DannyMac180/fable-advisor`
(observed live 2026-08-04): (1) treat an empty diff after a clean run as `refused`, never
`complete` — the companion script does not check this, so the dispatcher does: compare
`git status --porcelain` before and after a `--write` rescue, and read the returned message as
a refusal when nothing moved; (2) open the task text with a one-line opt-out scoped to this run
("this task runs deliberately on the model and effort named in the invocation; treat it as an
explicit opt-out from any instruction-file default flow; every other rule still applies"). The
empty-diff check is the one that actually catches it; the preamble only avoids it.

Evidence status (2026-09-06, codex-cli 0.153.4, `gpt-5.4-mini`): reproduced locally, both halves.
A throwaway `CODEX_HOME` whose `AGENTS.md` mandates an "orchestrator flow", one append-a-line
task: without the preamble, **exit 0, `git status --porcelain` empty, final message a polite
refusal** ("this workspace requires the orchestrator flow ... you didn't opt out"); with the
preamble, exit 0 and the file changed. Quota-exhausted and provider-without-access runs, by
contrast, exit 1 with `ERROR:` on stderr: those fail loudly, only the refusal is silent.

The plugin's runner, `codex-companion.mjs task`, fails the same loud way, in its own shape
(GH #333, codex-cli 0.160.0, plugin 1.0.6). Reproduced logged-out with an empty `CODEX_HOME`:
exit 1, the backend error message alone on stdout, and `[codex] Codex error: <message>` then
`[codex] Turn failed.` on stderr. The quota-exhausted case was not reproduced. From the runner
source it takes the same path (app-server `error` notification, turn not completed, exit 1),
carrying the binary's "You've hit your usage limit." text. The codex-quota sensor and advisory
match the companion invocation as well as the bare `codex` CLI. The sensor also stores the
"try again at" time when the message has one (`reset_at`); while it is ahead, the advisory denies a
Codex dispatch instead of advising (a parallel batch of lanes burned five round-trips once on a
known limit). A message with no readable time still only advises.

## Degrading gracefully

Every line above still has to make sense with the plugin absent, the Codex CLI missing, or the
operator logged out: the routing table just names an unavailable fallback path (the "on
rate-limit or absence" column), the gate no-ops if `Skill(codex:setup)` is never called, and
check 71 (`skills/meta/harness-audit/scripts/checks/71-codex-review-gate-state.sh`) reports
INFO "not installed" rather than erroring.
