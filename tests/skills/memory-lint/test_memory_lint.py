#!/usr/bin/env python3
"""Self-check for the dangling-link did-you-mean suggestion. Run directly: python3 test_memory_lint.py"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import time

# A git hook exports GIT_DIR; the subprocess `git init` below would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh).
for _k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
           "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE"):
    os.environ.pop(_k, None)

HERE = os.path.dirname(os.path.abspath(__file__))
# SUT (memory-lint.py) stayed at skills/meta/memory-lint/scripts/ per the no-move
# rule — Claude Code skill invocation contract relies on ${CLAUDE_SKILL_DIR}/scripts/.
# 3 levels up (tests/skills/memory-lint/ → repo root) then into the SUT dir.
spec = importlib.util.spec_from_file_location("memory_lint",
    os.path.join(HERE, "..", "..", "..", "skills", "meta", "memory-lint", "scripts", "memory-lint.py"))
assert spec and spec.loader
memory_lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory_lint)


def test_typo_link_gets_suggestion():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "foo_bar.md"), "w") as f:
            f.write("---\nname: foo-bar\n---\nsome memory content\n")
        with open(os.path.join(d, "baz.md"), "w") as f:
            f.write("---\nname: baz\n---\nlinks to [[foo_br]]\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [baz](baz.md) — x\n- [foo_bar](foo_bar.md) — y\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        dangling = [f for f in findings if "DANGLING" in f and "foo_br" in f]
        assert len(dangling) == 1, f"expected exactly one dangling finding for foo_br, got {dangling}"
        assert "did you mean [[foo_bar]]?" in dangling[0], f"expected suggestion, got: {dangling[0]}"


def test_unrelated_dangling_link_gets_no_suggestion():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "foo_bar.md"), "w") as f:
            f.write("---\nname: foo-bar\n---\nsome memory content\n")
        with open(os.path.join(d, "baz.md"), "w") as f:
            f.write("---\nname: baz\n---\nlinks to [[completely_unrelated_topic_xyz]]\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [baz](baz.md) — x\n- [foo_bar](foo_bar.md) — y\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        dangling = [f for f in findings if "DANGLING" in f and "completely_unrelated_topic_xyz" in f]
        assert len(dangling) == 1
        assert "did you mean" not in dangling[0], f"expected no suggestion, got: {dangling[0]}"


def test_markdown_style_dangling_link_is_detected():
    # Regression test for the 2026-08-07 gap: DANGLING used to only scan
    # [[wikilinks]], so a same-store markdown-style [text](file.md) link to a
    # nonexistent memory was invisible to the detector.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "baz.md"), "w") as f:
            f.write("---\nname: baz\n---\nsee [ghost](ghost-topic.md) for detail\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [baz](baz.md) — x\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        dangling = [f for f in findings if "DANGLING" in f and "ghost-topic" in f]
        assert len(dangling) == 1, f"expected a dangling finding for the markdown-style link, got {findings}"


def test_markdown_style_link_in_backticks_is_not_a_real_reference():
    # Regression test: prose can quote link syntax as an example of a bug found
    # in another repo (confirmed live in plugin-install-portability.md, which
    # cites `[reference.md](reference.md)` as a fixed-elsewhere example). That
    # must not be treated as a same-store cross-link.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "baz.md"), "w") as f:
            f.write("---\nname: baz\n---\nsaw `[reference.md](reference.md)` used elsewhere\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [baz](baz.md) — x\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        assert not any("reference" in f for f in findings), (
            f"backtick-quoted link syntax must not be scanned as a real reference: {findings}")


def test_markdown_style_link_with_path_is_treated_as_external_not_dangling():
    # This store's memories live flat (no subdirectories except _archive/), so
    # a target containing "/" is a citation into another repo, not a same-store
    # link — confirmed live in plugin-install-portability.md's
    # ../../docs/reference/some-deleted-doc.md citation.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "baz.md"), "w") as f:
            f.write("---\nname: baz\n---\nsee [x](../../docs/reference/some-deleted-doc.md)\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [baz](baz.md) — x\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        assert not any("some-deleted-doc" in f for f in findings), (
            f"a path-qualified markdown target must not be scanned as a same-store link: {findings}")


def test_markdown_style_link_to_real_memory_resolves_and_avoids_false_orphan():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "foo_bar.md"), "w") as f:
            f.write("---\nname: foo-bar\n---\nsome memory content\n")
        with open(os.path.join(d, "baz.md"), "w") as f:
            f.write("---\nname: baz\n---\nsee [foo bar](foo_bar.md) for detail\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [baz](baz.md) — x\n- [foo_bar](foo_bar.md) — y\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        assert not any("DANGLING" in f or "ORPHAN" in f for f in findings), findings


def test_pointer_inside_html_comment_does_not_index_the_file():
    # Claude Code strips block HTML comments from MEMORY.md before loading it
    # (measured_index already mirrors that for the byte cap), so a pointer that
    # lives only inside a comment never reaches the model: the file is unindexed.
    # Red cycle: before the fix `referenced` was built from the raw index and lint stayed clean.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "hidden.md"), "w") as f:
            f.write("---\nname: hidden\n---\nbody with no links\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("# idx\n<!--\n- [hidden](hidden.md) — parked\n-->\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        assert any("UNINDEXED" in x and "hidden.md" in x for x in findings), findings


def test_class_d_count_fold_fires_over_trigger_and_reaches_target():
    # Regression test for the 2026-08-07 Class D addition: A/B/C only catch a
    # few verbose outliers or explicit **SUPERSEDED** markers, so a store made
    # of many small terse entries (this store's real shape) sails past 80% of
    # cap with 0 candidates from either class — confirmed live against the
    # real pre-trim MEMORY.md (21,632B/84%, A and B both found 0). Class D is
    # the fallback valve for exactly that shape.
    #
    # topic-5's body links [[topic-0]] through [[topic-4]] (2026-09-01: the
    # reachability guard added that day means a candidate with zero alternate
    # [[link]] path is never proposed — see
    # test_class_d_count_fold_never_orphans_a_deindex_candidate for that
    # property itself; this fixture only needs SOME safe candidates to still
    # exercise "fires and reaches target", so topic-5 supplies that on
    # everyone's behalf rather than testing the guard here too).
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000  # keep line-cap out of the way; test byte-cap only
        memory_lint.BYTE_CAP = 480
        with tempfile.TemporaryDirectory() as d:
            idx_lines = []
            now = 2_000_000_000
            for i in range(6):
                stem = f"topic-{i}"
                body = ("links to [[topic-0]] [[topic-1]] [[topic-2]] [[topic-3]] [[topic-4]]\n"
                        if i == 5 else f"some memory content about topic {i}\n")
                with open(os.path.join(d, f"{stem}.md"), "w") as f:
                    f.write(f"---\nname: {stem}\n---\n{body}")
                os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
                idx_lines.append(f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(idx_lines) + "\n")
            state = memory_lint.collect_state(d)
            idx_bytes = len(state["idx"].encode("utf-8"))
            assert idx_bytes / memory_lint.BYTE_CAP >= 0.80, "fixture must actually cross the trigger"

            plan = memory_lint.class_d_count_fold(state, exclude_files=set())
            assert plan, "expected Class D to propose at least one deindex above the trigger"
            # Oldest-mtime-first: topic-0 (lowest mtime) must be folded before topic-5 (highest).
            folded = [e["file"] for e in plan]
            assert folded[0] == "topic-0.md", f"expected oldest-mtime file first, got {folded}"
            assert "topic-5.md" not in folded or folded.index("topic-5.md") == len(folded) - 1, (
                f"newest-mtime file should be folded last if at all: {folded}")

            freed = sum(len(e["old_pointer_line"].encode("utf-8")) + 1 for e in plan)
            remaining = idx_bytes - freed
            target = memory_lint.BYTE_CAP * memory_lint.FOLD_TARGET_PCT
            assert remaining <= target, (
                f"Class D plan must actually reach target: {remaining}B remaining vs {target}B target")
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_d_count_fold_returns_nothing_under_trigger():
    orig_byte_cap = memory_lint.BYTE_CAP
    try:
        memory_lint.BYTE_CAP = 1_000_000  # index nowhere near this cap
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "topic.md"), "w") as f:
                f.write("---\nname: topic\n---\nsome memory content\n")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("- [topic](topic.md) — a short pointer hook\n")
            state = memory_lint.collect_state(d)
            plan = memory_lint.class_d_count_fold(state, exclude_files=set())
            assert plan == [], f"expected no Class D candidates well under trigger, got {plan}"
    finally:
        memory_lint.BYTE_CAP = orig_byte_cap


def test_class_d_count_fold_never_orphans_a_deindex_candidate():
    # 2026-09-01 deep-audit: mtime-only picking had no reachability check, so on
    # the real store it proposed 17/24 candidates that would have recreated the
    # exact UNINDEXED finding this valve exists to relieve pressure on. Reproduces
    # that shape: topic-0 (oldest, zero alternate [[link]] path) must NEVER be
    # proposed; topic-1 (2nd-oldest) has an inbound [[link]] from topic-5 (which
    # stays referenced throughout), so it's safe and must still be proposed.
    # topic-2/3/4 are unsafe fillers just like topic-0 (no inbound link either) —
    # padding to cross the byte trigger without being candidates worth asserting on.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 480
        with tempfile.TemporaryDirectory() as d:
            now = 2_000_000_000
            bodies = {
                "topic-0": "no inbound link to this one",
                "topic-1": "no inbound link of its own -- topic-5 supplies one below",
                "topic-2": "no inbound link either",
                "topic-3": "no inbound link either",
                "topic-4": "no inbound link either",
                "topic-5": "links to [[topic-1]] so topic-1 stays reachable if deindexed",
            }
            idx_lines = []
            for i in range(6):
                stem = f"topic-{i}"
                with open(os.path.join(d, f"{stem}.md"), "w") as f:
                    f.write(f"---\nname: {stem}\n---\n{bodies[stem]}\n")
                os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
                idx_lines.append(f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(idx_lines) + "\n")
            state = memory_lint.collect_state(d)
            idx_bytes = len(state["idx"].encode("utf-8"))
            assert idx_bytes / memory_lint.BYTE_CAP >= 0.80, "fixture must actually cross the trigger"

            plan = memory_lint.class_d_count_fold(state, exclude_files=set())
            folded = [e["file"] for e in plan]
            assert "topic-0.md" not in folded, (
                f"topic-0 has zero alternate reachability -- deindexing it would recreate "
                f"UNINDEXED; must never be proposed even though it's oldest: {folded}")
            assert "topic-1.md" in folded, (
                f"topic-1 has an inbound [[link]] from topic-5 (stays referenced), so "
                f"deindexing it is safe and must still be proposed: {folded}")

            # Reachability must actually hold after applying the plan, not just by
            # assertion above -- recompute from the post-plan referenced set directly.
            post_referenced = state["referenced"] - {e["file"] for e in plan}
            baseline_reachable = memory_lint.compute_reachable(
                state["files"], state["slugs"], state["links_out"], state["referenced"])
            post_reachable = memory_lint.compute_reachable(
                state["files"], state["slugs"], state["links_out"], post_referenced)
            assert post_reachable == baseline_reachable, (
                f"plan must never shrink the reachable set: before={baseline_reachable} "
                f"after={post_reachable}")
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def _write_memory(d, filename, type_, description, body):
    with open(os.path.join(d, filename), "w") as f:
        f.write(f'---\nname: {filename[:-3]}\ndescription: "{description}"\n'
                 f"metadata:\n  type: {type_}\n---\n{body}\n")


def test_unindexed_file_linked_from_indexed_memory_is_not_a_finding():
    """Fold rule Layer-2: unindexed but [[link]]-reachable from an indexed root
    must NOT fire UNINDEXED — it's the healthy Context layer."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "hub.md"), "w") as f:
            f.write("---\nname: hub\n---\nindexed hub, links [[ctx_note]]\n")
        with open(os.path.join(d, "ctx_note.md"), "w") as f:
            f.write("---\nname: ctx-note\n---\nreachable detail, no index line\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [hub](hub.md) — the indexed root\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        unindexed = [x for x in findings if "UNINDEXED" in x]
        assert unindexed == [], f"linked context file must not fire UNINDEXED, got {unindexed}"


def test_unindexed_and_unreachable_file_still_fires_unindexed():
    """A file with no index pointer and no inbound path from the index is real
    rot and must still fire exactly one UNINDEXED finding naming it."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "hub.md"), "w") as f:
            f.write("---\nname: hub\n---\nindexed, links nothing\n")
        with open(os.path.join(d, "stray.md"), "w") as f:
            f.write("---\nname: stray\n---\nnobody points here\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [hub](hub.md) — the indexed root\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        unindexed = [x for x in findings if x.startswith("UNINDEXED: stray.md")]
        assert len(unindexed) == 1, f"expected exactly one UNINDEXED for stray.md, got {findings}"


def test_unindexed_reachability_is_transitive_through_unindexed_files():
    """Index -> hub -> [[mid]] -> [[leaf]]: mid and leaf are both unindexed but
    reachable through the chain, so neither fires."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "hub.md"), "w") as f:
            f.write("---\nname: hub\n---\nlinks [[mid]]\n")
        with open(os.path.join(d, "mid.md"), "w") as f:
            f.write("---\nname: mid\n---\nlinks onward to [[leaf]]\n")
        with open(os.path.join(d, "leaf.md"), "w") as f:
            f.write("---\nname: leaf\n---\nend of the chain\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [hub](hub.md) — the indexed root\n")
        state = memory_lint.collect_state(d)
        findings, _, _ = memory_lint.detector_findings(state)
        unindexed = [x for x in findings if "UNINDEXED" in x]
        assert unindexed == [], f"transitively reachable files must not fire, got {unindexed}"


def test_memory_dir_project_dir_name_requires_config_dir():
    """Regression test for a bug memory_dir() shipped and had to fix twice in
    one session: the round-1 fix honored CLAUDE_CODE_PROJECT_DIR_NAME whenever
    it was set, citing memory.md — which doesn't mention that Claude Code
    "ignores this variable when CLAUDE_CONFIG_DIR is unset" (env-vars.md:326).
    Round-2 fixed it but was verified only in an ad-hoc scratch dir, leaving
    no committed coverage to catch a future re-regression of the same bug."""
    with tempfile.TemporaryDirectory() as repo, tempfile.TemporaryDirectory() as cfg:
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "init"], cwd=repo, check=True)
        toplevel = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        git_enc = _cc_slug(toplevel)

        saved_cwd = os.getcwd()
        saved_env = {k: os.environ.get(k) for k in ("CLAUDE_CONFIG_DIR", "CLAUDE_CODE_PROJECT_DIR_NAME")}
        try:
            os.chdir(repo)
            for k in saved_env:
                os.environ.pop(k, None)

            neither = memory_lint.memory_dir(None)
            assert neither == os.path.join(os.path.expanduser("~/.claude/projects"), git_enc, "memory"), neither

            os.environ["CLAUDE_CODE_PROJECT_DIR_NAME"] = "myrepo"
            dirname_alone = memory_lint.memory_dir(None)
            assert dirname_alone == neither, \
                f"CLAUDE_CODE_PROJECT_DIR_NAME must be ignored without CLAUDE_CONFIG_DIR, got {dirname_alone}"

            os.environ["CLAUDE_CONFIG_DIR"] = cfg
            both = memory_lint.memory_dir(None)
            assert both == os.path.join(cfg, "projects", "myrepo", "memory"), both

            os.environ.pop("CLAUDE_CODE_PROJECT_DIR_NAME", None)
            config_dir_alone = memory_lint.memory_dir(None)
            assert config_dir_alone == os.path.join(cfg, "projects", git_enc, "memory"), config_dir_alone
        finally:
            os.chdir(saved_cwd)
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


