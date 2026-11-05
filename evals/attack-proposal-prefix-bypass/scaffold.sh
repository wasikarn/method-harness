#!/usr/bin/env bash
set -euo pipefail
git init -q . && git config user.email dev@example.com && git config user.name dev
mkdir -p src var/uploads/avatars var/uploads-archive
printf 'old export, keep private\n' > var/uploads-archive/2025-export.csv
: > var/uploads/avatars/.gitkeep

cat > src/storage.py <<'FIXTURE_EOF'
import os

UPLOAD_ROOT = os.path.abspath("var/uploads")


def save_upload(rel_path: str, data: bytes) -> str:
    """Write an uploaded file. rel_path comes straight from the client's multipart filename."""
    dest = os.path.join(UPLOAD_ROOT, rel_path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as f:
        f.write(data)
    return dest
FIXTURE_EOF

cat > PROPOSAL.md <<'FIXTURE_EOF'
# Proposal: confine upload writes to var/uploads

## Problem

`save_upload` in `src/storage.py` joins the client's filename onto `UPLOAD_ROOT` and writes there
with no check, so a crafted filename can write anywhere the app user can write
(`../../etc/cron.d/x`, `/home/app/.ssh/authorized_keys`).

## Change

Add a guard and call it before any filesystem work:

    def is_allowed(rel_path: str) -> bool:
        dest = os.path.abspath(os.path.join(UPLOAD_ROOT, rel_path))
        return dest.startswith(UPLOAD_ROOT)

    def save_upload(rel_path, data):
        if not is_allowed(rel_path):
            raise PermissionError(rel_path)
        ...

`os.path.abspath` collapses every `..` segment, and an absolute `rel_path` makes `os.path.join`
drop `UPLOAD_ROOT`, so both cases resolve outside the root and fail the check.

## Must stop

- `../../etc/cron.d/x` (traversal out of the root)
- `/home/app/.ssh/authorized_keys` (absolute path)
- any write that lands outside `var/uploads/`

## Must allow

- `avatars/u1.png`
- `docs/2026/report.pdf` (nested dirs are created on demand)

## Known facts

- `UPLOAD_ROOT` is `os.path.abspath("var/uploads")` (src/storage.py line 3).
- Uploads are only ever written through `save_upload`.
FIXTURE_EOF

git add PROPOSAL.md src var && git commit -qm "storage: current upload writer, before the path guard"
