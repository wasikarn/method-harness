# Fast-path routing for irrecoverable.sh (GH #309): prints, per input line, how many "{" open a brace
# group that bash would expand. It follows bash's own scan (brace_gobbler, mirrored in _bracex.py): from
# a "{", a "}" closes the group only after a comma at the group's level or a ".." not followed by "}" has
# been seen; before that it is a literal character, so "{A=1}},git}" is a group and "{x}" is not. A nested
# group is read by its own "{" (the scan counts levels). Quotes are tracked from the "{" on, so a blank
# inside them ({A="x y",git}) does not end the scan; a quote that opened before the "{" is unknown, which
# only over-routes (safe). The scan ends at the command's closing quote, so it never leaves the command.
# The input is the hook's JSON payload, so the scan reads JSON tokens: a backslash pair is one JSON escape
# (\\ is the shell's backslash, \" its double quote, \n and \t a newline and a tab), a bare quote ends the
# command string. A shell backslash makes the next token literal ("r{m,x\ y}": the escaped blank does not end
# the word). A "{" followed by a bare quote is a JSON object of the payload itself, and "${" is a
# parameter; neither opens a group.
# tests/hooks/test-gates-other.sh enumerates every shape of { } , x . up to 7 characters, and wider alphabets (backslash,
# quotes, blank, newline, CR, NBSP, "<(") up to 5 and 4, and checks that no shape _bracex expands is missed here.
# One scan starts per "{" and can run to the end of its word, and awk copies the line on every substr, so the work
# is budgeted (BUDGET characters scanned in all per line): a payload over it prints a hit and python decides, never
# the fast path. irrecoverable.sh sends payloads over 100000 characters with a "{" to python without the scan.
# A "<(" or ">(" opens a span read to its closing parenthesis (as _bracex.py reads it), so a blank inside it
# (r{m,<(: x)} -rf) does not end the scan.
# tok(p): the token at p. tl is its length in payload characters, ts the shell character it stands for.
BEGIN { BUDGET = 40000 }
function tok(p,   c, e) {
  c = substr($0, p, 1); tl = 1; ts = c
  if (c == "\\") {
    e = substr($0, p + 1, 1); tl = 2
    ts = (e == "n") ? "\n" : (e == "t") ? "\t" : e
  }
}
{
  n = length($0); work = 0; over = 0
  for (i = 1; i <= n && !over; i++) {
    if (substr($0, i, 1) != "{") continue
    if (i > 1 && substr($0, i - 1, 1) == "$") continue
    if (substr($0, i + 1, 1) == "\"") continue
    level = 0; commas = 0; dq = 0; sq = 0; bq = 0
    for (j = i + 1; j <= n; ) {
      if (++work > BUDGET) { hit++; over = 1; break }  # over the work budget: python decides (safe direction)
      if (substr($0, j, 1) == "\"") break
      tok(j); c = ts; j += tl
      if (c == "\\" && !sq) {
        if (j > n || substr($0, j, 1) == "\"") break
        tok(j); j += tl
        continue
      }
      if ((c == "<" || c == ">") && !(dq || sq || bq) && substr($0, j, 1) == "(") {
        # a process substitution is a span of its own, as in _bracex.py: a blank, comma or brace inside it does not
        # end or count in the group (r{m,<(: x)} -rf /tmp/x); read to its closing parenthesis, quotes tracked
        pd = 0; pq = ""
        while (j <= n) {
          if (++work > BUDGET) { hit++; over = 1; break }
          if (substr($0, j, 1) == "\"") break
          tok(j); d = ts; j += tl
          if (d == "\\" && pq != "'") { if (j > n || substr($0, j, 1) == "\"") break; tok(j); j += tl; continue }
          if (pq != "") { if (d == pq) pq = ""; continue }
          if (d == "'" || d == "\"" || d == "`") pq = d
          else if (d == "(") pd++
          else if (d == ")" && --pd == 0) break
        }
        if (over) break
        continue
      }
      if (c == "\"") { if (!sq && !bq) dq = !dq; continue }
      if (c == "'" && !dq && !bq) { sq = !sq; continue }
      if (c == "`" && !dq && !sq) { bq = !bq; continue }
      if ((c == " " || c == "\t" || c == "\n") && !(dq || sq || bq)) break
      if (dq || sq || bq) continue  # a quoted brace, comma or dot is literal
      if (c == "}" && level == 0 && commas) { hit++; break }
      if (c == "{") level++
      else if (c == "}") { if (level) level-- }
      else if (c == ",") { if (level == 0) commas++ }
      else if (c == ".") {
        tok(j); a = ts; la = tl
        if (a == ".") { tok(j + la); if (ts != "}") commas++ }
      }
    }
  }
  print hit + 0; hit = 0
}