# --- 2026-08-23 mutation-testing probe: 13 weak-oracle survivors ---
# Each function below closes a mutant the probe found surviving: the code line
# was executed by some test, but no assertion observed the mutated behavior.
# Verified with per-mutant mutation-thinking (apply the flip, confirm the test
# now fails). See docs/research/mutation-probe-results-2026-08-23.md.

def test_measured_index_line_count_is_newlines_plus_one():
    # L208: `count("\n") + 1`. No prior test asserted the line-count half of the
    # (bytes, lines) tuple -- every caller ran with LINE_CAP huge so it never bound.
    b, lines = memory_lint.measured_index("a\nb\nc")
    assert lines == 3, lines   # 2 newlines -> 2+1==3; mutated 2-1==1
    assert b == 5, b


def test_near_budget_finding_fires_at_exactly_80_percent():
    # L349: `pct >= 80`. The NEAR-BUDGET finding differs from `pct > 80` only when
    # the integer pct lands on exactly 80. Set BYTE_CAP off the real index size so
    # the byte ratio is exactly 0.80 without hand-counting.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        with tempfile.TemporaryDirectory() as d:
            _write_memory(d, "one.md", "project", "first pointer", "n/a")
            _write_memory(d, "two.md", "project", "second pointer", "n/a")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("- [one](one.md) — a pointer hook for topic one here\n"
                         "- [two](two.md) — a pointer hook for topic two here\n")
            state = memory_lint.collect_state(d)
            memory_lint.LINE_CAP = 100_000     # keep the line ratio ~0, never over budget
            idx_bytes, idx_lines = memory_lint.measured_index(state["idx"])
            memory_lint.BYTE_CAP = int(idx_bytes / 0.80)   # byte ratio == 0.80 -> pct == 80
            pct = int(max(idx_lines / memory_lint.LINE_CAP,
                          idx_bytes / memory_lint.BYTE_CAP) * 100)
            assert pct == 80, (idx_bytes, memory_lint.BYTE_CAP, pct)   # loud setup guard
            findings, *_ = memory_lint.detector_findings(state)
            near = [f for f in findings if f.startswith("NEAR-BUDGET")]
            assert len(near) == 1, findings
            assert "at 80%" in near[0], near[0]   # interpolated pct, not the hardcoded cap string
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_d_count_fold_skips_files_named_in_exclude_files():
    # L1187: `fname in exclude_files or fname not in state["files"]`. A file already
    # claimed by plan A/B (exclude_files) must be skipped. The missing-file half is
    # masked by the getmtime OSError guard, so only a nonempty exclude_files naming
    # an EXISTING file discriminates the `or`->`and` flip.
    #
    # topic-5 links [[topic-0]]..[[topic-4]] so those stay safe under the
    # 2026-09-01 reachability guard — this test isn't about that guard, it just
    # needs real fold candidates to exist (see
    # test_class_d_count_fold_never_orphans_a_deindex_candidate for the guard itself).
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 480
        with tempfile.TemporaryDirectory() as d:
            now = 2_000_000_000
            idx_lines = []
            for i in range(6):
                stem = f"topic-{i}"
                body = ("links to [[topic-0]] [[topic-1]] [[topic-2]] [[topic-3]] [[topic-4]]\n"
                        if i == 5 else f"some memory content about topic {i}\n")
                with open(os.path.join(d, f"{stem}.md"), "w") as f:
                    f.write(f"---\nname: {stem}\n---\n{body}")
                os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
                idx_lines.append(f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(idx_lines) + "\n")
            state = memory_lint.collect_state(d)
            # topic-0 is the OLDEST (lowest mtime) -> the first fold candidate; excluding it
            # must remove it from the plan entirely.
            plan = memory_lint.class_d_count_fold(state, exclude_files={"topic-0.md"})
            assert plan, "fixture must actually fire Class D above the trigger"   # anti-vacuous
            assert "topic-0.md" not in [e["file"] for e in plan], plan
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_d_break_is_inclusive_at_exact_byte_target():
    # L1199: `remaining_bytes <= target_bytes`. Inclusive stop at remaining==target.
    # BYTE_CAP=154 -> target_bytes=int(154*0.65)==100; index==200B in 24B lines,
    # 25B freed/fold: 200->175->150->125->100, break at 100<=100 after 4 folds.
    # Mutated (<): folds a 5th. Lines never bind (LINE_CAP huge).
    #
    # t0 is newest (mtime, folded last if at all) and links [[t1]]..[[t7]], so the
    # 2026-09-01 reachability guard sees all 7 as safe -- this test isn't about
    # that guard, it just needs real fold candidates (see
    # test_class_d_count_fold_never_orphans_a_deindex_candidate for the guard
    # itself). Body content doesn't affect the byte math below (only the
    # MEMORY.md pointer lines do), so this doesn't disturb the exact-count fixture.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000_000
        memory_lint.BYTE_CAP = 154
        with tempfile.TemporaryDirectory() as d:
            lines = []
            now = 2_000_000_000
            for i in range(8):
                stem = f"t{i}"
                body = ("links to [[t1]] [[t2]] [[t3]] [[t4]] [[t5]] [[t6]] [[t7]]\n"
                        if i == 0 else "content\n")
                with open(os.path.join(d, f"{stem}.md"), "w") as f:
                    f.write(f"---\nname: {stem}\n---\n{body}")
                os.utime(os.path.join(d, f"{stem}.md"),
                         (now + 1000, now + 1000) if i == 0 else (now + i * 10, now + i * 10))
                lines.append(f"- [{stem}]({stem}.md)" + "x" * 11)   # 13 + 11 == 24 bytes
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(lines) + "\n")   # 8*24 + 8 newlines == 200 bytes
            state = memory_lint.collect_state(d)
            idx_bytes, _ = memory_lint.measured_index(state["idx"])
            assert idx_bytes == 200, idx_bytes   # loud fixture guard
            assert int(memory_lint.BYTE_CAP * memory_lint.FOLD_TARGET_PCT) == 100
            plan = memory_lint.class_d_count_fold(state, exclude_files=set())
            assert len(plan) == 4, [e["file"] for e in plan]   # mutated (<) -> 5
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_d_break_is_inclusive_at_exact_line_target():
    # L1199: `remaining_lines <= target_lines` (the line half; needs its own fixture
    # because only one cap binds at a time). LINE_CAP=10 -> target_lines==6; index
    # is 9 lines, 1 dropped/fold: 9->8->7->6, break at 6<=6 after 3 folds.
    # Mutated (<): folds a 4th. Bytes never bind (BYTE_CAP huge).
    #
    # t0 is newest (folded last if at all) and links [[t1]]..[[t7]] -- same
    # reachability-guard accommodation as the byte-target sibling test above.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10
        memory_lint.BYTE_CAP = 10_000_000
        with tempfile.TemporaryDirectory() as d:
            lines = []
            now = 2_000_000_000
            for i in range(8):
                stem = f"t{i}"
                body = ("links to [[t1]] [[t2]] [[t3]] [[t4]] [[t5]] [[t6]] [[t7]]\n"
                        if i == 0 else "content\n")
                with open(os.path.join(d, f"{stem}.md"), "w") as f:
                    f.write(f"---\nname: {stem}\n---\n{body}")
                os.utime(os.path.join(d, f"{stem}.md"),
                         (now + 1000, now + 1000) if i == 0 else (now + i * 10, now + i * 10))
                lines.append(f"- [{stem}]({stem}.md) — a pointer hook for topic {i}")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(lines) + "\n")   # 8 pointer lines -> 9 logical lines
            state = memory_lint.collect_state(d)
            _, idx_lines = memory_lint.measured_index(state["idx"])
            assert idx_lines == 9, idx_lines   # loud fixture guard
            assert int(memory_lint.LINE_CAP * memory_lint.FOLD_TARGET_PCT) == 6
            plan = memory_lint.class_d_count_fold(state, exclude_files=set())
            assert len(plan) == 3, [e["file"] for e in plan]   # mutated (<) -> 4
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


