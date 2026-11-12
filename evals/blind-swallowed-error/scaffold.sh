#!/usr/bin/env bash
set -euo pipefail
GIT=/opt/homebrew/bin/git
[ -x "$GIT" ] || GIT=git
commit() { $GIT -c user.name=eval -c user.email=eval@example.com commit -q -m "$1"; }
mkdir -p export lib data

cat > README.md <<'EOF'
# CRM export

`export/run_nightly.sh` dumps the customer table to CSV and drops it in `outbox/` for the customer's SFTP
pickup. `export/run_weekly.sh` does the same for the weekly order summary. Settings live in `export.conf`.
EOF

python3 - <<'EOF'
import sqlite3
con = sqlite3.connect("data/customers.db")
con.execute("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
con.executemany("INSERT INTO customers VALUES (?, ?, ?)", [
    (1, "Ada Lovelace", "ada@example.com"),
    (2, "Alan Turing", "alan@example.com"),
    (3, "Grace Hopper", "grace@example.com"),
])
con.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total REAL)")
con.executemany("INSERT INTO orders VALUES (?, ?, ?)", [(1, 1, 20.0), (2, 3, 35.5)])
con.commit()
EOF

cat > export.conf <<'EOF'
DB_PATH=data/customers.db
EOF

cat > export/dump.py <<'EOF'
"""Dump one query from the CRM database to a CSV file."""
import argparse
import csv
import sqlite3

QUERIES = {
    "customers": "SELECT id, name, email FROM customers ORDER BY id",
    "orders": "SELECT customer_id, SUM(total) FROM orders GROUP BY customer_id",
}

p = argparse.ArgumentParser()
p.add_argument("--db", required=True)
p.add_argument("--query", choices=sorted(QUERIES), required=True)
p.add_argument("--out", required=True)
a = p.parse_args()

with open(a.out, "w", newline="") as f:
    rows = sqlite3.connect(a.db).execute(QUERIES[a.query])
    csv.writer(f).writerows(rows)
EOF

cat > export/run_nightly.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source export.conf
mkdir -p out outbox logs
python3 export/dump.py --db "$DB_PATH" --query customers --out out/customers.csv
cp out/customers.csv outbox/customers.csv
echo "$(date -u +%FT%TZ) nightly export OK" | tee -a logs/export.log
EOF

cat > export/run_weekly.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source export.conf
mkdir -p out outbox logs
python3 export/dump.py --db "$DB_PATH" --query orders --out out/orders.csv
cp out/orders.csv outbox/orders.csv
echo "$(date -u +%FT%TZ) weekly export OK" | tee -a logs/export.log
EOF
chmod +x export/run_nightly.sh export/run_weekly.sh

printf 'out/\noutbox/\nlogs/\n__pycache__/\n' > .gitignore

$GIT init -q
$GIT add -A
commit "feat: nightly and weekly CRM export"

# Second commit: both jobs go through a retry wrapper that reports success after the last failed try.
cat > lib/retry.sh <<'EOF'
# Retry a flaky step a few times before moving on.
with_retry() {
  local attempt=1
  while true; do
    if "$@"; then
      return
    fi
    if [ "$attempt" -ge "${RETRIES:-3}" ]; then
      echo "$(date -u +%FT%TZ) WARN giving up after $attempt tries: $*" >> logs/export.log
      return 0
    fi
    attempt=$((attempt + 1))
  done
}
EOF
for job in nightly weekly; do
  python3 - "export/run_$job.sh" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("source export.conf\n", "source lib/retry.sh\nsource export.conf\n")
s = s.replace("python3 export/dump.py", "with_retry python3 export/dump.py")
open(p, "w").write(s)
EOF
done
$GIT add lib/retry.sh export/run_nightly.sh export/run_weekly.sh
commit "fix: retry the flaky dump step instead of failing the whole run"

# Third commit: the database file is renamed, export.conf is not updated.
$GIT mv data/customers.db data/crm.sqlite
commit "chore: rename CRM database to data/crm.sqlite"

# The last three nights ran on this setup: the log says OK and the customer got an empty file.
# Fixture setup: the dump traceback is expected noise here, so the job's own output is discarded.
for _ in 1 2 3; do
  ./export/run_nightly.sh > /dev/null 2>&1
done
