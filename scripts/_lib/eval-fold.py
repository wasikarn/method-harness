#!/usr/bin/env python3
"""Fold-vs-keep eval helper for scripts/eval-fold.sh (evals/README.md "Fold-vs-keep").

  eval-fold.py build <repo> <agent> <out>
      Writes two throwaway plugins from <repo>'s tracked files (working-tree bytes):
        <out>/kept    the plugin as shipped, defaultEnabled true
        <out>/folded  agents/<agent>.md removed; its text becomes skills/fold/<agent>/SKILL.md
                      (frontmatter: name, description and the agent's model/effort pin; body
                      byte-identical); the <agent>-tagged cases ask for the skill instead of the
                      subagent, their Agent-dispatch tool_used graders check the Skill tool
                      instead (same file names), and each gains fold-agent-calls.md, a display
                      counter of Agent calls (did the folded main loop still delegate?)
      Prints the --allow-tools list for the agent's cases (empty line if none).
      Never writes inside <repo>.

  eval-fold.py compare <kept aggregate-result.json> <folded aggregate-result.json>
      Per-case, per-run table of the outcome graders in both variants, a * on every grader
      whose pass rate differs (a flipped task), and per-case outcome means. The mechanism
      graders (agent-fired, dispatch-confirmed, fold-agent-calls) are shown, not scored. Errored
      runs (E) and cost-capped runs (S, skippedPaidGraders) stay out of rates, flips, means and
      the verdict; each is counted apart.
"""
import json
import os
import re
import subprocess
import sys
from typing import NoReturn

# did the variant's mechanism run; shown, never part of the outcome score
FIRING = {"agent-fired", "dispatch-confirmed", "fold-agent-calls"}
CALLS_GRADER = """---
type: tool_used
tool: Agent
min: 0
---
Display-only (fold arm): counts Agent calls, so compare can flag a folded run that loaded the
skill and still handed the work to a subagent. Always passes; never part of the score.
"""
HEADER = """Fold-vs-keep comparison. Read before the verdict:
- model/effort: the folded SKILL.md carries the agent's model/effort pin, which takes effect once
  the skill loads; turns before the Skill call run on the eval child's model (--model if passed).
- tool limits: the folded variant has the case's allowed_tools, not the agent's own tools: list.
- Errored runs (E) and cost-capped runs (S: --max-cost-usd hit, paid graders skipped unjudged)
  are left out of rates, flips, means and the verdict, and counted at the end.
- * = a grader whose pass rate changed between variants (a flipped task)."""


def die(msg) -> NoReturn:
    print(f"eval-fold: ERROR {msg}", file=sys.stderr)
    sys.exit(1)


def split_fm(text):
    m = re.match(r"---\n(.*?)\n---\n?(.*)\Z", text, re.S)
    if not m:
        return None, text
    return m.group(1), m.group(2)


def copy_tracked(repo, dst):
    files = subprocess.run(["git", "-C", repo, "ls-files", "-z"], check=True,
                           capture_output=True).stdout.decode().split("\0")
    for rel in filter(None, files):
        src = os.path.join(repo, rel)
        if not os.path.isfile(src):  # tracked but deleted in the working tree
            continue
        out = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(src, "rb") as f, open(out, "wb") as g:
            g.write(f.read())
        os.chmod(out, os.stat(src).st_mode)


def enable(manifest_path, extra_skill_dir=None):
    with open(manifest_path) as f:
        m = json.load(f)
    m["defaultEnabled"] = True  # eval sandboxes load no user settings (eval-default-enabled.sh)
    if extra_skill_dir:
        m.setdefault("skills", []).append(extra_skill_dir)
    with open(manifest_path, "w") as f:
        json.dump(m, f, indent=2)
        f.write("\n")


def agent_cases(root, agent):
    evals = os.path.join(root, "evals")
    cases = []
    for name in sorted(os.listdir(evals)):
        p = os.path.join(evals, name, "prompt.md")
        if not os.path.isfile(p):
            continue
        fm, _ = split_fm(open(p).read())
        t = re.search(r"^tags:\s*\[\s*([^,\]\s]+)", fm or "", re.M)
        if t and t.group(1) == agent:
            cases.append(os.path.join(evals, name))
    return cases


def allow_tools(case_dirs):
    tools = set()
    for c in case_dirs:
        fm, _ = split_fm(open(os.path.join(c, "prompt.md")).read())
        m = re.search(r"^allowed_tools:\s*\[([^\]]*)\]", fm or "", re.M)
        if m:
            tools.update(t.strip() for t in m.group(1).split(",") if t.strip())
    if tools:
        tools.add("Skill")
    return ",".join(sorted(tools))