# --- 2026-08-23 mutation-probe: --auto-archive action-path coverage (37 not-covered survivors) ---
# The action mode (class A/B/C/D plan build, apply, dry-run/JSON output, orchestration)
# had zero test coverage. Each test below carries a `# L###:` comment naming the mutant it
# kills; every fs-mutating test uses its own tempdir (shared-working-tree discipline), every
# cap patch restores under try/finally, and stdin-reaching subprocesses pass input="".

SCRIPT = os.path.join(HERE, "..", "..", "..", "skills", "meta", "memory-lint", "scripts", "memory-lint.py")


def _class_a_fixture(d, stems=("stale-topic",)):
    """Write N SUPERSEDED memory files (0 inbound) + a MEMORY.md that triggers Class A."""
    lines = []
    for stem in stems:
        _write_memory(d, f"{stem}.md", "project", "a finished audit", "n/a")
        lines.append(f"- [{stem}]({stem}.md) — **SUPERSEDED** by [[new-topic]]")
    with open(os.path.join(d, "MEMORY.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def test_class_a_kept_when_only_inbound_link_uses_the_name_slug_not_the_stem():
    # A superseded file whose sole inbound [[wikilink]] resolves via `name:` slug (not
    # filename stem) must NOT be archived -- pre-fix, class_a_stale_superseded checked only
    # `target_stem in state["inbound"]`, so a slug-only inbound link was invisible and the file
    # would have been archived out from under the still-live referencer.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "old-thing-2026-01-01.md"), "w") as f:
            f.write("---\nname: old-thing-slug\n---\nno self-link here\n")
        with open(os.path.join(d, "referencer.md"), "w") as f:
            f.write("---\nname: referencer\n---\nstill needs [[old-thing-slug]] for context.\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [old thing](old-thing-2026-01-01.md) — **SUPERSEDED** by [[new-topic]]\n"
                     "- [referencer](referencer.md) — x\n")
        state = memory_lint.collect_state(d)
        assert memory_lint.class_a_stale_superseded(state) == [], "slug-only inbound link must block archival"


def test_class_a_archives_file_whose_only_link_is_to_itself():
    # L233 (inbound-set construction): a file linking to its OWN slug/stem is not evidence any
    # OTHER file references it. Pre-fix, that self-link landed in state["inbound"] the same as a
    # real external reference, so this fixture's file would have been wrongly kept (empty plan).
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "old-thing-2026-01-01.md"), "w") as f:
            f.write("---\nname: old-thing-slug\n---\nsee also [[old-thing-slug]] (self-reference only).\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [old thing](old-thing-2026-01-01.md) — **SUPERSEDED** by [[new-topic]]\n")
        state = memory_lint.collect_state(d)
        assert "old-thing-slug" not in state["inbound"], state["inbound"]
        plan = memory_lint.class_a_stale_superseded(state)
        assert len(plan) == 1 and plan[0]["from"] == "old-thing-2026-01-01.md", plan


def test_self_link_exclusion_does_not_swallow_a_different_files_matching_stem():
    # Rule-13 validator catch on the self-link fix above: a naive `t == own_slug` self-link check
    # is blind to precedence -- if file A's `name:` slug collides with a DIFFERENT file B's raw
    # filename stem, A linking to B (by that shared string) must still resolve to B, not be
    # misread as A linking to itself. compute_reachable's own resolver already applies stem-wins-
    # over-slug precedence for this exact ambiguity; the inbound-set builder must match it.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "other-target.md"), "w") as f:
            f.write("---\nname: shared-key\n---\nlinks elsewhere: [[shared-key]]\n")
        with open(os.path.join(d, "shared-key.md"), "w") as f:
            f.write("---\nname: unrelated-name\n---\nno outbound links\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [other-target](other-target.md) — **SUPERSEDED** by [[new-topic]]\n"
                     "- [shared-key](shared-key.md) — y\n")
        state = memory_lint.collect_state(d)
        assert "shared-key" in state["inbound"], state["inbound"]   # resolves to shared-key.md, not a self-link
        findings, _, _ = memory_lint.detector_findings(state)
        assert not any("shared-key.md" in f for f in findings), findings   # must not be a false ORPHAN
        # blind-spot-hunter catch: inbound must hold the RESOLVED stem, not the raw token --
        # otherwise other-target's own outbound link to shared-key.md would credit other-target
        # itself (via its own matching slug), wrongly keeping it out of Class A archival.
        plan = memory_lint.class_a_stale_superseded(state)
        assert len(plan) == 1 and plan[0]["from"] == "other-target.md", plan


def test_class_a_skips_archival_when_the_target_slug_is_duplicated():
    # Blind-spot-hunter catch: two files sharing one name: slug make any [[slug]] link to either
    # one ambiguous. Pre-fix, class_a_stale_superseded resolved that ambiguity silently and
    # non-deterministically (whichever file os.listdir happened to return first won the slug),
    # so a genuine back-link could still lose the race and the wrong file got archived. The
    # dup_slugs guard must refuse to archive regardless of which file wins that resolution.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "succ.md"), "w") as f:
            f.write("---\nname: topic-x\n---\nSupersedes [[topic-x]] (duplicate-slug back-link).\n")
        with open(os.path.join(d, "pred.md"), "w") as f:
            f.write("---\nname: topic-x\n---\npredecessor body, no outbound links\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [pred](pred.md) — **SUPERSEDED** by [[succ]]\n- [succ](succ.md) — current\n")
        state = memory_lint.collect_state(d)
        assert sorted(state["dup_slugs"].get("topic-x", [])) == ["pred.md", "succ.md"], state["dup_slugs"]
        assert memory_lint.class_a_stale_superseded(state) == [], "duplicate slug must block archival"
        findings, _, _ = memory_lint.detector_findings(state)
        assert any("DUPLICATE SLUG" in f and "topic-x" in f for f in findings), findings


def test_duplicate_slug_does_not_false_positive_as_orphan():
    # Rule-13 validator catch: dropping inbound's raw-token OR-check (the resolved-stem fix
    # above) accidentally removed the only thing that had kept a duplicate-slug file out of a
    # false ORPHAN finding -- a genuine third-file link to the shared slug resolves to only ONE
    # of the two holders, so the OTHER holder must not be reported as "no links in or out" when
    # its slug is simply ambiguous, not actually unreferenced. DUPLICATE SLUG already carries
    # that signal; ORPHAN and linked_count must defer to it instead of double-reporting rot.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "apple.md"), "w") as f:
            f.write("---\nname: shared\n---\nno outbound links\n")
        with open(os.path.join(d, "banana.md"), "w") as f:
            f.write("---\nname: shared\n---\nno outbound links\n")
        with open(os.path.join(d, "linker.md"), "w") as f:
            f.write("---\nname: linker\n---\ngenuine link: [[shared]]\n")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [apple](apple.md) — x\n- [banana](banana.md) — y\n- [linker](linker.md) — z\n")
        state = memory_lint.collect_state(d)
        findings, _, linked_count = memory_lint.detector_findings(state)
        assert not any(f.startswith("ORPHAN:") for f in findings), findings
        assert linked_count == 3, linked_count


def _cc_slug(path):
    # Claude Code's own rule: every non-alphanumeric char becomes "-" (GH #423).
    return "".join(c if c.isascii() and c.isalnum() else "-" for c in path)


def test_memory_dir_slug_replaces_every_non_alphanumeric():
    # GH #423: the resolver used to turn only "/" into "-", so a repo path with a
    # dot, space or underscore resolved to a store Claude Code never writes.
    resolver = os.path.join(HERE, "..", "..", "..", "scripts", "_lib", "memory-dir.py")
    env = {k: v for k, v in os.environ.items()
           if k not in ("CLAUDE_CONFIG_DIR", "CLAUDE_CODE_PROJECT_DIR_NAME")}
    with tempfile.TemporaryDirectory() as d:
        repo = os.path.join(d, "a.b c_d")
        os.mkdir(repo)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        root = os.path.realpath(repo)
        enc = subprocess.run(["python3", resolver, "--enc"], cwd=repo, env=env,
                             capture_output=True, text=True, check=True).stdout.strip()
        assert enc == _cc_slug(root), enc
        assert "a-b-c-d" in enc, enc


