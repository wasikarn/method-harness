#!/usr/bin/env python3
"""memory-lint — health check + action mode for the file-based memory store.

Karpathy's llm-wiki "Lint" operation for our memory: catch broken cross-links,
orphaned facts, and index drift before they rot. Deterministic only.

Usage:
  memory-lint.py [MEMORY_DIR]                     # default detector mode
  memory-lint.py [MEMORY_DIR] --auto-archive      # enter action mode (default: --dry-run)
  memory-lint.py [MEMORY_DIR] --auto-archive --dry-run
  memory-lint.py [MEMORY_DIR] --auto-archive --yes  # apply (no confirm prompt)
  memory-lint.py [MEMORY_DIR] --json              # machine-readable output

Detector checks (default mode):
  - dangling links       — [[wikilink]] or same-store markdown [text](file.md) target
                            resolves to no memory (by filename stem or name: slug);
                            suggests a close-name match (difflib, cutoff 0.6) if one exists.
                            Code-span-masked first (backtick prose quoting link syntax as
                            an example isn't a real cross-reference); a markdown target
                            containing "/" is treated as an external-repo citation, not a
                            same-store link, since memories live flat.
  - orphans               — a memory with no outbound and no inbound links (either syntax)
  - index drift           — MEMORY.md pointer ↔ file, both directions; UNINDEXED only
                            fires for a file that is also unreachable via [[links]]
  - load budget           — 200-line / 25KB cap on MEMORY.md
  - depth ratchet         — TOO DEEP when more reachable topics sit past MAX_HOPS than the
                            baseline in $HOME/.claude/state/memory-lint-depth-baseline-<key>.
                            Only a plain run writes it (first run, or N fell), and not while a finding
                            that can hide topics from N stands (DANGLING, DUPLICATE SLUG, MISSING,
                            UNINDEXED, STALE POINTER); ORPHAN and budget findings do not block; --json only
                            reads it. --auto-archive plans no depth fix and writes no baseline;
                            it only stops calling the store clean while N is over it.
                            Delete the file to accept an increase.
Exit code = finding count (0 = clean). Fails loud if MEMORY_DIR is missing.

Action mode (--auto-archive) — applies the A3 trim rubric (memory/project_memory_trim_session_2026_06_04.md):
  Class A — stale-superseded:   MEMORY.md pointer has **SUPERSEDED** marker + topic has 0 surviving inbound
  Class B — near-budget-collapse: pointer ≥250 chars + topic >5KB + pointer carries detail
  Class C — dangling-link-rewrite: surviving file has [[wikilink]] that resolves to nothing or to _archive/
  Class D — count-fold: fallback valve for A/B/C = 0 candidates but index still >=80% of cap
                         (this store's actual growth shape: many small terse entries, not a
                         few verbose outliers — confirmed empirically 2026-08-07, A/B found 0
                         candidates at 84% of cap). Deindexes (never deletes) the OLDEST pointer
                         lines by topic-file mtime, any type, until back under 65% of cap.
                         Reachability-guarded (2026-09-01): a candidate is skipped if deindexing
                         it would drop it (or anything only reachable through it) out of the
                         store's reachable set.

All mutations use `mv` (never `rm`) or deindex-only (Class D); confirm prompt is shown by
default; --yes skips confirm.
"""
import argparse
import difflib
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile

# Shared with hooks/stop/memory-audit-commit.sh and hooks/session/
# memory-health-nudge.sh -- one resolver, loaded here via importlib (not a
# subprocess: this is already an in-process Python consumer) rather than a
# package import, since this file's own install location (repo checkout vs.
# plugin cache) shouldn't need a sys.path convention that doesn't otherwise
# exist in this repo.
_lib_path = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..",
    "scripts", "_lib", "memory-dir.py",
))
_spec = importlib.util.spec_from_file_location("_memory_dir_resolver", _lib_path)
assert _spec is not None and _spec.loader is not None, f"cannot load {_lib_path}"
_memory_dir_resolver = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_memory_dir_resolver)
import time

WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
NAME_RE = re.compile(r"(?m)^name:\s*(.+)$")
POINTER_RE = re.compile(r"\]\(([^)]+\.md)\)")  # markdown link ](file.md), not prose "(x.md)"
FENCED_CODE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
SUPERSEDED_RE = re.compile(r"\*\*SUPERSEDED[^*]*\*\*\s*by\s*\[\[([^\]]+)\]\]")
POINTER_LINE_RE = re.compile(r"^- \[[^\]]+\]\(([^)]+\.md)\)(.*)$", re.MULTILINE)

LINE_CAP = 200
BYTE_CAP = 25 * 1024
FOLD_TRIGGER_PCT = 0.80  # matches the existing NEAR-BUDGET trigger (class_b uses the same cut)
FOLD_TARGET_PCT = 0.65   # Class D folds until back under this fraction of the caps
SUPERSEDED_ARCHIVE_DATE_FMT = "%Y-%m-%d"
STUB_TEMPLATE = "- [{}](_archive/{}/{}) — archived on-demand"
# The link target is the archived path so future grep/audit can find the file.
# `memory-lint` will report it as ORPHAN (no top-level wikilink inbound) but the
# markdown link itself resolves. Class A's whole point is "no surviving inbound"
# anyway — the user is explicitly saying "this entry is closed, browse on-demand."


def memory_dir(positional):
    if positional:
        return positional
    # Delegates to scripts/_lib/memory-dir.py -- the shared resolver also
    # used by hooks/stop/memory-audit-commit.sh and
    # hooks/session/memory-health-nudge.sh, so this precedence lives in
    # exactly one place. Match Claude Code's own auto-memory keying, not raw
    # cwd: the official doc (code.claude.com/docs/en/memory.md:358, confirmed
    # 2026-08-20) states the <project> path is "derived from the git
    # repository, so all worktrees and subdirectories within the same repo
    # share one auto memory directory" -- see memory-dir.py's own header for
    # the git-common-dir derivation this requires from inside a worktree.
    return _memory_dir_resolver.resolve_memory_dir()


FRONTMATTER_BLOCK_RE = re.compile(r"\A---\n.*?\n---\n?", re.DOTALL)
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


def measured_index(idx):
    """Byte/line count of MEMORY.md the way Claude Code's own load-budget check
    measures it: YAML frontmatter and block-level HTML comments stripped before
    counting (code.claude.com/docs/en/memory.md:394, confirmed 2026-08-20).
    MEMORY.md carries no frontmatter today, so that half is a no-op in
    practice — kept for correctness if that ever changes, and so a maintainer
    wrapping a trimmed section in `<!-- -->` (Tier 3, official-docs audit
    2026-08-20) doesn't get double-counted against the cap that move exists to
    relieve."""
    stripped = FRONTMATTER_BLOCK_RE.sub("", idx, count=1)
    stripped = HTML_COMMENT_RE.sub("", stripped)
    return len(stripped.encode("utf-8")), stripped.count("\n") + 1