def fold_prompt(path, agent, should_not_fire):
    fm, body = split_fm(open(path).read())
    if fm is None:
        die(f"{path}: no frontmatter")
    a = re.escape(agent)
    dispatch = re.compile(
        r"`mh:" + a + r"`\s+agent(\s+for\s+this)?\s+\("
        r"(?:dispatch\s+it\s+via\s+the\s+Agent\s+tool\s+with|Agent\s+tool,)\s+"
        r"`subagent_type:\s*\"mh:" + a + r"\"`\)")
    body, n = dispatch.subn(lambda m: f'`mh:{agent}` skill{m.group(1) or ""} '
                            f'(Skill tool, `skill: "mh:{agent}"`)', body)
    body = re.sub(r"\bthe\s+agent's\s+report\b", "the skill's report", body)
    if "subagent_type" in body or n > 1 or (n == 0 and not should_not_fire):
        die(f"{path}: dispatch sentence not rewritten exactly once ({n} rewrites); "
            "update fold_prompt's pattern for this wording")
    fm = re.sub(r"^(allowed_tools:\s*\[)([^\]]*)\]",
                lambda m: m.group(0) if "Skill" in m.group(2)
                else f"{m.group(1)}{m.group(2)}, Skill]", fm, flags=re.M)
    with open(path, "w") as f:
        f.write(f"---\n{fm}\n---\n{body}")
    return n


def is_no_dispatch_grader(path, agent):
    """A should-not-fire case: an Agent tool_used grader naming the agent with max: 0."""
    fm, _ = split_fm(open(path).read())
    return bool(fm and re.search(r"^tool:\s*Agent\s*$", fm, re.M)
                and re.search(r"^input_match:.*" + re.escape(agent), fm, re.M)
                and re.search(r"^max:\s*0\s*$", fm, re.M))


def fold_grader(path, agent):
    fm, body = split_fm(open(path).read())
    if not fm or not re.search(r"^type:\s*tool_used\s*$", fm, re.M) \
            or not re.search(r"^tool:\s*Agent\s*$", fm, re.M):
        return False
    im = re.search(r"^input_match:.*$", fm, re.M)
    if not im or agent not in im.group(0):
        return False
    fm = re.sub(r"^tool:\s*Agent\s*$", "tool: Skill", fm, flags=re.M)
    fm = fm.replace(im.group(0),
                    "input_match: '\"skill\"\\s*:\\s*\"(?:[\\w-]+:)?" + agent + "\"'")
    with open(path, "w") as f:
        f.write(f"---\n{fm}\n---\n(fold arm: Skill-tool form of the kept arm's Agent check)\n{body}")
    return True


def build(repo, agent, out):
    repo, out = os.path.realpath(repo), os.path.realpath(out)
    if out == repo or out.startswith(repo + os.sep):
        die(f"output dir {out} is inside the repo")
    agent_md = os.path.join(repo, "agents", agent + ".md")
    if not os.path.isfile(agent_md):
        die(f"no agent file {agent_md}")
    kept, folded = os.path.join(out, "kept"), os.path.join(out, "folded")
    for d in (kept, folded):
        copy_tracked(repo, d)
    enable(os.path.join(kept, ".claude-plugin", "plugin.json"))
    enable(os.path.join(folded, ".claude-plugin", "plugin.json"), "./skills/fold/")

    fm, body = split_fm(open(agent_md).read())
    if fm is None:
        die(f"{agent_md}: no frontmatter")
    desc = re.search(r"^description:\s*(.*)$", fm, re.M)
    if not desc:
        die(f"{agent_md}: no description line")
    d = desc.group(1).strip()
    if len(d) >= 2 and d[0] == d[-1] and d[0] in "\"'":
        d = d[1:-1]
    os.remove(os.path.join(folded, "agents", agent + ".md"))
    skill_dir = os.path.join(folded, "skills", "fold", agent)
    os.makedirs(skill_dir)
    with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
        # model/effort: the agent's own pin, so the folded turns run where the subagent did
        # (a concrete pin on a main-thread skill switches the model once the skill loads)
        pins = "".join(m.group(0) + "\n" for k in ("model", "effort")
                       for m in [re.search(rf"^{k}:[ \t]*\S.*$", fm, re.M)] if m)
        f.write(f"---\nname: {agent}\ndescription: {json.dumps(d)}\n{pins}---\n{body}")

    cases = agent_cases(folded, agent)
    if not cases:
        die(f"no eval case has {agent} as its first tag")
    for c in cases:
        gdir = os.path.join(c, "graders")
        graders = [os.path.join(gdir, g) for g in sorted(os.listdir(gdir)) if g.endswith(".md")]
        fold_prompt(os.path.join(c, "prompt.md"), agent,
                    any(is_no_dispatch_grader(g, agent) for g in graders))
        for g in graders:
            fold_grader(g, agent)
        with open(os.path.join(gdir, "fold-agent-calls.md"), "w") as f:
            f.write(CALLS_GRADER)
    print(allow_tools(cases))