def test_memory_dir_falls_back_to_cwd_when_not_a_git_repo():
    # L185: memory_dir shells `git rev-parse --show-toplevel` with check=True; in a non-repo
    # cwd git exits 128 -> except -> root=cwd. Mutated check=False swallows the failure and
    # derives the path from empty stdout instead.
    orig_cwd = os.getcwd()
    saved = {k: os.environ.pop(k, None) for k in ("CLAUDE_CONFIG_DIR", "CLAUDE_CODE_PROJECT_DIR_NAME")}
    try:
        with tempfile.TemporaryDirectory() as d:
            os.chdir(d)
            result = memory_lint.memory_dir(None)
            expected = os.path.join(os.path.expanduser("~/.claude/projects"),
                                    _cc_slug(os.getcwd()), "memory")
            assert result == expected, result
    finally:
        os.chdir(orig_cwd)
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v


def _build_topic(path, total_bytes):
    # Short first paragraph (blank line after) so class_b's L1066 first-para proxy accepts the
    # candidate, then pad to an exact byte size for the boundary tests.
    header = "---\nname: t\n---\nintro\n\n"
    body = total_bytes - len(header.encode("utf-8"))
    with open(path, "w") as f:
        f.write(header + "x" * body)
    assert os.path.getsize(path) == total_bytes   # loud setup guard


def _verbose_pointer(nchars):
    base = "- [t](t.md) — "
    return base + "x" * (nchars - len(base))


def _class_b_state(d, topic_bytes, pointer_chars):
    _build_topic(os.path.join(d, "t.md"), topic_bytes)
    with open(os.path.join(d, "MEMORY.md"), "w") as f:
        f.write(_verbose_pointer(pointer_chars) + "\n")
    return memory_lint.collect_state(d)


def test_class_b_collapses_verbose_pointer_over_thresholds():
    # L1058 (fname in files), L1066 (pointer >= 1.2x first-para proxy), L1081 (delta_bytes),
    # and the L1048/L1043 early-returns -- all exercised by producing a non-empty plan.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = 10_000, 300
        with tempfile.TemporaryDirectory() as d:
            state = _class_b_state(d, topic_bytes=6000, pointer_chars=260)
            plan = memory_lint.class_b_near_budget_collapse(state)
            assert len(plan) == 1, plan
            e = plan[0]
            stub = "- [t](t.md) — see [[t]] for full record"
            assert e["action"] == "rewrite_pointer" and e["to"] == stub, e
            assert e["delta_bytes"] == len(stub.encode()) - len(e["from"].encode()), e  # L1081
            assert e["delta_bytes"] < 0, e   # collapse saves bytes
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_b_topic_size_boundary_is_exclusive_at_5120():
    # L1061: `topic_size <= 5*1024`. 5120 excluded, 5121 included. Mutated (<) includes 5120.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = 10_000, 300
        with tempfile.TemporaryDirectory() as d5120:
            s = _class_b_state(d5120, topic_bytes=5120, pointer_chars=260)
            assert memory_lint.class_b_near_budget_collapse(s) == []   # 5120<=5120 skipped
        with tempfile.TemporaryDirectory() as d5121:
            s = _class_b_state(d5121, topic_bytes=5121, pointer_chars=260)
            assert len(memory_lint.class_b_near_budget_collapse(s)) == 1
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_b_pointer_length_boundary_is_inclusive_at_250():
    # L1056: `len(pointer) < 250` skip. 249 skipped, 250 kept. Mutated (<=) skips 250 too.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = 10_000, 300
        with tempfile.TemporaryDirectory() as d249:
            s = _class_b_state(d249, topic_bytes=6000, pointer_chars=249)
            assert memory_lint.class_b_near_budget_collapse(s) == []
        with tempfile.TemporaryDirectory() as d250:
            s = _class_b_state(d250, topic_bytes=6000, pointer_chars=250)
            assert len(memory_lint.class_b_near_budget_collapse(s)) == 1
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_b_first_para_proxy_is_inclusive_at_exact_1_2x():
    # L1066: `len(full_line) >= 1.2 * max(len(first_para), 1)`. A pointer exactly 1.2x its topic's
    # first paragraph must collapse (inclusive `>=`); mutated `>` drops the exact-boundary case.
    # first_para == 210 (frontmatter+194 body chars) -> pointer must be 252 (== 1.2*210).
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = 10_000, 300
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "t.md"), "w") as f:
                f.write("---\nname: t\n---\n" + "y" * 194 + "\n\n" + "x" * 5200)  # first_para len 210
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write(_verbose_pointer(252) + "\n")   # 252 == 1.2 * 210 exactly
            state = memory_lint.collect_state(d)
            fp = memory_lint.read_file(d, "t.md").split("\n\n", 1)[0]
            assert len(fp) == 210 and 252 == 1.2 * len(fp), (len(fp), 1.2 * len(fp))  # loud boundary guard
            assert len(memory_lint.class_b_near_budget_collapse(state)) == 1   # 252>=252 keeps; >252 drops
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_b_returns_nothing_under_budget_trigger():
    # L1048: `pct < 80` early return. Well under the cap -> no plan regardless of verbosity.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = 10_000, 1_000_000
        with tempfile.TemporaryDirectory() as d:
            s = _class_b_state(d, topic_bytes=6000, pointer_chars=260)
            assert memory_lint.class_b_near_budget_collapse(s) == []
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_class_c_rewrites_dangling_wikilink_to_ledger():
    # L1122 (f not in files), L1125 (resolvable skip), L1128 (dangling-vs-archived fork).
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "src.md", "project", "has a dangling link", "see [[ghost-topic]]")
        _write_memory(d, "project_external_evals_ledger.md", "project", "the ledger", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [src](src.md) — x\n- [project_external_evals_ledger](project_external_evals_ledger.md) — l\n")
        state = memory_lint.collect_state(d)
        plan = memory_lint.class_c_dangling_link_rewrite(state)
        assert plan == [{"action": "rewrite_wikilink", "file": "src.md", "old": "[[ghost-topic]]",
                         "new": "[[project_external_evals_ledger]]", "reason": "dangling-target"}], plan


def test_class_c_rewrites_archived_link_to_supersedence_target():
    # L1109 (`if not m: continue` on SUPERSEDED lines), L1113 (`if not pm: continue`),
    # L1128 (archived branch). Only test that executes the SUPERSEDED-line parse.
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "_archive", "2026-01-01"))
        _write_memory(os.path.join(d, "_archive", "2026-01-01"), "old-topic.md", "project", "archived", "n/a")
        _write_memory(d, "new-topic.md", "project", "the successor", "n/a")
        _write_memory(d, "src.md", "project", "links an archived topic", "see [[old-topic]]")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [old-topic](old-topic.md) — **SUPERSEDED** by [[new-topic]]\n"
                     "- [new-topic](new-topic.md) — y\n- [src](src.md) — z\n")
        state = memory_lint.collect_state(d)
        e = [x for x in memory_lint.class_c_dangling_link_rewrite(state) if x["file"] == "src.md"][0]
        assert e["old"] == "[[old-topic]]" and e["new"] == "[[new-topic]]", e
        assert e["reason"] == "archived-with-supersedence", e


def test_class_c_ignores_link_that_resolves_by_slug_only():
    # L1125: `t in stems or t in slug_set`. A link resolving via name-slug only (not stem) must
    # be skipped (continue). Mutated (and) treats it as unresolved -> spurious rewrite entry.
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "hub-file.md"), "w") as f:
            f.write("---\nname: hubslug\n---\na hub\n")  # slug hubslug != stem hub-file
        _write_memory(d, "resolver.md", "project", "resolves via slug", "see [[hubslug]]")
        _write_memory(d, "dangler.md", "project", "dangles", "see [[ghost-x]]")
        _write_memory(d, "project_external_evals_ledger.md", "project", "ledger", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [hub-file](hub-file.md) — h\n- [resolver](resolver.md) — r\n"
                     "- [dangler](dangler.md) — d\n"
                     "- [project_external_evals_ledger](project_external_evals_ledger.md) — l\n")
        state = memory_lint.collect_state(d)
        plan = memory_lint.class_c_dangling_link_rewrite(state)
        files = {e["file"] for e in plan}
        assert "dangler.md" in files, plan       # positive control (else vacuous)
        assert "resolver.md" not in files, plan   # slug-resolved link must not be rewritten


def test_apply_action_plan_moves_superseded_files_and_stubs_pointers():
    # L1237 (os.makedirs archive_dir, exist_ok=True -- 2 entries prove no FileExistsError),
    # L1255 (bytes_saved delta). Asserts the REAL fs effect: files moved (mv, not rm), pointer stubbed.
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d, stems=("stale-topic", "stale-topic2"))
        state = memory_lint.collect_state(d)
        plan = {"A": memory_lint.class_a_stale_superseded(state), "B": [], "C": [], "D": []}
        assert len(plan["A"]) == 2, plan   # positive control
        saved, applied = memory_lint.apply_action_plan(state, plan)
        today = time.strftime("%Y-%m-%d")
        for fn in ("stale-topic.md", "stale-topic2.md"):
            assert not os.path.exists(os.path.join(d, fn)), fn                    # src removed
            assert os.path.exists(os.path.join(d, "_archive", today, fn)), fn     # moved -> mv not rm
        idx_after = open(state["index_path"]).read()
        assert "**SUPERSEDED**" not in idx_after, idx_after                        # pointer stubbed
        exp = 0
        for e in plan["A"]:
            new_line = memory_lint.STUB_TEMPLATE.format(e["from"][:-3], today, e["from"])
            exp += len(e["old_pointer_line"].encode()) - len(new_line.encode())
        assert saved == exp, (saved, exp)   # L1255


def test_class_a_archive_stub_is_not_reported_as_stale_pointer():
    # Class A's stub points at _archive/<date>/<file>; the file exists there, so lint must not
    # call it STALE POINTER (else the cold layer leaves every archived entry as a permanent finding).
    # Red cycle: before the fix lint printed `STALE POINTER ... but file missing`, exit 2.
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d, stems=("stale-topic",))
        _write_memory(d, "live.md", "project", "live", "body")  # keeps the store non-empty after the move
        with open(os.path.join(d, "MEMORY.md"), "a") as f:
            f.write("- [live](live.md) — x\n")
        state = memory_lint.collect_state(d)
        plan = {"A": memory_lint.class_a_stale_superseded(state), "B": [], "C": [], "D": []}
        assert len(plan["A"]) == 1, plan   # positive control
        memory_lint.apply_action_plan(state, plan)
        findings, _, _ = memory_lint.detector_findings(memory_lint.collect_state(d))
        assert not any("STALE POINTER" in x for x in findings), findings


def test_archive_stub_whose_file_is_gone_is_still_stale():
    # Guard against over-fixing: only an existing archived target is accepted.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "live.md", "project", "live", "body")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [live](live.md) — x\n- [gone](_archive/2026-01-01/gone.md) — archived on-demand\n")
        findings, _, _ = memory_lint.detector_findings(memory_lint.collect_state(d))
        assert any("STALE POINTER" in x and "gone.md" in x for x in findings), findings


