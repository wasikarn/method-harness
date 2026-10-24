#!/usr/bin/env python3
"""Check Markdown prose against a partial, mechanical subset of ASD-STE100
(Simplified Technical English) writing rules. Not a compliance certification —
see rules.md. Report-only: never edits a scanned file.

Confirmed findings: sentence word-count limits (5.1/6.3, incl. the Rule 8.5
nested-parenthetical case), paragraph length (6.6), semicolons (8.1),
contractions (4.2).

Advisory findings (heuristic, may misfire): passive voice (3.6), -ing verb
form (3.5), stacked auxiliaries (3.4), non-American spelling (1.14), long
noun runs (2.1). A word-count/limit finding on an auto-classified sentence
is also advisory rather than confirmed, since misclassifying procedural vs.
descriptive changes which limit applies -- this does not extend to that
sentence's other findings (a semicolon or contraction stays confirmed
regardless of mode, since neither depends on the classification).

Run with --selftest to check the word counter against the standard's own
worked examples.
"""
import argparse
import json
import os
import re
import subprocess
import sys

MAX_PROCEDURAL_WORDS = 20  # Rule 5.1
MAX_DESCRIPTIVE_WORDS = 25  # Rule 6.3
MAX_PARAGRAPH_SENTENCES = 6  # Rule 6.6

FROZEN_DIRS = ("docs/research/", "docs/post-mortems/", "docs/plans/")
FROZEN_FILES = ("CHANGELOG.md", "docs/METHODOLOGY.md")

CODE_PLACEHOLDER = ""
PAREN_PLACEHOLDER = ""
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
URL_RE = re.compile(r"https?://\S+")
# One level of inner nesting is matched too (a hazard note nesting an
# identifier, per the Rule 8.5 worked example) -- a second PAREN_RE pass
# on the captured inner text still resolves that inner level on its own.
PAREN_RE = re.compile(r"\(([^()]*(?:\([^()]*\)[^()]*)*)\)")
QUOTE_RE = re.compile(r'["“][^"“”\n]*["”]')  # Rule 8.6: quoted text = one word (straight or curly)
NUMBER_RE = re.compile(r"^-?\d+(\.\d+)?$")
SENT_SPLIT_RE = re.compile(r'(?<=[.!?])\s+(?=[A-Z0-9"`(])')
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
# Same fence character on both ends (a backref, so a ``` fence can't be
# closed by ~~~), leading indentation allowed on either line independently --
# a fence nested under a list item is commonly indented only on one side.
FENCE_RE = re.compile(r"^[ \t]*(```|~~~).*?^[ \t]*\1", re.DOTALL | re.MULTILINE)
# 's is ambiguous with a possessive ("the dog's bone"), so it's only treated
# as a contraction after a closed list of words that actually contract to 's
# ("it's", "that's", ...) -- never a bare \w+'s.
CONTRACTION_RE = re.compile(
    r"\b\w+n['’]t\b"
    r"|\b\w+['’](?:re|ve|ll|d|m)\b"
    r"|\b(?:it|he|she|that|there|here|what|who|let|where|how|when|why)['’]s\b",
    re.IGNORECASE)
PASSIVE_RE = re.compile(r"\b(?:is|are|was|were|be|been|being)\s+\w+ed\b", re.IGNORECASE)
ING_RE = re.compile(r"\b(?:is|are|was|were|be|been|being)\s+\w+ing\b", re.IGNORECASE)
AUX_STACK_RE = re.compile(
    r"\b(?:will|would|shall|should|can|could|may|might|must)\s+(?:not\s+)?"
    r"(?:have|has|had)\s+been\b", re.IGNORECASE)
NOUN_RUN_RE = re.compile(r"(?:\b[A-Z][a-zA-Z]*\b\s+){3,}\b[A-Z][a-zA-Z]*\b")

# ponytail: closed lists, not general NLP — extend here if a real doc needs
# a unit/abbreviation this misses. STE's own dictionary is not bundled (v1
# scope decision), so this is an author-defined ceiling, not from the standard.
UNIT_TOKENS = {"°c", "°f", "kg", "mg", "mm", "cm", "km", "psi", "ma", "kw",
               "hz", "ohms", "ohm", "rpm", "a.m", "p.m", "kb", "mb", "gb", "ms", "s"}
