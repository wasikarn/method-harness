#!/usr/bin/env python3
"""lint-files.py [--prefix P] <file>... -- py_compile every .py and JSON-parse every .json in one
python process (pre-commit and run-gauntlet.sh used to start python once per file). Every bad
file is reported, not just the first (`python3 -m py_compile a b` stops at the first error).
Exit 1 if any file failed."""
import json
import py_compile
import sys

args = sys.argv[1:]
prefix = ""
if args[:1] == ["--prefix"]:
    prefix, args = args[1], args[2:]
rc = 0
for f in args:
    try:
        if f.endswith(".json"):
            with open(f, encoding="utf-8") as fh:
                json.load(fh)
        else:
            py_compile.compile(f, doraise=True)
    except py_compile.PyCompileError as e:
        print(e.msg, file=sys.stderr)
        rc = 1
    except Exception as e:  # bad JSON, unreadable file, bad encoding
        kind = "invalid JSON" if f.endswith(".json") else "py_compile failed"
        print(f"{prefix}{kind}: {f}: {e}", file=sys.stderr)
        rc = 1
sys.exit(rc)
