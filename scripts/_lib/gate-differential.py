#!/usr/bin/env python3
# Engine for scripts/gate-differential.sh (GH #411); call it through that wrapper, which
# resolves OLD, checks the slug and owns the temp dir. Python 3.9.
#
# Prints only diff classes, counts and up to 3 redacted, truncated sample commands per class:
# transcripts can hold secrets, so no other command text is ever printed.
import argparse, glob, io, json, os, random, re, shutil, subprocess, sys, time

TIMEOUT = 8  # hooks.json's timeout for every gate here; past it Claude Code blocks irrecoverable (onFailure: block)
# and lets the others through, so a timeout is its own class
SAMPLES, WIDTH = 3, 100
DEADLINES = {"irrecoverable": 4.0, "subagent-git-guard": 5.0}  # each gate's own deadline (GH #771, #469)
NEAR = 0.5  # a fork-mode time over half the deadline re-runs through bash (#889)
FORK_SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gate-fork-server.py")


def secret_patterns(gates_dir):
    # Reuse the live PATTERNS list: run secret-scan.py with an empty payload and read its globals.
    src_path = os.path.join(gates_dir, "secret-scan.py")
    ns = {"__name__": "secret_scan_patterns", "__file__": src_path}
    saved = sys.stdin
    sys.stdin = io.StringIO("{}")
    try:
        with open(src_path) as f:
            exec(compile(f.read(), src_path, "exec"), ns)
    except SystemExit:
        pass
    finally:
        sys.stdin = saved
    return [p for _, p, _ in ns["PATTERNS"]]


def redact(text, patterns, home):
    for p in patterns:
        text = p.sub("[REDACTED]", text)
    if home:
        text = text.replace(home, "~")
    text = text.replace("\n", "\\n")
    return text[:WIDTH] + ("..." if len(text) > WIDTH else "")


def fixture_cases(fixtures, gate):
    out = []
    for path in sorted(glob.glob(os.path.join(fixtures, gate + "-*.txt"))):
        with open(path) as f:
            lines = f.read().splitlines()
        if "%%" in lines:  # block format: "VERB ID desc", body lines, "%%"
            body, header = [], None
            for line in lines + ["%%"]:
                if line == "%%":
                    if body:
                        out.append("\n".join(body))
                    body, header = [], None
                elif header is None:
                    if line and not line.startswith("#"):
                        header = line
                else:
                    body.append(line)
        else:  # line format: "VERB cmd" or "WOULD_X rule cmd"
            for line in lines:
                if not line.strip() or line.startswith("#"):
                    continue
                n = 2 if line.startswith("WOULD_") else 1
                parts = line.split(None, n)
                if len(parts) > n:
                    out.append(parts[n])
    return out