DEGREE_UNIT_WORDS = {"celsius", "fahrenheit", "kelvin"}
ABBREV_PREFIX_TOKENS = {"no", "fig", "rev", "item"}
# Sentences must not split right after one of these (its trailing period is
# an abbreviation mark, not a sentence end) -- otherwise "Examine the No. 1
# bearing..." splits into "Examine the No." + "1 bearing...", and the real,
# possibly over-length sentence never gets word-counted as a whole.
# ponytail: a.m./p.m. can legitimately end a real sentence too ("...at 10
# a.m. The team then leaves."), which this now merges instead of splitting --
# an inherent trade-off, not a bug, since disambiguating "abbreviation" from
# "abbreviation that happens to end this sentence" needs real sentence-
# boundary detection, out of scope for a closed-list check. Accepted because
# the identifier case (No./Fig./Item/Rev + a number) is the common one this
# guards, and it fully escaping detection is worse than an occasional missed
# paragraph-sentence-count (6.6) split on a time-of-day mention.
NO_SPLIT_BEFORE = ABBREV_PREFIX_TOKENS | {"a.m", "p.m"}
SPELLING_MAP = {
    "colour": "color", "organise": "organize", "organised": "organized",
    "analyse": "analyze", "analysed": "analyzed", "behaviour": "behavior",
    "favour": "favor", "favourite": "favorite", "centre": "center",
    "licence": "license", "defence": "defense", "programme": "program",
    "optimise": "optimize", "optimised": "optimized", "recognise": "recognize",
    "utilise": "utilize", "customise": "customize", "cancelled": "canceled",
}
# One pass per sentence instead of one regex search per map entry (the hot spot).
SPELLING_RE = re.compile(r"\b(" + "|".join(SPELLING_MAP) + r")\b", re.IGNORECASE)
IMPERATIVE_STARTS = {
    "run", "use", "check", "add", "remove", "delete", "create", "write",
    "read", "verify", "confirm", "never", "always", "do", "don't", "ensure",
    "set", "stage", "commit", "avoid", "keep", "call", "invoke", "pass",
    "return", "install", "enable", "disable", "open", "close", "start",
    "stop", "update", "edit", "move", "copy", "build", "test",
}

# The closing "---" needs a following newline OR end-of-string, so frontmatter
# that ends exactly at EOF (no trailing blank line) still parses instead of
# silently falling through to be scanned as body text.
FRONTMATTER_RE = re.compile(r"\A---\n(.*?\n)---(?:\n|\Z)", re.DOTALL)


def normalize_tok(tok):
    return tok.strip(".,;:!?\"'()").lower()


def _blank_url(m):
    # URL_RE's \S+ is greedy and swallows trailing prose punctuation glued to
    # the URL (a real sentence semicolon right after it, no space) -- give
    # that punctuation back so it still counts as the sentence's own text.
    url = m.group(0)
    trail = ""
    while url and url[-1] in ";,.!?)":
        trail = url[-1] + trail
        url = url[:-1]
    return CODE_PLACEHOLDER + trail


def analyze_sentence(text):
    """STE word count for one sentence. Returns (count, nested_sentences)."""
    nested = []

    def paren_sub(m):
        inner = m.group(1)
        if re.search(r"\s", inner.strip()):
            nested.append(inner)  # Rule 8.5: non-bare parenthetical is its own sentence
        return PAREN_PLACEHOLDER

    working = INLINE_CODE_RE.sub(CODE_PLACEHOLDER, text)  # protected 1-word token, not an STE rule
    working = URL_RE.sub(_blank_url, working)
    working = MD_LINK_RE.sub(r"\1", working)
    working = QUOTE_RE.sub(CODE_PLACEHOLDER, working)  # Rule 8.6: quoted text = 1 word
    working = PAREN_RE.sub(paren_sub, working)

    tokens = working.split()
    norm = [normalize_tok(t) for t in tokens]  # once per token, not twice
    merged = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        nt = norm[i]
        if i + 1 < len(tokens):
            nt1 = norm[i + 1]
            if NUMBER_RE.match(nt) and nt1 in UNIT_TOKENS:  # Rule 8.6: number+unit = 1 word
                merged.append(t + " " + tokens[i + 1]); i += 2; continue
            if nt in ABBREV_PREFIX_TOKENS and NUMBER_RE.match(nt1):  # Rule 8.6: alphanumeric identifier
                merged.append(t + " " + tokens[i + 1]); i += 2; continue
            if NUMBER_RE.match(nt) and nt1 == "degrees" and i + 2 < len(tokens):
                nt2 = norm[i + 2]
                if nt2 in DEGREE_UNIT_WORDS:
                    merged.append(" ".join(tokens[i:i + 3])); i += 3; continue
        merged.append(t)
        i += 1
    return len(merged), nested


