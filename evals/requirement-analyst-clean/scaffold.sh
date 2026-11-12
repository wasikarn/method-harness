#!/usr/bin/env bash
cat > ticket.md <<'FIXTURE_EOF'
# OPS-77: Health endpoint

Add `GET /health` to the API service. It returns HTTP 200 with the JSON body `{"status":"ok"}`.
No authentication. No database or downstream call; it only proves the process is serving requests.

Acceptance criteria:
- `curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health` prints `200`.
- `curl -s http://localhost:8080/health` prints exactly `{"status":"ok"}`.
- The endpoint is excluded from the auth middleware (existing allowlist in `api/middleware/auth.py`).

Out of scope: readiness checks, dependency probes.
FIXTURE_EOF