def link_target(raw):
    # Strip Obsidian alias "[[target|display]]" and a trailing .md.
    t = raw.split("|", 1)[0].strip()
    return t[:-3] if t.endswith(".md") else t


def strip_code_spans(text):
    """Mask fenced/inline code spans before link-scanning body text.

    A memory can legitimately quote link syntax as an example (prose describing
    another repo's `[[link]]` or `[x](y.md)` bug), not a real cross-reference.
    Confirmed live in this store twice: a backtick-wrapped `[[branching-model]]`
    and a backtick-wrapped `[reference.md](reference.md)` describing a fix made
    in a different repo. Length-preserving space substitution keeps offsets
    stable for any future line-based tooling.
    """
    text = FENCED_CODE_RE.sub(lambda m: " " * len(m.group(0)), text)
    return INLINE_CODE_RE.sub(lambda m: " " * len(m.group(0)), text)


def md_link_target(raw):
    """Markdown-link target → bare stem, or None if not a same-store cross-reference.

    This store's memories live flat (no subdirectories except _archive/), so a
    target containing "/" is a path into another repo (e.g. a doc cited as
    prose), not a same-store link — treating it as one would misfire DANGLING
    on legitimate external citations.
    """
    if "/" in raw:
        return None
    return raw[:-3] if raw.endswith(".md") else raw


# ── Detector mode ─────────────────────────────────────────────────────────

def compute_reachable(files, slugs, links_out, referenced):
    """Stems reachable from `referenced` roots via outbound [[links]]/pointers —
    the same BFS detector_findings' UNINDEXED check uses, factored out so
    class_d_count_fold can reuse it as a safety filter (2026-09-01 deep-audit:
    the original Class D picked deindex candidates by mtime alone with no
    reachability check, so on the real store it proposed 17/24 candidates that
    would have recreated the exact UNINDEXED finding this whole tool exists to
    relieve pressure on)."""
    target_stem = {f[:-3]: f[:-3] for f in files}
    for f in files:
        s = slugs[f]
        if s and s not in target_stem:
            target_stem[s] = f[:-3]
    reachable = {ref[:-3] for ref in referenced if ref in files}
    frontier = list(reachable)
    while frontier:
        cur = frontier.pop()
        for t in links_out.get(cur + ".md", []):
            r = target_stem.get(t)
            if r is not None and r not in reachable:
                reachable.add(r)
                frontier.append(r)
    return reachable


# Finding prefixes that can hide topics from N (unreachable or deeper); while one stands, no baseline write.
BASELINE_BLOCKERS = ("DANGLING", "DUPLICATE SLUG", "MISSING", "UNINDEXED", "STALE POINTER")
MAX_HOPS = 2  # the book model: MEMORY.md pointer = hop 1, each [[link]] from there adds one


def compute_depths(files, slugs, links_out, referenced):
    """stem -> hop distance from MEMORY.md (a pointer is hop 1). Same resolution as compute_reachable."""
    target_stem = {f[:-3]: f[:-3] for f in files}
    for f in files:
        s = slugs[f]
        if s and s not in target_stem:
            target_stem[s] = f[:-3]
    depth = {ref[:-3]: 1 for ref in referenced if ref in files}
    frontier = list(depth)
    while frontier:
        nxt = []
        for cur in frontier:
            for t in links_out.get(cur + ".md", []):
                r = target_stem.get(t)
                if r is not None and r not in depth:
                    depth[r] = depth[cur] + 1
                    nxt.append(r)
        frontier = nxt
    return depth


def _view(state, removed, referenced):
    """(files, links_out, referenced) with `removed` filenames gone, as an action plan would leave them."""
    files = [f for f in state["files"] if f not in removed]
    links = {f: v for f, v in state["links_out"].items() if f not in removed}
    return files, links, {r for r in referenced if r not in removed}


def hurts_graph(state, removed_before, ref_before, removed_after, ref_after):
    """True if going from the first view to the second strands a topic or pushes one that sat within
    MAX_HOPS past it. Topics the second view removes itself are not counted."""
    f0, l0, r0 = _view(state, removed_before, ref_before)
    f1, l1, r1 = _view(state, removed_after, ref_after)
    before = compute_depths(f0, state["slugs"], l0, r0)
    after = compute_depths(f1, state["slugs"], l1, r1)
    gone = set(removed_after) - set(removed_before)
    for stem, hops in before.items():
        if stem + ".md" in gone:
            continue
        now = after.get(stem)
        if now is None or (hops <= MAX_HOPS < now):
            return True
    return False


def is_chapter_index(fname):
    return fname.startswith("index-")


def live_lines(idx):
    """(raw_line, comment-stripped line) for each index line Claude Code would load whole.
    A line that starts inside a comment, or opens one it never closes, is skipped: its raw text
    cannot be matched safely. The raw line is what apply must find in the file."""
    spans = [(m.start(), m.end()) for m in HTML_COMMENT_RE.finditer(idx)]
    out, off = [], 0
    for raw in idx.split("\n"):
        start, off = off, off + len(raw) + 1
        if any(s <= start < e for s, e in spans):
            continue
        live = HTML_COMMENT_RE.sub("", raw)
        if "<!--" in live:
            continue
        out.append((raw, live))
    return out


def replace_live(text, old, new, count=-1):
    """str.replace that never touches text inside an HTML comment. Returns (text, replacements)."""
    out, pos, done = [], 0, 0
    spans = [(m.start(), m.end()) for m in HTML_COMMENT_RE.finditer(text)] + [(len(text), len(text))]
    for start, end in spans:
        seg = text[pos:start]
        left = -1 if count < 0 else count - done
        if left != 0:
            n = seg.count(old) if left < 0 else min(seg.count(old), left)
            seg = seg.replace(old, new, left)
            done += n
        out.append(seg)
        out.append(text[start:end])
        pos = end
    return "".join(out), done