def runs_of(result_path):
    with open(result_path) as f:
        data = json.load(f)
    out = {}
    for case in data.get("cases", []):
        arms = case.get("arms", {})
        if "with" not in arms:
            die(f"{result_path}: case {case.get('name')} has no 'with' arm (arms: {sorted(arms)})")
        out[case["name"]] = arms["with"]
    return out, data.get("costUsd")


def outcome_score(run):
    gs = [g for g in run.get("graders", []) if g["name"] not in FIRING]
    w = sum(g.get("weight", 1) for g in gs)
    return sum(g.get("weight", 1) for g in gs if g.get("passed")) / w if w else 0.0


def agent_calls(run):
    """Agent calls in a folded run, from the runner's own tool_used explanation
    ("Agent called Nx ..."); None when the counter is absent or its wording changed."""
    for g in run.get("graders", []):
        if g["name"] == "fold-agent-calls":
            m = re.match(r"Agent called (\d+)x", g.get("explanation") or "")
            return int(m.group(1)) if m else None
    return None


def status(run):
    """E = errored, S = cost cap hit (skippedPaidGraders: llm graders marked failed unjudged),
    "" = clean. E and S runs stay out of rates, flips, means and the verdict."""
    return "E" if run.get("error") else "S" if run.get("skippedPaidGraders") else ""


def cell(runs, grader):
    out = ""
    for r in runs:
        if status(r):  # every grader cell, even when an errored run has graders: []
            out += status(r)
            continue
        for x in r.get("graders", []):
            if x["name"] == grader:
                out += "P" if x.get("passed") else "F"
    return out


def rate(c):
    clean = c.replace("E", "").replace("S", "")
    return clean.count("P") / len(clean) if clean else None


def compare(kept_path, folded_path):
    kept, kcost = runs_of(kept_path)
    folded, fcost = runs_of(folded_path)
    print(HEADER)
    worse = better = same = 0
    errored = {"kept": 0, "folded": 0}
    capped = {"kept": 0, "folded": 0}
    for name in sorted(set(kept) | set(folded)):
        k, f = kept.get(name, []), folded.get(name, [])
        print(f"\n## {name}   (kept {len(k)} runs, folded {len(f)} runs)")
        for label, runs in (("kept", k), ("folded", f)):
            errs = [r.get("error") for r in runs if r.get("error")]
            errored[label] += len(errs)
            if errs:
                print(f"  {label} run errors (left out): {errs}")
            n_capped = sum(status(r) == "S" for r in runs)
            capped[label] += n_capped
            if n_capped:
                print(f"  {label}: {n_capped} cost-capped run(s), paid graders skipped (left out)")
        graders = sorted({g["name"] for r in k + f for g in r.get("graders", [])})
        print(f"  {'grader':34} {'kept':8} {'folded':8}")
        for g in graders:
            kc, fc = cell(k, g), cell(f, g)
            tag = " (mechanism, not scored)" if g in FIRING else ("  *" if rate(kc) != rate(fc) else "")
            print(f"  {g:34} {kc or '-':8} {fc or '-':8}{tag}".rstrip())
        calls = [None if r.get("error") else agent_calls(r) for r in f]
        if f:
            line = "  folded Agent calls per run: " + ", ".join(
                "E" if r.get("error") else "?" if c is None else str(c) for r, c in zip(f, calls))
            if any(c for c in calls):
                line += "  <- DELEGATED: a folded run still handed work to a subagent"
            if any(c is None and not r.get("error") for r, c in zip(f, calls)):
                line += "  (? = no readable fold-agent-calls count for that run; unknown, not 0)"
            print(line)
        ks = [outcome_score(r) for r in k if not status(r)]
        fs = [outcome_score(r) for r in f if not status(r)]
        if not ks or not fs:
            print("  outcome: no clean runs in one variant; left out of the verdict")
            continue
        km, fm = sum(ks) / len(ks), sum(fs) / len(fs)
        verdict = "folded worse" if fm < km else "folded better" if fm > km else "same"
        worse += verdict == "folded worse"
        better += verdict == "folded better"
        same += verdict == "same"
        print(f"  outcome per clean run: kept {[round(x, 2) for x in ks]}  "
              f"folded {[round(x, 2) for x in fs]}  -> {verdict}")
    print(f"\nCases: folded worse {worse}, folded better {better}, same {same}."
          f"  Cost: kept ${kcost}, folded ${fcost}.")
    print(f"errored runs (not in the verdict): kept {errored['kept']}, folded {errored['folded']}")
    print(f"cost-capped runs (skippedPaidGraders; not in the verdict): "
          f"kept {capped['kept']}, folded {capped['folded']}")
    print("Rule (fold-subagents audit, rec 1): keep the subagent only if the folded variant "
          "scores worse; read the * rows and any DELEGATED line before deciding.")


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "build":
        build(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        compare(*sys.argv[2:])
    else:
        die("usage: eval-fold.py build <repo> <agent> <out> | compare <kept.json> <folded.json>")
