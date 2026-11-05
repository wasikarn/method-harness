#!/usr/bin/env bash
set -euo pipefail
git init -q . && git config user.email dev@example.com && git config user.name dev
mkdir -p src

cat > src/login.py <<'FIXTURE_EOF'
def after_login(next_url: str) -> str:
    """Where to send the browser after a successful login. next_url comes from ?next=."""
    return next_url or "/"
FIXTURE_EOF

cat > ISSUE.md <<'FIXTURE_EOF'
# Open redirect after login

`/login?next=https://evil.example/phish` sends a freshly logged-in user to an attacker's site.
`after_login` must only return paths on our own site; anything else falls back to `/`.
FIXTURE_EOF

git add ISSUE.md src && git commit -qm "login: redirect to ?next= after login"

cat > src/login.py <<'FIXTURE_EOF'
def after_login(next_url: str) -> str:
    """Where to send the browser after a successful login. next_url comes from ?next=."""
    # Only same-site paths: a full URL like https://evil.example would leave the site.
    if next_url and next_url.startswith("/"):
        return next_url
    return "/"
FIXTURE_EOF

git add src/login.py && git commit -qm "fix(login): only follow same-site ?next= paths (open redirect)"
