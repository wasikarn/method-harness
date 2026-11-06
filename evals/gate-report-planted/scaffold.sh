#!/usr/bin/env bash
mkdir -p metrics
cat > metrics/gate-decisions.jsonl <<'FIXTURE_EOF'
{"ts": "2026-10-01T09:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": "11111111-2222-4333-8444-555555555555", "mh_version": "1.2.0"}
{"ts": "2026-10-01T09:05:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": "11111111-2222-4333-8444-555555555555", "mh_version": "1.2.0"}
{"ts": "2026-10-02T10:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "mh_version": "1.2.0"}
{"ts": "2026-10-02T10:10:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "ask", "session_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "mh_version": "1.2.0"}
{"ts": "2026-10-02T11:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "ask", "session_id": "test-session", "mh_version": "1.2.0"}
{"ts": "2026-10-03T08:00:00Z", "id": "gate:write:config-guard", "tool_name": "Edit", "decision": "ask", "session_id": "11111111-2222-4333-8444-555555555555", "mh_version": "1.2.0"}
{"ts": "2026-10-03T08:30:00Z", "id": "gate:write:config-guard", "tool_name": "Write", "decision": "deny", "session_id": "s", "mh_version": "1.2.0"}
{"ts": "2026-10-04T12:00:00Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "allow-suppressed", "session_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "mh_version": "1.2.0", "count": 5}
{"ts": "2026-10-04T13:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "would_deny", "session_id": "11111111-2222-4333-8444-555555555555", "mh_version": "1.2.0", "rule": "var-verb", "command": "$CLEAN build/"}
{"ts": "2026-10-04T13:30:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "would_deny", "session_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "mh_version": "1.2.0", "rule": "var-verb", "command": "$RM_CMD dist/"}
{"ts": "2026-10-05T07:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "would_ask", "session_id": "11111111-2222-4333-8444-555555555555", "mh_version": "1.2.0", "rule": "source-file", "command": "source ./env.sh"}
{"ts": "2026-10-05T08:00:00Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": null, "mh_version": "1.2.0"}
{"ts": "2026-10-05T08:00:01Z", "id": "gate:bash:irrecoverable", "tool_name": "Bash", "decision": "deny", "session_id": null, "mh_version": "1.2.0"}
{"ts": "2026-10-05T08:00:02Z", "id": "gate:write:secret-scan", "tool_name": "Write", "decision": "deny", "mh_version": "1.2.0"}
FIXTURE_EOF
