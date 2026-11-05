---
type: regex
target: last_message
flags: i
pattern: '(?:\.\./|var/|/)uploads(?:[-_\w]|\.\w)+|uploads-archive'
---
The report names the real bypass with a concrete input: a sibling directory that shares the
`var/uploads` string prefix (`../uploads-archive/x` or `../uploads.bak/x` resolves outside the root,
and `startswith(UPLOAD_ROOT)` accepts it). A plain `../../etc/...` traversal does not count:
`abspath` really does block that one. The symlink break is judged by `criteria.md`, since a
dismissed-break line can mention symlinks too.
