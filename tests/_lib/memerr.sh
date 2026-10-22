# shellcheck shell=bash
# memerr <gate.sh|gate.py>: run the gate's python half on stdin with json.load forced to raise
# MemoryError, the half of the fail-closed `except (RecursionError, MemoryError)` that a deep payload
# cannot reach (deepen only ever trips RecursionError). Exit code and streams are the gate's own.
memerr() {
  python3 -S -c '
import json, os, runpy, sys
def boom(*a, **k):
    raise MemoryError
json.load = boom
p = sys.argv[1]
sys.path.insert(0, os.path.dirname(p))
sys.argv = [p]
runpy.run_path(p, run_name="__main__")
' "${1%.sh}.py"
}
