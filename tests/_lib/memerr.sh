# shellcheck shell=bash
# memerr <gate.sh|gate.py>: run the gate's python half on stdin with json.load forced to raise
# MemoryError, the half of the fail-closed `except (RecursionError, MemoryError)` that a deep payload
# cannot reach (deepen only ever trips RecursionError). Exit code and streams are the gate's own.
# boom reads its input first, as the real json.load does: raising on an unread pipe let the payload
# writer die of SIGPIPE, which pipefail reported as the row's failure.
memerr() {
  python3 -S -c '
import json, os, runpy, sys
def boom(fp=None, *a, **k):
    if hasattr(fp, "read"):
        fp.read()
    raise MemoryError
json.load = boom
p = sys.argv[1]
sys.path.insert(0, os.path.dirname(p))
sys.argv = [p]
runpy.run_path(p, run_name="__main__")
' "${1%.sh}.py"
}