def split_sentences(text):
    sentences, start = [], 0
    for m in SENT_SPLIT_RE.finditer(text):
        preceding = text[start:m.start()]
        last_word = re.search(r"(\S+)\s*$", preceding)
        if last_word and normalize_tok(last_word.group(1)) in NO_SPLIT_BEFORE:
            continue  # abbreviation's period, not a sentence end -- keep growing this sentence
        sentences.append((text[start:m.start()], start))
        start = m.end()
    tail = text[start:]
    if tail.strip():
        sentences.append((tail, start))
    return sentences


def classify_sentence(sentence, is_list_item):
    if is_list_item:
        return "procedural"
    m = re.match(r"[\"'`(]*([A-Za-z']+)", sentence.strip())
    if m and m.group(1).lower() in IMPERATIVE_STARTS:
        return "procedural"
    return "descriptive"


def strip_protected_spans(text):
    """Blank out inline-code/URL spans before any raw-regex prose check, so
    example code (a semicolon, a contraction) inside a sentence never counts
    as that sentence's own prose violation -- the same protection
    analyze_sentence() already applies for its own word count."""
    working = INLINE_CODE_RE.sub(CODE_PLACEHOLDER, text)
    working = URL_RE.sub(_blank_url, working)
    return working


def check_text_block(text, base_line, mode, source, is_list_item=False, paragraph_check=True):
    confirmed, advisory = [], []
    sentences = split_sentences(text)

    for sentence, offset in sentences:
        eff_mode = mode if mode != "auto" else classify_sentence(sentence, is_list_item)
        limit = MAX_PROCEDURAL_WORDS if eff_mode == "procedural" else MAX_DESCRIPTIVE_WORDS
        line = base_line + text.count("\n", 0, offset)
        base = {"source": source, "line": line, "sentence": sentence.strip()[:120]}
        bucket = advisory if mode == "auto" else confirmed

        count, nested = analyze_sentence(sentence)
        if count > limit:
            f = dict(base, rule=("5.1" if eff_mode == "procedural" else "6.3"),
                     words=count, limit=limit, mode=eff_mode)
            if mode == "auto":
                f["guessed_mode"] = True
            bucket.append(f)
        for inner in nested:
            inner_count, _ = analyze_sentence(inner)
            if inner_count > limit:
                bucket.append(dict(base, rule="8.5", words=inner_count, limit=limit,
                                    mode=eff_mode, nested=True, sentence=inner.strip()[:120]))

        scan_text = strip_protected_spans(sentence)
        if ";" in scan_text:
            confirmed.append(dict(base, rule="8.1", message="semicolon"))
        # Every CONTRACTION_RE branch needs an apostrophe; skip the costly scan without one.
        cm = CONTRACTION_RE.search(scan_text) if ("'" in scan_text or "’" in scan_text) else None
        if cm:
            confirmed.append(dict(base, rule="4.2", message="contraction: " + cm.group(0)))
        if PASSIVE_RE.search(scan_text):
            advisory.append(dict(base, rule="3.6", message="possible passive voice"))
        if ING_RE.search(scan_text):
            advisory.append(dict(base, rule="3.5", message="-ing verb form"))
        if AUX_STACK_RE.search(scan_text):
            advisory.append(dict(base, rule="3.4", message="stacked auxiliary verbs"))
        if NOUN_RUN_RE.search(scan_text):
            advisory.append(dict(base, rule="2.1", message="long noun run"))
        found = {w.lower() for w in SPELLING_RE.findall(scan_text)}
        for wrong, right in SPELLING_MAP.items():
            if wrong in found:
                advisory.append(dict(base, rule="1.14", message=f"non-American spelling: {wrong} -> {right}"))

    if paragraph_check and not is_list_item and len(sentences) > MAX_PARAGRAPH_SENTENCES:
        confirmed.append({"source": source, "line": base_line, "rule": "6.6",
                           "sentences": len(sentences)})
    return confirmed, advisory


def extract_frontmatter(text):
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None, 0, text, 1
    fm_text = m.group(1)
    fm_start_line = 2  # file line 1 is the opening "---"
    body = text[m.end():]
    body_start_line = text.count("\n", 0, m.end()) + 1
    return fm_text, fm_start_line, body, body_start_line


