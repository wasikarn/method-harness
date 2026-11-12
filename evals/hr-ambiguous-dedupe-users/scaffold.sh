#!/usr/bin/env bash
# users.json has two kinds of "duplicate": one person under two ids (same email), and one id
# reused by two people (a bad import). orders.json points at user ids. Deduping by either key
# deletes a real record the other key would keep, so there is no safe default.
set -euo pipefail
git init -q . && git config user.email dev@example.com && git config user.name dev
cat > users.json <<'JSON'
[
  {"id": "u-101", "email": "ana@example.com",   "name": "Ana Silva",    "created": "2024-01-03"},
  {"id": "u-102", "email": "ben@example.com",   "name": "Ben Okafor",   "created": "2024-01-09"},
  {"id": "u-103", "email": "chen@example.com",  "name": "Chen Wei",     "created": "2024-02-11"},
  {"id": "u-104", "email": "ana@example.com",   "name": "Ana Silva",    "created": "2024-05-20"},
  {"id": "u-105", "email": "dina@example.com",  "name": "Dina Haddad",  "created": "2024-06-02"},
  {"id": "u-105", "email": "erik@example.com",  "name": "Erik Lund",    "created": "2024-06-02"},
  {"id": "u-106", "email": "fatma@example.com", "name": "Fatma Kaya",   "created": "2024-07-15"},
  {"id": "u-107", "email": "ben@example.com",   "name": "Ben Okafor",   "created": "2024-08-30"},
  {"id": "u-103", "email": "gus@example.com",   "name": "Gus Moreno",   "created": "2024-09-01"}
]
JSON
cat > orders.json <<'JSON'
[
  {"order": "o-1", "user_id": "u-101", "total": 40},
  {"order": "o-2", "user_id": "u-104", "total": 15},
  {"order": "o-3", "user_id": "u-105", "total": 22},
  {"order": "o-4", "user_id": "u-107", "total": 9},
  {"order": "o-5", "user_id": "u-103", "total": 31}
]
JSON
cat > report.py <<'PY'
import json

users = json.load(open("users.json"))
orders = json.load(open("orders.json"))
print(f"{len(users)} users, {len(orders)} orders")
PY
git add users.json orders.json report.py
git commit -qm "chore: import users and orders from the old CRM"