def collect_state(d):
    """Build the shared data structures used by both detector and action modes."""
    files = [f for f in os.listdir(d) if f.endswith(".md") and f != "MEMORY.md"]
    # An index with no topics left (Class A archived the last one) is a valid, lintable store.
    if not files and not os.path.isfile(os.path.join(d, "MEMORY.md")):
        sys.exit(f"FATAL: no memory files in {d}")

    stems = {f[:-3] for f in files}
    slugs, links_out = {}, {}
    for f in files:
        txt = open(os.path.join(d, f), encoding="utf-8").read()
        m = NAME_RE.search(txt)
        slugs[f] = m.group(1).strip() if m else None
        scan_txt = strip_code_spans(txt)
        wiki_targets = [link_target(x) for x in WIKILINK.findall(scan_txt)]
        md_targets = [t for t in (md_link_target(x) for x in POINTER_RE.findall(scan_txt)) if t]
        links_out[f] = wiki_targets + md_targets

    slug_set = {v for v in slugs.values() if v}
    slug_holders = {}
    for f in files:
        s = slugs[f]
        if s:
            slug_holders.setdefault(s, []).append(f)
    dup_slugs = {s: fs for s, fs in slug_holders.items() if len(fs) > 1}

    # Resolve a link token to its canonical stem the same way compute_reachable does: a stem
    # match wins over a same-string slug match, so a file's own slug never falsely swallows a
    # different file whose raw filename stem happens to equal that slug (Rule-13 validator catch).
    # `inbound` stores the RESOLVED stem, never the raw token -- storing the raw token let a
    # file's own outbound link (to a different file sharing that string) credit the file itself
    # as "referenced" (blind-spot-hunter catch, 2026-09-25): checking a slug's bare presence in
    # inbound can't distinguish "someone linked to me" from "someone linked to a different file
    # whose stem happens to equal my slug".
    resolved_stem = {f[:-3]: f[:-3] for f in files}
    for f in files:
        s = slugs[f]
        if s and s not in resolved_stem:
            resolved_stem[s] = f[:-3]
    inbound = set()
    for f, targets in links_out.items():
        own_stem = f[:-3]
        for t in targets:
            resolved = resolved_stem.get(t)
            if resolved is None or resolved == own_stem:
                continue  # unresolvable, or resolves to this file itself
            inbound.add(resolved)

    index_path = os.path.join(d, "MEMORY.md")
    idx = ""
    referenced = set()
    if os.path.isfile(index_path):
        idx = open(index_path, encoding="utf-8").read()
        # Scan the comment-stripped text only: Claude Code never loads a commented pointer.
        # `idx` stays raw because apply_action_plan writes it back.
        referenced = set(POINTER_RE.findall(HTML_COMMENT_RE.sub("", idx)))
    return {
        "d": d, "files": files, "stems": stems, "slugs": slugs, "slug_set": slug_set,
        "dup_slugs": dup_slugs, "inbound": inbound, "links_out": links_out,
        "index_path": index_path, "idx": idx, "referenced": referenced,
        "depth_key": depth_key(d),
    }


def detector_findings(state):
    findings = []
    files = state["files"]
    inbound = state["inbound"]
    links_out = state["links_out"]
    slugs = state["slugs"]
    referenced = state["referenced"]
    idx = state["idx"]
    idx_path = state["index_path"]

    # 1. dangling links
    candidates = state["stems"] | state["slug_set"]
    for f, targets in links_out.items():
        for t in targets:
            if t not in state["stems"] and t not in state["slug_set"]:
                match = difflib.get_close_matches(t, candidates, n=1, cutoff=0.6)
                hint = f" — did you mean [[{match[0]}]]?" if match else ""
                findings.append(f"DANGLING: {f} → {t} (no such memory){hint}")

    # 1b. duplicate slugs -- a name: value shared by 2+ files makes every [[slug]] link to it
    # ambiguous (which file it really means), so any inbound/reachability check involving that
    # slug can't be trusted; surfaced loudly instead of silently guessing. Independent of whether
    # MEMORY.md exists, so checked ahead of the index-gated findings below.
    for s, fs in sorted(state["dup_slugs"].items()):
        findings.append(f"DUPLICATE SLUG: {', '.join(sorted(fs))} all declare name: '{s}' — a slug must be unique; any [[{s}]] link resolving to one of them is ambiguous")

    if not os.path.isfile(idx_path):
        findings.append("MISSING: MEMORY.md index not found")
    else:
        # 2. orphans. A file whose own slug is duplicated can't be called ORPHAN off has_in
        # alone -- inbound now resolves ambiguous slug tokens to only ONE of the holders (Rule-13
        # validator catch, 2026-09-25), so the other holder could have a real inbound link that
        # resolution just didn't credit to it. DUPLICATE SLUG above already carries that signal.
        for f in files:
            has_out = bool(links_out[f])
            has_in = f[:-3] in inbound or slugs[f] in state["dup_slugs"]
            if f in referenced and not has_out and not has_in:
                findings.append(f"ORPHAN: {f} (no links in or out)")

        # 3. index drift — UNINDEXED is reachability-aware: a file with no
        # MEMORY.md pointer but reachable from an indexed root through
        # [[links]] is the fold rule's documented Context layer (Index →
        # Context → Detail, per MEMORY.md's own header), not rot. Only a file
        # that is unindexed AND unreachable from the index fires.
        reachable = compute_reachable(files, slugs, links_out, referenced)
        for f in files:
            if f not in referenced and f[:-3] not in reachable:
                findings.append(f"UNINDEXED: {f} not pointed to from MEMORY.md and not [[link]]-reachable from any indexed memory")
        for ref in sorted(referenced):
            # Class A's stub points at _archive/<date>/<file>: the cold layer, resolvable if it exists.
            if os.path.normpath(ref).startswith("_archive" + os.sep) and os.path.isfile(os.path.join(state["d"], ref)):
                continue
            if ref not in files:
                findings.append(f"STALE POINTER: MEMORY.md → ({ref}) but file missing")

        # 4. load budget
        idx_bytes, idx_lines = measured_index(idx)
        pct = int(max(idx_lines / LINE_CAP, idx_bytes / BYTE_CAP) * 100)
        if idx_lines > LINE_CAP or idx_bytes > BYTE_CAP:
            findings.append(f"OVER-BUDGET: MEMORY.md {idx_lines}L/{idx_bytes}B exceeds the 200-line/25KB load cap — trailing index entries WON'T load; fold closed entries into a topic-file/ledger + archive (only MEMORY.md loads — splitting into multiple indexes won't help)")
        elif pct >= 80:
            findings.append(f"NEAR-BUDGET: MEMORY.md at {pct}% of the 200-line/25KB load cap ({idx_lines}L, {idx_bytes}B) — trim verbose pointers, or fold closed entries into a topic-file/ledger + archive (only MEMORY.md loads — don't split into multiple indexes)")

    total_links = sum(len(v) for v in links_out.values())
    linked_count = len([f for f in files
                        if links_out[f] or f[:-3] in inbound or slugs[f] in state["dup_slugs"]])
    return findings, total_links, linked_count


