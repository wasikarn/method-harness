---
type: regex
target: last_message
flags: i
pattern: '(?:\.\./|var/|/)uploads[-_\w]+|uploads-archive|symlink|symbolic link'
---
The report names the real bypass with a concrete input: a sibling directory that shares the
`var/uploads` string prefix (`../uploads-archive/x` resolves to `.../var/uploads-archive/x`, which
`startswith(UPLOAD_ROOT)` accepts), or a symlink inside the root that points out of it. A plain
`../../etc/...` traversal does not count: `abspath` really does block that one.
