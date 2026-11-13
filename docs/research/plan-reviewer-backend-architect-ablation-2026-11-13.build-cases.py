"""Cases for measuring mh:plan-reviewer and mh:backend-architect against a plain prompt.
argv: <repo> <out plugin copy> <tar dir> <scratchpad holding the proposal files>."""
import os, re, shutil, subprocess, sys, tempfile
repo, out, tars, pad = (os.path.abspath(a) for a in sys.argv[1:5])
for d in (out, tars):
    assert d.startswith(os.path.realpath(tempfile.gettempdir()) + os.sep) or "/scratchpad/" in d, d
X = " Judge only whether this one problem is identified; the wording may differ, and other findings never lower the score."
TREE = "d0604dbf6e119ead4170b1abf07c6b191ccb4925"  # develop before any of the proposals was committed
PLANS = {
 "plan-v1-human-out": ("attack-proposal-human-out-of-loop.md", None, {
  "self-verdict": "The review says the agent that wrote a change can post the `Fresh-context review: MERGE` verdict comment itself (the merge script does not check who wrote it) and so merge its own work.",
  "self-status": "The review says the agent can post the `mh/gauntlet` commit status itself (any token with write access can set a status), so the status proves nothing.",
  "judge-replaced": "The review says a pull request can change the gauntlet, the tests or the merge script that judge it, because the merge-time gauntlet runs the branch's own copy.",
  "pass-cache": "The review says the gauntlet pass cache (a file named by tree hash) or a similar local record can be forged by the agent, so a cached pass is not evidence.",
  "hooks-off": "The review says the agent can switch off or get around mh's own gates from inside its run (disableAllHooks or editing settings, overwriting the plugin cache, launching claude without the plugin), so the gates are not a control against it.",
  "script-bypass": "The review says the gates match command text only, so the agent can write a script or use an interpreter to do what a gate denies when typed directly.",
  "deletion-breaks": "The review says deleting one of the listed files (for example `slug-hash.sh`) breaks the audit or other code that still sources or counts it, locking commits.",
  "ask-deny": "The review says turning ask into deny (or running unattended where an ask is a denial) blocks ordinary work, such as editing tests or committing, or harms attended sessions.",
 }),
 "plan-v3-bundle-intake": ("attack-proposal-option-a-no-write-access.md", "## Revision 1", {
  "option-injection": "The review says an outbox file name or task name chosen by the agent can be read by git as an option or a remote (for example a name starting with `--upload-pack=` or shaped like `host:path`), running a command or opening a connection as the owner.",
  "tag-shadow": "The review says the bundle can carry extra refs (for example a tag named `origin/develop`) that the fetch writes, so the base the diff is taken against is one the agent chose and the shown diff is wrong.",
  "fsck-bundle": "The review says `transfer.fsckObjects` cannot be relied on for a fetch from a bundle (or that hostile objects such as a `.git` tree entry get stored), so the unverified fsck claim is false or unsafe.",
  "key-exfil": "The review says the Anthropic API key inside the jail can be sent out or abused despite the network allowlist (through the allowed API host itself, an allowed host with attacker-supplied credentials, or DNS).",
  "merge-base": "The review says a merge commit, criss-cross history or unusual base on the agent's branch can make the three-dot diff hide a change that still merges.",
  "judge-list": "The review says the list of judge paths is incomplete or dodgeable (for example scripts under skills, a renamed test, nested instruction files), so an unflagged change can still alter what runs.",
  "size-bomb": "The review says the 20 MB cap on the bundle does not bound what intake must process (a small bundle can expand into a huge diff or object), or that the outbox can fill the owner's disk.",
  "runs-after-push": "The review says the agent's code runs with the owner's privileges once the owner pushes and runs the merge script (or already at checkout through the repository's own git hooks), so approval rests entirely on the owner reading the diff.",
 }),
 "plan-v4-branch-key": ("attack-proposal-v4-jail-with-branch-key.md", "## Revision 1", {
  "fetch-pulls": "The review says an ordinary `git fetch origin` on the owner's machine (which the merge script runs) downloads the `agent/*` branches, so the claim that no agent object reaches the owner's machine before freezing is false.",
  "ref-conflict": "The review says the agent can create branch names that break the owner's fetch or flow (for example deleting `agent/a` and creating `agent/a/b`), locking the owner out.",
  "hooks-at-checkout": "The review says checking out the frozen branch runs that branch's own git hooks (the hooks path is relative), so the agent's code runs as the owner before the gauntlet.",
  "merge-base": "The review says a merge commit or criss-cross history on the agent branch can make the comparison the owner reads differ from what merges.",
  "github-hides": "The review says github.com does not show everything (large diffs over a file limit, files marked or judged generated, binary files), so the owner can read less than what merges.",
  "freeze-any-sha": "The review says the freeze step or helper accepts any commit id (one suggested by the agent's note, or no longer the branch tip), so the owner can freeze a commit that was not the one read.",
  "outsider-verdict": "The review says anyone can post the `Fresh-context review: MERGE` comment on a public pull request because the merge script does not check its author.",
  "agent-socket": "The review says mounting an ssh-agent socket can expose other keys the agent holds (the owner's own key), or lets the run lock or empty the agent.",
 }),
}
PR = {
 "arch-pr453-merge-race": ("145f308567b09732d8127690eab33ae724705e88", "Score 1 if the review identifies at least one of these in scripts/merge-pr.sh: (a) the ancestry check runs once before the load-wait loop and is not repeated after it, so develop can move during the wait and a stale head is merged (check-then-act race); (b) the PR's base branch is never checked, so a PR targeting another branch is merged there. Score 0 otherwise."),
 "arch-pr368-ledger": ("fea6ebd319fd372b5f507e281671bfbe49771942", "Score 1 if the review identifies that a non-finite or non-number usd reading is mishandled between the ledger writer and the cost-report reader: NaN or Infinity is written as null and/or Number(null) or Number('') reads as 0, so the row counts as a zero reading or process reset and the total is wrong. Score 0 otherwise."),
 "arch-pr965-rollback": ("67fd709adeb83ad99d4e8a0b9b1ec9853a072b09", "Score 1 if the review identifies at least one of these in memory-lint.py's rollback: (a) it only runs on OSError, so another exception leaves files archived while the index still points at them; (b) the restore move can overwrite a file that exists again at the original path. Score 0 otherwise."),
 "arch-pr752-miss-log": ("1c307117bddb220dad8e8e499c4a1ee770bccf35", "Score 1 if the review identifies at least one of these in scripts/merge-pr.sh: (a) a relative GAUNTLET_MISS_LOG path writes the log inside the checkout, which the unchanged-checkout check then treats as a change and refuses the merge; (b) an unset HOME under set -u aborts the merge at the miss-log default. Score 0 otherwise."),
}
FIXT = {"backend-architect-client-trusted-price": "source-of-truth-quality.md", "backend-architect-guard-column-bug": "catches-race-quality.md",
        "backend-architect-multi-writer-table": "data-ownership-quality.md", "backend-architect-no-idempotency-webhook": "idempotency-quality.md"}

