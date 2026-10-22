# Runs the gate named in argv[1] by importing it: python3 compiles a script given on its command line
# from source on every run (about 10 ms for irrecoverable.py), while an imported module is read from
# __pycache__. The gate's own sys.exit() ends the process as before; the script dir stays sys.path[0].
import sys
__import__(sys.argv[1])
