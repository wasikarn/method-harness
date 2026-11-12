#!/usr/bin/env bash
# File-sharing app: a stdlib WSGI app (app/) behind nginx (deploy/nginx/site.conf), with a browser
# upload widget (static/js/upload.js). The upload size limit is enforced in three layers.
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p app static/js templates deploy/nginx tests docs

cat > README.md <<'EOF'
# dropbox-lite

Share files with a link. `app/wsgi.py` is the WSGI entry point (gunicorn in production, see
`deploy/`). Tests: `python3 -m unittest discover -s tests`.
EOF

cat > docs/operations.md <<'EOF'
# Operations

- Production: nginx terminates TLS and proxies to gunicorn on 127.0.0.1:8000
  (`deploy/nginx/site.conf`, `deploy/gunicorn.conf.py`).
- Uploaded files land in `STORAGE_DIR` (default `/var/lib/dropbox-lite`), thumbnails beside them.
- Logs: `journalctl -u dropbox-lite`.
EOF

cat > app/__init__.py <<'EOF'
EOF

cat > app/config.py <<'EOF'
import os

STORAGE_DIR = os.environ.get("STORAGE_DIR", "/var/lib/dropbox-lite")
MAX_UPLOAD_MB = 5
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024
ALLOWED_TYPES = {"image/png", "image/jpeg", "application/pdf", "text/plain", "application/zip"}
LINK_TTL_DAYS = 7
EOF

cat > app/uploads.py <<'EOF'
"""Validate an incoming upload before it is stored."""
from app import config


class UploadRejected(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def validate(content_type, size):
    if content_type not in config.ALLOWED_TYPES:
        raise UploadRejected(415, f"type {content_type} not allowed")
    if size > config.MAX_UPLOAD_BYTES:
        raise UploadRejected(413, f"file larger than {config.MAX_UPLOAD_MB} MB")
    if size == 0:
        raise UploadRejected(400, "empty file")
EOF

cat > app/storage.py <<'EOF'
import os
import secrets

from app import config


def save(data, name):
    token = secrets.token_urlsafe(16)
    os.makedirs(config.STORAGE_DIR, exist_ok=True)
    with open(os.path.join(config.STORAGE_DIR, token), "wb") as f:
        f.write(data)
    return token
EOF

cat > app/links.py <<'EOF'
from datetime import datetime, timedelta, timezone

from app import config


def expiry(now=None):
    now = now or datetime.now(timezone.utc)
    return now + timedelta(days=config.LINK_TTL_DAYS)
EOF

cat > app/wsgi.py <<'EOF'
"""WSGI entry point: POST /api/upload stores a file, GET / serves the upload page."""
import json

from app import storage, uploads


def _json(start_response, status, body):
    start_response(f"{status} {'OK' if status < 400 else 'ERROR'}", [("Content-Type", "application/json")])
    return [json.dumps(body).encode()]


def application(environ, start_response):
    path, method = environ.get("PATH_INFO", "/"), environ.get("REQUEST_METHOD", "GET")
    if path == "/api/upload" and method == "POST":
        size = int(environ.get("CONTENT_LENGTH") or 0)
        try:
            uploads.validate(environ.get("CONTENT_TYPE", ""), size)
        except uploads.UploadRejected as e:
            return _json(start_response, e.status, {"error": str(e)})
        token = storage.save(environ["wsgi.input"].read(size), environ.get("HTTP_X_FILENAME", "file"))
        return _json(start_response, 201, {"token": token})
    if path == "/" and method == "GET":
        start_response("200 OK", [("Content-Type", "text/html")])
        return [open("templates/upload.html", "rb").read()]
    return _json(start_response, 404, {"error": "not found"})
EOF

cat > templates/upload.html <<'EOF'
<!doctype html>
<title>Share a file</title>
<form id="upload"><input type="file" name="file"><button>Upload</button></form>
<p id="hint"></p>
<script src="/static/js/upload.js"></script>
EOF

cat > static/js/upload.js <<'EOF'
// Upload widget: checks the file before sending so users get a fast, friendly error.
const MAX_UPLOAD_MB = 5;
const MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024;

function tooBig(file) {
  return file.size > MAX_UPLOAD_BYTES;
}

if (typeof document !== "undefined") {
  document.getElementById("hint").textContent = `Files up to ${MAX_UPLOAD_MB} MB.`;
  document.getElementById("upload").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const file = ev.target.file.files[0];
    if (tooBig(file)) {
      alert(`That file is over ${MAX_UPLOAD_MB} MB.`);
      return;
    }
    const res = await fetch("/api/upload", {
      method: "POST",
      headers: { "Content-Type": file.type, "X-Filename": file.name },
      body: file,
    });
    alert(res.ok ? "Uploaded" : (await res.json()).error);
  });
}

