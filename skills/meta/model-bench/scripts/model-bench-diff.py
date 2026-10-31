#!/usr/bin/env python3
"""Diff two claude plugin eval aggregate-result.json files and print a labeled comparison.

Schema notes (verified empirically against every real result file on this machine, not from any
claude plugin eval documentation): aggregates.overallScore, aggregates.overallPassRate, top-level
costUsd, cases[].name, cases[].aggregates.score, cases[].aggregates.passRate are always present.
suite.judgeModel, suite.caseFilter, aggregates.meanDelta, and the *Without/delta ablation fields
are present only on a subset of files at the same schemaVersion, so they're read with a default
rather than assumed present.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "scripts", "_lib"))
import eval_judge_models  # noqa: E402

DEFAULT_JUDGE_MODEL_DISPLAY = "haiku (default)"
DEFAULT_CASE_FILTER_DISPLAY = "all cases"
# Models Claude Code runs with safety classifiers (model-config#automatic-model-fallback): Fable,
# Opus 5.5, Opus 5, plus the `opus`/`fable`/`best`/`default` aliases (`default` is Opus 5.5 on
# every plan). Opus 4.x has none.
# ponytail: label-text heuristic, since aggregate-result.json records no model; read the model
# from arm-meta.txt if a label ever stops being the model spec.
CLASSIFIER_MODEL_RE = re.compile(r"fable|\bbest\b|\bdefault\b|opus(?![-_]?4)", re.IGNORECASE)
MODEL_FAMILY_RE = re.compile(r"haiku|sonnet|opus|fable", re.IGNORECASE)


def model_family(spec):
    """Family word in a model spec or label ('sonnet@high' -> sonnet), or None if it names none."""
    match = MODEL_FAMILY_RE.search(spec)
    return match.group(0).lower() if match else None


def load(path):
    with open(path) as f:
        return json.load(f)


def judge_model_display(suite):
    value = suite.get("judgeModel")
    return value if value else DEFAULT_JUDGE_MODEL_DISPLAY


def case_filter_display(suite):
    value = suite.get("caseFilter")
    return value if value else DEFAULT_CASE_FILTER_DISPLAY


def expected_judge_note(data_a, data_b, judge_models):
    """GH #510: a case in evals/judge-models.tsv is judged by its own model, so its history
    mixes judges. When one side ran only such cases under their declared judge (same family)
    and the other side is haiku-judged history, say the judgeModel mismatch is expected;
    otherwise None."""
    for data, other in ((data_a, data_b), (data_b, data_a)):
        if model_family(judge_model_display(other.get("suite", {}))) != eval_judge_models.DEFAULT_JUDGE:
            continue
        family = model_family(judge_model_display(data.get("suite", {})))
        names = [c.get("name") for c in data.get("cases") or []]
        rows = [(n, judge_models.get(n)) for n in names]
        if names and family and all(row and model_family(row[0]) == family for _, row in rows):
            return "; ".join(
                f"expected: {n} is judged by {row[0]} (evals/judge-models.tsv: {row[1]})" for n, row in rows
            )
    return None


def is_agent_dispatch(case):
    prompt = case.get("promptMarkdown") or ""
    return "subagent_type" in prompt


def hard_fail_reasons(label, data):
    reasons = []
    for plugin in (data.get("suite", {}).get("plugins") or []):
        problem = plugin.get("problem")
        if problem:
            reasons.append(f"{label}: plugin problem: {problem}")
    if data.get("partial"):
        reason = data.get("partialReason", "unknown")
        reasons.append(
            f"{label}: partial run (reason: {reason}) — score covers a smaller, "
            "non-random case set, not comparable"
        )
    return reasons


def compare(path_a, path_b, label_a, label_b, judge_models=None):
    data_a, data_b = load(path_a), load(path_b)
    suite_a, suite_b = data_a.get("suite", {}), data_b.get("suite", {})

    reasons = hard_fail_reasons(label_a, data_a) + hard_fail_reasons(label_b, data_b)
    if reasons:
        print(f"=== model-bench: {label_a} vs {label_b} ===")
        print("HARD-FAIL: results are not comparable.")
        for r in reasons:
            print(f"  - {r}")
        return 1

    lines = [f"=== model-bench: {label_a} vs {label_b} ==="]
    warnings = []
    # 2026-09-20 audit: this module's own docstring calls these fields
    # "always present." A .get(key, 0.0) default on a field that's actually
    # missing (a schema drift, or a truncated/partial result file that still
    # parses) silently reads as "this model scored 0" -- indistinguishable
    # from a real zero score -- which could steer a model-selection decision.
    # hard_fail_reasons() above already hard-fails on other malformed-result
    # signals; a merely-missing field gets a WARN here instead, using the
    # same warnings mechanism the comparability checks below already use.
    cases_totals = []
    for label, data in ((label_a, data_a), (label_b, data_b)):
        agg = data.get("aggregates", {})
        for key, holder in (("costUsd", data), ("overallScore", agg), ("overallPassRate", agg)):
            if key not in holder:
                warnings.append(f"{label}: '{key}' missing from result file — shown as 0.0 below, not a real score")
        # 2026-09-21 deep-audit: a missing casesTotal is the same silent-zero
        # -- it read as 0 and skipped the per-case table while cases[] had
        # entries. WARN and fall back to len(cases) instead.
        if "casesTotal" in agg:
            cases_totals.append(agg["casesTotal"])
        else:
            n = len(data.get("cases", []))
            warnings.append(f"{label}: 'casesTotal' missing from result file — using len(cases)={n} instead")
            cases_totals.append(n)

    for label, data in ((label_a, data_a), (label_b, data_b)):
        agg = data.get("aggregates", {})
        lines.append(
            f"{label}: cost=${data.get('costUsd', 0.0):.4f}  "
            f"score={agg.get('overallScore', 0.0):.3f}  "
            f"passRate={agg.get('overallPassRate', 0.0):.3f}"
        )

    if judge_model_display(suite_a) != judge_model_display(suite_b):
        warning = (
            f"judgeModel differs: {label_a}={judge_model_display(suite_a)} "
            f"vs {label_b}={judge_model_display(suite_b)}"
        )
        note = expected_judge_note(data_a, data_b, judge_models or {})
        warnings.append(f"{warning} — {note}" if note else warning)
    # #391: a judge tends to favor output from its own model family, which skews that arm's score.
    for label, suite in ((label_a, suite_a), (label_b, suite_b)):
        family = model_family(label)
        if family and family == model_family(judge_model_display(suite)):
            warnings.append(
                f"{label}: arm shares the judge model family ({family}) — the judge may favor its own family"
            )
    if case_filter_display(suite_a) != case_filter_display(suite_b):
        warnings.append(
            f"caseFilter differs: {label_a}={case_filter_display(suite_a)} "
            f"vs {label_b}={case_filter_display(suite_b)}"
        )
    if suite_a.get("ablation") != suite_b.get("ablation"):
        warnings.append(
            f"ablation differs: {label_a}={suite_a.get('ablation')} vs {label_b}={suite_b.get('ablation')}"
        )
    if data_a.get("claudeVersion") != data_b.get("claudeVersion"):
        warnings.append(
            f"claudeVersion differs: {label_a}={data_a.get('claudeVersion')} "
            f"vs {label_b}={data_b.get('claudeVersion')}"
        )
    versions_a = [p.get("version") for p in (suite_a.get("plugins") or [])]
    versions_b = [p.get("version") for p in (suite_b.get("plugins") or [])]
    if versions_a != versions_b:
        warnings.append(f"plugin version differs: {label_a}={versions_a} vs {label_b}={versions_b}")

    if warnings:
        lines.append("WARN: results may not be directly comparable:")
        lines.extend(f"  - {w}" for w in warnings)

    cases_total_a, cases_total_b = cases_totals
    if cases_total_a == 0 or cases_total_b == 0:
        empty_side = label_a if cases_total_a == 0 else label_b
        lines.append(f"NOTE: casesTotal is 0 on {empty_side} — no cases ran, skipping per-case table.")
        print("\n".join(lines))
        return 0

    cases_a = {c["name"]: c for c in data_a.get("cases", [])}
    cases_b = {c["name"]: c for c in data_b.get("cases", [])}
    common = sorted(set(cases_a) & set(cases_b))
    only_a = sorted(set(cases_a) - set(cases_b))
    only_b = sorted(set(cases_b) - set(cases_a))

    agent_dispatch_count = 0
    lines.append("")
    lines.append(f"{'case':<42} {label_a + ' score':>14} {label_b + ' score':>14} {'delta':>8}")
    for name in common:
        case_a, case_b = cases_a[name], cases_b[name]
        if is_agent_dispatch(case_a) or is_agent_dispatch(case_b):
            agent_dispatch_count += 1
        score_a = case_a.get("aggregates", {}).get("score", 0.0)
        score_b = case_b.get("aggregates", {}).get("score", 0.0)
        lines.append(f"{name:<42} {score_a:>14.3f} {score_b:>14.3f} {score_b - score_a:>+8.3f}")

    if only_a or only_b:
        lines.append("")
        lines.append("Not comparable (present on only one side — different --tag/--case filters?):")
        lines.extend(f"  - {n}: only in {label_a}" for n in only_a)
        lines.extend(f"  - {n}: only in {label_b}" for n in only_b)

    if agent_dispatch_count:
        lines.append("")
        lines.append(
            f"CAVEAT: {agent_dispatch_count} of {len(common)} compared cases dispatch a subagent, "
            "which runs at its"
        )
        lines.append(
            "agents/*.md frontmatter-pinned model regardless of --model (a same-family arm moves an "
            "opus/sonnet alias pin). Whether --model reaches subagent"
        )
        lines.append("dispatch inside the eval sandbox is unverified. Treat these deltas with caution.")

    for label in (label_a, label_b):
        if CLASSIFIER_MODEL_RE.search(label):
            lines.append("")
            lines.append(f"CAVEAT: {label} runs a model with safety classifiers. A flagged request can")
            lines.append("automatically re-run on Opus 4.8 or Opus 5 inside the eval (runs load no user settings, so")
            lines.append("your switchModelsOnFlag can't stop it; only a managed one applies there), and")
            lines.append("aggregate-result.json doesn't record which")
            lines.append("model answered. A security- or biology-heavy case may be scored on the wrong model.")

    print("\n".join(lines))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label-a", required=True, help="Label for the first result (e.g. a model name)")
    parser.add_argument("--label-b", required=True, help="Label for the second result")
    parser.add_argument("result_a", help="Path to the first aggregate-result.json")
    parser.add_argument("result_b", help="Path to the second aggregate-result.json")
    parser.add_argument(
        "--judge-models",
        help="Per-eval judge sidecar (default: the repo's evals/judge-models.tsv, if present)",
    )
    args = parser.parse_args()
    if args.judge_models and not os.path.exists(args.judge_models):
        print(f"model-bench: --judge-models {args.judge_models}: no such file", file=sys.stderr)
        sys.exit(1)
    try:
        judge_models = eval_judge_models.load(args.judge_models or eval_judge_models.sidecar_path())
    except ValueError as e:
        print(f"model-bench: {e}", file=sys.stderr)
        sys.exit(1)
    sys.exit(compare(args.result_a, args.result_b, args.label_a, args.label_b, judge_models))


if __name__ == "__main__":
    main()
