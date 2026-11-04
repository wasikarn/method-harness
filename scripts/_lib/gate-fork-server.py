#!/usr/bin/env python3
# Fork server for scripts/_lib/gate-differential.py (GH #889); never run by hand.
# Usage: python3 -S gate-fork-server.py GATES_DIR GATE   (the same python3 and -S as the gate wrapper)
#
# Starting bash and python3 for every command is most of a replay's time. This process imports the
# stdlib and warms the regex cache once, then forks one child per command. The child drops every
# module loaded from GATES_DIR and imports the gate again, as `python3 -S _run.py GATE` does, with
# fresh stdin, stdout and stderr, so each command still runs the gate's module code from the top.
# The gates call os._exit (sgg's denies, irrecoverable's deadline), so they never run in this process
# in a loop: only a child may exit, and a warm-up that would kill the server makes the engine fall
# back to the bash runner.
#
# Protocol: one JSON line per command on stdin, {"in": path, "out": path, "err": path}; one JSON line
# back on stdout, {"code": int | "timeout" | "sigN", "secs": float}. The child's exit code is the
# gate's, as the interpreter would give it; the wrapper's own mapping is left to the bash runner.
import io, json, os, select, signal, sys, time, traceback

TIMEOUT = 8  # hooks.json's timeout, the same as the bash runner's

gates_dir, gate = sys.argv[1], sys.argv[2]
run_py = os.path.join(gates_dir, "_run.py")
proto_in = io.open(0, "rb", closefd=False)
# Copy the stream settings this interpreter chose for itself (the wrapper's python3 gets the same
# env and the same kind of fds: pipes or files, never a tty).
STREAMS = [(s.encoding, s.errors, s.line_buffering) for s in (sys.__stdin__, sys.__stdout__, sys.__stderr__)]


def gate_modules():
    root = os.path.realpath(gates_dir) + os.sep
    out = []
    for name, mod in list(sys.modules.items()):
        f = getattr(mod, "__file__", None)
        if f and os.path.realpath(f).startswith(root):
            out.append(name)
    return out


def drop_gate_modules():
    for name in gate_modules():
        del sys.modules[name]


def quiet():
    try:
        signal.setitimer(signal.ITIMER_REAL, 0)
    except (AttributeError, ValueError, OSError):
        pass
    signal.signal(signal.SIGALRM, signal.SIG_DFL)


def warm():
    # Run the gate in this process on a few allowing commands, then put back every piece of
    # interpreter state it may have changed. Only an allow path runs here: sgg's denies call os._exit.
    saved = (sys.stdin, sys.stdout, sys.stderr, list(sys.argv), sys.getrecursionlimit(),
             sys.get_int_max_str_digits() if hasattr(sys, "get_int_max_str_digits") else None,
             os.environ.get("MH_GATE_JOURNAL_PATH"))
    os.environ["MH_GATE_JOURNAL_PATH"] = os.devnull
    sys.argv = [run_py, gate]
    for cmd in ("ls -la", "git status && git diff --stat", 'echo "$(date)" | tee notes.txt'):
        d = {"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "warm"}
        if gate == "subagent-git-guard":
            d["agent_id"], d["agent_type"] = "warm", "general-purpose"
        sys.stdin, sys.stdout, sys.stderr = io.StringIO(json.dumps(d)), io.StringIO(), io.StringIO()
        try:
            __import__(gate)
        except BaseException:
            pass
        finally:
            quiet()
            drop_gate_modules()
    sys.stdin, sys.stdout, sys.stderr, sys.argv = saved[0], saved[1], saved[2], saved[3]
    sys.setrecursionlimit(saved[4])
    if saved[5] is not None:
        sys.set_int_max_str_digits(saved[5])
    if saved[6] is None:
        os.environ.pop("MH_GATE_JOURNAL_PATH", None)
    else:
        os.environ["MH_GATE_JOURNAL_PATH"] = saved[6]


def stream(fd, mode, settings):
    enc, errs, line = settings
    raw = io.FileIO(fd, mode, closefd=False)
    buf = io.BufferedReader(raw) if mode == "r" else io.BufferedWriter(raw)
    return io.TextIOWrapper(buf, encoding=enc, errors=errs, line_buffering=line)


def exit_code(e):
    # What the interpreter does with an uncaught SystemExit.
    c = e.code
    if c is None:
        return 0
    if isinstance(c, int):
        return c
    try:
        print(c, file=sys.stderr)
    except Exception:
        pass
    return 1


def child(req, w):
    code = 1
    try:
        for fd, path, flags in ((0, req["in"], os.O_RDONLY),
                                (1, req["out"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC),
                                (2, req["err"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC)):
            f = os.open(path, flags, 0o600)
            os.dup2(f, fd)
            os.close(f)
        sys.stdin = sys.__stdin__ = stream(0, "r", STREAMS[0])
        sys.stdout = sys.__stdout__ = stream(1, "w", STREAMS[1])
        sys.stderr = sys.__stderr__ = stream(2, "w", STREAMS[2])
        sys.argv = [run_py, gate]
        drop_gate_modules()
        try:
            __import__(gate)
            code = 0
        except SystemExit as e:
            code = exit_code(e)
        except BaseException:
            traceback.print_exc()
            code = 1
        try:
            sys.stdout.flush()
        except Exception:
            code = 120  # the interpreter's code for a failed flush at exit
        try:
            sys.stderr.flush()
        except Exception:
            pass
    finally:
        try:
            os._exit(code)
        except (OverflowError, TypeError):
            os._exit(1)


def serve():
    while True:
        line = proto_in.readline()
        if not line:
            return
        req = json.loads(line)
        r, w = os.pipe()  # the child holds w until it exits; subprocess children close it (close_fds)
        t0 = time.monotonic()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            child(req, w)
        os.close(w)
        done = select.select([r], [], [], TIMEOUT)[0]
        if not done:
            os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        secs = time.monotonic() - t0
        os.close(r)
        if not done:
            code = "timeout"
        elif os.WIFSIGNALED(status):
            code = "sig%d" % os.WTERMSIG(status)
        else:
            code = os.WEXITSTATUS(status)
        os.write(1, (json.dumps({"code": code, "secs": secs}) + "\n").encode())


sys.path[0] = gates_dir  # the wrapper runs gates_dir/_run.py, so the gates dir is sys.path[0]
warm()
os.write(1, b"ready\n")
serve()