def git(*a): return subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True).stdout
def tree_tar(rev, name, extra):
    d = os.path.join(tars, name); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    a = subprocess.Popen(["git", "-C", repo, "archive", rev], stdout=subprocess.PIPE)
    subprocess.check_call(["tar", "-x", "-C", d], stdin=a.stdout); a.wait()
    for junk in ("CLAUDE.md", "AGENTS.md", ".claude", ".claude-plugin"):
        p = os.path.join(d, junk)
        shutil.rmtree(p) if os.path.isdir(p) else (os.remove(p) if os.path.exists(p) else None)
    for fn, data in extra.items(): open(os.path.join(d, fn), "wb").write(data)
    tb = os.path.join(tars, name + ".tar"); subprocess.check_call(["tar", "-cf", tb, "-C", d, "."]); shutil.rmtree(d); return tb
def case(name, tags, prompt, scaffold, graders, max_turns=40, timeout=1500):
    c = os.path.join(out, "evals", name); os.makedirs(os.path.join(c, "graders"))
    open(os.path.join(c, "prompt.md"), "w").write("---\nname: %s\ntags: [%s]\nruns: 3\nmax_turns: %d\ntimeout_seconds: %d\n---\n%s" % (name, ", ".join(tags), max_turns, timeout, prompt))
    open(os.path.join(c, "case.yaml"), "w").write('schema_version: "1.1"\nname: %s\ncontext:\n  scaffold_script: scaffold.sh\n' % name)
    open(os.path.join(c, "scaffold.sh"), "w").write(scaffold)
    for g, text in graders.items(): open(os.path.join(c, "graders", g + ".md"), "w").write("---\ntype: llm\n---\n%s\n" % text)