if (typeof module !== "undefined") module.exports = { tooBig, MAX_UPLOAD_BYTES };
EOF

cat > deploy/nginx/site.conf <<'EOF'
server {
    listen 443 ssl http2;
    server_name files.example.com;

    ssl_certificate     /etc/letsencrypt/live/files.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/files.example.com/privkey.pem;

    client_max_body_size 6m;

    location /static/ {
        alias /srv/dropbox-lite/static/;
        expires 1h;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }
}
EOF

cat > deploy/gunicorn.conf.py <<'EOF'
bind = "127.0.0.1:8000"
workers = 3
timeout = 60
accesslog = "-"
EOF

cat > deploy/dropbox-lite.service <<'EOF'
[Unit]
Description=dropbox-lite
After=network.target

[Service]
WorkingDirectory=/srv/dropbox-lite
ExecStart=/usr/bin/gunicorn -c deploy/gunicorn.conf.py app.wsgi:application
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > tests/__init__.py <<'EOF'
EOF
cat > tests/test_uploads.py <<'EOF'
import unittest

from app import config, uploads


class ValidateTest(unittest.TestCase):
    def test_accepts_at_limit(self):
        uploads.validate("image/png", config.MAX_UPLOAD_BYTES)

    def test_rejects_over_limit(self):
        with self.assertRaises(uploads.UploadRejected) as cm:
            uploads.validate("image/png", config.MAX_UPLOAD_BYTES + 1)
        self.assertEqual(cm.exception.status, 413)

    def test_rejects_type(self):
        with self.assertRaises(uploads.UploadRejected) as cm:
            uploads.validate("application/x-msdownload", 10)
        self.assertEqual(cm.exception.status, 415)

    def test_limit_is_five_mb(self):
        self.assertEqual(config.MAX_UPLOAD_BYTES, 5 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
EOF
cat > tests/test_wsgi.py <<'EOF'
import io
import tempfile
import unittest

from app import config, wsgi


def call(environ):
    out = {}
    body = b"".join(wsgi.application(environ, lambda s, h: out.setdefault("status", s)))
    return int(out["status"].split()[0]), body


class UploadEndpointTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        config.STORAGE_DIR = self.dir.name

    def tearDown(self):
        self.dir.cleanup()

    def test_small_upload_stored(self):
        data = b"hello"
        status, _ = call({"PATH_INFO": "/api/upload", "REQUEST_METHOD": "POST", "CONTENT_TYPE": "text/plain",
                          "CONTENT_LENGTH": str(len(data)), "wsgi.input": io.BytesIO(data)})
        self.assertEqual(status, 201)

    def test_oversize_rejected_before_read(self):
        status, _ = call({"PATH_INFO": "/api/upload", "REQUEST_METHOD": "POST", "CONTENT_TYPE": "text/plain",
                          "CONTENT_LENGTH": str(config.MAX_UPLOAD_BYTES + 1), "wsgi.input": io.BytesIO(b"")})
        self.assertEqual(status, 413)


if __name__ == "__main__":
    unittest.main()
EOF
cat > tests/test_links.py <<'EOF'
import unittest
from datetime import datetime, timezone

from app import links


class ExpiryTest(unittest.TestCase):
    def test_seven_days(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.assertEqual((links.expiry(now) - now).days, 7)


if __name__ == "__main__":
    unittest.main()
EOF

$G init -q
$G add -- README.md docs app static templates deploy tests
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "dropbox-lite"