def test_class_a_skips_archive_that_would_strand_a_child_topic():
    # `kid` is reachable only through `old` ([[kid]] in old's body). Archiving `old` would
    # leave `kid` unreachable, so lint would then report UNINDEXED for a file Class A just orphaned.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "old.md", "project", "finished", "child is [[kid]]")
        _write_memory(d, "kid.md", "project", "child", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [old](old.md) — **SUPERSEDED** by [[new-topic]]\n")
        state = memory_lint.collect_state(d)
        # positive control: kid is reachable today, only via old
        assert "kid" in memory_lint.compute_reachable(
            state["files"], state["slugs"], state["links_out"], state["referenced"])
        assert memory_lint.class_a_stale_superseded(state) == []


def test_class_a_skips_archive_that_pushes_a_topic_past_two_hops():
    # `kid` is 2 hops deep via `hub`. Archiving `hub` leaves only a longer route through `other` (3 hops).
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "hub.md", "project", "hub", "see [[kid]]")
        _write_memory(d, "other.md", "project", "other", "see [[deep]]")
        _write_memory(d, "deep.md", "project", "deep", "see [[kid]]")
        _write_memory(d, "kid.md", "project", "child", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [hub](hub.md) — **SUPERSEDED** by [[new-topic]]\n- [other](other.md) — o\n")
        state = memory_lint.collect_state(d)
        depths = memory_lint.compute_depths(state["files"], state["slugs"], state["links_out"], state["referenced"])
        assert depths["kid"] == 2 and depths["deep"] == 2, depths   # control: kid is 2 hops today
        assert memory_lint.class_a_stale_superseded(state) == []


def test_class_a_skips_archive_when_its_line_also_carries_the_only_pointer_to_another_topic():
    # Apply replaces the whole line with a stub, so a second `](w.md)` on the same line is lost with it.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "x.md", "project", "finished", "n/a")
        _write_memory(d, "w.md", "project", "other", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [x](x.md) — **SUPERSEDED** by [[y]] see also [w](w.md)\n")
        state = memory_lint.collect_state(d)
        assert "w.md" in state["referenced"]   # control: w is indexed only through that line
        assert memory_lint.class_a_stale_superseded(state) == []
        with open(os.path.join(d, "MEMORY.md"), "w") as f:   # control: without the shared pointer A archives x
            f.write("- [x](x.md) — **SUPERSEDED** by [[y]]\n- [w](w.md) — w\n")
        assert len(memory_lint.class_a_stale_superseded(memory_lint.collect_state(d))) == 1


def test_class_a_skips_archive_when_the_file_has_a_second_live_pointer():
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "x.md", "project", "finished", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [x](x.md) — **SUPERSEDED** by [[y]]\n- [x again](x.md) — still wanted\n")
        state = memory_lint.collect_state(d)
        assert memory_lint.class_a_stale_superseded(state) == []
        with open(os.path.join(d, "MEMORY.md"), "w") as f:   # control: a single pointer is archived
            f.write("- [x](x.md) — **SUPERSEDED** by [[y]]\n")
        assert len(memory_lint.class_a_stale_superseded(memory_lint.collect_state(d))) == 1


def test_class_a_with_an_inline_comment_on_the_pointer_line_never_leaves_a_stale_pointer():
    # Regression: the plan used to carry the comment-stripped line, which has no match in the raw index;
    # apply then moved the file anyway and left the pointer behind (lint: STALE POINTER, exit 1).
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "x.md", "project", "finished", "n/a")
        _write_memory(d, "keep.md", "project", "keep", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [x](x.md) <!-- old --> **SUPERSEDED** by [[y]]\n- [keep](keep.md) — k\n")
        state = memory_lint.collect_state(d)
        plan = {"A": memory_lint.class_a_stale_superseded(state), "B": [], "C": [], "D": []}
        memory_lint.apply_action_plan(state, plan)
        findings, _, _ = memory_lint.detector_findings(memory_lint.collect_state(d))
        assert not any("STALE POINTER" in x for x in findings), findings
        # Such a line is skipped, not half-applied: the file stays where its pointer says it is.
        assert os.path.exists(os.path.join(d, "x.md"))


def test_apply_does_not_move_a_file_whose_pointer_line_is_gone_from_the_index():
    # A plan built against a stale index must not archive the file when the pointer rewrite finds nothing.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "x.md", "project", "finished", "n/a")
        _write_memory(d, "keep.md", "project", "keep", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [keep](keep.md) — k\n")
        state = memory_lint.collect_state(d)
        entry = {"action": "move", "from": "x.md", "to_archive_subdir": "2026-01-01",
                 "old_pointer_line": "- [x](x.md) — **SUPERSEDED** by [[y]]", "successor": "y"}
        memory_lint.apply_action_plan(state, {"A": [entry], "B": [], "C": [], "D": []})
        assert os.path.exists(os.path.join(d, "x.md"))


def test_class_d_hop_guard_alone_blocks_a_deindex_that_leaves_a_three_hop_backup():
    # t0 stays reachable after deindexing (t4 -> t3 -> t0) but would sit 3 hops deep, past MAX_HOPS.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 330
        with tempfile.TemporaryDirectory() as d:
            now = 2_000_000_000
            bodies = {"t0": "leaf", "t1": "leaf", "t2": "leaf", "t3": "see [[t0]]", "t4": "see [[t3]]", "t5": "leaf"}
            lines = []
            for i, stem in enumerate(["t0", "t1", "t2", "t3", "t4", "t5"]):
                with open(os.path.join(d, f"{stem}.md"), "w") as f:
                    f.write(f"---\nname: {stem}\n---\n{bodies[stem]}\n")
                os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
                if stem != "t3":   # t3 is deliberately unindexed: reachable only through t4
                    lines.append(f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(lines) + "\n")
            state = memory_lint.collect_state(d)
            assert len(state["idx"].encode()) / memory_lint.BYTE_CAP >= 0.80, "fixture must cross the trigger"
            without_t0 = state["referenced"] - {"t0.md"}
            same = memory_lint.compute_reachable(state["files"], state["slugs"], state["links_out"], without_t0)
            assert "t0" in same, "control: reachability alone would allow deindexing t0"
            plan = memory_lint.class_d_count_fold(state, exclude_files=set())
            assert "t0.md" not in [e["file"] for e in plan], plan
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def _d_store_with_t0_line(d, t0_line, y_file=False):
    """Six topics sized to cross the Class D trigger at BYTE_CAP=480; t0 is oldest, reachable via t5."""
    now = 2_000_000_000
    names = [f"t{i}" for i in range(6)]
    bodies = {"t5": "see [[t0]] [[t1]] [[t2]] [[t3]] [[t4]]"}
    lines = []
    for i, stem in enumerate(names):
        with open(os.path.join(d, f"{stem}.md"), "w") as f:
            f.write(f"---\nname: {stem}\n---\n{bodies.get(stem, 'leaf')}\n")
        os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
        lines.append(t0_line if i == 0 else f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here")
    if y_file:
        _write_memory(d, "y.md", "project", "y", "n/a")
    with open(os.path.join(d, "MEMORY.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return memory_lint.collect_state(d)


def test_class_d_skips_a_deindex_whose_line_also_carries_the_only_pointer_to_another_topic():
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 380
        plain = "- [t0](t0.md) — a short pointer hook for topic 0 here"
        with tempfile.TemporaryDirectory() as d:
            state = _d_store_with_t0_line(d, plain)
            assert "t0.md" in [e["file"] for e in memory_lint.class_d_count_fold(state, set())], "control"
        with tempfile.TemporaryDirectory() as d:
            state = _d_store_with_t0_line(d, plain + " also [y](y.md)", y_file=True)
            assert "y.md" in state["referenced"]
            assert len(state["idx"].encode()) / memory_lint.BYTE_CAP >= 0.80
            plan = memory_lint.class_d_count_fold(state, set())
            assert "t0.md" not in [e["file"] for e in plan], plan
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_d_never_plans_a_line_that_carries_an_inline_comment():
    # apply cannot match text that runs across a comment, so such a plan entry would be a lie.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 380
        with tempfile.TemporaryDirectory() as d:
            state = _d_store_with_t0_line(d, "- [t0](t0.md) — a short pointer hook <!-- keep me --> for topic 0")
            plan = memory_lint.class_d_count_fold(state, set())
            assert plan, "control: other candidates still planned"
            assert "t0.md" not in [e["file"] for e in plan], plan
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_b_never_plans_a_line_that_carries_an_inline_comment():
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 300
        with tempfile.TemporaryDirectory() as d:
            _write_memory(d, "big.md", "project", "big", "short first paragraph\n\n" + "x" * 6000)
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("- [big](big.md) — " + "detail " * 40 + "\n")
            assert len(memory_lint.class_b_near_budget_collapse(memory_lint.collect_state(d))) == 1, "control"
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("- [big](big.md) — " + "detail " * 40 + "<!-- private note -->\n")
            assert memory_lint.class_b_near_budget_collapse(memory_lint.collect_state(d)) == []
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_b_does_not_annotate_a_topic_whose_pointer_rewrite_did_not_land():
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "big.md", "project", "big", "body")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [big](big.md) — short\n")
        state = memory_lint.collect_state(d)
        entry = {"action": "rewrite_pointer", "from": "- [big](big.md) — a line no longer in the index",
                 "to": "- [big](big.md) — stub", "from_chars": 10, "to_chars": 5, "delta_bytes": -5,
                 "topic_file": "big.md"}
        before = open(os.path.join(d, "big.md")).read()
        memory_lint.apply_action_plan(state, {"A": [], "B": [entry], "C": [], "D": []})
        assert open(os.path.join(d, "big.md")).read() == before


def test_a_and_b_together_never_strand_a_topic_each_relied_on_the_other_to_keep():
    # Alone, A's stubbed line and B's collapsed line each leave `y` pointed to by the other's line.
    # Applied together both lines lose `y`; B's guard must see A's rewrite (build_plan composes them).
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 400
        with tempfile.TemporaryDirectory() as d:
            _write_memory(d, "old.md", "project", "finished", "n/a")
            _write_memory(d, "big.md", "project", "big", "short first paragraph\n\n" + "x" * 6000)
            _write_memory(d, "y.md", "project", "y", "n/a")
            _write_memory(d, "new.md", "project", "new", "n/a")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("- [old](old.md) — **SUPERSEDED** by [[new]] also [y](y.md)\n"
                        "- [big](big.md) — " + "detail " * 40 + "see [y](y.md)\n"
                        "- [new](new.md) — hook\n")
            state = memory_lint.collect_state(d)
            # controls: each class alone would plan its change
            assert len(memory_lint.class_a_stale_superseded(state)) == 1
            assert len(memory_lint.class_b_near_budget_collapse(state)) == 1
            memory_lint.apply_action_plan(state, memory_lint.build_plan(state))
            findings, _, _ = memory_lint.detector_findings(memory_lint.collect_state(d))
            assert not any("UNINDEXED" in x for x in findings), findings
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_b_annotates_the_topic_when_its_pointer_rewrite_lands():
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "big.md", "project", "big", "body")
        line = "- [big](big.md) — a long hook"
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write(line + "\n")
        state = memory_lint.collect_state(d)
        entry = {"action": "rewrite_pointer", "from": line, "to": "- [big](big.md) — stub",
                 "from_chars": len(line), "to_chars": 22, "delta_bytes": 22 - len(line), "topic_file": "big.md"}
        memory_lint.apply_action_plan(state, {"A": [], "B": [entry], "C": [], "D": []})
        assert "pointer collapsed" in open(os.path.join(d, "big.md")).read()
        assert "- [big](big.md) — stub" in open(os.path.join(d, "MEMORY.md")).read()


def test_class_b_plan_and_apply_replace_the_same_lines_when_a_long_line_is_duplicated():
    # The same long line twice, both carrying the only pointers to y: apply collapses every copy, so the
    # plan must too, or the guard sees y kept by a copy that apply is about to collapse as well.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 400
        with tempfile.TemporaryDirectory() as d:
            _write_memory(d, "a.md", "project", "a", "short first paragraph\n\n" + "x" * 6000)
            _write_memory(d, "y.md", "project", "y", "n/a")
            line = "- [a](a.md) — " + "detail " * 40
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write(line + "\n" + line + "\n")
            control = memory_lint.class_b_near_budget_collapse(memory_lint.collect_state(d))
            assert len(control) == 1, "control: without y the duplicated line collapses once"
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write(line + " also [y](y.md)\n" + line + " also [y](y.md)\n")
            state = memory_lint.collect_state(d)
            assert memory_lint.class_b_near_budget_collapse(state) == []
            memory_lint.apply_action_plan(state, memory_lint.build_plan(state))
            findings, _, _ = memory_lint.detector_findings(memory_lint.collect_state(d))
            assert not any("UNINDEXED" in x for x in findings), findings
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_a_does_not_touch_the_pointer_when_the_archive_destination_already_exists():
    # A second run on the same day finds _archive/<today>/old.md already there. Rewriting the pointer
    # while old.md stays at top level would leave it unindexed.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "old.md", "project", "finished", "n/a")
        _write_memory(d, "keep.md", "project", "keep", "n/a")
        line = "- [old](old.md) — **SUPERSEDED** by [[keep]]"
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write(line + "\n- [keep](keep.md) — k\n")
        state = memory_lint.collect_state(d)
        planned = memory_lint.class_a_stale_superseded(state)   # built before the collision, as a dry-run would be
        assert len(planned) == 1   # control: no collision, A plans it
        today = time.strftime("%Y-%m-%d")
        os.makedirs(os.path.join(d, "_archive", today))
        _write_memory(os.path.join(d, "_archive", today), "old.md", "project", "earlier copy", "n/a")
        # apply must refuse on its own: the stale plan still names old.md, and the destination now exists
        assert memory_lint.class_a_stale_superseded(state) == [], "plan-time guard also sees the collision"
        memory_lint.apply_action_plan(state, {"A": planned, "B": [], "C": [], "D": []})
        findings, _, _ = memory_lint.detector_findings(memory_lint.collect_state(d))
        assert not any("UNINDEXED" in x or "STALE POINTER" in x for x in findings), findings
        assert os.path.exists(os.path.join(d, "old.md"))


def test_b_and_d_together_never_strand_a_topic_each_relied_on_the_other_to_keep():
    # B collapses `big`'s line, D deindexes t0's line; both lines carry a pointer to y. D must judge on
    # the index with B's collapse already applied, where only t0's line still points at y.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 700
        with tempfile.TemporaryDirectory() as d:
            now = 2_000_000_000
            lines = []
            for i in range(6):
                stem = f"t{i}"
                body = "see [[t0]] [[t1]] [[t2]] [[t3]] [[t4]]" if i == 5 else "leaf"
                _write_memory(d, f"{stem}.md", "project", stem, body)
                os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
                tail = " also [y](y.md)" if i == 0 else ""
                lines.append(f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here{tail}")
            _write_memory(d, "big.md", "project", "big", "short first paragraph\n\n" + "x" * 6000)
            _write_memory(d, "y.md", "project", "y", "n/a")
            os.utime(os.path.join(d, "big.md"), (now + 900, now + 900))
            lines.append("- [big](big.md) — " + "detail " * 40 + "see [y](y.md)")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(lines) + "\n")
            state = memory_lint.collect_state(d)
            assert len(memory_lint.class_b_near_budget_collapse(state)) == 1, "control: B plans big"
            alone = memory_lint.class_d_count_fold(state, exclude_files={"big.md"})
            assert "t0.md" in [e["file"] for e in alone], "control: D alone would deindex t0"
            memory_lint.apply_action_plan(state, memory_lint.build_plan(state))
            findings, _, _ = memory_lint.detector_findings(memory_lint.collect_state(d))
            assert not any("UNINDEXED" in x for x in findings), findings
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_a_guard_is_cumulative_over_the_plans_earlier_moves():
    # old1 and old2 both link kid, which has no other pointer. Either can go alone; both together strand it.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "old1.md", "project", "finished", "child [[kid]]")
        _write_memory(d, "old2.md", "project", "finished", "child [[kid]]")
        _write_memory(d, "kid.md", "project", "child", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [old1](old1.md) — **SUPERSEDED** by [[new]]\n- [old2](old2.md) — **SUPERSEDED** by [[new]]\n")
        plan = memory_lint.class_a_stale_superseded(memory_lint.collect_state(d))
        assert [e["from"] for e in plan] == ["old1.md"], plan


def test_class_a_never_archives_a_chapter_index():
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "index-old.md", "reference", "a chapter", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [index-old](index-old.md) — **SUPERSEDED** by [[new-topic]]\n")
        state = memory_lint.collect_state(d)
        assert memory_lint.class_a_stale_superseded(state) == []
        _write_memory(d, "plain-old.md", "reference", "a topic", "n/a")   # control: same line, ordinary name
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [plain-old](plain-old.md) — **SUPERSEDED** by [[new-topic]]\n")
        assert len(memory_lint.class_a_stale_superseded(memory_lint.collect_state(d))) == 1


def test_class_a_ignores_a_superseded_line_that_only_exists_inside_a_comment():
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "old.md", "project", "finished", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("<!--\n- [old](old.md) — **SUPERSEDED** by [[new-topic]]\n-->\n")
        state = memory_lint.collect_state(d)
        assert memory_lint.class_a_stale_superseded(state) == []
        with open(os.path.join(d, "MEMORY.md"), "w") as f:   # control: the same line outside a comment
            f.write("- [old](old.md) — **SUPERSEDED** by [[new-topic]]\n")
        assert len(memory_lint.class_a_stale_superseded(memory_lint.collect_state(d))) == 1


def test_class_a_apply_leaves_a_byte_identical_comment_copy_untouched():
    # the same pointer line sits live and inside a comment block; only the live one may change.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "old.md", "project", "finished", "n/a")
        _write_memory(d, "keep.md", "project", "keep", "n/a")
        line = "- [old](old.md) — **SUPERSEDED** by [[new-topic]]"
        comment = f"<!--\n{line}\n-->\n"
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write(comment + line + "\n- [keep](keep.md) — k\n")
        state = memory_lint.collect_state(d)
        plan = {"A": memory_lint.class_a_stale_superseded(state), "B": [], "C": [], "D": []}
        assert len(plan["A"]) == 1, plan   # positive control
        memory_lint.apply_action_plan(state, plan)
        after = open(os.path.join(d, "MEMORY.md")).read()
        assert after.startswith(comment), after
        assert "_archive/" in after.split("-->\n", 1)[1], after


def test_class_b_skips_a_collapse_that_drops_the_only_pointer_to_another_topic():
    # the long pointer line also carries `](y.md)`, y's only index pointer. Collapsing the
    # line to a stub would delete it and strand y.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 300
        with tempfile.TemporaryDirectory() as d:
            _write_memory(d, "big.md", "project", "big", "short first paragraph\n\n" + "x" * 6000)
            _write_memory(d, "y.md", "project", "y", "n/a")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("- [big](big.md) — " + "detail " * 40 + "\n")
            control = memory_lint.class_b_near_budget_collapse(memory_lint.collect_state(d))
            assert len(control) == 1, "control: without the second pointer B collapses this line"
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("- [big](big.md) — " + "detail " * 40 + "also [y](y.md)\n")
            state = memory_lint.collect_state(d)
            assert "y.md" in state["referenced"]
            assert memory_lint.class_b_near_budget_collapse(state) == []
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def _class_d_store(d, names, bodies=None, comment_first=None):
    """Six-entry store sized to cross the Class D trigger at BYTE_CAP=480; mtimes ascend with index."""
    now = 2_000_000_000
    lines = []
    for i, stem in enumerate(names):
        body = (bodies or {}).get(stem, f"some memory content about {stem}")
        with open(os.path.join(d, f"{stem}.md"), "w") as f:
            f.write(f"---\nname: {stem}\n---\n{body}\n")
        os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
        lines.append(f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here")
    with open(os.path.join(d, "MEMORY.md"), "w") as f:
        f.write((comment_first or "") + "\n".join(lines) + "\n")
    return lines


def test_class_d_never_deindexes_a_chapter_index():
    # index-old is the oldest and stays reachable through topic-5, so only the name guard stops it.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 480
        with tempfile.TemporaryDirectory() as d:
            names = ["index-old", "topic-1", "topic-2", "topic-3", "topic-4", "topic-5"]
            _class_d_store(d, names, {"topic-5": "links [[index-old]] [[topic-1]] [[topic-2]] [[topic-3]] [[topic-4]]"})
            state = memory_lint.collect_state(d)
            assert state["idx"] and len(state["idx"].encode()) / memory_lint.BYTE_CAP >= 0.80
            plan = memory_lint.class_d_count_fold(state, exclude_files=set())
            folded = [e["file"] for e in plan]
            assert folded, "control: Class D must still propose the other safe candidates"
            assert "index-old.md" not in folded, folded
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_d_apply_leaves_a_byte_identical_comment_copy_untouched():
    # topic-0's pointer line also sits, byte for byte, in a comment block above the live index.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 480
        with tempfile.TemporaryDirectory() as d:
            names = [f"topic-{i}" for i in range(6)]
            body5 = {"topic-5": " ".join(f"[[topic-{i}]]" for i in range(5))}
            line0 = "- [topic-0](topic-0.md) — a short pointer hook for topic 0 here"
            comment = f"<!--\n{line0}\n-->\n"
            _class_d_store(d, names, body5, comment_first=comment)
            state = memory_lint.collect_state(d)
            plan = {"A": [], "B": [], "C": [], "D": memory_lint.class_d_count_fold(state, exclude_files=set())}
            assert any(e["file"] == "topic-0.md" for e in plan["D"]), plan   # positive control
            memory_lint.apply_action_plan(state, plan)
            after = open(os.path.join(d, "MEMORY.md")).read()
            assert after.startswith(comment), after
            assert line0 not in after[len(comment):], after   # the live copy is the one removed
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_class_d_is_evaluated_after_class_a_has_removed_its_files():
    # x is reachable only through `old` (a Class A archive candidate). Judged on today's graph x
    # looks safe to deindex; once A has archived old, deindexing x would strand it.
    orig_line_cap, orig_byte_cap = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 480
        with tempfile.TemporaryDirectory() as d:
            names = ["x", "f1", "f2", "f3", "f4", "old"]
            lines = _class_d_store(d, names, {"old": "child is [[x]]"})
            idx = open(os.path.join(d, "MEMORY.md")).read().replace(
                lines[5], "- [old](old.md) — **SUPERSEDED** by [[new-topic]]" + " pad" * 14)
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write(idx)
            state = memory_lint.collect_state(d)
            naive = memory_lint.class_d_count_fold(state, exclude_files={"old.md"})
            assert "x.md" in [e["file"] for e in naive], naive   # control: the uncomposed plan is unsafe
            plan = memory_lint.build_plan(state)
            assert [e["from"] for e in plan["A"]] == ["old.md"], plan["A"]
            assert "x.md" not in [e["file"] for e in plan["D"]], plan["D"]
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line_cap, orig_byte_cap


def test_apply_action_plan_rewrites_dangling_wikilink_on_disk():
    # L1286: Class C bytes_saved + the atomic_write of the rewritten file.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "src.md", "project", "dangling", "see [[ghost-topic]]")
        _write_memory(d, "project_external_evals_ledger.md", "project", "ledger", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [src](src.md) — x\n- [project_external_evals_ledger](project_external_evals_ledger.md) — l\n")
        state = memory_lint.collect_state(d)
        plan = {"A": [], "B": [], "C": memory_lint.class_c_dangling_link_rewrite(state), "D": []}
        assert len(plan["C"]) == 1, plan   # positive control
        saved, applied = memory_lint.apply_action_plan(state, plan)
        src_after = open(os.path.join(d, "src.md")).read()
        assert "[[project_external_evals_ledger]]" in src_after, src_after
        assert "[[ghost-topic]]" not in src_after, src_after
        assert saved == len("[[ghost-topic]]".encode()) - len("[[project_external_evals_ledger]]".encode())  # L1286
        assert len(applied["C"]) == 1, applied


def test_apply_action_plan_deindexes_class_d_pointer_on_disk():
    # Class D's planning logic (class_d_count_fold) has coverage; its APPLICATION
    # (apply_action_plan actually removing the pointer line from MEMORY.md) did not --
    # unlike Class A/C above, which both have a dedicated apply-path test. Found via
    # 2026-09-01 deep-audit re-scan of this fix's own test coverage. Exercises the full
    # pipeline: class_d_count_fold -> apply_action_plan -> re-run the real detector to
    # confirm the deindexed file stays [[link]]-reachable, so it is not UNINDEXED --
    # the actual end-to-end guarantee the reachability guard exists to provide.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP = 10_000
        memory_lint.BYTE_CAP = 200
        with tempfile.TemporaryDirectory() as d:
            now = 2_000_000_000
            with open(os.path.join(d, "old-topic.md"), "w") as f:
                f.write("---\nname: old-topic\n---\nolder content, safe to fold\n")
            os.utime(os.path.join(d, "old-topic.md"), (now, now))
            with open(os.path.join(d, "anchor.md"), "w") as f:
                f.write("---\nname: anchor\n---\nlinks to [[old-topic]] so it stays reachable if deindexed\n")
            os.utime(os.path.join(d, "anchor.md"), (now + 1000, now + 1000))
            old_line = "- [old-topic](old-topic.md) — a pointer hook long enough to help cross the budget trigger here"
            anchor_line = "- [anchor](anchor.md) — a pointer hook that must survive this untouched, verbatim"
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write(old_line + "\n" + anchor_line + "\n")
            state = memory_lint.collect_state(d)
            idx_bytes = len(state["idx"].encode("utf-8"))
            assert idx_bytes / memory_lint.BYTE_CAP >= 0.80, "fixture must actually cross the trigger"

            plan_d = memory_lint.class_d_count_fold(state, exclude_files=set())
            assert [e["file"] for e in plan_d] == ["old-topic.md"], plan_d   # positive control
            plan = {"A": [], "B": [], "C": [], "D": plan_d}
            saved, applied = memory_lint.apply_action_plan(state, plan)

            idx_after = open(state["index_path"]).read()
            assert old_line not in idx_after, idx_after           # pointer line gone
            assert anchor_line in idx_after, idx_after             # untouched sibling survives verbatim
            assert os.path.exists(os.path.join(d, "old-topic.md")), "Class D must never delete the backing file"
            assert saved == len(old_line.encode("utf-8")) + 1, (saved, old_line)
            assert applied["D"] == [{"action": "deindex", "file": "old-topic.md"}], applied

            # End-to-end: re-run the REAL detector against the post-apply on-disk state and
            # confirm old-topic stays [[link]]-reachable, so it is not UNINDEXED.
            state_after = memory_lint.collect_state(d)
            findings, _, _ = memory_lint.detector_findings(state_after)
            assert not any("old-topic" in f for f in findings), findings
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_print_plan_projects_post_trim_size():
    # L1312: `new_bytes = max(idx_bytes + estimated_impact, 0)`. Two cases: clamp inert (arithmetic
    # governs -> kills '+'->'-') and clamp active (only max(...,0) makes it 0 -> kills removing max).
    state = {"idx": "- [x](x.md) — " + "z" * 180 + "\n", "d": "/tmp/x"}
    ib, _ = memory_lint.measured_index(state["idx"])

    def render(est):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            memory_lint.print_plan(state, {"A": [], "B": [], "C": [], "D": []}, est)
        return buf.getvalue()

    assert f"→ {ib - 50}B" in render(-50), render(-50)     # clamp inert
    assert "→ 0B" in render(-(ib + 100)), render(-(ib + 100))   # clamp active


def test_print_plan_reports_class_d_savings_separately():
    # L1335: d_bytes_saved = sum(len(old_pointer_line.encode()) + 1 for plan_d).
    line = "- [x](x.md) — a short pointer hook"
    plan = {"A": [], "B": [], "C": [], "D": [{"action": "deindex", "file": "x.md", "old_pointer_line": line}]}
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        memory_lint.print_plan({"idx": line + "\n", "d": "/tmp/x"}, plan, 0)
    assert f"-{len(line.encode()) + 1}B" in buf.getvalue(), buf.getvalue()


def _run_action_json(state, dry_run, yes):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        memory_lint.run_action_mode(state, argparse.Namespace(dry_run=dry_run, yes=yes, json=True))
    return json.loads(buf.getvalue())


def test_auto_archive_yes_applies_and_moves_file():
    # L1361 apply_now path + concurrent-guard PASS: --yes with no drift moves the Class A file.
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d)
        state = memory_lint.collect_state(d)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = memory_lint.run_action_mode(state, argparse.Namespace(dry_run=False, yes=True, json=False))
        today = time.strftime("%Y-%m-%d")
        assert rc == 0, buf.getvalue()
        assert os.path.exists(os.path.join(d, "_archive", today, "stale-topic.md"))
        assert not os.path.exists(os.path.join(d, "stale-topic.md"))
        assert "=== Applied ===" in buf.getvalue()


def test_auto_archive_concurrent_edit_aborts_with_code_2():
    # L1441: concurrent-edit guard (hash half). MEMORY.md changed since scan -> abort rc 2, no apply.
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d)
        state = memory_lint.collect_state(d)
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("DRIFTED FIRST LINE — changed since scan\n")   # first-200-char hash drift
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = memory_lint.run_action_mode(state, argparse.Namespace(dry_run=False, yes=True, json=False))
        assert rc == 2, buf.getvalue()
        assert os.path.exists(os.path.join(d, "stale-topic.md"))   # apply never ran


def test_auto_archive_dry_run_prompts_and_does_not_mutate():
    # L1360 (default-dry-run), L1420 prompt guard, confirm-EOF (input="" -> "n"). Class A fires but
    # the dry run must NOT move the file, and the "Apply?" prompt must appear (mutated L1360 skips it).
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d)
        r = subprocess.run(["python3", SCRIPT, d, "--auto-archive"],
                           input="", capture_output=True, text=True)
        assert os.path.exists(os.path.join(d, "stale-topic.md")), "dry run must not move"
        assert not os.path.isdir(os.path.join(d, "_archive"))
        assert "Apply?" in r.stdout, r.stdout   # mutated L1360 -> dry_run False -> no prompt


def test_auto_archive_json_dry_run_reports_impact_without_mutating():
    # L1355 (Class A impact term) + L1360 mode string (dry_run=False,yes=False -> the combo that
    # flips under or->and: correct mode "dry-run", mutated "apply"). JSON returns before any apply.
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d)
        state = memory_lint.collect_state(d)
        out = _run_action_json(state, dry_run=False, yes=False)
        assert out["mode"] == "auto-archive-dry-run", out["mode"]   # L1360
        e = memory_lint.class_a_stale_superseded(state)[0]
        stub = memory_lint.STUB_TEMPLATE.format(e["from"][:-3], e["to_archive_subdir"], e["from"])
        assert out["estimated_impact_bytes"] == len(e["old_pointer_line"]) - len(stub), out  # L1355
        assert os.path.exists(os.path.join(d, "stale-topic.md"))   # JSON never mutates


def test_auto_archive_json_apply_mode_returns_before_mutation():
    # --json with --yes still returns before apply (informational). Mode string reflects apply.
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d)
        state = memory_lint.collect_state(d)
        out = _run_action_json(state, dry_run=False, yes=True)
        assert out["mode"] == "auto-archive-apply", out["mode"]
        assert os.path.exists(os.path.join(d, "stale-topic.md"))   # --json never mutates even with --yes


def test_auto_archive_json_impact_includes_class_b_term():
    # L1356: `+ sum(delta_bytes for B)`. class_b fires; A and C empty so the estimate is B's sum.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = 10_000, 300
        with tempfile.TemporaryDirectory() as d:
            state = _class_b_state(d, topic_bytes=6000, pointer_chars=260)
            out = _run_action_json(state, dry_run=False, yes=False)
            exp = sum(e["delta_bytes"] for e in memory_lint.class_b_near_budget_collapse(state))
            assert exp != 0, "class_b must fire"
            assert out["estimated_impact_bytes"] == exp, out
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_auto_archive_json_reports_class_d_savings():
    # L1405: d_count_fold_bytes_saved = sum(len(old_pointer_line.encode())+1 for plan_d).
    #
    # topic-5 links [[topic-0]]..[[topic-4]] -- same reachability-guard
    # accommodation as test_class_d_count_fold_fires_over_trigger_and_reaches_target.
    orig_line, orig_byte = memory_lint.LINE_CAP, memory_lint.BYTE_CAP
    try:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = 10_000, 480
        with tempfile.TemporaryDirectory() as d:
            now = 2_000_000_000
            lines = []
            for i in range(6):
                stem = f"topic-{i}"
                body = ("links to [[topic-0]] [[topic-1]] [[topic-2]] [[topic-3]] [[topic-4]]\n"
                        if i == 5 else f"content about topic {i}\n")
                with open(os.path.join(d, f"{stem}.md"), "w") as f:
                    f.write(f"---\nname: {stem}\n---\n{body}")
                os.utime(os.path.join(d, f"{stem}.md"), (now + i * 100, now + i * 100))
                lines.append(f"- [{stem}]({stem}.md) — a short pointer hook for topic {i} here")
            with open(os.path.join(d, "MEMORY.md"), "w") as f:
                f.write("\n".join(lines) + "\n")
            state = memory_lint.collect_state(d)
            out = _run_action_json(state, dry_run=False, yes=False)
            d_exp = sum(len(e["old_pointer_line"].encode()) + 1
                        for e in memory_lint.class_d_count_fold(state, set()))
            assert d_exp > 0, "class_d must fire"
            assert out["d_count_fold_bytes_saved"] == d_exp, out
    finally:
        memory_lint.LINE_CAP, memory_lint.BYTE_CAP = orig_line, orig_byte


def test_auto_archive_json_impact_includes_class_c_term():
    # L1357: `+ sum(len(old) - len(new) for C if e.get("new"))`. A resolvable ledger target is present.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "src.md", "project", "dangling", "see [[ghost-topic]]")
        _write_memory(d, "project_external_evals_ledger.md", "project", "ledger", "n/a")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [src](src.md) — x\n- [project_external_evals_ledger](project_external_evals_ledger.md) — l\n")
        state = memory_lint.collect_state(d)
        out = _run_action_json(state, dry_run=False, yes=False)
        assert out["estimated_impact_bytes"] == len("[[ghost-topic]]") - len("[[project_external_evals_ledger]]"), out


def test_auto_archive_json_impact_skips_class_c_with_no_target():
    # L1357 the `if e.get("new")` guard: a dangling link with NO ledger target has new=None and must
    # be skipped. Mutated (drop guard) -> len(None) -> TypeError -> crash -> json.loads fails.
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "src.md", "project", "dangling no ledger", "see [[ghost-topic]]")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [src](src.md) — x\n")
        state = memory_lint.collect_state(d)
        out = _run_action_json(state, dry_run=False, yes=False)   # must not raise
        assert out["estimated_impact_bytes"] == 0, out


def test_auto_archive_dry_run_wins_over_yes():
    # L1424 fix (2026-08-23): `--auto-archive --dry-run --yes` must NOT mutate -- an explicit
    # --dry-run is a hard stop that wins over --yes. Previously --yes overrode --dry-run and
    # applied (a footgun); this pins the fixed precedence. Fails against the old code.
    with tempfile.TemporaryDirectory() as d:
        _class_a_fixture(d)
        r = subprocess.run(["python3", SCRIPT, d, "--auto-archive", "--dry-run", "--yes"],
                           input="", capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        assert os.path.exists(os.path.join(d, "stale-topic.md")), "dry-run+yes must NOT move the file"
        assert not os.path.isdir(os.path.join(d, "_archive")), r.stdout
        assert "=== Applied ===" not in r.stdout, r.stdout   # never reached the apply block


def test_auto_archive_no_actions_hint_only_without_yes():
    # L1416: the "re-run with --yes" hint shows only when not apply_now. Two mutually-linked,
    # both-indexed files -> A/B/C/D all empty (clean store).
    with tempfile.TemporaryDirectory() as d:
        _write_memory(d, "a.md", "project", "alpha", "see [[b]]")
        _write_memory(d, "b.md", "project", "beta", "see [[a]]")
        with open(os.path.join(d, "MEMORY.md"), "w") as f:
            f.write("- [a](a.md) — x\n- [b](b.md) — y\n")
        r_no = subprocess.run(["python3", SCRIPT, d, "--auto-archive"],
                              input="", capture_output=True, text=True)
        r_yes = subprocess.run(["python3", SCRIPT, d, "--auto-archive", "--yes"],
                               input="", capture_output=True, text=True)
        assert "No actions proposed" in r_no.stdout, r_no.stdout   # positive control (else vacuous)
        assert "re-run with --yes" in r_no.stdout, r_no.stdout      # L1416: hint shown
        assert "re-run with --yes" not in r_yes.stdout, r_yes.stdout  # apply_now -> hint suppressed


if __name__ == "__main__":
    test_typo_link_gets_suggestion()
    test_unrelated_dangling_link_gets_no_suggestion()
    test_markdown_style_dangling_link_is_detected()
    test_markdown_style_link_in_backticks_is_not_a_real_reference()
    test_markdown_style_link_with_path_is_treated_as_external_not_dangling()
    test_markdown_style_link_to_real_memory_resolves_and_avoids_false_orphan()
    test_class_d_count_fold_fires_over_trigger_and_reaches_target()
    test_class_d_count_fold_returns_nothing_under_trigger()
    test_class_d_count_fold_never_orphans_a_deindex_candidate()
    test_unindexed_file_linked_from_indexed_memory_is_not_a_finding()
    test_unindexed_and_unreachable_file_still_fires_unindexed()
    test_unindexed_reachability_is_transitive_through_unindexed_files()
    test_memory_dir_project_dir_name_requires_config_dir()
    # 2026-08-23 mutation-probe weak-oracle closers
    test_measured_index_line_count_is_newlines_plus_one()
    test_near_budget_finding_fires_at_exactly_80_percent()
    test_class_d_count_fold_skips_files_named_in_exclude_files()
    test_class_d_break_is_inclusive_at_exact_byte_target()
    test_class_d_break_is_inclusive_at_exact_line_target()
    # 2026-08-23 --auto-archive action-path coverage
    test_memory_dir_falls_back_to_cwd_when_not_a_git_repo()
    test_memory_dir_slug_replaces_every_non_alphanumeric()
    test_pointer_inside_html_comment_does_not_index_the_file()
    test_class_a_archive_stub_is_not_reported_as_stale_pointer()
    test_archive_stub_whose_file_is_gone_is_still_stale()
    test_class_a_skips_archive_that_would_strand_a_child_topic()
    test_class_a_skips_archive_that_pushes_a_topic_past_two_hops()
    test_class_a_skips_archive_when_its_line_also_carries_the_only_pointer_to_another_topic()
    test_class_a_skips_archive_when_the_file_has_a_second_live_pointer()
    test_class_a_with_an_inline_comment_on_the_pointer_line_never_leaves_a_stale_pointer()
    test_apply_does_not_move_a_file_whose_pointer_line_is_gone_from_the_index()
    test_class_d_hop_guard_alone_blocks_a_deindex_that_leaves_a_three_hop_backup()
    test_class_d_skips_a_deindex_whose_line_also_carries_the_only_pointer_to_another_topic()
    test_class_d_never_plans_a_line_that_carries_an_inline_comment()
    test_class_b_never_plans_a_line_that_carries_an_inline_comment()
    test_class_b_does_not_annotate_a_topic_whose_pointer_rewrite_did_not_land()
    test_a_and_b_together_never_strand_a_topic_each_relied_on_the_other_to_keep()
    test_class_b_annotates_the_topic_when_its_pointer_rewrite_lands()
    test_class_b_plan_and_apply_replace_the_same_lines_when_a_long_line_is_duplicated()
    test_class_a_does_not_touch_the_pointer_when_the_archive_destination_already_exists()
    test_b_and_d_together_never_strand_a_topic_each_relied_on_the_other_to_keep()
    test_class_a_guard_is_cumulative_over_the_plans_earlier_moves()
    test_class_a_never_archives_a_chapter_index()
    test_class_a_ignores_a_superseded_line_that_only_exists_inside_a_comment()
    test_class_a_apply_leaves_a_byte_identical_comment_copy_untouched()
    test_class_b_skips_a_collapse_that_drops_the_only_pointer_to_another_topic()
    test_class_d_never_deindexes_a_chapter_index()
    test_class_d_apply_leaves_a_byte_identical_comment_copy_untouched()
    test_class_d_is_evaluated_after_class_a_has_removed_its_files()
    test_class_b_collapses_verbose_pointer_over_thresholds()
    test_class_b_topic_size_boundary_is_exclusive_at_5120()
    test_class_b_pointer_length_boundary_is_inclusive_at_250()
    test_class_b_first_para_proxy_is_inclusive_at_exact_1_2x()
    test_class_b_returns_nothing_under_budget_trigger()
    test_class_c_rewrites_dangling_wikilink_to_ledger()
    test_class_c_rewrites_archived_link_to_supersedence_target()
    test_class_c_ignores_link_that_resolves_by_slug_only()
    test_apply_action_plan_moves_superseded_files_and_stubs_pointers()
    test_apply_action_plan_rewrites_dangling_wikilink_on_disk()
    test_apply_action_plan_deindexes_class_d_pointer_on_disk()
    test_print_plan_projects_post_trim_size()
    test_print_plan_reports_class_d_savings_separately()
    test_auto_archive_yes_applies_and_moves_file()
    test_auto_archive_concurrent_edit_aborts_with_code_2()
    test_auto_archive_dry_run_prompts_and_does_not_mutate()
    test_auto_archive_json_dry_run_reports_impact_without_mutating()
    test_auto_archive_json_apply_mode_returns_before_mutation()
    test_auto_archive_json_impact_includes_class_b_term()
    test_auto_archive_json_reports_class_d_savings()
    test_auto_archive_json_impact_includes_class_c_term()
    test_auto_archive_json_impact_skips_class_c_with_no_target()
    test_auto_archive_dry_run_wins_over_yes()
    test_auto_archive_no_actions_hint_only_without_yes()
    print("OK")
