"""Build a throwaway copy of the plugin whose evals/ holds two variants of each agent case:
<case>-agent (the original prompt, naming the mh agent) and <case>-plain (the same task with no
agent named). Both carry one LLM grader that judges substance only, so a bare model is not marked
down for lacking the agent's report format."""
import glob, os, re, shutil, subprocess, sys, tempfile

repo, out = sys.argv[1], sys.argv[2]


def under_tmp(p):  # these scripts delete their output dirs: only ever under the temp dir
    root = os.path.realpath(tempfile.gettempdir()) + os.sep
    if not os.path.realpath(p).startswith(root):
        sys.exit("refusing %r: the output directory must be under %s" % (p, root))
under_tmp(out)
SUBSTANCE = {
 'type-design-analyzer-planted': 'Score 1 if the answer names at least two of: public mutable amount/currency, no validation in the constructor (NaN, non-integer, unknown currency), add() combining different currencies, as real design problems. Score 0 otherwise. Extra observations, suggestions or minor notes beyond this never lower the score.',
 'type-design-analyzer-clean': "Score 1 if the answer's overall verdict is that the Money type's design is sound and it claims no correctness bug or broken invariant in the code as written. Suggestions for a larger API or other optional improvements are allowed. Score 0 only if it claims a correctness bug, a broken invariant, or judges the design unsound. Extra observations, suggestions or minor notes beyond this never lower the score.",
 'blind-spot-hunter-planted': "Score 1 if the answer identifies that pay passes order_total's cents into Gateway.charge, which expects dollars, so customers are overcharged about 100x, and treats it as a serious defect. Score 0 if this defect is missing or only vaguely hinted at. Extra observations, suggestions or minor notes beyond this never lower the score.",
 'blind-spot-hunter-clean': 'Score 1 if the answer does not claim any defect that produces wrong behaviour today across the files (in particular it does not claim a unit mismatch, a wrong charge amount, or a broken transaction id). Hardening suggestions and notes marked minor, hypothetical or not reachable are allowed. Score 0 only if it claims a present, real cross-file bug. Extra observations, suggestions or minor notes beyond this never lower the score.',
 'plan-reviewer-planted': 'Score 1 if the answer states that step 1 destroys the data step 2 needs (data loss) and concludes the plan must not be built as written. Score 0 if it judges the plan ready. Extra observations, suggestions or minor notes beyond this never lower the score.',
 'plan-reviewer-clean': "Score 1 if the answer's verdict is that the plan is ready to build / approved as written. Minor notes explicitly marked non-blocking are allowed. Score 0 only if it withholds approval, demands changes before building, or raises a blocking finding. Extra observations, suggestions or minor notes beyond this never lower the score.",
 'plan-reviewer-trivial-no-rollback': "Score 1 if the answer's verdict is that the plan is ready to build / approved as written. Minor notes explicitly marked non-blocking are allowed. Score 0 only if it withholds approval, demands changes before building, or raises a blocking finding (for example a required rollback plan). Extra observations, suggestions or minor notes beyond this never lower the score.",
 'requirement-analyst-planted': 'Score 1 if the answer concludes the ticket is not ready to implement as written and flags at least three of: "handle errors gracefully" is vague/untestable; export and email delivery are two bundled things or the delivery mechanism is unclear; the export format is unspecified; the failure/toast behaviour is unspecified. Score 0 otherwise. Extra observations, suggestions or minor notes beyond this never lower the score.',
 'requirement-analyst-clean': "Score 1 if the answer's verdict is that the ticket is ready to implement. Questions or notes explicitly marked non-blocking or informational are allowed. Score 0 only if it says the ticket is not ready or lists a blocking question. Extra observations, suggestions or minor notes beyond this never lower the score.",
 'silent-failure-hunter-planted': 'Score 1 if the answer identifies the `except Exception: pass` in app/billing.py, says the order is still marked paid after the charge failed, and treats it as a serious defect. Score 0 if that is missing. Extra observations, suggestions or minor notes beyond this never lower the score.',
 'silent-failure-hunter-clean': 'Score 1 if the answer does not claim that any error is swallowed, hidden or lost in the code as written (logging then re-raising is correct). Optional suggestions are allowed. Score 0 only if it claims a silent failure or swallowed error exists. Extra observations, suggestions or minor notes beyond this never lower the score.',
 'test-gap-analyzer-planted': 'Score 1 if the answer names the out-of-range `pct` guard and/or the negative-price guard in src/discount.py as untested and treats that as a gap worth closing. Score 0 if neither is named, or if it claims the happy-path 10% case is untested. Extra observations, suggestions or minor notes beyond this never lower the score.',
 'test-gap-analyzer-clean': "Score 1 if the answer's verdict is that the change is adequately covered by its tests. Optional nice-to-have tests marked low priority are allowed. Score 0 only if it reports an important or blocking coverage gap. Extra observations, suggestions or minor notes beyond this never lower the score.",
}
BACKEND = {  # original substance grader kept as written
 "backend-architect-client-trusted-price": "source-of-truth-quality.md",
 "backend-architect-guard-column-bug": "catches-race-quality.md",
 "backend-architect-multi-writer-table": "data-ownership-quality.md",
 "backend-architect-no-idempotency-webhook": "idempotency-quality.md",
}

