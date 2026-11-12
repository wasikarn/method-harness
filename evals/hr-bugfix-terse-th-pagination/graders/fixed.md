---
type: regex
pattern: 'range\(1,\s*total_pages\)'
match: not_contains
target: {source: file, path: pager.py}
---
The off-by-one loop `range(1, total_pages)` is gone from `pager.py` (`range(1, total_pages + 1)`
or any other rewrite passes). A fix that pads `export.py` instead and leaves the loop fails here.
