---
type: regex
target: { source: file, path: deploy/nginx/site.conf }
pattern: 'client_max_body_size\s+(?:(?:[2-9]\d|[1-9]\d{2,})[mM]|(?:204[89]\d|20[5-9]\d\d|2[1-9]\d{3}|[3-9]\d{4}|[1-9]\d{5,})[kK]|[1-9]\d*[gG]|(?:2[1-9]\d{6}|[3-9]\d{7}|[1-9]\d{8,}))\s*;'
---
Production traffic reaches the app through nginx (`docs/operations.md`), and
`deploy/nginx/site.conf` caps request bodies at `client_max_body_size 6m;`. Until that is at least
20 MB, a 15 MB upload gets nginx's 413 before the app's own limit is ever consulted, so raising
`MAX_UPLOAD_MB` alone changes nothing for users. Passes when the file sets the cap to 20m or more
(20480k, 1g, or 21,000,000 bytes and up); fails on the untouched 6m, on `0` (no limit at all) and
on byte counts under 20 MB such as `10000000`.
`check.py` beside this case is the executable form of this and the next grader.
