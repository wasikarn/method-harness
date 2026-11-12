"""Executable ground truth for fh-upload-limit-layers (not run by `claude plugin eval`; no grader
type executes code). Usage: python3 check.py <workspace>. Exit 0 when a 20 MiB upload gets through
every layer: nginx's client_max_body_size, the browser widget and the WSGI app; and 20 MiB + 1 byte
is still refused by the app."""
import io, re, subprocess, sys, tempfile

ws = sys.argv[1]
sys.path.insert(0, ws)
from app import config, wsgi  # noqa: E402

MB20 = 20 * 1024 * 1024
UNITS = {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}
conf = open(f"{ws}/deploy/nginx/site.conf").read()
sizes = [int(n) * UNITS[u.lower()] for n, u in re.findall(r"client_max_body_size\s+(\d+)([kKmMgG]?)\s*;", conf)]
assert sizes and MB20 <= max(sizes), f"nginx client_max_body_size {sizes}"

js = subprocess.run(["node", "-e", "const m=require(process.argv[1]);process.stdout.write(JSON.stringify([m.tooBig({size:%d}),m.MAX_UPLOAD_BYTES]))" % MB20,
                     f"{ws}/static/js/upload.js"], capture_output=True, text=True, check=True)
too_big, js_max = __import__("json").loads(js.stdout)
assert not too_big, f"upload widget refuses 20 MiB (its max {js_max})"


def post(n):
    out = {}
    env = {"PATH_INFO": "/api/upload", "REQUEST_METHOD": "POST", "CONTENT_TYPE": "application/pdf",
           "CONTENT_LENGTH": str(n), "wsgi.input": io.BytesIO(b"x" * n)}
    b"".join(wsgi.application(env, lambda s, h: out.setdefault("s", s)))
    return int(out["s"].split()[0])


with tempfile.TemporaryDirectory() as d:
    config.STORAGE_DIR = d
    assert post(MB20) == 201, "app refuses 20 MiB"
    assert post(MB20 + 1) == 413, "app accepts over 20 MiB"
print("ok: 20 MiB passes nginx, widget and app")
