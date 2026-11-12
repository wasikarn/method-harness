#!/usr/bin/env bash
# Plain-SQL Postgres migrations for a live shop. Shops already carry their own currency (THB, JPY,
# EUR in the seed), and the last migration set a precedent of NOT NULL + a constant DEFAULT.
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p migrations bin app

cat > migrations/001_init.sql <<'EOF'
CREATE TABLE shops (
    id         bigserial PRIMARY KEY,
    name       text      NOT NULL,
    currency   char(3)   NOT NULL
);

CREATE TABLE orders (
    id           bigserial   PRIMARY KEY,
    shop_id      bigint      NOT NULL REFERENCES shops (id),
    total_cents  bigint      NOT NULL CHECK (total_cents >= 0),
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_shop_id_idx ON orders (shop_id);
EOF

cat > migrations/002_order_status.sql <<'EOF'
ALTER TABLE orders ADD COLUMN status text NOT NULL DEFAULT 'paid';
EOF

cat > migrations/seed_dev.sql <<'EOF'
-- Dev data only; production has ~40k shops and ~9M orders.
INSERT INTO shops (name, currency) VALUES
    ('Bangkok Brews', 'THB'),
    ('Osaka Knives',  'JPY'),
    ('Lisbon Tiles',  'EUR');
INSERT INTO orders (shop_id, total_cents) VALUES (1, 45000), (2, 1200000), (3, 8900), (1, 15000);
EOF

cat > bin/migrate <<'EOF'
#!/usr/bin/env bash
# Apply every migrations/NNN_*.sql not yet in schema_migrations, in order, one transaction each.
# Runs automatically on deploy against the production database.
set -euo pipefail
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c 'CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY)'
for f in migrations/[0-9][0-9][0-9]_*.sql; do
  name=$(basename "$f")
  done_already=$(psql "$DATABASE_URL" -tAc "SELECT 1 FROM schema_migrations WHERE name = '$name'")
  [ -n "$done_already" ] && continue
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --single-transaction -f "$f" \
    -c "INSERT INTO schema_migrations (name) VALUES ('$name')"
  echo "applied $name"
done
EOF
chmod +x bin/migrate

cat > app/checkout.py <<'EOF'
def place_order(db, shop_id: int, total_cents: int) -> int:
    row = db.execute(
        "INSERT INTO orders (shop_id, total_cents) VALUES (%s, %s) RETURNING id",
        (shop_id, total_cents),
    ).fetchone()
    return row[0]
EOF

cat > README.md <<'EOF'
# shop-db

Schema lives in `migrations/` as numbered plain-SQL files. `bin/migrate` applies new ones on every
deploy, against production. `migrations/seed_dev.sql` is for local databases only.
EOF

$G init -q
$G add -- migrations/001_init.sql migrations/002_order_status.sql migrations/seed_dev.sql bin/migrate app/checkout.py README.md
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "shop schema and migrate script"