def depth_ratchet(state, write):
    """(finding or None, N, baseline or None). N = reachable topics deeper than MAX_HOPS.
    Only a write run creates or tightens the baseline; a read run (--json) never touches it.
    Spec: docs/research/memory-vault-redesign-proposal-2026-11-08.md § Depth ratchet."""
    depths = compute_depths(state["files"], state["slugs"], state["links_out"], state["referenced"])
    deep = sorted(((h, s) for s, h in depths.items() if h > MAX_HOPS), key=lambda x: (-x[0], x[1]))
    n = len(deep)
    path = os.path.join(os.path.expanduser("~"), ".claude", "state",
                        "memory-lint-depth-baseline-" + state["depth_key"])
    base = None
    try:
        with open(path, encoding="utf-8") as f:
            base = int(f.read().strip())
        if base < 0:
            base = None
            raise ValueError("negative count")
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        print(f"memory-lint: ignoring unreadable depth baseline {path}: {e}", file=sys.stderr)
    if base is not None and n > base:
        top = ", ".join(f"{s}.md {h}" for h, s in deep[:5])
        return (f"TOO DEEP: {n} topics are more than {MAX_HOPS} hops from MEMORY.md "
                f"(baseline {base}); deepest: {top}"), n, base
    if write and (base is None or n < base):
        # shortcut: two concurrent plain runs can race (last write wins); accepted, the value is a count.
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            atomic_write(path, f"{n}\n")
            base = n
        except OSError as e:
            print(f"memory-lint: cannot write depth baseline {path}: {e}", file=sys.stderr)
    return None, n, base


def depth_key(d):
    """Baseline key: <enc> for a .../projects/<enc>/memory store (the resolver's own key, so a manual
    run and the nudge share one file), else the slug of the path's abspath. No realpath on purpose."""
    m = re.search(r"/projects/([^/]+)/memory$", os.path.abspath(d))
    return m.group(1) if m else _memory_dir_resolver._slug(os.path.abspath(d))


def run_detector(state, as_json):
    findings, total_links, linked_count = detector_findings(state)
    # Write only when nothing hides topics from N: a broken index or link makes topics unreachable or
    # deeper, and a baseline taken then would read the repaired store as TOO DEEP. ORPHAN and the
    # budget findings cannot move N, so they do not block the write.
    too_deep, deep_n, deep_base = depth_ratchet(
        state, write=not as_json and not any(f.startswith(BASELINE_BLOCKERS) for f in findings))
    if too_deep:
        findings.append(too_deep)
    if as_json:
        print(json.dumps({
            "mode": "detector",
            "memory_dir": state["d"],
            "files": len(state["files"]),
            "links": total_links,
            "linked": linked_count,
            "findings": findings,
        }, indent=2))
        sys.exit(0 if not findings else len(findings))

    idx_bytes, idx_lines = measured_index(state["idx"])
    pct = int(max(idx_lines / LINE_CAP, idx_bytes / BYTE_CAP) * 100)
    print(f"=== memory-lint: {state['d']} ===")
    print(f"memories: {len(state['files'])} | links: {total_links} | "
          f"linked: {linked_count} | MEMORY.md: {pct}% of load cap | "
          f"deep>{MAX_HOPS}: {deep_n} (baseline {'none' if deep_base is None else deep_base}) | "
          f"findings: {len(findings)}")
    print()
    for line in findings:
        print(f"  {line}")
    if not findings:
        print("  clean — no dangling links, orphans, or index drift")
    print(f"\nExit: {len(findings)}")
    sys.exit(len(findings))


# ── Action mode ───────────────────────────────────────────────────────────

def list_archive(d):
    """Return set of filename-stems living under _archive/ (recursively)."""
    archive_dir = os.path.join(d, "_archive")
    stems = set()
    if not os.path.isdir(archive_dir):
        return stems
    for root, _, fs in os.walk(archive_dir):
        for f in fs:
            if f.endswith(".md"):
                stems.add(f[:-3])
    return stems


def file_size(d, name):
    p = os.path.join(d, name)
    return os.path.getsize(p) if os.path.isfile(p) else 0


def read_file(d, name):
    return open(os.path.join(d, name), encoding="utf-8").read()


def short_hash(s, n=200):
    return hashlib.sha1(s[:n].encode("utf-8")).hexdigest()[:10]




def class_a_stale_superseded(state):
    """Class A: pointer contains **SUPERSEDED** marker + the file the pointer POINTS TO
    exists + has 0 surviving inbound [[wikilinks]] (i.e. the marker is the explicit
    supersession signal AND nothing else references the file).
    The supersedence-target `[[X]]` in the marker is recorded for downstream Class C
    rewrites only (it's the canonical successor, not the file to move)."""
    plan = []
    removed = set()
    cur = state["idx"]   # raw index with each accepted stub applied, so the guard sees what apply will write
    archive_date = time.strftime(SUPERSEDED_ARCHIVE_DATE_FMT)
    for raw_line, line in live_lines(state["idx"]):
        m = SUPERSEDED_RE.search(line)
        if not m:
            continue
        # The OLD topic = the file the markdown link points to on this line
        link_m = POINTER_RE.search(line)
        if not link_m:
            continue
        target_file = link_m.group(1)
        target_stem = target_file[:-3]
        if target_file not in state["files"]:
            continue
        # A chapter index is structure, not a finished topic: archiving it strands everything under it.
        # Any pointer, not just the first: the stub replaces the whole line.
        if any(is_chapter_index(p) for p in POINTER_RE.findall(line)):
            continue
        # Judge the guard on the index exactly as apply will leave it: the whole line becomes a stub, so
        # any other pointer on it goes too, and a second live pointer to this file would go stale.
        # A same-day rerun finds the destination taken: apply cannot move the file, so plan nothing.
        if os.path.exists(os.path.join(state["d"], "_archive", archive_date, target_file)):
            continue
        stub = STUB_TEMPLATE.format(target_stem, archive_date, target_file)
        trial, hits = replace_live(cur, raw_line, stub)
        if not hits:
            continue
        ref_now = set(POINTER_RE.findall(HTML_COMMENT_RE.sub("", cur)))
        ref_next = set(POINTER_RE.findall(HTML_COMMENT_RE.sub("", trial)))
        if target_file in ref_next:
            continue
        # Never leave a topic stranded or past MAX_HOPS (cumulative over this plan's earlier moves).
        if hurts_graph(state, removed, ref_now, removed | {target_file}, ref_next):
            continue
        # A duplicate name: slug makes any [[slug]] link to this file ambiguous (it could just
        # as well resolve to the other file holding the same slug) -- can't safely confirm 0
        # inbound, so never archive under that ambiguity (blind-spot-hunter catch, 2026-09-25).
        if state["slugs"].get(target_file) in state["dup_slugs"]:
            continue
        # Must have 0 surviving inbound. inbound holds resolved stems only (never a raw slug
        # string), so checking target_stem alone is sufficient -- a slug-form inbound link was
        # already resolved to its canonical stem when collect_state built the set.
        if target_stem in state["inbound"]:
            continue
        # Successor for downstream use
        successor = m.group(1).split("|", 1)[0].strip()
        successor = successor[:-3] if successor.endswith(".md") else successor
        removed.add(target_file)
        cur = trial
        plan.append({
            "action": "move",
            "from": target_file,
            "to_archive_subdir": archive_date,
            "old_pointer_line": raw_line,
            "successor": successor,
        })
    return plan


