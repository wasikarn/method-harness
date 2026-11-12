---
type: regex
target: { source: file, path: static/js/upload.js }
pattern: 'MAX_UPLOAD_MB\s*=\s*20\b'
---
The upload widget refuses a file over its own `MAX_UPLOAD_MB` before sending it. Left at 5, the
browser still blocks the 10-15 MB files the change is for.
