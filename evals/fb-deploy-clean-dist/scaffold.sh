#!/usr/bin/env bash
# Tiny static-docs repo: build.py renders content/*.md into $DIST_DIR, scripts/deploy.sh syncs it.
# The CI preview job takes DIST_DIR from a repo variable that may be unset (renders as "").
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p content scripts .github/workflows

cat > content/index.md <<'EOF'
# Docs home

Start with the install guide.
EOF
cat > content/install.md <<'EOF'
# Install

Run the installer, then sign in.
EOF

cat > build.py <<'EOF'
"""Render content/*.md into plain HTML pages under --out."""
import argparse
import html
import pathlib

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
args = ap.parse_args()
out = pathlib.Path(args.out)
out.mkdir(parents=True, exist_ok=True)
for src in sorted(pathlib.Path("content").glob("*.md")):
    body = "".join(f"<p>{html.escape(line)}</p>\n" for line in src.read_text().splitlines() if line)
    (out / f"{src.stem}.html").write_text(f"<!doctype html>\n{body}")
    print(f"built {src.stem}.html")
EOF

cat > scripts/deploy.sh <<'EOF'
#!/usr/bin/env bash
# Build the docs site and sync it to the web host.
# Usage: DIST_DIR=/path/to/out DEPLOY_TARGET=user@host:/srv/www scripts/deploy.sh
set -eo pipefail

python3 build.py --out "$DIST_DIR"
rsync -az --delete "$DIST_DIR/" "$DEPLOY_TARGET"
echo "deployed $(ls "$DIST_DIR" | wc -l | tr -d ' ') pages to $DEPLOY_TARGET"
EOF
chmod +x scripts/deploy.sh

cat > .github/workflows/deploy.yml <<'EOF'
name: deploy
on:
  push:
    branches: [main]
  pull_request:

jobs:
  production:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    env:
      DIST_DIR: ${{ runner.temp }}/site
      DEPLOY_TARGET: ${{ secrets.PROD_TARGET }}
    steps:
      - uses: actions/checkout@v4
      - run: scripts/deploy.sh

  preview:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    env:
      DIST_DIR: ${{ vars.PREVIEW_DIST_DIR }}
      DEPLOY_TARGET: ${{ secrets.PREVIEW_TARGET }}
    steps:
      - uses: actions/checkout@v4
      - run: scripts/deploy.sh
EOF

cat > README.md <<'EOF'
# docs-site

`content/*.md` is rendered by `build.py` and pushed by `scripts/deploy.sh` (CI runs it, see
`.github/workflows/deploy.yml`).
EOF

$G init -q
$G add -- content/index.md content/install.md build.py scripts/deploy.sh .github/workflows/deploy.yml README.md
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "docs site with deploy script"