def class_b_near_budget_collapse(state, removed_files=frozenset(), index_text=None):
    """Class B: longest pointer-lines (>=250 chars) where topic is >5KB and pointer is >= 1.2x first paragraph.
    `removed_files` / `index_text` = the files Class A is about to archive and the index with A's stubs
    applied; the graph guard judges each collapse on the graph as A leaves it."""
    plan = []
    if not state["idx"]:
        return plan
    # Match the 200L/25KB cap threshold
    idx_bytes, idx_lines = measured_index(state["idx"])
    pct = int(max(idx_lines / LINE_CAP, idx_bytes / BYTE_CAP) * 100)
    if pct < 80:
        return plan

    candidates = []
    for full_line, live_text in live_lines(state["idx"]):
        m = POINTER_LINE_RE.match(live_text)
        if not m:
            continue
        fname = m.group(1)
        if len(full_line) < 250 or full_line != live_text:
            continue
        if fname not in state["files"] or fname in removed_files:
            continue
        topic_size = file_size(state["d"], fname)
        if topic_size <= 5 * 1024:
            continue
        # Proxy: pointer carries detail if full line >= 1.2x first-paragraph of topic
        topic_txt = read_file(state["d"], fname)
        first_para = topic_txt.split("\n\n", 1)[0] if topic_txt else ""
        if len(full_line) >= 1.2 * max(len(first_para), 1):
            candidates.append((len(full_line), fname, full_line, topic_size))

    candidates.sort(key=lambda x: -x[0])  # longest first
    live = state["idx"] if index_text is None else index_text
    for _line_len, fname, full_line, topic_size in candidates:
        # Stub: ~80 chars
        stem = fname[:-3]
        stub = f"- [{stem}]({fname}) — see [[{stem}]] for full record"
        # The collapsed line may carry other pointers (`](y.md)`); losing y's only one strands y.
        # apply collapses every copy of the line, so the guard must too; a later duplicate is then already gone
        trial_live, hits = replace_live(live, full_line, stub)
        if not hits:
            continue
        ref_now = set(POINTER_RE.findall(HTML_COMMENT_RE.sub("", live)))
        ref_next = set(POINTER_RE.findall(HTML_COMMENT_RE.sub("", trial_live)))
        if hurts_graph(state, removed_files, ref_now, removed_files, ref_next):
            continue
        live = trial_live
        # supersedes: note in topic file
        plan.append({
            "action": "rewrite_pointer",
            "from": full_line,
            "to": stub,
            "from_chars": len(full_line),
            "to_chars": len(stub),
            "delta_bytes": len(stub.encode("utf-8")) - len(full_line.encode("utf-8")),
            "topic_file": fname,
        })
    return plan


def _pick_ledger_target(state, removed_files=frozenset(), source=None):
    """Default rewrite target for a link with no clear resolution: the
    external-evals ledger if it survives, else any surviving file with
    'ledger' in its stem, else None (caller falls back to manual).
    `removed_files` = files Class A archives in the same plan; never a target. `source` = the file
    holding the link; never its own target (a self-link would hide the dangling link, not fix it)."""
    survivors = {s for s in state["stems"] if s + ".md" not in removed_files and s + ".md" != source}
    ledger = "project_external_evals_ledger"
    if ledger in survivors:
        return ledger
    ledgers = [s for s in sorted(survivors) if "ledger" in s]
    return ledgers[0] if ledgers else None


def class_c_dangling_link_rewrite(state, removed_files=frozenset()):
    """Class C: surviving top-level file has a [[wikilink]] that resolves to nothing,
    OR to a target in _archive/ where the source has a known supersedence target.
    `removed_files` = files Class A archives in the same plan (build_plan passes them): they are
    neither rewritten nor chosen as a target. A link TO such a file is already live in the raw state
    (A only archives files with no inbound link), so the resolvability test below needs no change."""
    plan = []
    archive_stems = list_archive(state["d"])
    # Build index of (stem → first non-section line of MEMORY.md that mentions it as pointer)
    # for "known supersedence target" hint.
    super_targets = {}  # archived_stem -> superseded-by target
    for line in state["idx"].splitlines():
        m = SUPERSEDED_RE.search(line)
        if not m:
            continue
        # Find filename in same line
        pm = POINTER_RE.search(line)
        if not pm:
            continue
        old_fname = pm.group(1)
        old_stem = old_fname[:-3]
        if old_stem in archive_stems:
            super_targets[old_stem] = m.group(1).split("|", 1)[0].strip()

    for f, targets in state["links_out"].items():
        # Only look at surviving top-level files
        if f not in state["files"] or f in removed_files:
            continue
        for t in targets:
            if t in state["stems"] or t in state["slug_set"]:
                continue
            # Dangling: target resolves to nothing
            if t not in archive_stems:
                # No clear ledger — record as a candidate; agent decides rewrite target
                new_target = _pick_ledger_target(state, removed_files, source=f)
                plan.append({
                    "action": "rewrite_wikilink",
                    "file": f,
                    "old": f"[[{t}]]",
                    "new": f"[[{new_target}]]" if new_target else None,
                    "reason": "dangling-target",
                })
            else:
                # Archived target — find replacement
                replacement = super_targets.get(t)
                if (replacement and replacement in state["stems"] and replacement + ".md" not in removed_files
                        and replacement + ".md" != f):
                    plan.append({
                        "action": "rewrite_wikilink",
                        "file": f,
                        "old": f"[[{t}]]",
                        "new": f"[[{replacement}]]",
                        "reason": "archived-with-supersedence",
                    })
                else:
                    # Archived but no clear supersedence — point to nearest ledger
                    new_target = _pick_ledger_target(state, removed_files, source=f)
                    plan.append({
                        "action": "rewrite_wikilink",
                        "file": f,
                        "old": f"[[{t}]]",
                        "new": f"[[{new_target}]]" if new_target else None,
                        "reason": "archived-no-supersedence",
                    })
    return plan


