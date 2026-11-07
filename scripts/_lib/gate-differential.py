#!/usr/bin/env python3
# Engine for scripts/gate-differential.sh (GH #411); call it through that wrapper, which
# resolves OLD, checks the slug and owns the temp dir. Python 3.9.
#
# Prints only diff classes, counts and up to 3 redacted, truncated sample commands per class:
# transcripts can hold secrets, so no other command text is ever printed.
import argparse, collections, contextlib, glob, hashlib, io, json, os, random, re, select, shutil, signal, subprocess, sys, time
from typing import NoReturn

TIMEOUT = 8  # hooks.json's timeout for every gate here; past it Claude Code blocks irrecoverable (onFailure: block)
# and lets the others through, so a timeout is its own class
SAMPLES, WIDTH = 3, 100
DEADLINES = {"irrecoverable": 4.0, "subagent-git-guard": 5.0}  # each gate's own deadline (GH #771, #469)
NEAR = 0.5  # a fork-mode time over half the deadline re-runs through bash (#889) and marks a slowdown (#890)
SLOWER_RATIO, SLOWER_MIN_SECS = 3.0, 0.2  # GH #890: 3x the old time and at least 200 ms
READY_SECS = 30  # python start-up plus the warm-up, once per run, under renice 19 and gauntlet load
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
    # GH #893: a cached old-side row must not depend on the caller's shell or interpreter either: BASH_ENV and
    # ENV are sourced by bash, PYTHON* steers python, and the locale changes sort and match results.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("MH_", "GIT_", "PYTHON", "LC_")) and k not in ("BASH_ENV", "ENV", "LANG", "LANGUAGE")}
    env.pop("CLAUDE_PLUGIN_ROOT", None)
    env["HOME"] = home
    env["LC_ALL"] = "C"
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


# out, err and rows hold sha256 hex digests (GH #893), never the text: journal rows carry the command, so the
# cache can keep a Result as it is. sig is journal_sig of the rows, for the diff class name. skip: the cache
# must not store this result (a timeout or a time-limit verdict says how loaded the machine was, not what the gate decides).
Result = collections.namedtuple("Result", "code out err rows secs sig skip")
# The gates' time-limit texts: irrecoverable's batch ask ("time budget ran out", journaled with no rule),
# its deadline ask ("ran out of time"), subagent-git-guard's deny ("time limit", journaled with no rule).
TIME_LIMIT = re.compile(rb"time limit|time budget|ran out of time")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def finish(gates_dir, code, out, err, journal, secs):
    rows = []
    with open(journal) as f:
        for line in f:
            row = json.loads(line)
            row.pop("ts", None)
            row.pop("mh_version", None)
            rows.append(row)
    err = err.replace(gates_dir.encode(), b"<GATES>")
    killed = code.lstrip("-").isdigit() and (int(code) < 0 or int(code) >= 128)  # a signal: load, not a verdict
    skip = code == "timeout" or killed or any(r.get("rule") == "deadline" for r in rows) or bool(TIME_LIMIT.search(out + b"\n" + err))
    digests = tuple(sha(json.dumps(r, sort_keys=True).encode()) for r in rows)
    return Result(code, sha(out), sha(err), digests, secs, journal_sig(rows), skip)


class BashRunner:
    # The real path: `bash <gate>.sh`, as hooks.json runs it.

    def __init__(self, gates_dir, gate, env, journal, cwd):
        self.gates_dir, self.gate, self.env, self.journal, self.cwd = gates_dir, gate, env, journal, cwd

    def run(self, data):
        open(self.journal, "w").close()
        t0 = time.monotonic()
        # Its own process group, so a timeout kills the gate's own children (git) too, not just bash.
        p = subprocess.Popen(["bash", os.path.join(self.gates_dir, self.gate + ".sh")], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, cwd=self.cwd,
                             start_new_session=True)
        try:
            out, err = p.communicate(data, timeout=TIMEOUT)
            code = str(p.returncode)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                # ESRCH: the group is gone; EPERM on macOS: its only member is the unreaped bash. Kill bash
                # itself.
                p.kill()
            try:
                p.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                # communicate() waits for the pipes to close, and a grandchild in its own session (out of
                # the killed group) can hold them open: stop reading instead of waiting on it.
                p.stdout.close()
                p.stderr.close()
                p.wait()
            code, out, err = "timeout", b"", b""
        return finish(self.gates_dir, code, out, err, self.journal, time.monotonic() - t0)

    def close(self):
        pass


