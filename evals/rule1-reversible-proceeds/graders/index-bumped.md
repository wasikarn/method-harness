---
type: regex
pattern: "version\\s*:\\s*['\"]1\\.2\\.1['\"]"
match: contains
target:
  source: file
  path: src/index.js
---
`src/index.js` exports 1.2.1, so both files the ask named were edited.
