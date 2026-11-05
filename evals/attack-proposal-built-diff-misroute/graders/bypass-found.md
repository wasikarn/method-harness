---
type: regex
target: last_message
flags: i
pattern: '(?<![:\w/])/[/\\]+[\w-]+\.[a-z]|protocol[- ]relative|scheme[- ]relative|network[- ]path|(?:two|double|leading) (?:leading )?slashes'
---
The review finds the real hole in the committed fix: `startswith("/")` also accepts a
protocol-relative URL such as `//evil.example/phish` (or `/\evil.example`, which browsers treat
the same way), so the open redirect is still open.