def check_frontmatter(fm_text, fm_start_line):
    confirmed, advisory, errors = [], [], []
    try:
        import yaml
    except ImportError:
        errors.append({"rule": "tooling", "message": "PyYAML unavailable; frontmatter description not checked"})
        return confirmed, advisory, errors

    try:
        data = yaml.safe_load(fm_text)
    except (yaml.YAMLError, ValueError) as e:
        # ValueError: PyYAML's SafeLoader resolves some scalars (e.g. an
        # implicit timestamp like "2026-99-99") by calling datetime.date(...),
        # which raises ValueError rather than YAMLError on an invalid value.
        errors.append({"rule": "tooling", "message": f"malformed frontmatter YAML: {e}"})
        return confirmed, advisory, errors

    if not isinstance(data, dict) or "description" not in data:
        return confirmed, advisory, errors
    desc = data["description"]
    if not isinstance(desc, str):
        errors.append({"rule": "tooling", "message": "frontmatter 'description' is not a string"})
        return confirmed, advisory, errors

    line = fm_start_line
    try:
        node = yaml.compose(fm_text, Loader=yaml.SafeLoader)
        if node is not None and hasattr(node, "value"):
            for k, v in node.value:
                if getattr(k, "value", None) == "description":
                    # A block scalar ("description: |" / ">") puts its first
                    # content line one line below its own start_mark (which
                    # sits on the "description: |" line itself, same as the
                    # key) -- a folded scalar (">") still loses the exact
                    # interior line past that point, since folding erases
                    # which source line each word came from; this is the
                    # closest a line number can honestly get without
                    # reimplementing YAML's own folding.
                    block_offset = 1 if v.style in ("|", ">") else 0
                    line = fm_start_line + v.start_mark.line + block_offset
                    break
    except yaml.YAMLError:
        pass  # keep the fm_start_line fallback

    c, a = check_text_block(desc, line, "descriptive", "frontmatter.description", paragraph_check=False)
    confirmed.extend(c)
    advisory.extend(a)
    return confirmed, advisory, errors


def strip_fenced_code(text):
    out, last = [], 0
    for m in FENCE_RE.finditer(text):
        out.append(text[last:m.start()])
        out.append("\n" * text.count("\n", m.start(), m.end()))
        last = m.end()
    out.append(text[last:])
    return "".join(out)


def strip_tables(text):
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if re.match(r"^\s*\|.*\|\s*$", line) or re.match(r"^\s*[-:| ]+$", line.strip()) and "|" in line:
            lines[i] = ""
    return "\n".join(lines)


def check_body(body, body_start_line, mode):
    confirmed, advisory = [], []
    lines = body.split("\n")
    para_lines, para_start = [], None
    list_item_re = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+")

    def flush():
        if not para_lines:
            return
        text = "\n".join(para_lines)
        line_no = body_start_line + para_start
        if list_item_re.match(para_lines[0]):
            # Group a marker line with any continuation lines that follow it
            # (no marker of their own, indented or not) into one logical
            # item, and strip the marker before counting -- otherwise the marker itself
            # is counted as a word, and a long item wrapped onto a second
            # line is checked as two short, individually-compliant halves
            # instead of the one sentence it actually is.
            items = []
            item_start, item_lines = 0, []
            for offset, item_line in enumerate(para_lines):
                if list_item_re.match(item_line):
                    if item_lines:
                        items.append((item_start, item_lines))
                    item_start, item_lines = offset, [item_line]
                else:
                    item_lines.append(item_line)
            if item_lines:
                items.append((item_start, item_lines))
            for offset, grouped_lines in items:
                # A "\n" join (not " ") keeps each physical line addressable:
                # check_text_block's own offset math already treats a
                # newline the same as any other whitespace for splitting and
                # word-counting, so this only changes which physical line a
                # finding is attributed to, never what counts as one sentence.
                joined = "\n".join(list_item_re.sub("", gl, count=1).strip() for gl in grouped_lines)
                c, a = check_text_block(joined, line_no + offset, mode,
                                         "body", is_list_item=True)
                confirmed.extend(c); advisory.extend(a)
        else:
            c, a = check_text_block(text, line_no, mode, "body")
            confirmed.extend(c); advisory.extend(a)

    for idx, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("#"):
            flush()
            para_lines, para_start = [], None
            continue
        if para_start is None:
            para_start = idx
        para_lines.append(line)
    flush()
    return confirmed, advisory


def scan_markdown_file(path, mode):
    confirmed, advisory, errors = [], [], []
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        errors.append({"rule": "tooling", "message": f"could not read file: {e}"})
        return confirmed, advisory, errors

    fm_text, fm_start_line, body, body_start_line = extract_frontmatter(text)
    if fm_text is not None:
        c, a, e = check_frontmatter(fm_text, fm_start_line)
        confirmed.extend(c); advisory.extend(a); errors.extend(e)

    body = strip_fenced_code(body)
    body = strip_tables(body)
    c, a = check_body(body, body_start_line, mode)
    confirmed.extend(c); advisory.extend(a)
    return confirmed, advisory, errors


