#!/usr/bin/env python3
# Drift check: the inline fallback mask copies in subagent-git-guard.py and
# test-integrity.py must produce the same output as the shared _quotemask.py.
# Prints one DRIFT line per disagreement; prints OK when all agree.
import ast, os, sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
gates = os.path.join(root, "hooks", "gates")
sys.path.insert(0, gates)
from _quotemask import mask_quotes

CORPUS = [
    "git reset --hard",
    "echo 'a; b' ; git stash",
    "echo hi # don't\ngit stash",
    "echo x\\\n#y; git stash",
    "echo x \\\n#y; git stash",
    "echo x\n#y; git stash",
    "echo x\\\\\n#y; git stash",
    "echo x\\\\\\\n#y; git stash",
    "\\\ngit stash",
    "echo \\\ngit stash",
    "echo 'a'\\\n#y; git stash",
    "git\\\nstash",
    "x\\\n\\\n#y",
    "echo \\'x\\' ; git stash",
    "echo $'a\\'b' ; git stash",
    "a\\",
    "(true)#c\ngit stash",
    # GH #309 audit: an escaped blank or separator is part of its word, so a "#" after it is no comment
    "echo x\\ #; git stash",
    "echo x\\;#; git stash",
    "echo x\\&#; git stash",
    "echo x #; git stash",
    # GH #306: one per continuation placement.
    "git\\\n stash",
    "g\\\nit stash",
    "git s\\\ntash",
    "env\\\n git stash",
    "{\\\n git stash; }",
    "if true; then\\\n git stash; fi",
    "git stash\\\n",
    "git\\\n;x",
    "g\\\ni\\\nt st\\\nash",
    "''\\\ngit stash",
    "\\\\\\\ngit stash",
    "x\\\\\\\ngit",
    "\\\n\\\n#y",
    "bash -\\\nc \"git \\\nstash\"",
    "eval 'g\\\nit stash'",
    "$'a'\\\nb c",
    # GH #820 item 5: a ")" closing $( <( >( =( keeps the word; a subshell ")" ends it
    "echo $(date)#|git stash",
    "echo $((1))#x; git stash",
    "cat <(ls)#x; git stash",
    "a=(x)#y; git stash",
    "echo $( (ls) )#x; git stash",
    "(ls)#x\ngit stash",
    "((1))#x\ngit stash",
    "case a in a)#x\ngit stash",
    # GH #833: a case pattern's ")" inside $( keeps the $( open; a continuation inside $\<nl>( is stepped over;
    # an extglob group glues as $( does
    "echo $(case a in a) :;; esac)#; git stash",
    "echo $(case a in (a) :;; esac)#; git stash",
    "echo $(case a in\n a|b) :;;\n esac)#; git stash",
    "echo $(if true; then case a in a) :;; esac; fi)#; git stash",
    "echo $(case a in esac)#; git stash",
    "echo $(case a in a) :;; esac) #; git stash",
    "echo $(echo case)#; git stash",
    "echo case a in a)#x\ngit stash",
    "echo $\\\n(date)#; git stash",
    "echo \\$(date)#; git stash",
    "echo @(a)#; git stash",
    "echo !(a)#; git stash",
    "echo ?(a)#; git stash",
    "echo *(a)#; git stash",
    "echo +(a)#; git stash",
    "echo @(a) #; git stash",
    # GH #833 review: a case misread from an argument, or whose esac goes unseen, fails safe
    "echo $(echo do case)#; git stash",
    "echo $( (echo do case) )#; git stash",
    "echo $(case a in a) { :; } esac)#; git stash",
    "echo $(if case a in a) :;; esac; then :; fi)#; git stash",
    "echo $(case a in a) case b in b) :;; esac;; c) :;; esac)#; git stash",
    "echo $(case a in a) echo in esac;; b) :;; esac)#; git stash",
    "case a in a)#x\nesac; git stash",
    "echo do case; (ls)#x\ngit stash",
    # GH #833 review 2: a # after an unsure ")" is read both ways; no quote or "<" on its line opens anything
    "a=(do case); case a in a)#'\n;; esac; git stash\n#'",
    "a=(do case); case a in a)#\"\n;; esac; git stash\n#\"",
    "a=(do case); case a in a)#<<E\n;; esac; git stash\nE",
    "echo $(echo do case); case a in a)\\\n#'x'; git stash",
    # GH #833 review 3: the unsure line keeps its frames and continuations; only quotes and "<" are inert
    "echo $(echo do case)#\\\n#; git stash",
    "echo $(echo do case)#$(\ncat <<E\nhi\nE)\ngit stash\nE",
    "echo $(echo do case)#x'y' ; git stash",
    "echo $(echo do case)#$'a\\'; git stash",
    # GH #833 review 4: once an inert quote or "<" shows up, nothing opens to the end of the text
    "echo $(echo do case)#\"\n\"; git stash",
    "echo $(echo do case)#\"\n\" && git reset --hard # \"",
    "echo $(echo do case)#${x:-\"\n\"}; git stash # \"",
    "echo $(echo do case)#x #'\ngit stash",
    # GH #833 review 5: an inert quote mark (and the $ of an inert $'..') is dropped, its blank at the word front
    "echo $(echo do case)#; \"git\" stash",
    "echo $(echo do case)#'x' && g''it stash",
    "echo $(echo do case)#; $'git' stash",
    "echo $(echo do case)#; $$$'git' stash",
    "echo $(echo do case)#\"",
    "echo $(echo do case)#<x; git stash",
    # GH #833 review 6: an inert $".." drops its $ too
    "echo $(echo do case)#; $\"git\" stash",
    "echo $(echo do case)#; g$\"it\" stash",
    "echo $(echo do case)#; git $\"reset\" --hard",
    # GH #833 review 7: an extglob candidate's ")" is unsure (a group, or with extglob off an operator)
    "!(true)#<<E\ngit stash\nE",
    "x+()#'\n{ git stash; }\nx+\n#'",
    "f@()#\"\ngit stash\n#\"",
    "echo @(a|b)#; git stash",
    "echo !(a) #'\ngit stash",
]


def inline(path, name):
    tree = ast.parse(open(path).read())
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            ns = {}
            exec(compile(ast.Module([node], []), path, "exec"), ns)
            return ns[name]
    raise SystemExit("DRIFT: %s not found in %s" % (name, path))


copies = [
    ("subagent-git-guard.py", inline(os.path.join(gates, "subagent-git-guard.py"), "_mask_quotes")),
    ("test-integrity.py", inline(os.path.join(gates, "test-integrity.py"), "_mask_quotes_bash")),
]
bad = 0
for label, fn in copies:
    for s in CORPUS:
        if fn(s) != mask_quotes(s):
            print("DRIFT %s on %r: %r != %r" % (label, s, fn(s), mask_quotes(s)))
            bad += 1
print("OK" if not bad else "FAIL")
sys.exit(1 if bad else 0)