if os.path.isdir(out): shutil.rmtree(out)
os.makedirs(out)
tar = subprocess.Popen(["git", "-C", repo, "archive", "HEAD"], stdout=subprocess.PIPE)
subprocess.check_call(["tar", "-x", "-C", out], stdin=tar.stdout)
tar.wait()
manifest = os.path.join(out, ".claude-plugin", "plugin.json")
text = open(manifest).read()
assert text.count('"defaultEnabled": false') == 1
open(manifest, "w").write(text.replace('"defaultEnabled": false', '"defaultEnabled": true'))
for ag in glob.glob(os.path.join(out, "agents", "*.md")):  # every condition on the session model
    t = open(ag).read(); open(ag, "w").write(re.sub(r"^model: .*$", "model: inherit", t, count=1, flags=re.M))
src_evals = os.path.join(repo, "evals")
shutil.rmtree(os.path.join(out, "evals"))
os.makedirs(os.path.join(out, "evals"))


def split(md):
    _, fm, body = md.split("---", 2)
    return fm.strip("\n"), body.strip("\n")


def plain(body):
    b = re.sub(r'^Use the `mh:[\w-]+` agent \(Agent tool, `subagent_type: "mh:[\w-]+"`\) to (\w)',
               lambda m: m.group(1).upper(), body)
    b = re.sub(r"\n+Return the agent's report verbatim as your final message\. Add nothing before or after it\.\s*$", "", b)
    b = re.sub(r"\s*Use the\s+`mh:backend-architect` agent for this.*$", "", b, flags=re.S)
    assert "mh:" not in b and "agent" not in b.lower().split("files are")[0], b
    return b.strip() + "\n"


made = []
for case in list(SUBSTANCE) + list(BACKEND):
    fm, body = split(open(os.path.join(src_evals, case, "prompt.md")).read())
    family = re.search(r"tags: \[([\w-]+)", fm).group(1)
    SHORT = ("\nReport only problems that are real in the material as written. If there are none, say so "
             "plainly and stop: do not add speculative concerns, optional suggestions or open questions.\n")
    kinds = [("agent", body + "\n"), ("plain", plain(body))]
    if case in SUBSTANCE:
        kinds.append(("short", plain(body) + SHORT))
    for kind, text in kinds:
        name = "%s-%s" % (case, kind)
        d = os.path.join(out, "evals", name)
        os.makedirs(os.path.join(d, "graders"))
        new_fm = re.sub(r"^name: .*$", "name: " + name, fm, flags=re.M)
        new_fm = re.sub(r"^tags: .*$", "tags: [%s-%s, %s]" % (kind, "backend" if case in BACKEND else "review", family), new_fm, flags=re.M)
        new_fm = re.sub(r"^runs: .*$", "runs: 3", new_fm, flags=re.M)
        open(os.path.join(d, "prompt.md"), "w").write("---\n%s\n---\n%s" % (new_fm, text))
        cy = open(os.path.join(src_evals, case, "case.yaml")).read()
        open(os.path.join(d, "case.yaml"), "w").write(re.sub(r"^name: .*$", "name: " + name, cy, flags=re.M))
        shutil.copy(os.path.join(src_evals, case, "scaffold.sh"), os.path.join(d, "scaffold.sh"))
        if case in BACKEND:
            shutil.copy(os.path.join(src_evals, case, "graders", BACKEND[case]), os.path.join(d, "graders", "substance.md"))
        else:
            open(os.path.join(d, "graders", "substance.md"), "w").write("---\ntype: llm\n---\n%s\n" % SUBSTANCE[case])
        made.append(name)
print(len(made), "variant cases written to", os.path.join(out, "evals"))
