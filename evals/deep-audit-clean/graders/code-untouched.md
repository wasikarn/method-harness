---
type: regex
pattern: '    if total == 0:\n        raise ValueError\("total must be non-zero"\)\n    return part \* 100 / total\n'
match: contains
target: {source: file, path: calc.py}
---
Zero survivors is a valid result: the guard's body is byte-identical after the audit, whichever tool (Edit, Write, Bash) an unwarranted fix would have used.