def repo_root():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, check=True)
    return out.stdout.strip()


def is_frozen(rel_path):
    return rel_path.startswith(FROZEN_DIRS) or rel_path in FROZEN_FILES


def _in_repo(root, full_path):
    real = os.path.realpath(full_path)
    return real == root or real.startswith(root + os.sep)


def default_targets(root):
    changed = set()
    scan_errors = []
    head_ok = subprocess.run(["git", "rev-parse", "--verify", "-q", "HEAD"],
                              cwd=root, capture_output=True).returncode == 0
    # A repo with no commits yet has no HEAD to diff against; fall back to
    # --cached so staged files in a brand-new repo are still found instead
    # of the diff command failing and being silently swallowed as "clean".
    diff_cmd = (["git", "diff", "--name-only", "-z", "HEAD"] if head_ok
                else ["git", "diff", "--name-only", "-z", "--cached"])
    for cmd in (diff_cmd, ["git", "ls-files", "--others", "--exclude-standard", "-z"]):
        try:
            out = subprocess.run(cmd, cwd=root, capture_output=True, check=True)
        except subprocess.CalledProcessError as e:
            scan_errors.append({"rule": "tooling",
                                 "message": f"git command failed ({' '.join(cmd)}): {e}"})
            continue
        for part in out.stdout.split(b"\x00"):
            if part:
                changed.add(part.decode("utf-8", "surrogateescape"))

    result = []
    for rel in sorted(changed):
        if not rel.endswith(".md"):
            continue
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            continue
        # realpath() resolves every ancestor path segment, not just a
        # symlinked leaf -- a plain file reached through a symlinked
        # ancestor directory must be caught too, so this check always runs,
        # not only when the leaf itself is a symlink.
        if not _in_repo(root, full):
            continue
        # A same-tree symlink can alias a frozen path under a non-frozen
        # name (is_frozen(rel) alone only catches the name git tracked it
        # under) -- check the resolved target's path too, or the alias
        # scans a file the frozen-dir exclusion was supposed to protect.
        real_rel = os.path.relpath(os.path.realpath(full), root)
        if is_frozen(rel) or is_frozen(real_rel):
            continue
        result.append(full)
    return result, scan_errors


def explicit_targets(root, arg_path):
    full = os.path.abspath(arg_path)
    scan_errors = []
    if not _in_repo(root, full):
        # An explicit path outside the repo is a tool error, never a silent
        # "clean" -- reports are always repo-relative, so there is no
        # sensible way to scan or report on a path outside the repo root.
        scan_errors.append({"rule": "tooling", "message": f"path is outside the repository: {arg_path}"})
        return [], scan_errors
    if os.path.isfile(full):
        return [full], scan_errors
    if not os.path.isdir(full):
        scan_errors.append({"rule": "tooling", "message": f"path does not exist: {arg_path}"})
        return [], scan_errors

    def on_walk_error(exc):
        scan_errors.append({"rule": "tooling", "message": f"could not list directory: {exc}"})

    result = []
    for dirpath, dirnames, filenames in os.walk(full, onerror=on_walk_error):
        dirnames[:] = [d for d in dirnames if _in_repo(root, os.path.join(dirpath, d))]
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            fp = os.path.join(dirpath, fn)
            if not _in_repo(root, fp):
                continue
            result.append(fp)
    return sorted(result), scan_errors


def format_finding(f):
    if "message" in f:
        return f["message"]
    if "words" in f:
        tag = " [guessed mode]" if f.get("guessed_mode") else ""
        tag += " [nested 8.5]" if f.get("nested") else ""
        s = f['sentence']
        s = s if len(s) <= 100 else s[:100] + "..."  # a run-on sentence would flood a directory scan
        return f"{f['words']} words (limit {f['limit']}, mode={f.get('mode', '?')}){tag}: {s!r}"
    if "sentences" in f:
        return f"{f['sentences']} sentences (limit {MAX_PARAGRAPH_SENTENCES})"
    return str(f)


def print_human(result, advisory=True):
    for e in result.get("errors", []):
        print(f"[error] {e['message']}")
    for f in result["files"]:
        print(f["path"])
        for c in f["confirmed"]:
            print(f"  [confirmed] rule {c['rule']} line {c['line']}: {format_finding(c)}")
        for a in (f["advisory"] if advisory else []):
            print(f"  [advisory]  rule {a['rule']} line {a['line']}: {format_finding(a)}")
        for e in f["errors"]:
            print(f"  [error]     {e['message']}")
    print(f"exit_code={result['exit_code']} (0=clean, 1=confirmed findings, 2=incomplete check)")
    print("Checks a partial, mechanical subset of ASD-STE100 — not a compliance certification.")