shutil.rmtree(out, ignore_errors=True); os.makedirs(out); os.makedirs(tars, exist_ok=True)
a = subprocess.Popen(["git", "-C", repo, "archive", "c5995ee2"], stdout=subprocess.PIPE)
subprocess.check_call(["tar", "-x", "-C", out], stdin=a.stdout); a.wait()
m = os.path.join(out, ".claude-plugin", "plugin.json"); t = open(m).read()
assert t.count('"defaultEnabled": false') == 1
open(m, "w").write(t.replace('"defaultEnabled": false', '"defaultEnabled": true'))
src_evals = os.path.join(out, "evals"); keep = tempfile.mkdtemp(prefix="fixt-", dir=tars)
for f in FIXT: shutil.copytree(os.path.join(src_evals, f), os.path.join(keep, f))
shutil.rmtree(src_evals); os.makedirs(src_evals)

for name, (fn, cut, breaks) in PLANS.items():
    text = open(os.path.join(pad, fn)).read()
    if cut: text = text[:text.index("\n" + cut)]
    assert "## Revision" not in text and "Status (" not in text
    tb = tree_tar(TREE, name, {"plan.md": text.encode()})
    sc = "#!/usr/bin/env bash\ntar -xf %s\n" % tb
    gr = {k: "Score 1 if the following holds for the review, else 0. " + v + X for k, v in breaks.items()}
    where = "The repository the plan is about is the current working directory; read any file you need.\n"
    case(name + "-agent", ["plan-agent"], "Use the `mh:plan-reviewer` agent (Agent tool, `subagent_type: \"mh:plan-reviewer\"`) to review the plan in `plan.md` before anyone builds it. " + where + "Tell the agent the same.\n\nReturn the agent's report verbatim as your final message. Add nothing else.\n", sc, gr)
    case(name + "-plain", ["plan-plain"], "Review the plan in `plan.md` before anyone builds it. " + where + "Report what would make it fail once built, most serious first, each with its evidence.\n", sc, gr)

for name, (merge, rule) in PR.items():
    tb = tree_tar(merge + "^2", name, {"pr.diff": git("diff", merge + "^1..." + merge + "^2", "--", ".", ":!.claude-plugin")})
    sc = "#!/usr/bin/env bash\ntar -xf %s\n" % tb
    where = "The diff is in `pr.diff`, and the repository at the pull request's head commit is the current working directory; read any file you need.\n"
    gr = {"substance": rule + " Finding other issues as well never lowers the score."}
    case(name + "-agent", ["arch-pr-agent"], "Use the `mh:backend-architect` agent (Agent tool, `subagent_type: \"mh:backend-architect\"`) to review the design of this pull request for races, failure handling and data integrity. " + where + "Tell the agent the same.\n\nReturn the agent's report verbatim as your final message. Add nothing else.\n", sc, gr)
    case(name + "-plain", ["arch-pr-plain"], "Review the design of this pull request for races, failure handling and data integrity. " + where + "Report the defects, most serious first, each with its file and line.\n", sc, gr)

for f, grader in FIXT.items():
    src = os.path.join(keep, f); md = open(os.path.join(src, "prompt.md")).read()
    _, fm, body = md.split("---", 2); body = body.strip("\n")
    plain = re.sub(r"\s*Use the\s+`mh:backend-architect` agent for this.*$", "", body, flags=re.S).strip() + "\n"
    assert "mh:" not in plain, plain
    sc = open(os.path.join(src, "scaffold.sh")).read()
    gtext = open(os.path.join(src, "graders", grader)).read().split("---", 2)[2].strip()
    for kind, text in (("agent", body + "\n"), ("plain", plain)):
        case("%s-%s" % (f.replace("backend-architect", "arch-fx"), kind), ["arch-fx-" + kind], text, sc, {"substance": gtext}, 20, 600)
shutil.rmtree(keep)
print(sorted(os.listdir(os.path.join(out, "evals"))))
