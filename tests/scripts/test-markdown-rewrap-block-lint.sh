#!/usr/bin/env bash
# test-markdown-rewrap-block-lint.sh — a rewrapped Markdown paragraph must not start a line with a
# block marker. CommonMark lets `>` (block quote) and `#`..`######` (ATX heading) interrupt a
# paragraph, so a rewrap that puts one at a line start silently splits the paragraph. The real case
# (PR #686, docs/reference/repo-gotchas.md): rewrapping the code span `cat 2> >(grep -q y)` put
# `>(grep -q y)`:` at a line start, and pandoc rendered the rest of the paragraph as a block quote,
# pairing the later backticks wrongly. Flagged, outside fences and front matter:
# - a `>` glued to the next character (`>(`, `>/dev/null`, `>&2`) on a line right after a non-blank,
#   non-quote line: a deliberate quote is `> text`, a wrapped shell redirect is not;
# - an ATX heading right after a paragraph line (not a list item, table row, quote, heading, HTML).
# Fences follow CommonMark: a backtick opener's info string has no backtick, and a closer is bare.
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
import re, sys
glued = re.compile(r'^ {0,3}>[^ \t>]')
heading = re.compile(r'^ {0,3}#{1,6}(?:[ \t]|$)')
fence = re.compile(r'^ {0,3}(`{3,}|~{3,})(.*)$')
quote = re.compile(r'^ {0,3}>')
not_para = re.compile(r'^ {0,3}(?:>|#|[-+*][ \t]|\d+[.)][ \t]|\||<)')
for f in sys.argv[1:]:
    try:
        lines = open(f, encoding='utf-8').read().split('\n')
    except (OSError, UnicodeDecodeError):
        continue
    start = 0
    if lines and lines[0].strip() == '---':
        for j in range(1, len(lines)):
            if lines[j].strip() in ('---', '...'):
                start = j + 1
                break
    open_fence, prev = None, ''
    for n in range(start, len(lines)):
        line = lines[n]
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
            open_fence, prev = m.group(1), ''
            continue
        if prev.strip() and not quote.match(prev):
            if glued.match(line) or (heading.match(line) and not not_para.match(prev)):
                print(f'{f}:{n + 1}: {line}')
        prev = line
PY
}

echo "=== no rewrapped Markdown line opens a block mid-paragraph ==="

probe=$(mktemp -d)
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
EOF
got=$(hits "$probe/bad.md" | sed 's/^[^:]*:\([0-9]*\):.*/\1/' | tr '\n' ' ')
[ "$got" = "2 4 6 8 14 " ] && ok "probe: a glued > after text and a heading after a paragraph are caught, also past an inline triple-backtick span and a closer with an info string (lines 2 4 6 8 14)" \
  || bad "probe: bad.md gave lines [$got], want [2 4 6 8 14 ]"
out=$(hits "$probe/good.md")
[ -z "$out" ] && ok "probe: quotes after a label, quote continuations, headings after a blank or a list, fences and front matter pass" \
  || bad "probe: good.md was flagged: $out"
[ -n "$probe" ] && trash "$probe"

files=()
while IFS= read -r -d '' f; do files+=("$ROOT/$f"); done < <(git -C "$ROOT" ls-files -z '*.md')
out=$(hits "${files[@]}")
[ -z "$out" ] && ok "no tracked Markdown line opens a block mid-paragraph" \
  || bad "a Markdown line opens a block mid-paragraph (rewrap so the marker stays mid-line, or add a blank line before a real heading): $(printf '%s' "$out" | sed "s|$ROOT/||" | tr '\n' ';')"

[ "${#files[@]}" -ge 100 ] && ok "lint saw ${#files[@]} tracked Markdown files (not vacuous)" \
  || bad "lint saw only ${#files[@]} tracked Markdown files"

echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
