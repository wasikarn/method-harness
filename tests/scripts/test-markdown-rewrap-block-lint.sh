#!/usr/bin/env bash
# test-markdown-rewrap-block-lint.sh — a rewrapped Markdown paragraph must not start a line with a
# block marker. CommonMark lets `>` (block quote) and `#`..`######` (ATX heading) interrupt a
# paragraph, so a rewrap that puts one at a line start silently splits the paragraph. The real case
# (PR #686, docs/reference/repo-gotchas.md): rewrapping the code span `cat 2> >(grep -q y)` put
# `>(grep -q y)`:` at a line start, and pandoc rendered the rest of the paragraph as a block quote,
# pairing the later backticks wrongly. Flagged, outside fences and front matter:
# - a `>` glued to the next character (`>(`, `>/dev/null`, `>&2`) on a line right after text
#   outside a block quote (lazy lines count as inside): a deliberate quote is `> text`, a wrapped
#   shell redirect is not;
# - an ATX heading right after a paragraph line (not a list item, table row, quote, heading, HTML).
# Neither counts after a horizontal rule, setext underline or link reference definition, and HTML
# blocks and comments are skipped. Fences follow CommonMark: a backtick opener's info string has no
# backtick, and a closer is bare. SCANNED_OUT, if set, names a file that gets the count of files
# read.
# Lists are out of scope: a list right after its lead-in line is common and deliberate.
# Fix a hit by rewrapping so the marker stays mid-line, or with a blank line before a real heading.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

# Prints "file:line: text" for each hit in the Markdown files named as arguments.
hits() {
  python3 - "$@" <<'PY'
import os, re, sys
glued = re.compile(r'^ {0,3}>[^ \t>]')
heading = re.compile(r'^ {0,3}#{1,6}(?:[ \t]|$)')
fence = re.compile(r'^ {0,3}(`{3,}|~{3,})(.*)$')
quote = re.compile(r'^ {0,3}>')
not_para = re.compile(r'^ {0,3}(?:>|#|[-+*][ \t]|\d+[.)][ \t]|\||<)')
# a line after which a marker opens no paragraph split: a horizontal rule, a setext underline, a
# link reference definition
leaf = re.compile(r'^ {0,3}(?:([-*_])(?:[ \t]*\1){2,}[ \t]*|=+[ \t]*|\[[^\]]+\]:[ \t].*)$')
scanned = 0
for f in sys.argv[1:]:
    try:
        lines = open(f, encoding='utf-8').read().split('\n')
    except (OSError, UnicodeDecodeError):
        continue
    scanned += 1
    start = 0
    if lines and lines[0].strip() == '---':
        for j in range(1, len(lines)):
            if lines[j].strip() in ('---', '...'):
                start = j + 1
                break
    open_fence, html, in_quote, prev = None, None, False, ''
    for n in range(start, len(lines)):
        line = lines[n]
        if html:
            # a comment ends at -->, any other HTML block at a blank line
            if (html == 'comment' and '-->' in line) or (html == 'block' and not line.strip()):
                html = None
            prev = ''
            continue
        if not line.strip():
            in_quote, prev = False, ''
            continue
        if re.match(r'^ {0,3}<!--', line):
            if '-->' not in line:
                html = 'comment'
            prev = ''
            continue
        if not prev.strip() and re.match(r'^ {0,3}</?[A-Za-z!?]', line):
            html, prev = 'block', ''
            continue
        m = fence.match(line)
        if open_fence:
            # a closer is the same character, at least as long, with nothing after it but spaces
            if (m and m.group(1)[0] == open_fence[0] and len(m.group(1)) >= len(open_fence)
                    and not m.group(2).strip()):
                open_fence = None
            prev = ''
            continue
        # a backtick fence's info string has no backtick: ```code``` text is an inline span
        if m and not (m.group(1)[0] == '`' and '`' in m.group(2)):
            open_fence, in_quote, prev = m.group(1), False, ''
            continue
        if prev.strip() and not leaf.match(prev):
            if ((glued.match(line) and not in_quote)
                    or (heading.match(line) and not not_para.match(prev))):
                print(f'{f}:{n + 1}: {line}')
        if quote.match(line):
            in_quote = True
        elif heading.match(line) or leaf.match(line):
            in_quote = False
        prev = line
if os.environ.get('SCANNED_OUT'):
    with open(os.environ['SCANNED_OUT'], 'w') as out:
        out.write(f'{scanned}\n')
PY
}

