#!/usr/bin/env python3
"""Reader of evals/judge-models.tsv, the per-eval judge model (GH #510).

`claude plugin eval` takes only a run-wide --judge-model, and its case and grader schemas are
strict (no judge key), so a case that needs another judge is listed in this sidecar instead:
one `case<TAB>model<TAB>reason` row per case, `#` comments and blank lines skipped.

  eval_judge_models.py check [--evals DIR]        exit 1 on a malformed row or unknown case
  eval_judge_models.py for-tag TAG [--evals DIR]  print `case<TAB>model<TAB>allowed_tools` for
                                                  TAG's overrides (the case's own tools, comma-joined,
                                                  for --allow-tools; empty when it lists none)

Imported by skills/meta/model-bench/scripts/model-bench-diff.py (load()).
"""
import argparse
import os
import re
import sys

DEFAULT_EVALS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "evals")
SIDECAR = "judge-models.tsv"
# The CLI's own default judge: a row naming it changes nothing, so it is refused.
DEFAULT_JUDGE = "haiku"


def sidecar_path(evals_dir=DEFAULT_EVALS):
    return os.path.join(evals_dir, SIDECAR)


def load(path):
    """Rows of the sidecar as {case: (model, reason)}; a missing file has none.
    Raises ValueError naming the line on a malformed or duplicate row."""
    if not os.path.exists(path):
        return {}
    rows = {}
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 3 or not all(x.strip() for x in fields):
                raise ValueError(f"{path}:{n}: want case<TAB>model<TAB>reason, got {line!r}")
            case, model, reason = (x.strip() for x in fields)
            if case in rows:
                raise ValueError(f"{path}:{n}: {case} is listed twice")
            if model == DEFAULT_JUDGE:
                raise ValueError(f"{path}:{n}: {case}: {DEFAULT_JUDGE} is already the default judge")
            rows[case] = (model, reason)
    return rows


def frontmatter_list(evals_dir, case, key):
    """The `<key>: [...]` list in the case's prompt.md frontmatter (empty if none)."""
    try:
        text = open(os.path.join(evals_dir, case, "prompt.md")).read()
    except OSError:
        return []
    fm = text.split("---")[1] if text.startswith("---") else ""
    m = re.search(r"^" + re.escape(key) + r":\s*\[([^\]]*)\]", fm, re.M)
    return [t.strip() for t in m.group(1).split(",") if t.strip()] if m else []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["check", "for-tag"])
    parser.add_argument("tag", nargs="?")
    parser.add_argument("--evals", default=DEFAULT_EVALS, help="evals dir holding the sidecar (default: the repo's)")
    args = parser.parse_args()
    try:
        rows = load(sidecar_path(args.evals))
    except ValueError as e:
        print(f"eval_judge_models: {e}", file=sys.stderr)
        return 1
    if args.command == "check":
        missing = [c for c in rows if not os.path.isfile(os.path.join(args.evals, c, "prompt.md"))]
        for c in missing:
            print(f"eval_judge_models: {c}: no such case (evals/{c}/prompt.md)", file=sys.stderr)
        return 1 if missing else 0
    if not args.tag:
        parser.error("for-tag needs a TAG")
    for case, (model, _) in rows.items():
        if args.tag in frontmatter_list(args.evals, case, "tags"):
            print(f"{case}\t{model}\t{','.join(frontmatter_list(args.evals, case, 'allowed_tools'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
