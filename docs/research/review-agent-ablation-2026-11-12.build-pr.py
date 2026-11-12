"""Real-PR review benchmark: each case is a merged PR (repo tree at the PR head + pr.diff) whose
bug a later PR fixed. Three variants per case: agent (mh review agents), plain, short."""
import os, re, shutil, subprocess, sys, glob
repo, out, tars = sys.argv[1], sys.argv[2], sys.argv[3]


def under_tmp(p):  # these scripts delete their output dirs: only ever under the temp dir
    import tempfile
    root = os.path.realpath(tempfile.gettempdir()) + os.sep
    if not os.path.realpath(p).startswith(root):
        sys.exit("refusing %r: the output directory must be under %s" % (p, root))
under_tmp(out); under_tmp(tars)
X = " Finding other issues as well never lowers the score. Judge only whether the named defect is identified; the wording may differ."
BUG = {
 "pr975-citation-exists": ("4b554241971b345a5960c4c473d22c90347fdd3f", "Score 1 if the review identifies at least one of these in scripts/_lib/citation_exists.py: (a) int() on a cited line number can raise (very long digit strings) and the script crashes instead of exiting 0 as promised; (b) cites inside JSON input that follow an escaped newline/tab (a backslash before the path) are silently dropped by the path regex's lookbehind, so the report undercounts; (c) the SHA/path overlap check is quadratic and slow on large inputs. Score 0 otherwise."),
 "pr965-memory-lint-rollback": ("67fd709adeb83ad99d4e8a0b9b1ec9853a072b09", "Score 1 if the review identifies at least one of these in memory-lint.py's apply_action_plan rollback: (a) the rollback only runs on OSError, so another exception (for example UnicodeDecodeError or KeyboardInterrupt) leaves files archived while the index still points at them; (b) the restore move can overwrite a file that exists again at the original path. Score 0 otherwise."),
 "pr544-codex-quota-deny": ("096924e0631d258918db6f4d8d37d2ec85e441bc", "Score 1 if the review identifies at least one of these in hooks/sensors/codex-quota-advisory.py: (a) the deny reuses the loose matcher, so any Bash command that merely mentions the word codex (a commit message, a file name) is denied, not only a real codex invocation; (b) the 24h TTL check runs before the reset_at logic, so a record whose reset is more than 24h ahead is deleted and the deny lapses while the limit is still closed. Score 0 otherwise."),
 "pr368-cost-ledger": ("fea6ebd319fd372b5f507e281671bfbe49771942", "Score 1 if the review identifies that a non-finite or non-number usd reading is mishandled: NaN/Infinity is written as null by the ledger module and/or Number(null) or Number('') reads as 0 in cost-report-dedup.js, so the row is counted as a zero reading / process reset and the total is wrong (or prev becomes NaN in the writer). Score 0 otherwise."),
 "pr494-skill-usage-window": ("0ebf5f192197ca999fc5d1a0d9ae39278b040198", "Score 1 if the review identifies that skill-usage.py orders sessions for the last-N window by first use, so a long-lived or resumed session with recent activity is ranked old and drops out of the window (it should order by last use). Score 0 otherwise."),
 "pr944-gate-closure": ("c93c815b5cf49d43fd000fd547c370607b9ac3fb", "Score 1 if the review identifies at least one of these: (a) scripts/_lib/gate_closure.py runs git ls-tree with a path relative to the cwd, so from a subdirectory --rev lists nothing and yields the empty-set hash with no error; (b) a non-UTF-8 file name crashes path.decode() or disagrees with the directory side; (c) _shared() takes any underscore-prefixed file, so an untracked backup file joins a folder's closure but never a rev's; (d) a relative OLD/NEW directory in gate-differential makes both sides fail the same way so the diff reads as zero. Score 0 otherwise."),
 "pr453-merge-pr-base": ("145f308567b09732d8127690eab33ae724705e88", "Score 1 if the review identifies at least one of these in scripts/merge-pr.sh: (a) the PR's base branch is never checked, so a PR targeting a branch other than develop passes and is merged there; (b) the ancestry check runs once before the load-wait loop and is not repeated after it, so develop can move during the wait and a stale head is merged. Score 0 otherwise."),
 "pr502-merge-pr-version": ("85310130690b75115bd7d6f005f627fc3fa1933b", "Score 1 if the review identifies that the version check in scripts/merge-pr.sh accepts leading zeros and mixes numeric comparison (lower-than) with string comparison (equal), so a head version such as 01.1.5 against develop 1.1.5 is neither lower nor equal and passes. Score 0 otherwise."),
 "pr625-merge-pr-verdict": ("bcff0e1fe4d894ef80b34f83fbebca0606a00690", "Score 1 if the review identifies at least one of these in scripts/merge-pr.sh's review-verdict check: (a) the fence tracking toggles one flag on both backtick and tilde fences, so mixed fences hide a real verdict line or expose a fenced one; (b) only non-merge commits after the reviewed sha are inspected, so edits made inside a merge commit keep the old verdict; (c) any post-review commit touching only plugin.json/marketplace.json is allowed, although those files can carry hooks or other behaviour beyond the version value. Score 0 otherwise."),
 "pr644-merge-pr-sync-tries": ("0747ddb84f532af757c10c8949663f98d7240fab", "Score 1 if the review identifies at least one of these: (a) MERGE_PR_SYNC_TRIES in scripts/merge-pr.sh is not validated, so a non-numeric value makes the -ge test error, read as false, and the retry cap never fires; (b) a test in test-sync-pr-head.sh cannot tell a wrong conflict resolution (keeping one side) from a correct one. Score 0 otherwise."),
 "pr752-miss-log": ("1c307117bddb220dad8e8e499c4a1ee770bccf35", "Score 1 if the review identifies at least one of these in scripts/merge-pr.sh: (a) a relative GAUNTLET_MISS_LOG path writes the log inside the checkout, which the unchanged-checkout check then treats as a change and refuses the merge; (b) an unset HOME under set -u aborts the merge at the miss-log default. Either contradicts the rule that a log problem never stops the merge. Score 0 otherwise."),
 "pr420-slug-traversal": ("d57c2b80aa731dc3d1c82f5b3e87cfc57193bcf2", "Score 1 if the review identifies that the --slug validation in scripts/gate-differential.sh is a prefix match only, so a slug containing / or .. passes and makes the tool read another project's transcripts (path traversal). Score 0 otherwise."),
}
CLEAN_RULE = "Score 1 if the review reports no defect that it presents as a bug, a blocker, or something that must be fixed before merge. Notes it marks minor, optional or non-blocking are allowed. Score 0 if it reports at least one defect as a real bug or as blocking."
CLEAN = {
 "ctl359-skill-telemetry": "c4c0569ea41033df1cad6dd283fd8ed395766071",
 "ctl535-bash-redact": "ad5248298865aa13787aef6a0a577fa901c0c2a6",
 "ctl746-hookspath-reexec": "84b4f4b00d981b536eaae82e7baadc8828dab11c",
 "ctl878-gauntlet-progress": "2d5b8c0ef2187fbb371cdd24d690c5e0d2e538dc",
}
TASK = ("Review the pull request whose diff is in `pr.diff`. The repository at the pull request's head "
        "commit is the current working directory; read any file you need. Report the defects in the "
        "changed code, most serious first, each with its file and line.\n")