echo "=== no rewrapped Markdown line opens a block mid-paragraph ==="

probe=$(mktemp -d)
[ -n "$probe" ] && [ -d "$probe" ] || { echo "  FAIL: mktemp -d failed, probe rows cannot run" >&2; exit 1; }
trap '[ -n "$probe" ] && trash "$probe" 2>/dev/null; true' EXIT
cat > "$probe/bad.md" <<'EOF'
when the writer never writes to the fd holding it (`true | grep -q 1`, `cat 2>
>(grep -q y)`: whether it writes there is the program's run-time behaviour

a redirect wrapped as
>/dev/null keeps going

the next note is
# not a heading the writer meant
```inline``` code span, not a fence, so the scan goes on
>(wrapped redirect after it)
```sh
```sh is not a closer: a closer has nothing after its backticks
# a comment inside the still-open block
```
text after the real closer
>&2 wrapped again
> a quote, then a blank line ends it

text after the quote
>(glued again)
EOF
cat > "$probe/good.md" <<'EOF'
---
# front matter comment
---
**Before:**
> a deliberate quote after its label
> its second line
>continued lazily inside the quote

# Heading after a blank line
text right before a list
- item
## Heading after a list item

```sh
echo text
>(grep -q y)
# shell comment
```
~~~~
```sh
# an inner fence and its closer stay code until the longer tilde fence closes
```
~~~~
> a quote
lazy line inside it
>(still the same quote)

intro

---
# Heading after a horizontal rule
[ref]: https://example.com
# Heading after a link reference definition
Setext heading
===
# Heading after a setext underline

<!--
a comment
# commented-out heading
>(commented-out redirect)
-->

<details>
# not rendered as a heading inside the HTML block
</details>
EOF
got=$(hits "$probe/bad.md" | sed 's/^[^:]*:\([0-9]*\):.*/\1/' | tr '\n' ' ')
[ "$got" = "2 5 8 10 16 20 " ] && ok "probe: a glued > after text and a heading after a paragraph are caught, also past an inline triple-backtick span, a closer with an info string and a quote ended by a blank line (lines 2 5 8 10 16 20)" \
  || bad "probe: bad.md gave lines [$got], want [2 5 8 10 16 20 ]"
out=$(hits "$probe/good.md")
[ -z "$out" ] && ok "probe: quotes after a label, lazy quote lines, headings after a blank, a list, a rule, a link ref or a setext underline, fences, HTML blocks, comments and front matter pass" \
  || bad "probe: good.md was flagged: $out"
files=()
while IFS= read -r -d '' f; do files+=("$ROOT/$f"); done < <(git -C "$ROOT" ls-files -z '*.md')
out=$(SCANNED_OUT="$probe/scanned" hits "${files[@]}")
scanned=$(cat "$probe/scanned" 2>/dev/null || echo 0)
[ -z "$out" ] && ok "no tracked Markdown line opens a block mid-paragraph" \
  || bad "a Markdown line opens a block mid-paragraph (rewrap so the marker stays mid-line, or add a blank line before a real heading): $(printf '%s' "$out" | sed "s|$ROOT/||" | tr '\n' ';')"

[ "$scanned" -ge 100 ] && ok "lint read $scanned of ${#files[@]} tracked Markdown files (not vacuous)" \
  || bad "lint read only $scanned of ${#files[@]} tracked Markdown files (missing in a sparse checkout, or not UTF-8)"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
