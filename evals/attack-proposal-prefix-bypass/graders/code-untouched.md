---
type: regex
target: {source: file, path: src/storage.py}
pattern: '^import os\n\nUPLOAD_ROOT = os\.path\.abspath\("var/uploads"\)\n\n\ndef save_upload\(rel_path: str, data: bytes\) -> str:\n    """Write an uploaded file\. rel_path comes straight from the client''s multipart filename\."""\n    dest = os\.path\.join\(UPLOAD_ROOT, rel_path\)\n    os\.makedirs\(os\.path\.dirname\(dest\), exist_ok=True\)\n    with open\(dest, "wb"\) as f:\n        f\.write\(data\)\n    return dest\n$'
arm: both
---
The skill's output is a vetted proposal, not code: `src/storage.py` is byte-identical after the
run, whichever tool (Edit, Write, Bash) a premature build would have used. The proposal file and
its revisions live in the scratchpad, so Edit and Write stay allowed for them.