AGENT = ("Use the `mh:blind-spot-hunter` and `mh:silent-failure-hunter` agents (Agent tool, "
         "`subagent_type: \"mh:blind-spot-hunter\"` and `subagent_type: \"mh:silent-failure-hunter\"`), "
         "dispatched in parallel, to review the pull request whose diff is in `pr.diff`. The repository at "
         "the pull request's head commit is the current working directory. Give each agent that same "
         "information.\n\nReturn both agents' reports verbatim as your final message. Add nothing else.\n")
SHORT = ("\nReport only problems that are real in the material as written. If there are none, say so "
         "plainly and stop: do not add speculative concerns, optional suggestions or open questions.\n")

def git(*a, **k): return subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True, **k).stdout
if os.path.isdir(out): shutil.rmtree(out)
os.makedirs(out); os.makedirs(tars, exist_ok=True)
tar = subprocess.Popen(["git", "-C", repo, "archive", "HEAD"], stdout=subprocess.PIPE)
subprocess.check_call(["tar", "-x", "-C", out], stdin=tar.stdout); tar.wait()
m = os.path.join(out, ".claude-plugin", "plugin.json"); t = open(m).read()
assert t.count('"defaultEnabled": false') == 1
open(m, "w").write(t.replace('"defaultEnabled": false', '"defaultEnabled": true'))
for ag in glob.glob(os.path.join(out, "agents", "*.md")):
    t = open(ag).read(); open(ag, "w").write(re.sub(r"^model: .*$", "model: inherit", t, count=1, flags=re.M))
shutil.rmtree(os.path.join(out, "evals")); os.makedirs(os.path.join(out, "evals"))
cases = [(k, v[0], v[1] + X, "bug") for k, v in BUG.items()] + [(k, v, CLEAN_RULE, "ctl") for k, v in CLEAN.items()]
for name, merge, rule, group in cases:
    d = os.path.join(tars, name)
    if os.path.isdir(d): shutil.rmtree(d)
    os.makedirs(d)
    a = subprocess.Popen(["git", "-C", repo, "archive", merge + "^2"], stdout=subprocess.PIPE)
    subprocess.check_call(["tar", "-x", "-C", d], stdin=a.stdout); a.wait()
    for junk in ("CLAUDE.md", "AGENTS.md", ".claude", ".claude-plugin"):
        p = os.path.join(d, junk)
        shutil.rmtree(p) if os.path.isdir(p) else (os.remove(p) if os.path.exists(p) else None)
    open(os.path.join(d, "pr.diff"), "wb").write(git("diff", merge + "^1..." + merge + "^2", "--", ".", ":!.claude-plugin"))
    tb = os.path.join(tars, name + ".tar"); subprocess.check_call(["tar", "-cf", tb, "-C", d, "."])
    shutil.rmtree(d)
    for kind, text in (("agent", AGENT), ("plain", TASK), ("short", TASK + SHORT)):
        c = os.path.join(out, "evals", "%s-%s" % (name, kind)); os.makedirs(os.path.join(c, "graders"))
        open(os.path.join(c, "prompt.md"), "w").write("---\nname: %s-%s\ntags: [pr-%s, pr-%s-%s]\nruns: 3\nmax_turns: 40\ntimeout_seconds: 1200\n---\n%s" % (name, kind, kind, kind, group, text))
        open(os.path.join(c, "case.yaml"), "w").write('schema_version: "1.1"\nname: %s-%s\ncontext:\n  scaffold_script: scaffold.sh\n' % (name, kind))
        open(os.path.join(c, "scaffold.sh"), "w").write("#!/usr/bin/env bash\ntar -xf %s\n" % tb)
        open(os.path.join(c, "graders", "substance.md"), "w").write("---\ntype: llm\n---\n%s\n" % rule)
    print(name, os.path.getsize(tb) // 1024, "KB", len(git("diff", "--stat", merge + "^1..." + merge + "^2").splitlines()) - 1, "files")
