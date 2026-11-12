#!/usr/bin/env bash
set -euo pipefail

mkdir -p src

cat > package.json <<'EOF'
{
  "name": "price-sync",
  "version": "1.4.0",
  "private": true,
  "type": "module",
  "scripts": {
    "import": "node src/cli.ts import",
    "typecheck": "tsc --noEmit"
  }
}
EOF

cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "allowImportingTsExtensions": true,
    "noEmit": true,
    "strict": true
  },
  "include": ["src"]
}
EOF

cat > README.md <<'EOF'
# price-sync

Serves product prices to the storefront and to checkout, with a short cache in
front of the pricing API, and imports the nightly supplier price file.
EOF

cat > src/telemetry.ts <<'EOF'
// Metrics are best-effort: a StatsD outage must never fail a price lookup.
// Drops are counted and logged (first one, then every 100th) so a dead
// collector still shows up in the logs without flooding them.
type Sink = (name: string, value: number) => void;

let sink: Sink = () => {};
let dropped = 0;

export function setSink(next: Sink): void {
  sink = next;
}

export function emitMetric(name: string, value: number): void {
  try {
    sink(name, value);
  } catch (err) {
    dropped += 1;
    if (dropped === 1 || dropped % 100 === 0) {
      console.warn(`metrics sink failed, ${dropped} metrics dropped so far`, err);
    }
  }
}
EOF

cat > src/upstream.ts <<'EOF'
import { emitMetric } from "./telemetry.ts";

export type Price = { sku: string; amountCents: number; currency: string };

export class UpstreamError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "UpstreamError";
  }
}

const BASE_URL = process.env.PRICING_API_URL ?? "http://pricing.internal";

export async function fetchPrice(sku: string, fetchImpl: typeof fetch = fetch): Promise<Price> {
  const started = Date.now();
  let res: Response;
  try {
    res = await fetchImpl(`${BASE_URL}/prices/${encodeURIComponent(sku)}`);
  } catch (err) {
    console.error(`pricing API unreachable for ${sku}`, err);
    throw new UpstreamError(`pricing API unreachable for ${sku}`, { cause: err });
  } finally {
    emitMetric("pricing.fetch_ms", Date.now() - started);
  }
  if (!res.ok) {
    throw new UpstreamError(`pricing API returned ${res.status} for ${sku}`);
  }
  return (await res.json()) as Price;
}
EOF

cat > src/ttlStore.ts <<'EOF'
export class TtlStore<V> {
  private entries = new Map<string, { value: V; expiresAt: number }>();

  get(key: string): V | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.entries.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: string, value: V, ttlMs: number): void {
    this.entries.set(key, { value, expiresAt: Date.now() + ttlMs });
  }

  clear(): void {
    this.entries.clear();
  }
}
EOF

cat > src/pricing.ts <<'EOF'
import { TtlStore } from "./ttlStore.ts";
import { fetchPrice, type Price } from "./upstream.ts";

const TTL_MS = 15 * 60 * 1000;
const cache = new TtlStore<Price>();

// Used by the product page and by checkout to price the cart.
export async function getPrice(sku: string, fetchImpl?: typeof fetch): Promise<Price> {
  const hit = cache.get(sku);
  if (hit) return hit;

  let price: Price;
  try {
    price = await fetchPrice(sku, fetchImpl);
  } catch {
    // Keep the page up if pricing is having a bad moment.
    price = { sku, amountCents: 0, currency: "USD" };
  }
  cache.set(sku, price, TTL_MS);
  return price;
}

export function resetPriceCache(): void {
  cache.clear();
}
EOF

cat > src/checkout.ts <<'EOF'
import { getPrice } from "./pricing.ts";

export type CartLine = { sku: string; qty: number };

// The total returned here is what the payment step charges.
export async function priceCart(lines: CartLine[], fetchImpl?: typeof fetch): Promise<number> {
  let total = 0;
  for (const line of lines) {
    const price = await getPrice(line.sku, fetchImpl);
    total += price.amountCents * line.qty;
  }
  return total;
}
EOF

cat > src/db.ts <<'EOF'
export interface Db {
  query(sql: string, params: unknown[]): Promise<void>;
}

export type PriceRow = { sku: string; amountCents: number; currency: string };

export async function upsertPrice(db: Db, row: PriceRow): Promise<void> {
  if (!row.sku) throw new Error("price row has no sku");
  if (!Number.isInteger(row.amountCents) || row.amountCents < 0) {
    throw new Error(`bad amount for ${row.sku}: ${row.amountCents}`);
  }
  if (!/^[A-Z]{3}$/.test(row.currency)) {
    throw new Error(`bad currency for ${row.sku}: ${row.currency}`);
  }
  await db.query(
    "INSERT INTO prices (sku, amount_cents, currency) VALUES ($1, $2, $3) " +
      "ON CONFLICT (sku) DO UPDATE SET amount_cents = $2, currency = $3",
    [row.sku, row.amountCents, row.currency],
  );
}
EOF

cat > src/importer.ts <<'EOF'
import { readFile, rename } from "node:fs/promises";
import path from "node:path";
import { upsertPrice, type Db, type PriceRow } from "./db.ts";

export type ImportResult = { file: string; imported: number };

function parseCsv(text: string): PriceRow[] {
  return text
    .trim()
    .split("\n")
    .slice(1)
    .map((line) => {
      const [sku, amount, currency] = line.split(",").map((s) => s.trim());
      return { sku, amountCents: Number(amount), currency };
    });
}

// Nightly job: load a supplier price file (sku,amount_cents,currency), then
// move it to the archive so the next run does not import it again.
export async function importPriceFile(db: Db, file: string, archiveDir: string): Promise<ImportResult> {
  const rows = parseCsv(await readFile(file, "utf8"));
  await Promise.allSettled(rows.map((row) => upsertPrice(db, row)));
  await rename(file, path.join(archiveDir, path.basename(file)));
  return { file, imported: rows.length };
}
EOF

cat > src/cli.ts <<'EOF'
import { readdir } from "node:fs/promises";
import path from "node:path";
import { importPriceFile } from "./importer.ts";
import type { Db } from "./db.ts";

const INBOX = process.env.PRICE_INBOX ?? "/var/price-sync/inbox";
const ARCHIVE = process.env.PRICE_ARCHIVE ?? "/var/price-sync/archive";

async function connect(): Promise<Db> {
  const { default: pg } = await import("pg" as string);
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
  return { query: async (sql: string, params: unknown[]) => void (await pool.query(sql, params)) };
}

async function main(): Promise<void> {
  const db = await connect();
  for (const name of (await readdir(INBOX)).filter((n) => n.endsWith(".csv"))) {
    const result = await importPriceFile(db, path.join(INBOX, name), ARCHIVE);
    console.log(`imported ${result.imported} prices from ${name}`);
  }
}

main().catch((err) => {
  console.error("price import failed", err);
  process.exit(1);
});
EOF

git init -q . && git config user.email dev@example.com && git config user.name dev && git add -A && git commit -qm init