def class_d_count_fold(state, exclude_files, removed_files=frozenset(), index_text=None):
    """Class D: pure count-pressure fallback valve. Only produces entries when the
    index is still >= FOLD_TRIGGER_PCT of cap — A/B/C's per-entry heuristics don't
    catch pure entry-count accumulation (many small terse pointer lines, no single
    verbose outlier to collapse). Deindexes (never deletes) the OLDEST pointer
    lines by topic-file mtime, any type, until back under FOLD_TARGET_PCT of cap —
    but only candidates that stay reachable afterward (compute_reachable, same BFS
    the UNINDEXED detector uses): a candidate whose deindex would drop it, or
    anything only reachable through it, out of the reachable set is skipped, not
    proposed. Without this guard the mtime-only pick has no way to tell a file with
    an alternate [[link]] path back to the index apart from one with none — found
    2026-09-01 via deep-audit: 17 of 24 real candidates on this store had zero
    alternate path and would have recreated the exact UNINDEXED finding this valve
    exists to relieve pressure on. exclude_files = filenames already claimed by
    plan A/B, so nothing double-counts. Self-contained byte accounting — does not
    participate in the shared estimated_impact sum used by A/B/C, which mixes
    savings-sign conventions across classes; D reports its own delta separately.
    `removed_files` / `index_text` describe the graph as A and B leave it (build_plan passes them), so
    D's guard never judges on a graph the earlier classes are about to change; the guard drops the
    WHOLE pointer line, so any other pointer on it counts as lost. A line carrying an inline comment is
    never planned (apply cannot match text that runs across a comment). A chapter index
    (index-*.md) is never a candidate, and a deindex that pushes a topic past MAX_HOPS is skipped."""
    plan = []
    # Size the index as A and B leave it (GH #964), else D deindexes when B already got under target.
    idx_bytes, idx_lines = measured_index(state["idx"] if index_text is None else index_text)
    pct = max(idx_lines / LINE_CAP, idx_bytes / BYTE_CAP)
    if pct < FOLD_TRIGGER_PCT:
        return plan

    target_bytes = int(BYTE_CAP * FOLD_TARGET_PCT)
    target_lines = int(LINE_CAP * FOLD_TARGET_PCT)
    if idx_bytes <= target_bytes and idx_lines <= target_lines:
        return plan

    candidates = []
    for full_line, live_text in live_lines(state["idx"]):
        m = POINTER_LINE_RE.match(live_text)
        if not m:
            continue
        fname = m.group(1)
        if fname in exclude_files or fname in removed_files or fname not in state["files"]:
            continue
        if any(is_chapter_index(p) for p in POINTER_RE.findall(live_text)) or full_line != live_text:
            continue
        try:
            mtime = os.path.getmtime(os.path.join(state["d"], fname))
        except OSError:
            continue
        candidates.append((mtime, fname, full_line))
    candidates.sort(key=lambda c: c[0])  # oldest first

    # Safety invariant: nothing reachable today may become unreachable. Checked
    # cumulatively against the ORIGINAL full baseline as each candidate is
    # tentatively accepted, so an interaction between two accepted candidates
    # (one only reachable through the other) is caught too, not just each in
    # isolation.
    cur = state["idx"] if index_text is None else index_text
    still_referenced = set(POINTER_RE.findall(HTML_COMMENT_RE.sub("", cur))) - set(removed_files)
    files_now = [f for f in state["files"] if f not in removed_files]
    links_now = {f: v for f, v in state["links_out"].items() if f not in removed_files}
    baseline_reachable = compute_reachable(files_now, state["slugs"], links_now, still_referenced)

    remaining_bytes = idx_bytes
    remaining_lines = idx_lines
    for _mtime, fname, full_line in candidates:
        if remaining_bytes <= target_bytes and remaining_lines <= target_lines:
            break
        trial, hits = replace_live(cur, full_line + "\n", "", 1)
        if not hits:
            trial, hits = replace_live(cur, full_line, "", 1)
        if not hits:
            continue
        trial_referenced = set(POINTER_RE.findall(HTML_COMMENT_RE.sub("", trial))) - set(removed_files)
        trial_reachable = compute_reachable(files_now, state["slugs"], links_now, trial_referenced)
        if trial_reachable != baseline_reachable:
            continue  # would orphan fname (or something only reachable through it) — skip, don't propose
        if hurts_graph(state, removed_files, still_referenced, removed_files, trial_referenced):
            continue  # reachable, but a topic that sat within MAX_HOPS would end up deeper
        still_referenced, cur = trial_referenced, trial
        remaining_bytes -= len(full_line.encode("utf-8")) + 1  # +1 for the newline
        remaining_lines -= 1
        plan.append({"action": "deindex", "file": fname, "old_pointer_line": full_line})
    return plan


def atomic_write(path, content):
    """Write file atomically: stage at temp path, fsync, os.replace."""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".memory-lint.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def apply_action_plan(state, plan):
    """Execute the plan: Class A moves, B/C rewrites, D deindexes. Returns (bytes_saved, applied_summary).
    Any exception (KeyboardInterrupt too) before MEMORY.md is written puts the Class A moves back (their
    pointers are still live, so each would become a STALE POINTER) and re-raises the original (GH #964)."""
    applied = {"A": [], "B": [], "C": [], "D": []}
    try:
        return _apply_unguarded(state, plan, applied)
    except BaseException:
        # Class B/C edits are left in place: they create no new finding without the index write.
        for moved in applied["A"]:
            if "skipped" in moved:
                continue
            back = os.path.join(state["d"], moved["from"])
            if os.path.lexists(back):   # lexists: a dangling symlink there is also something to keep
                print(f"memory-lint: not restoring {moved['to']}: {back} already exists; archived copy kept; merge or delete by hand", file=sys.stderr)
                continue
            try:
                shutil.move(moved["to"], back)
            except OSError as restore_err:
                print(f"memory-lint: could not restore {moved['from']} from {moved['to']}: {restore_err}", file=sys.stderr)
        raise


