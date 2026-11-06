# Claude web plugin-install workaround (anthropics/claude-code#88214) adoption audit (2026-11-06)

**Date:** 2026-11-06
**Source:** GitHub issue anthropics/claude-code#88214 ("Cloud sessions never install plugins declared in .claude/settings.json, and /plugin is unavailable to fix it") plus its one comment, read 2026-11-06 through `gh api` and saved verbatim as `idea-audit-source-issue88214.md` (7520 B, session scratchpad; no WebFetch banner). Issue state at read: open, created 2026-08-20, last updated 2026-10-10, one comment by an author with association NONE, no maintainer reply. No local clone and no pinned revision: it is a live issue thread.
**Verdict:** Do not adopt the issue's workaround (`CLAUDE_CODE_SYNC_PLUGIN_INSTALL=1` in server-managed settings, or `claude plugin install` inside a session) as mh's route to Claude web. The issue's premise is dead: the issue quotes a docs row promising auto-install, and the current docs say a cloud session does not install repo-declared or user-level plugins. The workaround is one commenter's single-session report; the documented scope of the env var is non-interactive `-p` runs, the managed-settings route needs a Team or Enterprise plan the operator may not have, and nothing in the source shows plugin hooks (the gates) running in cloud. Keep the agreed vendored bundle. Use the source for one thing only: add `claude plugin install mh@...` (and, if a Team or Enterprise plan exists, the managed `env` variant) to the planned cloud setup-script probe, and make that probe check that the gates are active, not merely that the session starts.
**Score:** 45.5/100 — **FAIL** (threshold 60; confidence medium). Full criteria table: see Decision score below.

Every claim below about the source's internals is what it describes as of this read, not a verified fact about the source as it exists today or in the future.

## Method

