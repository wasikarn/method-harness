#!/usr/bin/env bash
# test-markdown-rewrap-block-lint.sh — a rewrapped Markdown paragraph must not start a line with a
# block marker. CommonMark lets `>` (block quote) and `#`..`######` (ATX heading) interrupt a
# paragraph, so a rewrap that puts one at a line start silently splits the paragraph. The real case
# (PR #686, docs/reference/repo-gotchas.md): rewrapping the code span `cat 2> >(grep -q y)` put
# `>(grep -q y)`:` at a line start, and pandoc rendered the rest of the paragraph as a block quote,
# pairing the later backticks wrongly. Flagged, outside fences and front matter:
# - a `>` or `>>` glued to the next character (`>(`, `>/dev/null`, `>>log`) on a line right after
#   text outside a block quote (lazy lines count as inside): a deliberate quote is `> text`, a
#   wrapped shell redirect is not;
# - an ATX heading right after a paragraph line (not a list item, table row, quote, heading, HTML).
# Neither counts after a horizontal rule, setext underline or link reference definition, and HTML
# blocks (by CommonMark's start and end rules) and comments are skipped. Fences follow CommonMark: a
# backtick opener's info string has no backtick, and a closer is bare. SCANNED_OUT, if set, names a
# file that gets the count of files read.
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
glued = re.compile(r'^ {0,3}>+[^ \t>]')
heading = re.compile(r'^ {0,3}#{1,6}(?:[ \t]|$)')
fence = re.compile(r'^ {0,3}(`{3,}|~{3,})(.*)$')
quote = re.compile(r'^ {0,3}>')
not_para = re.compile(r'^ {0,3}(?:>|#|[-+*][ \t]|\d+[.)][ \t]|\||<)')
# a line after which a marker opens no paragraph split: a horizontal rule, a setext underline, a
# link reference definition
leaf = re.compile(r'^ {0,3}(?:([-*_])(?:[ \t]*\1){2,}[ \t]*|=+[ \t]*|\[[^\]]+\]:[ \t].*)$')
html_tag = re.compile(r'^ {0,3}</?([A-Za-z][A-Za-z0-9-]*)(?=[\s/>]|$)')
html_alone = re.compile(r'^ {0,3}</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>\s*$')
RAW = {'pre', 'script', 'style', 'textarea'}
BLOCK = set('address article aside base basefont blockquote body caption center col colgroup dd '
            'details dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 '
            'h2 h3 h4 h5 h6 head header hr html iframe legend li link main menu menuitem nav '
            'noframes ol optgroup option p param search section summary table tbody td tfoot th '
            'thead title tr track ul'.split())
list_item = re.compile(r'^ {0,3}(?:[-+*]|\d+[.)])[ \t]')
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
    open_fence, html, in_quote, in_list, prev = None, None, False, False, ''
    for n in range(start, len(lines)):
        line = lines[n]
        m = fence.match(line)
        # code comes first: an HTML-looking line inside a fence is code, not an HTML block
        if open_fence:
            # a closer is the same character, at least as long, with nothing after it but spaces
            if (m and m.group(1)[0] == open_fence[0] and len(m.group(1)) >= len(open_fence)
                    and not m.group(2).strip()):
                open_fence = None
            prev = ''
            continue
        if html:
            # a comment ends at -->, a raw block (<pre>, <script>, ...) at its closing tag, any
            # other HTML block at a blank line
            if ((html == 'comment' and '-->' in line) or (html == 'block' and not line.strip())
                    or (html not in ('comment', 'block') and html in line.lower())):
                html = None
            prev = ''
            continue
        if not line.strip():
            in_quote, in_list, prev = False, False, ''
            continue
        # a backtick fence's info string has no backtick: ```code``` text is an inline span
        if m and not (m.group(1)[0] == '`' and '`' in m.group(2)):
            open_fence, in_quote, in_list, prev = m.group(1), False, False, ''
            continue
        if re.match(r'^ {0,3}<!--', line):
            if '-->' not in line:
                html = 'comment'
            prev = ''
            continue
        t = html_tag.match(line)
        if t:
            name = t.group(1).lower()
            if name in RAW:
                if f'</{name}>' not in line.lower():
                    html = f'</{name}>'
                prev = ''
                continue
            # CommonMark block tags open an HTML block even right after text; any other tag only
            # when it stands alone after a blank line (a paragraph may start with an inline tag)
            if name in BLOCK or (not prev.strip() and html_alone.match(line)):
                html, prev = 'block', ''
                continue
        if prev.strip() and not leaf.match(prev):
            # a heading right after a list item's lines ends the list; it splits no paragraph
            if ((glued.match(line) and not in_quote)
                    or (heading.match(line) and not in_list and not not_para.match(prev))):
                print(f'{f}:{n + 1}: {line}')
        if quote.match(line):
            in_quote = True
        elif heading.match(line) or leaf.match(line):
            in_quote = in_list = False
        if list_item.match(line):
            in_list = True
        prev = line
if os.environ.get('SCANNED_OUT'):
    with open(os.environ['SCANNED_OUT'], 'w') as out:
        out.write(f'{scanned}\n')
PY
}

echo "=== no rewrapped Markdown line opens a block mid-paragraph ==="

probe=$(mktemp -d)
[ -n "$probe" ] && [ -d "$probe" ] || { echo "  FAIL: mktemp -d failed, probe rows cannot run" >&2; exit 1; }
trap '[ -n "$probe" ] && python3 "$ROOT/tests/_lib/tmp_delete.py" "$probe"' EXIT
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

an append redirect wrapped as
>>file.log keeps going

<https://example.com> starts a paragraph, not an HTML block
>(wrapped after an autolink)

```html
<pre>
<!-- an unclosed comment inside a fence is code
```
text after an html fence
>(wrapped after the fence)
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

text right before a block tag
<div>
>raw glued inside the div
</div>

<pre>
x

# still raw inside pre until its closing tag
</pre>

```html
<div>
```
```
# a shell comment in a later fence stays code
>(grep -q y)
```

- a bullet that wraps
  onto a second line
# Heading after a multi-line list item
1. an item
   wrapped
## Heading after a wrapped numbered item
EOF
got=$(hits "$probe/bad.md" | sed 's/^[^:]*:\([0-9]*\):.*/\1/' | tr '\n' ' ')
[ "$got" = "2 5 8 10 16 20 23 26 33 " ] && ok "probe: a glued > after text and a heading after a paragraph are caught, also past an inline triple-backtick span, a closer with an info string and a quote ended by a blank line (lines 2 5 8 10 16 20 23 26 33)" \
  || bad "probe: bad.md gave lines [$got], want [2 5 8 10 16 20 23 26 33 ]"
out=$(hits "$probe/good.md")
[ -z "$out" ] && ok "probe: quotes after a label, lazy quote lines, headings after a blank, a list item (one line or wrapped), a rule, a link ref or a setext underline, fences (HTML-looking lines inside are code), HTML blocks, comments and front matter pass" \
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