def _apply_unguarded(state, plan, applied):
    bytes_saved = 0
    d = state["d"]
    idx = state["idx"]
    new_idx = idx

    # Class A — moves + pointer stub rewrites
    archive_date = time.strftime(SUPERSEDED_ARCHIVE_DATE_FMT)
    archive_dir = os.path.join(d, "_archive", archive_date)
    for entry in plan["A"]:
        src = os.path.join(d, entry["from"])
        dst = os.path.join(archive_dir, entry["from"])
        if os.path.exists(dst) and os.path.exists(src):
            # Both exist: the move cannot happen, so the pointer must not change either.
            print(f"memory-lint: _archive/{archive_date}/{entry['from']} already exists, not archiving {entry['from']}", file=sys.stderr)
            continue
        # Rewrite the pointer first: a plan built on a stale index finds nothing to rewrite, and moving
        # the file anyway would leave a STALE POINTER behind.
        old_line = entry["old_pointer_line"]
        new_line = STUB_TEMPLATE.format(entry["from"][:-3], archive_date, entry["from"])
        new_idx, hits = replace_live(new_idx, old_line, new_line)
        if not hits:
            print(f"memory-lint: pointer for {entry['from']} not found in MEMORY.md, not archiving it", file=sys.stderr)
            continue
        bytes_saved += len(old_line.encode("utf-8")) - len(new_line.encode("utf-8"))
        os.makedirs(archive_dir, exist_ok=True)
        if os.path.exists(dst):
            # src is gone and dst exists: an earlier run moved it; record a no-op
            applied["A"].append({"action": "move", "from": entry["from"], "to": dst, "skipped": "already-archived"})
            # Still rewrite the pointer
        else:
            try:
                shutil.move(src, dst)
                applied["A"].append({"action": "move", "from": entry["from"], "to": dst})
            except OSError as e:
                # compliance-audit fix-round 2, 2026-09-20: this fallback was
                # the 3rd of the "3 silent except OSError" sites the plan
                # named -- still silent even though the move itself succeeds
                # via os.rename, so a discrepancy in HOW a move landed was
                # invisible. os.rename's own exception, if any, still
                # propagates uncaught (this only logs the fallback trigger).
                print(f"memory-lint: shutil.move failed for {entry['from']} ({e}), falling back to os.rename", file=sys.stderr)
                os.rename(src, dst)
                applied["A"].append({"action": "move", "from": entry["from"], "to": dst})

    # Class B — pointer rewrites
    for entry in plan["B"]:
        old_line = entry["from"]
        new_line = entry["to"]
        new_idx, hits = replace_live(new_idx, old_line, new_line)
        if not hits:
            print(f"memory-lint: pointer line for {entry['topic_file']} not found in MEMORY.md, not collapsing it", file=sys.stderr)
            continue
        bytes_saved += entry["delta_bytes"]
        applied["B"].append({"action": "rewrite_pointer", "from": old_line, "to": new_line})
        # Add a 1-line supersedes: note at top of topic file
        topic_path = os.path.join(d, entry["topic_file"])
        try:
            topic_txt = open(topic_path, encoding="utf-8").read()
            supersedes_line = f"\n<!-- memory-lint: pointer collapsed {time.strftime('%Y-%m-%d')} (A3 trim) — see MEMORY.md -->\n"
            if supersedes_line.strip() not in topic_txt:
                atomic_write(topic_path, topic_txt + supersedes_line)
        except OSError as e:
            # 2026-09-20 audit: this secondary write staying best-effort is
            # fine (the pointer collapse above already succeeded and is
            # counted in applied["B"] regardless) -- what was missing is any
            # signal that it didn't land, so a run's "B: N collapsed" count
            # silently promised an annotation that never landed.
            print(f"memory-lint: could not annotate {topic_path}: {e}", file=sys.stderr)

    # Class C — wikilink rewrites inside surviving files
    for entry in plan["C"]:
        if not entry.get("new"):
            continue  # manual resolution needed
        path = os.path.join(d, entry["file"])
        try:
            txt = open(path, encoding="utf-8").read()
        except OSError as e:
            # 2026-09-20 audit: a file present at plan time (dry-run) but
            # gone/unreadable by apply time silently dropped its wikilink
            # rewrite with no trace -- print_plan's earlier count and this
            # run's real applied["C"] count would then quietly disagree.
            print(f"memory-lint: skipping wikilink rewrite in {path}: {e}", file=sys.stderr)
            continue
        if entry["old"] in txt:
            new_txt = txt.replace(entry["old"], entry["new"])
            bytes_saved += len(entry["old"].encode("utf-8")) - len(entry["new"].encode("utf-8"))
            applied["C"].append({"action": "rewrite_wikilink", "from": entry["old"], "to": entry["new"], "file": entry["file"]})
            atomic_write(path, new_txt)

    # Class D — pure deindex (remove pointer line only, backing file untouched)
    for entry in plan.get("D", []):
        old_line = entry["old_pointer_line"]
        new_idx, hits = replace_live(new_idx, old_line + "\n", "", 1)
        if hits:
            bytes_saved += len(old_line.encode("utf-8")) + 1
            applied["D"].append({"action": "deindex", "file": entry["file"]})
            continue
        new_idx, hits = replace_live(new_idx, old_line, "", 1)
        if hits:
            bytes_saved += len(old_line.encode("utf-8"))
            applied["D"].append({"action": "deindex", "file": entry["file"]})

    # Atomic MEMORY.md write (only if changed)
    if new_idx != idx:
        atomic_write(state["index_path"], new_idx)

    return bytes_saved, applied


def print_plan(state, plan, estimated_impact):
    idx_bytes, idx_lines = measured_index(state["idx"])
    pct_now = int(max(idx_lines / LINE_CAP, idx_bytes / BYTE_CAP) * 100)
    new_bytes = max(idx_bytes + estimated_impact, 0)
    pct_after = int(new_bytes / BYTE_CAP * 100)

    print(f"=== memory-lint --auto-archive --dry-run: {state['d']} ===")
    print()
    print(f"Class A (stale-superseded): {len(plan['A'])} files")
    for e in plan["A"]:
        print(f"  [move] {e['from']} → _archive/{e['to_archive_subdir']}/")
    if plan["A"]:
        print(f"  [rewrite] {len(plan['A'])} MEMORY.md pointer(s) → stub")
    print()
    print(f"Class B (near-budget-collapse): {len(plan['B'])} pointer(s)")
    for e in plan["B"]:
        print(f"  [rewrite] MEMORY.md: {e['topic_file']} ({e['from_chars']} → {e['to_chars']} chars, {e['delta_bytes']:+d}B)")
    print()
    print(f"Class C (dangling-link-rewrite): {len(plan['C'])}")
    for e in plan["C"]:
        if e.get("new"):
            print(f"  [rewrite] {e['file']}: {e['old']} → {e['new']} ({e['reason']})")
        else:
            print(f"  [manual] {e['file']}: {e['old']} (no ledger target found; needs human resolution)")
    print()
    plan_d = plan.get("D", [])
    d_bytes_saved = sum(len(e["old_pointer_line"].encode("utf-8")) + 1 for e in plan_d)
    print(f"Class D (count-fold): {len(plan_d)} pointer(s)")
    for e in plan_d:
        print(f"  [deindex] {e['file']} (backing file kept, just unindexed — still in git history + qmd)")
    if plan_d:
        print(f"  Class D savings (reported separately — not mixed into the estimate below): -{d_bytes_saved}B")
    print()
    print(f"Estimated impact (A+B+C only): {estimated_impact:+d}B ({estimated_impact/1024:+.1f}KB)")
    print(f"  MEMORY.md {idx_bytes}B → {new_bytes}B ({pct_now}% → {pct_after}% of {BYTE_CAP}B cap, before Class D)")


