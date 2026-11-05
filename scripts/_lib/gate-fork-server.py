#!/usr/bin/env python3
# Fork server for scripts/_lib/gate-differential.py (GH #889); never run by hand.
# Usage: python3 -S gate-fork-server.py GATES_DIR GATE TIMEOUT   (the wrapper's own python3 and -S)
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
# back on stdout, {"code": int | "timeout" | "sigN" | "setup-failed", "secs": float}. The child's exit
# code is the gate's, as the interpreter would give it; the wrapper's own mapping is left to the bash
# runner. "setup-failed" (the child could not open its files, traceback on this process's stderr) is
# never a gate result: the engine falls back to bash, since both sides failing alike would read as
# no diff.
#
# Why a fork result can add a diff but never hide one, while both sides run the same wrapper (the
# engine checks that), rests on two assumptions; revisit them if a gate or the wrapper changes:
# - warm() puts back the state it lists (streams, argv, recursion limit, int digit limit, the journal
#   env var, the timer and SIGALRM, the gates-dir modules), but not os.environ, the cwd or sys.path
#   changes a gate makes at import time. No gate makes any today.
# - The child imports the gate directly, not through _run.py, so a change in _run.py itself is only
#   seen through the wrapper-identity check (_run.py is a wrapper file there).
# Neither the gates nor _journal.py use atexit, and the wrapper exports nothing to python.
import io, json, os, select, signal, sys, time, traceback

gates_dir, gate, TIMEOUT = sys.argv[1], sys.argv[2], float(sys.argv[3])  # TIMEOUT: hooks.json's, from the engine
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
        except SystemExit:
            pass  # a gate ends by exiting
        except BaseException:
            traceback.print_exc(file=sys.__stderr__)  # server.err; a crash here may repeat in every child
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
        os.setpgid(0, 0)  # its own group: a timeout or a dying server kills the gate's children too
        signal.signal(signal.SIGTERM, signal.SIG_DFL)  # the server's handler is not the gate's
        for fd, path, flags in ((0, req["in"], os.O_RDONLY),
                                (1, req["out"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC),
                                (2, req["err"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC)):
            f = os.open(path, flags, 0o600)
            os.dup2(f, fd)
            os.close(f)
        sys.stdin = sys.__stdin__ = stream(0, "r", STREAMS[0])
        sys.stdout = sys.__stdout__ = stream(1, "w", STREAMS[1])
        sys.stderr = sys.__stderr__ = stream(2, "w", STREAMS[2])
        os.write(w, b"S")  # set-up done: from here on the exit code is the gate's; w stays open until exit
        os.close(SERVER_ERR)  # the gate sees only fds 0, 1 and 2, as under the wrapper
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
    except BaseException:
        try:  # before the "S": fd 2 is still the server's stderr unless the dup2 got that far
            os.write(SERVER_ERR, traceback.format_exc().encode(errors="replace"))
        except Exception:
            pass
        code = 1
    finally:
        try:
            os._exit(code)
        except (OverflowError, TypeError):
            os._exit(1)


CURRENT = [None]  # the running child's pid, which is also its process group


def kill_child():
    if CURRENT[0]:
        try:
            os.killpg(CURRENT[0], signal.SIGKILL)
        except ProcessLookupError:
            pass  # the child and its group already exited


def on_term(signum, frame):
    kill_child()  # the engine stops a hung server with SIGTERM: take the gate's group with it
    os._exit(1)


def wait_child(r, t0):
    # -> (set-up done, finished in time). The child writes "S" after set-up and holds w until it exits;
    # subprocess children close it (close_fds).
    setup, left = False, TIMEOUT
    while left > 0 and select.select([r], [], [], left)[0]:
        b = os.read(r, 1)
        if not b:
            return setup, True
        setup = True
        left = TIMEOUT - (time.monotonic() - t0)
    return setup, False


def serve():
    while True:
        line = proto_in.readline()
        if not line:
            return
        req = json.loads(line)
        r, w = os.pipe()
        t0 = time.monotonic()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            child(req, w)
        CURRENT[0] = pid
        try:
            os.setpgid(pid, pid)  # the child does it too: whichever runs first, no race with killpg
        except OSError:
            pass
        os.close(w)
        setup, done = wait_child(r, t0)
        if not done:
            kill_child()
        _, status = os.waitpid(pid, 0)
        CURRENT[0] = None
        secs = time.monotonic() - t0
        os.close(r)
        if not setup:
            code = "setup-failed"
        elif not done:
            code = "timeout"
        elif os.WIFSIGNALED(status):
            code = "sig%d" % os.WTERMSIG(status)
        else:
            code = os.WEXITSTATUS(status)
        os.write(1, (json.dumps({"code": code, "secs": secs}) + "\n").encode())


SERVER_ERR = os.dup(2)  # kept for a child whose set-up fails after replacing fd 2
signal.signal(signal.SIGTERM, on_term)
sys.path[0] = gates_dir  # the wrapper runs gates_dir/_run.py, so the gates dir is sys.path[0]
warm()
os.write(1, b"ready\n")
serve()