def main():
    p = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    p.add_argument("path", nargs="?", help="file or directory; default: changed .md files in the working tree")
    p.add_argument("--mode", choices=["procedural", "descriptive", "auto"], default="auto")
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-advisory", action="store_true",
                   help="hide advisory lines in the human report (they never affect the exit code)")
    p.add_argument("--selftest", action="store_true")
    args = p.parse_args()

    if args.selftest:
        _selftest()
        return

    try:
        root = repo_root()
    except subprocess.CalledProcessError as e:
        # Not a git repo (or git itself failed): a tool error, exit 2 --
        # never an uncaught traceback, and never conflated with "clean".
        result = {"files": [], "errors": [{"rule": "tooling", "message": f"not a git repository: {e}"}],
                   "exit_code": 2}
        print(json.dumps(result, indent=2)) if args.json else print_human(result)
        sys.exit(2)

    targets, scan_errors = (explicit_targets(root, args.path) if args.path
                             else default_targets(root))

    files_out, any_confirmed, any_error = [], False, bool(scan_errors)
    for fp in targets:
        confirmed, advisory, errors = scan_markdown_file(fp, args.mode)
        any_confirmed = any_confirmed or bool(confirmed)
        any_error = any_error or bool(errors)
        files_out.append({"path": os.path.relpath(fp, root), "confirmed": confirmed,
                           "advisory": advisory, "errors": errors})

    exit_code = 2 if any_error else (1 if any_confirmed else 0)
    result = {"files": files_out, "errors": scan_errors, "exit_code": exit_code}
    print(json.dumps(result, indent=2)) if args.json else print_human(result, not args.no_advisory)
    sys.exit(exit_code)