Three agents. Two isolated `general-purpose` analysts (A: claims, B: fit with this repo; neither saw the other's output), then one attacker from a different model family (Codex, read-only, resolved slug `gpt-6.1-sol`, effort medium; verdict accepted through `check-verdict.py` exit 0 and `check-citations.py` exit 0). The working tree stayed clean after the attacker ran (`git status --porcelain` empty). Prior coverage check: grep of `docs/research`, `docs/reference`, `scripts`, `evals` and the memory store for `88214`, `18088`, `63028`, `SYNC_PLUGIN_INSTALL` found nothing; one qmd query without a collection filter found no earlier audit of this source. This pass increments on the project decision recorded in the memory note `cloud-bundle-web-decisions-2026-11-06.md` (vendored bundle accepted, plugin route rejected, with the condition that a successful setup-script plugin install would shrink the bundle work); it does not relitigate it. The analysts and the attacker reached the docs differently (A through its own fetch of the current pages; the attacker through its web tool), and the attacker could not run `gh api` (connection error), so issue-state claims rest on web pages.

## Claim-by-claim: the premise is dead and the one workaround is thin

Legend: `MATCH` = claim confirmed against primary evidence · `PARTIAL` = partially confirmed · `GAP` = claim not found / contradicted by primary evidence · `N-A` = not applicable to this repo.

| # | Claim | Verified? | This repo's posture | Verdict |
|---|---|---|---|---|
| 1 | The docs promise repo-declared plugins are installed at session start | Author-asserted (`idea-audit-source-issue88214.md:15-18`) | Current cloud-environments page says No for repo-declared and for user-level plugins (attacker re-read the page, retrieved line 351) | GAP |
| 2 | `/plugin` is unavailable in cloud sessions | Yes — observed directly (A and attacker, claude-code-on-the-web page) | A terminal-interface limit; it does not say the `claude plugin` CLI subcommand is unavailable | MATCH |
| 3 | Repo-declared plugins never install in cloud | Author-asserted; current docs now agree | Matches the repo's existing posture (`.claude/hooks/session-start.sh:10` is dev-only; the bundle plan assumes no plugins) | MATCH |
| 4 | Marketplace syncs but the install record is empty and the cache holds only README/LICENSE | Author-asserted (`idea-audit-source-issue88214.md:33-68`) | One session on 2026-08-20; not reproducible now | PARTIAL |
| 5 | No startup warning for missing plugins | Author-asserted; commenter reports the same (`idea-audit-source-issue88214.md:131`) | Matters for mh: gates could be silently absent, so the probe needs a canary | PARTIAL |
| 6 | Plugin state is rebuilt on every boot, so installs would not persist | insufficient evidence (inferred from mtimes, `idea-audit-source-issue88214.md:85-89`) | Cannot be used to decide caching behaviour | N-A |
| 7 | Only one of two declared marketplaces registers | Author-asserted, one instance; the comment's session cloned all three (`idea-audit-source-issue88214.md:129`) | Not a general limit | PARTIAL |
| 8 | Managed-settings plugins also fail to install in cloud | Author-asserted (comment, CLI 2.1.296) | Not reproduced; shows a different declaration route with the same symptom | PARTIAL |
| 9 | The marketplace reconcile finishes about 2 s after plugins load, so install is a background race | Author-asserted from quoted log events | Root cause not proven (no raw trace, no control) | PARTIAL |
| 10 | `CLAUDE_CODE_SYNC_PLUGIN_INSTALL=1` in managed `env` fixes it | Author-asserted, one fresh session (`idea-audit-source-issue88214.md:137`) | The env-vars page documents it for non-interactive `-p` runs, not cloud or managed settings; with a timeout variable it continues without plugins on timeout | PARTIAL |
| 11 | Managed settings apply in cloud sessions | Yes — observed directly (cloud-environments row; server-managed settings page) | Requires a Teams or Enterprise plan; the operator's plan is unknown; a change applies org-wide, with no per-group setting | MATCH |
| 12 | Related issues #83422 and #76759 | Yes — observed directly via the web pages (A through `gh api`; attacker through the web) | #83422 open and reproduced, hooks and autoUpdate still reported broken; #76759 closed not_planned by the stale bot | MATCH |

Attacker findings (verdict `pass: false`) folded in: (a) the in-session `claude plugin install` result is real but the parent session sees the plugins only after a resume, so it is not evidence that a setup-script install survives the cached-environment restore or that hooks run; (b) the managed-settings variant has a wider blast radius than B described (org-wide, no per-group scope); (c) the startup risk is not only slowness: without the timeout variable it waits, and on timeout it continues with no plugins and logs an error, so the probe must check gate activation; (d) A's statement that managed settings are the only documented channel for settings in cloud was too broad: repo hooks and permissions are documented as carried over in single-repo sessions.

## Shipped

Nothing — this is a read-only research pass. The only artifact is this file and a memory note; no code, setting or version changed.

## Deliberately not shipped

- **Adopt `CLAUDE_CODE_SYNC_PLUGIN_INSTALL=1` via managed settings as the route to Claude web** — `idea-audit-source-issue88214.md:137` (one fresh-session report) and the env-vars page's `-p` scope, **and** METHODOLOGY Rule 3 (a borrowed claim is checked against this repo's own invocation path before it lands in a committed file) plus Rule 1 (org-wide managed-settings change is a wide blast radius). Labeled: **declined on evidence**.
- **Drop the vendored bundle plan in favour of the plugin route** — `cloud-bundle-web-decisions-2026-11-06.md:18-21` (probe first, bundle stays until the probe shows plugin hooks firing) **and** Rule 1 (do not remove the working path on one unverified report). Labeled: **deferred** until the cloud probe shows plugin hooks firing and the gates active.
- **Treat the issue as a bug to track or comment on** — `idea-audit-source-issue88214.md:15-18` (its documented-contract premise is contradicted by the current docs) **and** YAGNI (no action on this repo's side). Labeled: **premise dead**.

## Decision score (METHODOLOGY Rule 14)

Criteria and anchors (score out of 10):

- **primary-source-fidelity, weight 45** — largest weight by the skill's rule. 3 = the core premise is contradicted by current primary docs; 8 = every load-bearing claim is corroborated by the docs and by two independent reports.
- **fit, weight 30** — the repo has a live need (running mh on Claude web) but the route must fit its plan and constraints. 3 = the route needs something the operator cannot have; 8 = the route works on the operator's plan and public marketplace with no gate lost.
- **blast-radius-reversibility, weight 25** — cost if adopted and wrong. 3 = org-wide or irreversible change that can silently disable gates; 8 = a local, reversible change with a visible failure.

| Criterion | Weight | Score | Reason |
|---|---|---|---|
| primary-source-fidelity | 45 | 4/10 | Docs row and `/plugin` limit are verified, but the issue's central premise is stale and the workaround is one commenter's single test outside the env var's documented scope. |
| fit | 30 | 5/10 | The need is real and mh's own memory note makes a setup-script install a decision input, but the route needs a Team or Enterprise plan the operator may not have and says nothing about plugin hooks running in cloud. |
| blast-radius-reversibility | 25 | 5/10 | The managed setting reverts with a console toggle and weakens no gate, but it is org-wide with no per-group scope and a timeout leaves a session running with no gates and only a log line. |

Weighted sum: (4×45 + 5×30 + 5×25) / 10 = 455 / 10 = **45.5/100** (computed by `scripts/_lib/weighted-score.py`: `belowFloor` empty, `primaryWeightOk` true). Pass threshold 60, fatal-weakness floor 40% of each criterion's own max (4/10 does not fall below it); the source side did not trip the all-`insufficient evidence` rule. **FAIL.** Confidence: medium (three agents with a cross-family attacker whose verdict was `pass: false` with four findings, all folded in; the attacker could not run `gh api`, nothing was tested in a real cloud session, and the operator's plan is unknown).

## Open questions

- Does `claude plugin marketplace add` plus `claude plugin install mh@...` succeed in a cloud setup script, and do the plugin's hooks fire in the session? Revisit only when the planned cloud probe (setup script plus first-message checks) has been run, not from further reading of this issue.
- Is the operator on a Team or Enterprise plan? Revisit only if the managed-settings variant is wanted; it is out of reach without one.
- Is `CLAUDE_CODE_SYNC_PLUGIN_INSTALL` documented for cloud or managed settings? Revisit only if the env-vars page or the cloud-environments page changes.

<!-- Reserved: a later pass appends a dated correction here, never rewrites the sections above.
**Correction (date, mechanism):** ... -->
