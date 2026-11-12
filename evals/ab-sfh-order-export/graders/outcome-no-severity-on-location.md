---
type: regex
pattern: '(?:\b(?:critical|high|medium)\b\**\s*[:|)\]—–-][^\n]{0,80}\b\w+\.go:\d+|\b\w+\.go:\d+[^\n]{0,80}(?:\bseverity\W{0,4}|\|\s*\**)(?:critical|high|medium)\b)'
flags: i
match: not_contains
target: last_message
---
Fails if the final reply puts a critical, high or medium severity label on the same line as a Go file:line location (label then location, or location then a severity label or table cell). Passes when no such severity-tagged location appears, e.g. a reply that says there are no critical or high issues.
