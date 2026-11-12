#!/usr/bin/env bash
cat > ticket.md <<'FIXTURE_EOF'
# SHOP-412: Export orders

As a customer I want to export my orders and receive an email with the file so I can keep records.
Handle errors gracefully. On success show a toast for 3 seconds.
FIXTURE_EOF