def secret_seed(rng):
    # Built at run time, so this file never holds a live-shaped token.
    an = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
    def r(n, chars=an):
        return "".join(rng.choice(chars) for _ in range(n))
    toks = ["AKIA" + r(16, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"), "sk-ant-api03-" + r(40),
            "sk-proj-" + r(20) + "T3Blbk" + "FJ" + r(20), "gh" + "p_" + r(36), "github_" + "pat_" + r(82),
            "gl" + "pat-" + r(20), "hf_" + r(34), "xo" + "xb-" + r(12, "0123456789") + "-" + r(12, "0123456789") + "-" + r(24),
            "sk_" + "live_" + r(24), "AI" + "za" + r(35), "np" + "m_" + r(36), "pypi-AgEIcHlwaS5vcmc" + r(50)]
    cases = ["token=" + t for t in toks]
    cases += ["AKIA" + "IOSFODNN7EXAMPLE", "token=" + toks[3] + "  # gitleaks:allow", "plain text, no token"]
    return cases


def replay_cases(projects, own_slug, slug, gate):
    dirs = [os.path.join(projects, slug)] if slug else [
        os.path.join(projects, d) for d in sorted(os.listdir(projects))
        if d == own_slug or d.startswith(own_slug + "--claude-worktrees-")] if os.path.isdir(projects) else []
    seen, bad = set(), 0
    for d in dirs:
        for path in glob.glob(os.path.join(d, "**", "*.jsonl"), recursive=True):
            try:
                f = open(path, errors="replace")
            except OSError:
                bad += 1
                continue
            with f:
                for line in f:
                    if '"tool_use"' not in line:
                        continue
                    try:
                        content = json.loads(line).get("message", {}).get("content")
                    except ValueError:
                        bad += 1
                        continue
                    if not isinstance(content, list):
                        continue
                    for b in content:
                        if not isinstance(b, dict) or b.get("type") != "tool_use":
                            continue
                        inp = b.get("input") or {}
                        if gate == "secret-scan":
                            text = inp.get("content") if b.get("name") == "Write" else (
                                inp.get("new_string") if b.get("name") == "Edit" else None)
                        else:
                            text = inp.get("command") if b.get("name") == "Bash" else None
                        if isinstance(text, str) and text:
                            seen.add(text)
    return sorted(seen), len(dirs), bad


def fuzz(corpus, seed):
    # ponytail: a handful of fixed shell rewrites, not a grammar fuzzer; write a generator per shape
    # (repo-gotchas "Changing a deny heuristic") when a change needs more than these.
    rng = random.Random(seed)
    ops = [lambda c: "sudo " + c, lambda c: "env X=1 " + c, lambda c: "{ " + c + "; }",
           lambda c: c.replace(" ", "${IFS}", 1), lambda c: c.replace(" ", "  \\\n  ", 1),
           lambda c: "''" + c, lambda c: c[:1] + "''" + c[1:], lambda c: "eval '" + c.replace("'", "'\\''") + "'",
           lambda c: "echo \"$(" + c + ")\"", lambda c: "true && " + c, lambda c: c + " # " + c[::-1]]
    if not corpus:
        return []
    return [rng.choice(ops)(rng.choice(corpus)) for _ in range(200)]


def payload(gate, text):
    if gate == "secret-scan":
        return {"tool_name": "Write", "tool_input": {"file_path": "differential.txt", "content": text},
                "session_id": "gate-differential"}
    d = {"tool_name": "Bash", "tool_input": {"command": text}, "session_id": "gate-differential"}
    if gate == "subagent-git-guard":
        d["agent_id"], d["agent_type"] = "gate-differential", "general-purpose"
    return d


def canonical_env(home):
    # GH #888: the result must not depend on who runs the replay. Gate knobs (MH_IRR_DEADLINE_SECS,
    # MH_IRR_BUDGET_SCALE, MH_SGG_*, MH_GATE_BATCH_BUDGET_S, MH_GATE_NO_FASTPATH) and GIT_* (GIT_DIR can
    # point irrecoverable's mid-merge check at the caller's repo) never reach the gates.
    env = {k: v for k, v in os.environ.items() if not k.startswith(("MH_", "GIT_"))}
    env.pop("CLAUDE_PLUGIN_ROOT", None)
    env["HOME"] = home
    return env


def canonical_cwd(tmp, env):
    # GH #888: a fresh dir outside any git repo, so a caller checkout that is mid-merge cannot turn
    # irrecoverable's `git add -A` deny into an allow (its _mid_merge asks git in the cwd).
    cwd = os.path.join(tmp, "cwd")
    os.makedirs(cwd, exist_ok=True)
    try:
        r = subprocess.run(["git", "rev-parse", "--git-dir"], cwd=cwd, env=env, capture_output=True)
        inside = r.returncode == 0
    except OSError:
        inside = False  # no git: _mid_merge's own check fails the same way
    if inside:
        print("gate-differential: the replay dir %s is inside a git repo; set TMPDIR outside one" % cwd, file=sys.stderr)
        sys.exit(2)
    return cwd


def finish(gates_dir, code, out, err, journal, secs):
    rows = []
    with open(journal) as f:
        for line in f:
            row = json.loads(line)
            row.pop("ts", None)
            row.pop("mh_version", None)
            rows.append(row)
    err = err.replace(gates_dir.encode(), b"<GATES>")
    return code, out, err, rows, secs


class BashRunner:
    # The real path: `bash <gate>.sh`, as hooks.json runs it.

    def __init__(self, gates_dir, gate, env, journal, cwd):
        self.gates_dir, self.gate, self.env, self.journal, self.cwd = gates_dir, gate, env, journal, cwd

    def run(self, data):
        open(self.journal, "w").close()
        t0 = time.monotonic()
        try:
            p = subprocess.run(["bash", os.path.join(self.gates_dir, self.gate + ".sh")], input=data,
                               capture_output=True, env=self.env, cwd=self.cwd, timeout=TIMEOUT)
            code, out, err = str(p.returncode), p.stdout, p.stderr
        except subprocess.TimeoutExpired:
            code, out, err = "timeout", b"", b""
        return finish(self.gates_dir, code, out, err, self.journal, time.monotonic() - t0)

    def close(self):
        pass


class ServerDied(Exception):
    pass


class ForkRunner:
    # GH #889: one scripts/_lib/gate-fork-server.py per side, run by the wrapper's own `python3 -S`.

    def __init__(self, gates_dir, gate, env, journal, cwd, work):
        self.gates_dir, self.journal, self.work = gates_dir, journal, work
        os.makedirs(work, exist_ok=True)
        py = shutil.which("python3", path=env.get("PATH", os.defpath))
        if not py:
            raise ServerDied("no python3 on the gates' PATH")
        self.files = {k: os.path.join(work, k) for k in ("in", "out", "err")}
        self.server_err = open(os.path.join(work, "server.err"), "wb")
        self.p = subprocess.Popen([py, "-S", FORK_SERVER, gates_dir, gate], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=self.server_err, env=env, cwd=cwd)
        if self.p.stdout.readline() != b"ready\n":
            raise ServerDied(self.died())

    def died(self):
        self.close()
        with open(os.path.join(self.work, "server.err"), errors="replace") as f:
            tail = f.read()[-300:].strip().replace("\n", " | ")
        return "fork server exited (rc=%s)%s" % (self.p.returncode, ": " + tail if tail else "")

    def run(self, data):
        open(self.journal, "w").close()
        with open(self.files["in"], "wb") as f:
            f.write(data)
        try:
            self.p.stdin.write((json.dumps(self.files) + "\n").encode())
            self.p.stdin.flush()
            reply = self.p.stdout.readline()
        except OSError:
            reply = b""
        if not reply:
            raise ServerDied(self.died())
        r = json.loads(reply)
        with open(self.files["out"], "rb") as f:
            out = f.read()
        with open(self.files["err"], "rb") as f:
            err = f.read()
        code = r["code"] if r["code"] == "timeout" else str(r["code"])
        if code == "timeout":
            out, err = b"", b""
        return finish(self.gates_dir, code, out, err, self.journal, r["secs"])

    def close(self):
        if self.p.poll() is None:
            try:
                self.p.stdin.close()
            except OSError:
                pass
            try:
                self.p.wait(timeout=TIMEOUT + 2)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
        self.server_err.close()


def fork_blocker(old, new, gate):
    # GH #889: fork mode skips the wrapper, which is sound only while both sides run the same wrapper:
    # it hands python the payload unchanged, so then fork mode can add diffs but never hide one. Every
    # gates-dir file the wrapper text names (its awk, _run.py, ...) must be byte-identical, apart from
    # the gate's own .py. Returns why fork mode cannot run, or None.
    sh = gate + ".sh"
    texts = []
    for d in (old, new):
        with open(os.path.join(d, sh), "rb") as f:
            texts.append(f.read())
    if not all(b"_run.py" in t for t in texts):
        return "the wrapper does not run the gate through _run.py"
    names = {sh}
    for d in (old, new):
        for f in os.listdir(d):
            if f != gate + ".py" and os.path.isfile(os.path.join(d, f)) and any(f.encode() in t for t in texts):
                names.add(f)

    def content(d, f):
        try:
            with open(os.path.join(d, f), "rb") as h:
                return h.read()
        except OSError:
            return None
    differ = sorted(f for f in names if content(old, f) != content(new, f))
    return "wrapper files differ: " + ", ".join(differ) if differ else None


def journal_sig(rows):
    return ",".join(r.get("decision", "?") + (":" + r["rule"] if r.get("rule") else "") for r in rows) or "none"


def diff_class(o, n):
    parts = []
    if o[0] != n[0]:
        parts.append("exit %s->%s" % (o[0], n[0]))
    if o[1] != n[1]:
        parts.append("stdout")
    if o[2] != n[2]:
        parts.append("stderr")
    if o[3] != n[3]:
        parts.append("journal %s->%s" % (journal_sig(o[3]), journal_sig(n[3])))
    return " | ".join(parts)


def main():
    ap = argparse.ArgumentParser()
    for a in ("--old", "--new", "--gate", "--tmp", "--projects", "--own-slug", "--fixtures"):
        ap.add_argument(a, required=True)
    ap.add_argument("--replay", type=int, default=0)
    ap.add_argument("--cases")
    ap.add_argument("--slug")
    ap.add_argument("--fuzz-seed")
    ap.add_argument("--runner", choices=("auto", "fork", "bash"), default="auto")
    a = ap.parse_args()

    if a.cases:
        with open(a.cases) as f:
            base = [line for line in f.read().splitlines() if line.strip()]
    elif a.gate == "secret-scan":
        base = secret_seed(random.Random(0))
    else:
        base = fixture_cases(a.fixtures, a.gate)
    replay, ndirs, bad = [], 0, 0
    if a.replay:
        pool, ndirs, bad = replay_cases(a.projects, a.own_slug, a.slug, a.gate)
        replay = random.Random(a.fuzz_seed or 0).sample(pool, min(a.replay, len(pool)))
    fz = fuzz(base + replay, a.fuzz_seed) if a.fuzz_seed is not None else []
    corpus = list(dict.fromkeys(base + replay + fz))

    home = os.path.join(a.tmp, "home")
    os.makedirs(home, exist_ok=True)
    env = canonical_env(home)
    cwd = canonical_cwd(a.tmp, env)
    jo, jn = os.path.join(a.tmp, "old.jsonl"), os.path.join(a.tmp, "new.jsonl")
    env_o, env_n = dict(env, MH_GATE_JOURNAL_PATH=jo), dict(env, MH_GATE_JOURNAL_PATH=jn)
    # Both sides: a change that drops a pattern must not unredact the commands it now misses.
    patterns = secret_patterns(a.old) + secret_patterns(a.new)
    real_home = os.environ.get("HOME", "")
    deadline = DEADLINES.get(a.gate)

    bash = (BashRunner(a.old, a.gate, env_o, jo, cwd), BashRunner(a.new, a.gate, env_n, jn, cwd))
    fork, why = None, "forced by --runner bash" if a.runner == "bash" else fork_blocker(a.old, a.new, a.gate)
    if not why:
        started = []
        try:
            for side, d, e, j in (("old", a.old, env_o, jo), ("new", a.new, env_n, jn)):
                started.append(ForkRunner(d, a.gate, e, j, cwd, os.path.join(a.tmp, "fork-" + side)))
            fork = tuple(started)
        except ServerDied as e:
            why = str(e)
            for r in started:
                r.close()
    dropped = near = 0

    def pair(runners, data):
        return runners[0].run(data), runners[1].run(data)

    def measure(data):
        # -> (old result, new result, the runners that gave them)
        nonlocal fork, why, dropped, near
        if fork:
            try:
                o, n = pair(fork, data)
            except ServerDied as e:
                why = "%s; bash from that command on" % e
                for r in fork:
                    r.close()
                fork = None
            else:
                if deadline and max(o[4], n[4]) > NEAR * deadline:
                    near += 1  # near the deadline, load decides: only the real path's result counts
                    return pair(bash, data) + (bash,)
                if diff_class(o, n):  # every fork diff is confirmed through the real path, or dropped
                    o, n = pair(bash, data)
                    dropped += not diff_class(o, n)
                    return o, n, bash
                return o, n, fork
        return pair(bash, data) + (bash,)

    classes = {}
    for text in corpus:
        data = json.dumps(payload(a.gate, text)).encode()
        o, n, _ = measure(data)
        name = diff_class(o, n)
        if name:
            classes.setdefault(name, []).append(text)
    for r in bash + (fork or ()):
        r.close()

    total = sum(len(v) for v in classes.values())
    print("gate-differential: %s corpus=%d (base=%d replay=%d fuzz=%d) diffs=%d classes=%d"
          % (a.gate, len(corpus), len(base), len(replay), len(fz), total, len(classes)))
    if fork:
        print("  runner: fork (fork-only diffs dropped: %d, near-deadline re-runs: %d)" % (dropped, near))
    else:
        print("  runner: bash (%s)" % why)
    if a.replay:
        print("  transcript dirs read: %d, unreadable lines/files skipped: %d" % (ndirs, bad))
    for name, texts in sorted(classes.items(), key=lambda kv: -len(kv[1])):
        print("  [%d] %s" % (len(texts), name))
        for t in texts[:SAMPLES]:
            print("      - " + redact(t, patterns, real_home))
    return 1 if classes else 0


if __name__ == "__main__":
    sys.exit(main())