class ServerDied(Exception):
    pass


class NoGroup(Exception):
    # The fork child could not lead its own process group: this one command goes through bash.
    pass


class ForkRunner:
    # GH #889: one scripts/_lib/gate-fork-server.py per side, run by the wrapper's own `python3 -S`.
    # Every read from the server is bounded: a hung server falls back to bash, never hangs the replay.

    def __init__(self, gates_dir, gate, env, journal, cwd, work):
        self.gates_dir, self.journal, self.work = gates_dir, journal, work
        os.makedirs(work, exist_ok=True)
        py = shutil.which("python3", path=env.get("PATH", os.defpath))
        if not py:
            raise ServerDied("no python3 on the gates' PATH")
        self.files = {k: os.path.join(work, k) for k in ("in", "out", "err")}
        self.server_err = open(os.path.join(work, "server.err"), "wb")
        self.p = subprocess.Popen([py, "-S", FORK_SERVER, gates_dir, gate, str(TIMEOUT)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=self.server_err, env=env, cwd=cwd, bufsize=0)
        # The warm-up runs a few allowing commands in the server itself, with no deadline of its own.
        if self.line(READY_SECS) != b"ready\n":
            raise ServerDied(self.died())

    def line(self, secs):
        # One reply line within secs, else b"" (the server sends each line in one write).
        fd, buf, end = self.p.stdout.fileno(), b"", time.monotonic() + secs
        while not buf.endswith(b"\n"):
            left = end - time.monotonic()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                return b""
            chunk = os.read(fd, 4096)
            if not chunk:
                return b""
            buf += chunk
        return buf

    def died(self, what=None):
        what = what or ("exited (rc=%s)" % self.p.returncode if self.p.poll() is not None else "did not answer in time")
        self.close()
        with open(os.path.join(self.work, "server.err"), errors="replace") as f:
            tail = f.read()[-300:].strip().replace("\n", " | ")
        return "fork server %s%s" % (what, ": " + tail if tail else "")

    def run(self, data):
        open(self.journal, "w").close()
        with open(self.files["in"], "wb") as f:
            f.write(data)
        try:
            self.p.stdin.write((json.dumps(self.files) + "\n").encode())
            reply = self.line(TIMEOUT + 5)  # the server itself kills a child at TIMEOUT
        except OSError:
            reply = b""
        if not reply:
            raise ServerDied(self.died())
        try:
            r = json.loads(reply)
            code, secs = str(r["code"]), float(r["secs"])
        except (ValueError, TypeError, KeyError):  # a garbled reply is a broken server, never a result
            raise ServerDied(self.died("sent a garbled reply"))
        if code == "setup-failed":  # alike on both sides it would read as no diff: never a result
            raise ServerDied(self.died("could not set up a child"))
        if code == "no-group":
            raise NoGroup()
        with open(self.files["out"], "rb") as f:
            out = f.read()
        with open(self.files["err"], "rb") as f:
            err = f.read()
        if code == "timeout":
            out, err = b"", b""
        return finish(self.gates_dir, code, out, err, self.journal, secs)

    def close(self):
        # EOF on stdin ends a healthy server; SIGTERM makes a hung one kill its child's group first.
        if self.p.poll() is None:
            try:
                self.p.stdin.close()
            except OSError:
                pass
            for stop in (None, self.p.terminate, self.p.kill):
                if stop:
                    stop()
                try:
                    self.p.wait(timeout=2)
                    break
                except subprocess.TimeoutExpired:
                    pass
        self.server_err.close()


def bucket_id(gate, closure, tool, mode, versions):
    # GH #893: one cache file per (gate, old side's wide closure, this engine's hash, runner mode, tool versions).
    # Inside it a row is keyed by the sha256 of the payload sent to the gate.
    spec = json.dumps([gate, closure, tool, mode, sorted(versions.items())])
    return sha(spec.encode())[:32]


def tool_versions(env):
    # The gates run with the canonical env's PATH: that PATH's python3, bash, awk, sed, git and tr decide the verdicts.
    # A BSD sed or tr has no --version and prints the same usage error after an in-place update, so a failed
    # --version adds the binary's content hash to the value.
    out = {}
    # git: irrecoverable's _mid_merge; tr: the fast path in irrecoverable.sh and _silent_fastpath.sh.
    for tool in ("python3", "bash", "awk", "sed", "git", "tr"):
        exe = shutil.which(tool, path=env.get("PATH", os.defpath))
        if not exe:
            out[tool] = "none"
            continue
        try:
            r = subprocess.run([exe, "--version"], env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
            first = (r.stdout + r.stderr).decode(errors="replace").splitlines()[:1]
            out[tool] = os.path.realpath(exe) + " " + (first[0] if first else "")
            if r.returncode != 0:
                with open(exe, "rb") as f:
                    out[tool] += " sha256:" + hashlib.sha256(f.read()).hexdigest()
        except (OSError, subprocess.TimeoutExpired) as e:
            out[tool] = "%s unknown (%s)" % (exe, type(e).__name__)
    return out


class Cache:
    # GH #893: the old (develop) side's results, for review-round replays only. Opt-in (--cache); a cached
    # run never writes a replay record (replay_record); the replay before merge runs with --no-cache. Values:
    # exit code and digests, never command text. A row is a JSON line in <dir>/<gate>-<bucket>.jsonl.
    KEYS = {"k", "code", "out", "err", "rows", "sig"}

    def __init__(self, d, gate, old_files, env):
        self.dir, self.gate, self.env = d, gate, env
        self.closure = gate_closure().wide(old_files, gate)
        here = os.path.dirname(os.path.abspath(__file__))
        src = []
        for n in ("gate-differential.py", "gate-fork-server.py"):  # the engine and the fork server both shape a result
            with open(os.path.join(here, n), "rb") as f:
                src.append(f.read())
        self.tool = sha(b"".join(src))
        self.versions = tool_versions(env)
        self.hits = self.stored = self.skipped = self.bad = 0
        self.bypass = False
        try:
            os.makedirs(os.path.dirname(d), exist_ok=True)  # parents keep the default mode; only the cache dir is private
            os.makedirs(d, mode=0o700, exist_ok=True)
            st = os.stat(d)
        except OSError as e:
            cache_fail("cannot open the cache dir %s: %s" % (d, e))
        if st.st_uid != os.getuid() or st.st_mode & 0o022:
            cache_fail("the cache dir %s must be yours and not group- or world-writable" % d)

    @contextlib.contextmanager
    def bypassed(self):
        # A timing re-run needs a real old-side time: no lookups, no stores.
        self.bypass = True
        try:
            yield
        finally:
            self.bypass = False

    def wrap(self, runner, mode):
        path = os.path.join(self.dir, "%s-%s.jsonl" % (self.gate, bucket_id(self.gate, self.closure, self.tool, mode, self.versions)))
        rows = {}
        torn = False
        if os.path.lexists(path):
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                st = os.fstat(fd)
                if st.st_uid != os.getuid() or st.st_mode & 0o022:
                    os.close(fd)
                    cache_fail("the cache file %s must be yours and not group- or world-writable" % path)
                f = os.fdopen(fd, "rb")
            except OSError as e:
                cache_fail("cannot read the cache file %s: %s" % (path, e))
            with f:
                for line in f:
                    torn = not line.endswith(b"\n")
                    r = None
                    try:
                        r = json.loads(line)
                        ok = (isinstance(r, dict) and set(r) == self.KEYS and isinstance(r["code"], str) and isinstance(r["sig"], str)
                              and all(isinstance(r[k], str) and len(r[k]) == 64 for k in ("k", "out", "err"))
                              and isinstance(r["rows"], list) and all(isinstance(x, str) for x in r["rows"]))
                    except ValueError:
                        ok = False
                    if ok and r:
                        rows[r["k"]] = r
                    else:
                        self.bad += 1  # a torn last line from a killed run, or a hand edit: a miss, counted
        return CachingRunner(runner, self, path, rows, torn)


def cache_fail(msg) -> NoReturn:
    # Exit 1 means "diffs found", so a broken cache is a usage-class error: exit 2.
    print("gate-differential: " + msg, file=sys.stderr)
    sys.exit(2)


def gate_closure():
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import gate_closure as g
    return g


class CachingRunner:
    # Wraps the OLD side's runner. A hit has secs 0.0: no old time exists, so is_slower flags the command and
    # the timing re-run (Cache.bypassed) measures both sides for real.
    def __init__(self, inner, cache, path, rows, torn=False):
        self.inner, self.cache, self.path, self.rows = inner, cache, path, rows
        self.torn = torn  # the file ends mid-row (a killed run): the next append starts on a new line

    def run(self, data):
        c = self.cache
        if c.bypass:
            return self.inner.run(data)
        k = sha(data)
        hit = self.rows.get(k)
        if hit:
            c.hits += 1
            return Result(hit["code"], hit["out"], hit["err"], tuple(hit["rows"]), 0.0, hit["sig"], False)
        r = self.inner.run(data)
        if r.skip:
            c.skipped += 1
            return r
        row = {"k": k, "code": r.code, "out": r.out, "err": r.err, "rows": list(r.rows), "sig": r.sig}
        # One write() of one line to an O_APPEND fd: two replays on one cache cannot interleave a row.
        line = (("\n" if self.torn else "") + json.dumps(row) + "\n").encode()
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                if os.write(fd, line) != len(line):
                    cache_fail("short write to the cache file %s" % self.path)
            finally:
                os.close(fd)
        except OSError as e:
            cache_fail("cannot write the cache file %s: %s" % (self.path, e))
        self.torn = False
        self.rows[k] = row
        c.stored += 1
        return r

    def close(self):
        self.inner.close()


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
    if o.code != n.code:
        parts.append("exit %s->%s" % (o.code, n.code))
    if o.out != n.out:
        parts.append("stdout")
    if o.err != n.err:
        parts.append("stderr")
    if o.rows != n.rows:
        parts.append("journal %s->%s" % (o.sig, n.sig))
    return " | ".join(parts)


def is_slower(old_secs, new_secs, deadline):
    # GH #890, times from one run and one runner only. The work-count criterion of #890 waits for a gate
    # that exposes its count; none does yet.
    if deadline and new_secs > NEAR * deadline and not old_secs > NEAR * deadline:
        return True
    return new_secs >= SLOWER_RATIO * old_secs and new_secs >= SLOWER_MIN_SECS


def replay_record(a, pool, replay, corpus, diffs, slower, cached):
    # GH #891: scripts/merge-pr.sh merges a gate change only with this record for the gate's closure. Only a
    # whole-pool run counts: every command of every transcript dir of this project, so no --slug. A cached
    # run (GH #893, operator rule 2026-11-04) never writes one: the cache dir is writable locally, so only a
    # run that executed the old side proves the replay. Counts only, no command text.
    if cached:
        return "none (a cached run never writes a record; run with --no-cache, which is the default)"
    if a.slug or not pool or len(replay) < len(pool):
        return "none (a record needs the whole pool: --replay all, no --slug; this run replayed %d of %d)" % (
            len(replay), len(pool))
    c = a.new_closure  # hashed when main() took the snapshot, before any run
    d = os.environ.get("GATE_REPLAY_RECORD_DIR") or os.path.join(os.path.expanduser("~"), ".cache", "mh", "gate-replay")
    path = os.path.join(d, "%s-%s.json" % (a.gate, c))
    rec = {"gate": a.gate, "closure": c, "full": True, "pool": len(pool), "replay": len(replay), "corpus": len(corpus),
           "diffs": diffs, "slower": slower, "cache": False, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        os.makedirs(d, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(rec, f)
        os.replace(tmp, path)
    except OSError as e:
        return "NOT written (%s); merge-pr.sh will refuse this gate change" % e
    return "written %s" % path


def main():
    ap = argparse.ArgumentParser()
    for a in ("--old", "--new", "--gate", "--tmp", "--projects", "--own-slug", "--fixtures"):
        ap.add_argument(a, required=True)
    ap.add_argument("--replay", default="0")  # a count, or "all" (GH #891)
    ap.add_argument("--cases")
    ap.add_argument("--slug")
    ap.add_argument("--fuzz-seed")
    ap.add_argument("--runner", choices=("auto", "fork", "bash"), default="auto")
    ap.add_argument("--cache", action="store_true")  # GH #893: opt-in; --no-cache wins
    ap.add_argument("--no-cache", action="store_true")
    a = ap.parse_args()
    use_cache = a.cache and not a.no_cache
    # The runners start in a temp cwd: a relative dir would run nothing (exit 127 on that side) and read as 0 diffs.
    a.old = os.path.abspath(a.old)
    # Run NEW from a snapshot: an edit to the real dir during a long replay must not reach the runs or the
    # closure the replay record names (the gates import their siblings, so the whole dir is copied; a symlink
    # is copied as its target, since a relative one would break in the new place). The closure is hashed
    # here, before any run, so not even a gate that rewrites its own snapshot file changes what it names.
    snap = os.path.join(os.path.abspath(a.tmp), "new-snapshot")
    # A dangling link (an editor's lock file) is skipped, as from_dir skips links, instead of failing the copy.
    # Not ignore_dangling_symlinks: it tests a relative link's text against the cwd, so it drops live ones too.
    # __pycache__ is left out too: a stale .pyc whose mtime and size still match the source would run old code.
    skip = lambda d, names: [n for n in names if n == "__pycache__" or (os.path.islink(os.path.join(d, n))
                                                                       and not os.path.exists(os.path.join(d, n)))]
    shutil.copytree(os.path.abspath(a.new), snap, ignore=skip)
    a.new = snap
    if a.replay != "0":  # only a replay run can write a record
        g = gate_closure()
        a.new_closure = g.closure(g.from_dir(a.new), a.gate)

    if a.cases:
        with open(a.cases) as f:
            base = [line for line in f.read().splitlines() if line.strip()]
    elif a.gate == "secret-scan":
        base = secret_seed(random.Random(0))
    else:
        base = fixture_cases(a.fixtures, a.gate)
    replay, ndirs, bad, pool = [], 0, 0, []
    want = a.replay if a.replay == "all" else int(a.replay)
    if want:
        pool, ndirs, bad = replay_cases(a.projects, a.own_slug, a.slug, a.gate)
        replay = random.Random(a.fuzz_seed or 0).sample(pool, len(pool) if want == "all" else min(want, len(pool)))
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

    cache = None
    if use_cache:
        d = os.environ.get("GATE_REPLAY_CACHE_DIR") or os.path.join(os.path.expanduser("~"), ".cache", "mh", "gate-replay-cache")
        try:
            cache = Cache(d, a.gate, gate_closure().from_dir(a.old), env)
        except OSError as e:
            print("gate-differential: --cache: cannot use the cache dir %s (%s); run without --cache" % (d, e), file=sys.stderr)
            sys.exit(2)

    def cached_old(runner, mode):
        return cache.wrap(runner, mode) if cache else runner

    bash = (cached_old(BashRunner(a.old, a.gate, env_o, jo, cwd), "bash"), BashRunner(a.new, a.gate, env_n, jn, cwd))
    fork, why = None, "forced by --runner bash" if a.runner == "bash" else fork_blocker(a.old, a.new, a.gate)
    if not why:
        started = []
        try:
            for side, d, e, j in (("old", a.old, env_o, jo), ("new", a.new, env_n, jn)):
                started.append(ForkRunner(d, a.gate, e, j, cwd, os.path.join(a.tmp, "fork-" + side)))
            fork = (cached_old(started[0], "fork"), started[1])
        except ServerDied as e:
            why = str(e)
            for r in started:
                r.close()
    def refuse(reason):
        print("gate-differential: --runner fork: fork mode cannot run (%s)" % reason, file=sys.stderr)
        sys.exit(2)

    if why and a.runner == "fork":
        refuse(why)
    fork_started, dropped, near, nogroup = fork is not None, [], 0, 0

    def fork_failed(e):
        # The rest of the run goes through bash; --runner fork asked for fork mode only, so it stops.
        nonlocal fork, why
        for r in fork or ():
            r.close()
        fork, why = None, "%s; bash from that command on" % e
        if a.runner == "fork":
            refuse(e)

    def pair(runners, data):
        return runners[0].run(data), runners[1].run(data)

    def on_fork(data):
        # -> both results through fork mode, or None when this command must go through bash instead
        nonlocal nogroup
        try:
            return pair(fork, data)
        except NoGroup:
            nogroup += 1
            if a.runner == "fork":  # fork mode only: a command it cannot run stops the run (PR #899)
                for r in fork:
                    r.close()
                refuse("a child could not lead its own process group")
        except ServerDied as e:
            fork_failed(e)
        return None

    def measure(text, data):
        # -> (old result, new result, the runners that gave them)
        nonlocal near
        if fork:
            r = on_fork(data)
            if r:
                o, n = r
                if deadline and max(o.secs, n.secs) > NEAR * deadline:
                    near += 1  # near the deadline, load decides: only the real path's result counts
                    return pair(bash, data) + (bash,)
                if diff_class(o, n):  # every fork diff is confirmed through the real path, or dropped
                    o, n = pair(bash, data)
                    if not diff_class(o, n):
                        dropped.append(text)
                    return o, n, bash
                return o, n, fork
        return pair(bash, data) + (bash,)

    classes, slower = {}, []
    for text in corpus:
        data = json.dumps(payload(a.gate, text)).encode()
        o, n, runners = measure(text, data)
        name = diff_class(o, n)
        if name:
            classes.setdefault(name, []).append(text)
        if is_slower(o.secs, n.secs, deadline):
            # once more, both sides on one runner: a load spike must not count. A cached old side has no
            # time, so this run bypasses the cache (GH #893).
            with cache.bypassed() if cache else contextlib.nullcontext():
                r = on_fork(data) if runners is not bash and fork else None
                o, n = r or pair(bash, data)
            if is_slower(o.secs, n.secs, deadline):
                slower.append((text, o.secs, n.secs))
    for r in bash + (fork or ()):
        r.close()

    total = sum(len(v) for v in classes.values())
    print("gate-differential: %s corpus=%d (base=%d replay=%d fuzz=%d) diffs=%d slower=%d classes=%d"
          % (a.gate, len(corpus), len(base), len(replay), len(fz), total, len(slower), len(classes)))
    counts = "fork-only diffs dropped: %d, near-deadline re-runs: %d" % (len(dropped), near)
    if nogroup:
        counts += ", no-own-group re-runs: %d" % nogroup
    if fork:
        print("  runner: fork (%s)" % counts)
    else:
        print("  runner: bash (%s%s)" % (why, "; before that, " + counts if fork_started else ""))
    # A fork-only diff is how a gap in the wrapper's fast-path token list shows: name the first few.
    for t in dropped[:SAMPLES]:
        print("      - " + redact(t, patterns, real_home))
    if cache:
        print("  cache: %d hits, %d stored, %d not storable (timeouts and time-limit verdicts)%s" % (
            cache.hits, cache.stored, cache.skipped, ", %d unreadable rows ignored" % cache.bad if cache.bad else ""))
    if want:
        print("  transcript dirs read: %d, unreadable lines/files skipped: %d" % (ndirs, bad))
        print("  replay record: " + replay_record(a, pool, replay, corpus, total, len(slower), bool(cache)))
    for name, texts in sorted(classes.items(), key=lambda kv: -len(kv[1])):
        print("  [%d] %s" % (len(texts), name))
        for t in texts[:SAMPLES]:
            print("      - " + redact(t, patterns, real_home))
    if slower:
        print("  slower: %d (new time over %g%% of the %s s deadline, or %gx the old and %g s or more; re-run once)"
              % (len(slower), NEAR * 100, format(deadline, "g") if deadline else "-", SLOWER_RATIO, SLOWER_MIN_SECS))
        for t, os_, ns in sorted(slower, key=lambda x: -x[2])[:SAMPLES]:
            print("      - %s (old %.3f s, new %.3f s)" % (redact(t, patterns, real_home), os_, ns))
    return 1 if classes or slower else 0


if __name__ == "__main__":
    sys.exit(main())