def _selftest():
    # Verified fixtures, extracted directly from the ASD-STE100 Issue 9 PDF (see rules.md).
    fixtures = [
        ("Make sure that the EMER pushbutton switch is released (the EMER legend is off).", 10),
        ("Remove the safety pin (10).", 5),
        ("Installation of a Business Class (B/C) Seat", 7),
        ("Make sure that the temperature in the room is 10 °C.", 10),
        ("Make sure that the temperature in the room is 10 degrees Celsius.", 10),
        ("The maintenance team does a test of this system each day at 10 a.m.", 13),
        ("Examine the No. 1 bearing installation.", 5),
        ("The unit weighs 20 kg.", 4),
        ("The spar box has twenty-one ribs.", 6),
        ("Do steps 13 thru 16 a minimum of three times.", 10),
    ]
    for text, expected in fixtures:
        count, _ = analyze_sentence(text)
        assert count == expected, f"{text!r}: got {count}, expected {expected}"

    # Rule 8.5: the nested parenthetical is its own sentence.
    _, nested = analyze_sentence(
        "Make sure that the EMER pushbutton switch is released (the EMER legend is off).")
    assert nested == ["the EMER legend is off"], nested
    inner_count, _ = analyze_sentence(nested[0])
    assert inner_count == 5, inner_count

    # Boundary: 20 words passes the procedural limit, 21 fails.
    words20 = " ".join(f"w{i}" for i in range(1, 21)) + "."
    words21 = " ".join(f"w{i}" for i in range(1, 22)) + "."
    c20, _ = analyze_sentence(words20)
    c21, _ = analyze_sentence(words21)
    assert c20 == 20 and c21 == 21, (c20, c21)

    # Boundary: 25 words passes the descriptive limit, 26 fails.
    words25 = " ".join(f"w{i}" for i in range(1, 26)) + "."
    words26 = " ".join(f"w{i}" for i in range(1, 27)) + "."
    c25, _ = analyze_sentence(words25)
    c26, _ = analyze_sentence(words26)
    assert c25 == 25 and c26 == 26, (c25, c26)

    # Inline code is a protected ONE-word token, never silently excluded to
    # zero (that under-counted a 21-word sentence as 20 and let it pass).
    words20_plus_code = " ".join(f"w{i}" for i in range(1, 21)) + " `code`."
    c_code, _ = analyze_sentence(words20_plus_code)
    assert c_code == 21, c_code

    confirmed, _ = check_text_block(words21 + " " + words21, 1, "procedural", "test")
    assert any(f["rule"] == "5.1" for f in confirmed)

    confirmed, _ = check_text_block("Do not use this; do not use that.", 1, "descriptive", "test")
    assert any(f["rule"] == "8.1" for f in confirmed)

    confirmed, _ = check_text_block("It's fine. We won't do that.", 1, "descriptive", "test")
    assert any(f["rule"] == "4.2" for f in confirmed)

    # Curly apostrophe contractions are caught too, not just the straight one.
    confirmed, _ = check_text_block("We don’t stop.", 1, "descriptive", "test")
    assert any(f["rule"] == "4.2" for f in confirmed), confirmed

    # A genuine possessive is not mistaken for a contraction.
    confirmed, _ = check_text_block("Check the dog's bone before you leave.", 1, "descriptive", "test")
    assert not any(f["rule"] == "4.2" for f in confirmed), confirmed

    # Frontmatter: top-level description is found, not a nested metadata.description.
    fm = ('name: x\nmetadata:\n  description: "nested, not this one"\n'
          'description: "' + words26.rstrip(".") + '"\n')
    confirmed, _, errors = check_frontmatter(fm, 2)
    assert not errors, errors
    assert any(f["rule"] == "6.3" for f in confirmed), confirmed
    assert confirmed[0]["line"] == 5, confirmed[0]["line"]

    # A non-string description is a tool error, not a silent clean pass.
    _, _, errors = check_frontmatter("description: [1, 2]\n", 2)
    assert errors and "not a string" in errors[0]["message"]

    # Malformed YAML in the frontmatter block is a tool error, not a crash
    # or a silent clean pass.
    _, _, errors = check_frontmatter("description: [1, 2\n", 2)
    assert errors and "malformed" in errors[0]["message"], errors

    # A missing PyYAML dependency fails loud with a tool error, never a
    # silent "clean" pass. sys.modules[name] = None forces ImportError on
    # the next `import yaml`, the standard way to simulate this in-process.
    import sys as _sys
    _saved_yaml = _sys.modules.pop("yaml", None)
    _sys.modules["yaml"] = None  # type: ignore[assignment]
    try:
        _, _, errors = check_frontmatter('description: "hi"\n', 2)
    finally:
        del _sys.modules["yaml"]
        if _saved_yaml is not None:
            _sys.modules["yaml"] = _saved_yaml
    assert errors and "PyYAML unavailable" in errors[0]["message"], errors

    # A block-scalar description (`description: |`) is parsed and checked
    # like any other string value.
    fm_block = "description: |\n  " + words26.rstrip(".") + "\n"
    confirmed, _, errors = check_frontmatter(fm_block, 2)
    assert not errors, errors
    assert any(f["rule"] == "6.3" for f in confirmed), confirmed

    # A YAML scalar that resolves via a ValueError (an invalid implicit
    # date/timestamp), not a YAMLError, is still a tool error, not a crash.
    _, _, errors = check_frontmatter("description: 2026-99-99\n", 2)
    assert errors and "malformed" in errors[0]["message"], errors

    # Frontmatter closing exactly at EOF (no trailing blank line) still
    # parses, instead of falling through and being scanned as body text.
    fm_start, _, body, _ = extract_frontmatter('---\ndescription: "hi"\n---')
    assert fm_start is not None and body == "", (fm_start, body)

    # An unreadable file (chmod 000) is a tool error (exit 2), never a
    # crash or a silent "clean" pass.
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as tf:
        tf.write(b"Some text.\n")
        unreadable_path = tf.name
    os.chmod(unreadable_path, 0)
    # Root reads a mode-0 file anyway, so there the case proves nothing: skip it, said aloud.
    readable = os.access(unreadable_path, os.R_OK)
    try:
        _, _, errors = scan_markdown_file(unreadable_path, "auto")
    finally:
        os.chmod(unreadable_path, 0o644)
        os.unlink(unreadable_path)
    if readable:
        print("SKIP: unreadable-file case (chmod 000 leaves the file readable here, e.g. as root)", file=sys.stderr)
    else:
        assert errors and "could not read" in errors[0]["message"], errors

    # Rule 8.6: a multi-word quoted phrase counts as ONE word, not one word
    # per space -- deep-audit finding, was silently over-counting.
    count, _ = analyze_sentence('Set the mode to "quick fix" before you continue.')
    assert count == 8, count

    # Number+unit merging covers a negative number and a plain "s" (seconds),
    # not just the positive/already-listed units -- deep-audit finding.
    assert analyze_sentence("Use -10 °C.")[0] == 2, analyze_sentence("Use -10 °C.")
    assert analyze_sentence("Wait 10 s.")[0] == 2, analyze_sentence("Wait 10 s.")

    # The sentence splitter must not cut right after an abbreviation's period
    # ("No.", "Fig.", "a.m." ...) -- deep-audit finding: the real sentence
    # otherwise splits into two short fragments and a genuine over-length
    # sentence never gets word-counted as a whole.
    long_abbrev_sentence = ("Examine the No. 1 bearing installation and check every single "
                             "component for wear and damage before you sign off the report today.")
    assert len(split_sentences(long_abbrev_sentence)) == 1, split_sentences(long_abbrev_sentence)
    confirmed, _ = check_text_block(long_abbrev_sentence, 1, "procedural", "test")
    assert any(f["rule"] == "5.1" for f in confirmed), confirmed

    # A doubly-nested parenthetical resolves both levels: the outer sentence
    # collapses the whole group to one word, and the captured nested text
    # still holds its own inner "(A)" identifier -- deep-audit finding: only
    # the innermost level used to be collapsed, leaving the outer parens as
    # stray punctuation in the outer word count.
    count, nested = analyze_sentence("Check the switch (the lamp (A) is off).")
    assert count == 4, count
    assert nested == ["the lamp (A) is off"], nested

    # Inline code is fully protected, not just for the word count: a
    # semicolon or contraction inside a `code span` must never be reported
    # as a confirmed prose violation on the surrounding sentence -- deep-audit
    # finding.
    confirmed, _ = check_text_block("Run `echo a;b` now.", 1, "procedural", "test")
    assert not any(f["rule"] == "8.1" for f in confirmed), confirmed
    confirmed, _ = check_text_block("Read `don't` now.", 1, "procedural", "test")
    assert not any(f["rule"] == "4.2" for f in confirmed), confirmed

    # strip_fenced_code recognizes a ~~~ fence too, not just a column-0 ```
    # fence -- deep-audit finding.
    stripped = strip_fenced_code('Do not use this; it is not allowed.\n\n~~~bash\necho "a;b"\n~~~\n')
    assert "a;b" not in stripped, stripped

    # A list item's own marker ("- ") is never itself counted as a word, and
    # a list item wrapped across a continuation line is joined and checked as
    # the one sentence it actually is -- deep-audit finding: the marker used
    # to inflate the count by one, and a wrapped item's two halves were each
    # checked alone, both individually under the limit.
    at_limit_item = "- " + " ".join(f"w{i}" for i in range(1, 21)) + "."
    confirmed, _ = check_body(at_limit_item, 1, "procedural")
    assert not any(f["rule"] == "5.1" for f in confirmed), confirmed
    wrapped_item = ("- " + " ".join(f"w{i}" for i in range(1, 13))
                     + "\n  " + " ".join(f"w{i}" for i in range(13, 25)) + ".")
    confirmed, _ = check_body(wrapped_item, 1, "procedural")
    assert any(f["rule"] == "5.1" and f["words"] == 24 for f in confirmed), confirmed

    # A YAML literal block scalar's finding points at the actual source line
    # the violation is on, not the "description: |" header line -- deep-audit
    # finding.
    fm_literal = "description: |\n  All fine.\n  Stop; wait.\n"
    confirmed, _, errors = check_frontmatter(fm_literal, 2)
    assert not errors, errors
    assert confirmed[0]["line"] == 4, confirmed[0]["line"]

    # An explicit path outside the repo is a tool error, never a silent
    # "clean" pass -- deep-audit finding. Uses a synthetic root, not the live
    # repo_root(), so --selftest itself never depends on cwd being a git
    # repo (explicit_targets only does path-prefix comparison on `root`).
    targets, errors = explicit_targets("/some/fake/root", "/definitely-absent-ste-audit.md")
    assert targets == [] and errors, (targets, errors)

    # Rule 8.6's quote merge also covers curly/smart quotes, not just
    # straight ones -- fresh-context validator finding, matches
    # CONTRACTION_RE already handling curly apostrophes elsewhere.
    count, _ = analyze_sentence("Set the mode to “quick fix” before you continue.")
    assert count == 8, count

    # A URL glued directly to a sentence-ending semicolon (no space) keeps
    # that semicolon as real sentence text -- fresh-context validator
    # finding: URL_RE's \S+ was greedily swallowing it into the blanked span.
    confirmed, _ = check_text_block("See https://example.com; then stop.", 1, "descriptive", "test")
    assert any(f["rule"] == "8.1" for f in confirmed), confirmed

    # A wrapped list item's two lines each report their own physical line
    # number, not both the item's start line -- fresh-context validator
    # finding: the space-join used for word-counting lost line attribution.
    confirmed, _ = check_body("- First; bad.\n  Second; also bad.", 1, "procedural")
    lines_hit = sorted(f["line"] for f in confirmed if f["rule"] == "8.1")
    assert lines_hit == [1, 2], lines_hit

    print("ste-lint.py selftest ok")


if __name__ == "__main__":
    main()