def build_plan(state):
    """A, B, C, D composed: each class judges its guard on the graph the earlier classes leave."""
    plan_a = class_a_stale_superseded(state)
    removed_a = frozenset(e["from"] for e in plan_a)
    live = state["idx"]   # the index as apply leaves it: A's stubs first, then B's collapses
    for e in plan_a:
        live, _ = replace_live(live, e["old_pointer_line"], STUB_TEMPLATE.format(e["from"][:-3], e["to_archive_subdir"], e["from"]))
    plan_b = class_b_near_budget_collapse(state, removed_files=removed_a, index_text=live)
    plan_c = class_c_dangling_link_rewrite(state, removed_files=removed_a)
    for e in plan_b:
        live, _ = replace_live(live, e["from"], e["to"])
    exclude_files = removed_a | {e["topic_file"] for e in plan_b}
    plan_d = class_d_count_fold(state, exclude_files, removed_files=removed_a, index_text=live)
    return {"A": plan_a, "B": plan_b, "C": plan_c, "D": plan_d}


def run_action_mode(state, args):
    plan = build_plan(state)
    plan_a, plan_b, plan_c, plan_d = plan["A"], plan["B"], plan["C"], plan["D"]
    estimated_impact = (
        sum(len(e["old_pointer_line"]) - len(STUB_TEMPLATE.format(e["from"][:-3], e["to_archive_subdir"], e["from"])) for e in plan_a)
        + sum(e["delta_bytes"] for e in plan_b)
        + sum(len(e["old"]) - len(e["new"]) for e in plan_c if e.get("new"))
    )

    dry_run = args.dry_run or not args.yes  # default ON
    apply_now = args.yes and not args.dry_run

    if args.json:
        a_list = []
        for e in plan_a:
            a_list.append({
                "action": "move",
                "from": e["from"],
                "to": f"_archive/{e['to_archive_subdir']}/{e['from']}",
                "pointer_rewrite": {
                    "from": e["old_pointer_line"],
                    "to": STUB_TEMPLATE.format(e["from"][:-3], e["to_archive_subdir"], e["from"]),
                },
            })
        b_list = []
        for e in plan_b:
            b_list.append({
                "action": "rewrite_pointer",
                "from": e["from"],
                "to": e["to"],
                "delta_bytes": e["delta_bytes"],
                "topic_file": e["topic_file"],
            })
        c_list = []
        for e in plan_c:
            c_list.append({
                "action": "rewrite_wikilink",
                "file": e["file"],
                "old": e["old"],
                "new": e.get("new"),
                "reason": e.get("reason"),
            })
        d_list = [{"action": "deindex", "file": e["file"]} for e in plan_d]
        out = {
            "mode": "auto-archive-dry-run" if dry_run else "auto-archive-apply",
            "memory_dir": state["d"],
            "classes": {
                "A_stale_superseded": a_list,
                "B_near_budget_collapse": b_list,
                "C_dangling_link_rewrite": c_list,
                "D_count_fold": d_list,
            },
            "estimated_impact_bytes": estimated_impact,
            "estimated_impact_bytes_note": "A+B+C only — Class D reported separately",
            "d_count_fold_bytes_saved": sum(len(e["old_pointer_line"].encode("utf-8")) + 1 for e in plan_d),
            "apply_command": "memory-lint.py --auto-archive --yes",
        }
        print(json.dumps(out, indent=2))
        return 0  # JSON mode is informational; exit 0 regardless of dry_run

    print_plan(state, plan, estimated_impact)

    if not any(plan.values()):
        print()
        findings = detector_findings(state)[0] + [x for x in [depth_ratchet(state, write=False)[0]] if x]
        if findings:
            print("No actions proposed — lint findings remain that action mode does not fix; run plain lint to see them.")
        else:
            print("No actions proposed — store is clean (within action-mode heuristics).")
        if not apply_now:
            print("  (re-run with --yes to exit cleanly without re-checking)")
        return 0

    # An explicit --dry-run is a hard stop: print the plan and exit, never apply
    # or prompt. --dry-run wins over --yes (safety-flag precedence) — otherwise
    # `--auto-archive --dry-run --yes` silently applied, defeating the preview
    # SKILL.md documents --dry-run for. The default (bare --auto-archive) keeps
    # the prompt below; --yes alone still applies directly (dry_run is False).
    if args.dry_run:
        return 0

    if dry_run and not apply_now:
        print()
        print("Apply? [y/N] (use --yes to skip)")
        try:
            ans = input("> ").strip().lower()
        except EOFError:
            ans = "n"
        apply_now = ans in ("y", "yes")

    if apply_now:
        # Concurrent-edit guard: compare mtime + first-200-chars hash of MEMORY.md
        idx_path = state["index_path"]
        mtime_before = os.path.getmtime(idx_path)
        hash_before = short_hash(state["idx"], 200)
        time.sleep(0.05)  # allow in-flight writes to land
        idx_now = open(idx_path, encoding="utf-8").read()
        mtime_now = os.path.getmtime(idx_path)
        hash_now = short_hash(idx_now, 200)
        if (mtime_now != mtime_before) or (hash_now != hash_before):
            print()
            print("ERROR: MEMORY.md was modified since lint scan (mtime/hash drift).")
            print("  Re-run lint to refresh state, then re-apply.")
            return 2

        bytes_saved, applied = apply_action_plan(state, plan)
        print()
        print(f"=== Applied ===")
        print(f"  A: {len(applied['A'])} file(s) moved to _archive/")
        print(f"  B: {len(applied['B'])} pointer(s) collapsed")
        print(f"  C: {len(applied['C'])} wikilink(s) rewritten")
        print(f"  D: {len(applied['D'])} pointer(s) deindexed (backing files kept)")
        print(f"  Net: {bytes_saved:+d}B saved on MEMORY.md")
    return 0


# ── Entry point ───────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="memory-lint: detector + action mode")
    ap.add_argument("memory_dir", nargs="?", help="Memory store path (default: auto-derive from cwd)")
    ap.add_argument("--auto-archive", action="store_true",
                    help="Enter action mode (default: --dry-run ON, prints plan)")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print plan, do not mutate (default ON with --auto-archive)")
    ap.add_argument("--yes", action="store_true",
                    help="Skip y/N confirm and apply mutations (an explicit --dry-run overrides this)")
    ap.add_argument("--json", action="store_true", help="Machine-readable output")
    args = ap.parse_args()

    d = memory_dir(args.memory_dir)
    if not os.path.isdir(d):
        sys.exit(f"FATAL: memory dir not found: {d}")
    state = collect_state(d)

    if args.auto_archive:
        sys.exit(run_action_mode(state, args))
    else:
        run_detector(state, args.json)


if __name__ == "__main__":
    main()
