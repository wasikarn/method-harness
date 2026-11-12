#!/usr/bin/env bash
set -euo pipefail

mkdir -p billing config docs migrations tests
cat > README.md <<'__EOF__'
# billing

Monthly subscription billing for the hosted product. Accounts hold one
subscription each; on the 1st of every month the invoice run bills every active
subscription for the month ahead.

    python -m billing.cli --db billing.sqlite3

Plans live in `config/plans.json`, tax rates in `config/tax.json`. See
`docs/billing.md` for the billing rules.

Tests: `python -m unittest discover -s tests -t .`
__EOF__
: > billing/__init__.py
cat > billing/api.py <<'__EOF__'
"""JSON handlers. The web layer maps NotFound to 404, BadRequest to 400,
Forbidden to 403 and Conflict to 409."""
from .auth import require_owner
from .money import format_usd


class NotFound(Exception):
    pass


class BadRequest(Exception):
    pass


class Conflict(Exception):
    pass


def invoice_json(inv):
    return {
        "id": inv.id,
        "period_start": inv.period_start.isoformat(),
        "period_end": inv.period_end.isoformat(),
        "lines": [
            {"description": l.description, "amount_cents": l.amount_cents}
            for l in inv.lines
        ],
        "tax_cents": inv.tax_cents,
        "total_cents": inv.total_cents,
        "total": format_usd(inv.total_cents),
    }


def get_invoice(store, session, invoice_id):
    inv = store.get_invoice(invoice_id)
    if inv is None:
        raise NotFound()
    require_owner(session, inv.account_id)
    return invoice_json(inv)


def list_invoices(store, session, body):
    require_owner(session, body["account_id"])
    return [invoice_json(i) for i in store.invoices_for(body["account_id"])]


def update_seats(store, session, body):
    sub = store.get_subscription(body["subscription_id"])
    if sub is None:
        raise NotFound()
    require_owner(session, sub.account_id)
    seats = body.get("seats")
    if not isinstance(seats, int) or isinstance(seats, bool) or seats < 1:
        raise BadRequest("seats must be a positive integer")
    store.set_seats(sub.id, seats)
    return {"seats": seats}
__EOF__
cat > billing/auth.py <<'__EOF__'
from dataclasses import dataclass


class Forbidden(Exception):
    pass


@dataclass(frozen=True)
class Session:
    """The signed-in user. Built by the web layer from the session cookie."""

    account_id: str
    email: str


def require_owner(session, account_id):
    if session.account_id != account_id:
        raise Forbidden()
__EOF__
cat > billing/cli.py <<'__EOF__'
"""Monthly invoice run. Cron calls it every day; it only bills on the 1st."""
import argparse
from datetime import date

from .dates import month_period
from .db import connect
from .emails import PrintMailer, send_invoice
from .invoicing import build_invoice
from .plans import load_plans
from .store import Store
from .tax import load_rates


def run(store, plans, rates, mailer, today):
    if today.day != 1:
        return []
    period = month_period(today)
    issued = []
    for sub in store.active_subscriptions():
        inv = build_invoice(plans, rates, sub, period)
        if not store.save_invoice(inv):
            continue
        send_invoice(mailer, store, inv)
        issued.append(inv.id)
    return issued


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--db", required=True)
    p.add_argument("--plans", default="config/plans.json")
    p.add_argument("--tax", default="config/tax.json")
    p.add_argument("--date", type=date.fromisoformat, default=date.today())
    args = p.parse_args(argv)
    store = Store(connect(args.db))
    issued = run(store, load_plans(args.plans), load_rates(args.tax), PrintMailer(), args.date)
    print(f"issued {len(issued)} invoice(s)")


if __name__ == "__main__":
    main()
__EOF__
cat > billing/dates.py <<'__EOF__'
"""Billing periods.

A BillingPeriod covers the days start <= day < end. `end` is exclusive: it is
the first day of the next period, so the period from 2026-03-01 to 2026-04-01
covers all 31 days of March and `days` is 31.
"""
from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class BillingPeriod:
    start: date
    end: date

    @property
    def days(self):
        return (self.end - self.start).days

    def contains(self, day):
        return self.start <= day < self.end


def month_period(day):
    """The calendar month that contains `day`."""
    start = day.replace(day=1)
    if start.month == 12:
        end = date(start.year + 1, 1, 1)
    else:
        end = date(start.year, start.month + 1, 1)
    return BillingPeriod(start, end)
__EOF__
cat > billing/db.py <<'__EOF__'
"""Opens the database and applies migrations/NNN_*.sql in order, once each."""
import os
import sqlite3

MIGRATIONS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "migrations"
)


def connect(path):
    db = sqlite3.connect(path, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    migrate(db)
    return db


def migrate(db):
    db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY)")
    done = {r["name"] for r in db.execute("SELECT name FROM schema_migrations")}
    for name in sorted(os.listdir(MIGRATIONS)):
        if not name.endswith(".sql") or name in done:
            continue
        with open(os.path.join(MIGRATIONS, name)) as f:
            sql = f.read()
        db.execute("BEGIN")
        try:
            for statement in sql.split(";"):
                if statement.strip():
                    db.execute(statement)
            db.execute("INSERT INTO schema_migrations VALUES (?)", (name,))
        except BaseException:
            db.execute("ROLLBACK")
            raise
        db.execute("COMMIT")
__EOF__
cat > billing/emails.py <<'__EOF__'
from .money import format_usd


class PrintMailer:
    """Stand-in used by the CLI; production wires in the SMTP mailer."""

    def send(self, to, subject, body):
        print(f"To: {to}\nSubject: {subject}\n\n{body}\n")


def send_invoice(mailer, store, inv):
    to = store.account_email(inv.account_id)
    rows = "\n".join(
        f"  {l.description}: {format_usd(l.amount_cents)}" for l in inv.lines
    )
    body = (
        f"Your invoice for {inv.period_start:%B %Y}:\n{rows}\n"
        f"  Tax: {format_usd(inv.tax_cents)}\n"
        f"  Total: {format_usd(inv.total_cents)}\n"
    )
    mailer.send(to, f"Invoice {inv.id}", body)
__EOF__
cat > billing/events.py <<'__EOF__'
"""Domain events are written to the outbox table in the caller's transaction.
A separate relay process publishes them, so an event exists only if the change
that produced it was committed."""
import json
from datetime import datetime, timezone

INVOICE_ISSUED = "invoice.issued"


def emit(db, kind, payload):
    db.execute(
        "INSERT INTO outbox (kind, payload, created_at) VALUES (?, ?, ?)",
        (kind, json.dumps(payload, sort_keys=True), datetime.now(timezone.utc).isoformat()),
    )
__EOF__
cat > billing/invoicing.py <<'__EOF__'
from .models import Invoice, Line
from .tax import tax_for


def invoice_id(sub, period):
    return f"{sub.id}-{period.start:%Y%m}"


def build_invoice(plans, rates, sub, period):
    plan = plans[sub.plan]
    lines = [Line(f"{plan.name} plan, {period.start:%B %Y}", plan.monthly_cents)]
    extra = max(0, sub.seats - plan.seats_included)
    if extra:
        lines.append(Line(f"{extra} extra seat(s)", extra * plan.seat_price_cents))
    inv = Invoice(
        id=invoice_id(sub, period),
        account_id=sub.account_id,
        subscription_id=sub.id,
        period_start=period.start,
        period_end=period.end,
        lines=lines,
    )
    inv.tax_cents = tax_for(rates, sub.country, inv.subtotal_cents)
    return inv
__EOF__
cat > billing/models.py <<'__EOF__'
from dataclasses import dataclass, field
from datetime import date


@dataclass
class Subscription:
    id: str
    account_id: str
    plan: str
    seats: int
    country: str
    status: str = "active"


@dataclass
class Line:
    description: str
    amount_cents: int


@dataclass
class Invoice:
    id: str
    account_id: str
    subscription_id: str
    period_start: date
    period_end: date
    lines: list = field(default_factory=list)
    tax_cents: int = 0

    @property
    def subtotal_cents(self):
        return sum(line.amount_cents for line in self.lines)

    @property
    def total_cents(self):
        return self.subtotal_cents + self.tax_cents
__EOF__
cat > billing/money.py <<'__EOF__'
"""Money is held as integer cents everywhere. Never use floats for amounts."""


def format_usd(cents):
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}${cents // 100:,}.{cents % 100:02d}"
__EOF__
cat > billing/plans.py <<'__EOF__'
import json
from dataclasses import dataclass


@dataclass(frozen=True)
class Plan:
    name: str
    monthly_cents: int
    seats_included: int
    seat_price_cents: int


def load_plans(path):
    with open(path) as f:
        raw = json.load(f)
    return {
        name: Plan(
            name=name,
            monthly_cents=p["monthly_cents"],
            seats_included=p["seats_included"],
            seat_price_cents=p["seat_price_cents"],
        )
        for name, p in raw.items()
    }
__EOF__
cat > billing/store.py <<'__EOF__'
from contextlib import contextmanager
from datetime import date

from .models import Invoice, Line, Subscription

_SUB_SELECT = (
    "SELECT s.id, s.account_id, s.plan, s.seats, s.status, a.country "
    "FROM subscriptions s JOIN accounts a ON a.id = s.account_id"
)


def _sub(row):
    return Subscription(
        id=row["id"],
        account_id=row["account_id"],
        plan=row["plan"],
        seats=row["seats"],
        country=row["country"],
        status=row["status"],
    )


class Store:
    def __init__(self, db):
        self.db = db

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT")

    def get_subscription(self, sub_id):
        row = self.db.execute(_SUB_SELECT + " WHERE s.id = ?", (sub_id,)).fetchone()
        return _sub(row) if row else None

    def active_subscriptions(self):
        rows = self.db.execute(
            _SUB_SELECT + " WHERE s.status = 'active' ORDER BY s.id"
        ).fetchall()
        return [_sub(r) for r in rows]

    def account_email(self, account_id):
        row = self.db.execute(
            "SELECT email FROM accounts WHERE id = ?", (account_id,)
        ).fetchone()
        return row["email"] if row else None

    def set_seats(self, sub_id, seats):
        self.db.execute("UPDATE subscriptions SET seats = ? WHERE id = ?", (seats, sub_id))

    def save_invoice(self, inv):
        """Insert the invoice and its lines. False if it already exists."""
        with self.transaction():
            cur = self.db.execute(
                "INSERT OR IGNORE INTO invoices VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    inv.id,
                    inv.account_id,
                    inv.subscription_id,
                    inv.period_start.isoformat(),
                    inv.period_end.isoformat(),
                    inv.subtotal_cents,
                    inv.tax_cents,
                    inv.total_cents,
                ),
            )
            if cur.rowcount == 0:
                return False
            for position, line in enumerate(inv.lines):
                self.db.execute(
                    "INSERT INTO invoice_lines VALUES (?, ?, ?, ?)",
                    (inv.id, position, line.description, line.amount_cents),
                )
        return True

    def get_invoice(self, invoice_id):
        row = self.db.execute(
            "SELECT * FROM invoices WHERE id = ?", (invoice_id,)
        ).fetchone()
        if row is None:
            return None
        lines = self.db.execute(
            "SELECT description, amount_cents FROM invoice_lines "
            "WHERE invoice_id = ? ORDER BY position",
            (invoice_id,),
        ).fetchall()
        return Invoice(
            id=row["id"],
            account_id=row["account_id"],
            subscription_id=row["subscription_id"],
            period_start=date.fromisoformat(row["period_start"]),
            period_end=date.fromisoformat(row["period_end"]),
            lines=[Line(r["description"], r["amount_cents"]) for r in lines],
            tax_cents=row["tax_cents"],
        )

    def invoices_for(self, account_id):
        ids = self.db.execute(
            "SELECT id FROM invoices WHERE account_id = ? ORDER BY period_start",
            (account_id,),
        ).fetchall()
        return [self.get_invoice(r["id"]) for r in ids]
__EOF__
cat > billing/tax.py <<'__EOF__'
"""Sales tax / VAT. Rates live in config/tax.json as basis points (1900 = 19%)."""
import json


def load_rates(path):
    with open(path) as f:
        return json.load(f)


def tax_for(rates, country, amount_cents):
    """Tax on a non-negative amount, rounded half up to the cent."""
    if amount_cents < 0:
        raise ValueError("tax base must not be negative")
    bp = rates.get(country, 0)
    return (amount_cents * bp + 5000) // 10000
__EOF__
cat > config/plans.json <<'__EOF__'
{
  "basic": {"monthly_cents": 1000, "seats_included": 3, "seat_price_cents": 400},
  "pro": {"monthly_cents": 4900, "seats_included": 5, "seat_price_cents": 800}
}
__EOF__
cat > config/tax.json <<'__EOF__'
{
  "US": 0,
  "DE": 1900,
  "GB": 2000,
  "TH": 700
}
__EOF__
cat > docs/billing.md <<'__EOF__'
# Billing rules

- Money is stored as integer cents. No floats anywhere in the billing path.
- A billing period is a calendar month. `BillingPeriod.end` is exclusive (see
  `billing/dates.py`).
- Invoices are issued in advance: the run on the 1st bills the month that
  starts that day.
- Each plan includes some seats. Seats above that are billed at the plan's
  per-seat price.
- Tax is charged on the invoice subtotal at the account country's rate.
- The invoice run is safe to re-run: an invoice id is derived from the
  subscription and the month, and an invoice that already exists is skipped.
__EOF__
cat > migrations/001_init.sql <<'__EOF__'
CREATE TABLE accounts (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    country TEXT NOT NULL
);

CREATE TABLE subscriptions (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id),
    plan TEXT NOT NULL,
    seats INTEGER NOT NULL CHECK (seats > 0),
    status TEXT NOT NULL DEFAULT 'active'
);
__EOF__
cat > migrations/002_invoices.sql <<'__EOF__'
CREATE TABLE invoices (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id),
    subscription_id TEXT NOT NULL REFERENCES subscriptions(id),
    period_start TEXT NOT NULL,
    period_end TEXT NOT NULL,
    subtotal_cents INTEGER NOT NULL,
    tax_cents INTEGER NOT NULL,
    total_cents INTEGER NOT NULL
);

CREATE TABLE invoice_lines (
    invoice_id TEXT NOT NULL REFERENCES invoices(id),
    position INTEGER NOT NULL,
    description TEXT NOT NULL,
    amount_cents INTEGER NOT NULL,
    PRIMARY KEY (invoice_id, position)
);

CREATE TABLE outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at TEXT NOT NULL
);
__EOF__
: > tests/__init__.py
cat > tests/helpers.py <<'__EOF__'
from billing.db import connect
from billing.plans import Plan
from billing.store import Store

PLANS = {
    "basic": Plan("basic", monthly_cents=1000, seats_included=3, seat_price_cents=400),
    "pro": Plan("pro", monthly_cents=4900, seats_included=5, seat_price_cents=800),
}
RATES = {"US": 0, "DE": 1900}


class FakeMailer:
    def __init__(self):
        self.sent = []

    def send(self, to, subject, body):
        self.sent.append((to, subject, body))


def make_store():
    store = Store(connect(":memory:"))
    store.db.execute("INSERT INTO accounts VALUES ('a1', 'ann@example.com', 'DE')")
    store.db.execute("INSERT INTO accounts VALUES ('a2', 'bob@example.com', 'US')")
    store.db.execute(
        "INSERT INTO subscriptions (id, account_id, plan, seats) VALUES ('s1', 'a1', 'basic', 5)"
    )
    store.db.execute(
        "INSERT INTO subscriptions (id, account_id, plan, seats) VALUES ('s2', 'a2', 'pro', 2)"
    )
    return store
__EOF__
cat > tests/test_api.py <<'__EOF__'
import unittest

from billing import api
from billing.auth import Forbidden, Session
from tests.helpers import make_store

ANN = Session("a1", "ann@example.com")


class ApiTests(unittest.TestCase):
    def test_update_seats(self):
        store = make_store()
        body = {"subscription_id": "s1", "seats": 7}
        self.assertEqual(api.update_seats(store, ANN, body), {"seats": 7})
        self.assertEqual(store.get_subscription("s1").seats, 7)

    def test_update_seats_other_account_forbidden(self):
        store = make_store()
        with self.assertRaises(Forbidden):
            api.update_seats(store, ANN, {"subscription_id": "s2", "seats": 7})

    def test_seats_must_be_positive_int(self):
        store = make_store()
        for bad in (0, -1, "3", True, None):
            with self.assertRaises(api.BadRequest):
                api.update_seats(store, ANN, {"subscription_id": "s1", "seats": bad})


if __name__ == "__main__":
    unittest.main()
__EOF__
cat > tests/test_invoicing.py <<'__EOF__'
import unittest
from datetime import date

from billing.cli import run
from billing.dates import month_period
from billing.invoicing import build_invoice
from tests.helpers import PLANS, RATES, FakeMailer, make_store


class InvoicingTests(unittest.TestCase):
    def test_extra_seats_and_tax(self):
        store = make_store()
        sub = store.get_subscription("s1")
        inv = build_invoice(PLANS, RATES, sub, month_period(date(2026, 3, 1)))
        self.assertEqual(inv.subtotal_cents, 1000 + 2 * 400)
        self.assertEqual(inv.tax_cents, 342)

    def test_run_only_on_first_and_is_idempotent(self):
        store, mailer = make_store(), FakeMailer()
        self.assertEqual(run(store, PLANS, RATES, mailer, date(2026, 3, 2)), [])
        self.assertEqual(len(run(store, PLANS, RATES, mailer, date(2026, 3, 1))), 2)
        self.assertEqual(run(store, PLANS, RATES, mailer, date(2026, 3, 1)), [])
        self.assertEqual(len(mailer.sent), 2)


if __name__ == "__main__":
    unittest.main()
__EOF__
cat > tests/test_tax.py <<'__EOF__'
import unittest

from billing.tax import tax_for


class TaxTests(unittest.TestCase):
    def test_rounds_half_up(self):
        self.assertEqual(tax_for({"DE": 1900}, "DE", 1050), 200)
        self.assertEqual(tax_for({"DE": 1900}, "DE", 1000), 190)

    def test_unknown_country_untaxed(self):
        self.assertEqual(tax_for({}, "FR", 1000), 0)


if __name__ == "__main__":
    unittest.main()
__EOF__

git init -q . && git config user.email dev@example.com && git config user.name dev
git add -A && git commit -qm 'Initial import'

mkdir -p billing config docs migrations tests
cat > README.md <<'__EOF__'
# billing

Monthly subscription billing for the hosted product. Accounts hold one
subscription each; on the 1st of every month the invoice run bills every active
subscription for the month ahead. Customers can change plans at any time (see
"Plan changes" in `docs/billing.md`).

    python -m billing.cli --db billing.sqlite3
    python -m billing.cli --db billing.sqlite3 --date 2026-04-01 --dry-run

Plans live in `config/plans.json`, tax rates in `config/tax.json`. See
`docs/billing.md` for the billing rules.

Tests: `python -m unittest discover -s tests -t .`
__EOF__
cat > billing/api.py <<'__EOF__'
"""JSON handlers. The web layer maps NotFound to 404, BadRequest to 400,
Forbidden to 403 and Conflict to 409."""
from datetime import date

from . import events
from .auth import require_owner
from .dates import month_period
from .emails import send_downgrade_scheduled
from .invoicing import invoice_id
from .money import format_usd
from .proration import upgrade_charge


class NotFound(Exception):
    pass


class BadRequest(Exception):
    pass


class Conflict(Exception):
    pass


def invoice_json(inv):
    return {
        "id": inv.id,
        "period_start": inv.period_start.isoformat(),
        "period_end": inv.period_end.isoformat(),
        "lines": [
            {"description": l.description, "amount_cents": l.amount_cents}
            for l in inv.lines
        ],
        "tax_cents": inv.tax_cents,
        "total_cents": inv.total_cents,
        "total": format_usd(inv.total_cents),
    }


def get_invoice(store, session, invoice_id):
    inv = store.get_invoice(invoice_id)
    if inv is None:
        raise NotFound()
    require_owner(session, inv.account_id)
    return invoice_json(inv)


def list_invoices(store, session, body):
    require_owner(session, body["account_id"])
    return [invoice_json(i) for i in store.invoices_for(body["account_id"])]


def update_seats(store, session, body):
    sub = store.get_subscription(body["subscription_id"])
    if sub is None:
        raise NotFound()
    require_owner(session, sub.account_id)
    seats = body.get("seats")
    if not isinstance(seats, int) or isinstance(seats, bool) or seats < 1:
        raise BadRequest("seats must be a positive integer")
    store.set_seats(sub.id, seats)
    return {"seats": seats}


def change_plan(store, plans, mailer, session, body, today=None):
    """Move a subscription to another plan.

    body: {"account_id", "subscription_id", "plan"}. Upgrades apply now and
    add a prorated charge to the next invoice; downgrades start next period.
    """
    today = today or date.today()
    sub = store.get_subscription(body.get("subscription_id"))
    if sub is None:
        raise NotFound()
    require_owner(session, body.get("account_id"))
    new = plans.get(body.get("plan"))
    if new is None:
        raise BadRequest("unknown plan")
    if sub.status != "active":
        raise Conflict("subscription is not active")
    old = plans[sub.plan]

    if new.name == old.name:
        store.clear_scheduled_change(sub.id)
        return {"status": "unchanged", "plan": old.name}

    period = month_period(today)
    if new.rank > old.rank:
        # Only a month already invoiced at the old price owes the difference;
        # otherwise the coming invoice bills the new plan in full.
        invoiced = store.get_invoice(invoice_id(sub, period)) is not None
        charge = upgrade_charge(old, new, period, today) if invoiced else 0
        with store.transaction():
            if not store.update_subscription_plan(sub.id, old.name, new.name):
                raise Conflict("the subscription changed; reload and try again")
            if charge:
                store.add_adjustment(
                    sub.id, f"Upgrade from {old.name} to {new.name} on {today.isoformat()}", charge
                )
            events.emit(store.db, events.PLAN_UPGRADED, {
                "subscription_id": sub.id, "from": old.name, "to": new.name,
                "charge_cents": charge,
            })
        return {"status": "upgraded", "plan": new.name, "charge_cents": charge}

    with store.transaction():
        store.schedule_plan_change(sub.id, new.name, period.end)
        events.emit(store.db, events.PLAN_DOWNGRADE_SCHEDULED, {
            "subscription_id": sub.id, "from": old.name, "to": new.name,
            "effective": period.end.isoformat(),
        })
    send_downgrade_scheduled(mailer, store, sub, old, new, period.end)
    return {"status": "scheduled", "plan": new.name, "effective": period.end.isoformat()}
__EOF__
cat > billing/cli.py <<'__EOF__'
"""Monthly invoice run. Cron calls it every day; it only bills on the 1st."""
import argparse
from dataclasses import replace
from datetime import date

from .dates import month_period
from .db import connect
from .emails import PrintMailer, send_invoice
from .invoicing import build_invoice
from .money import format_usd
from .plans import load_plans
from .store import Store
from .tax import load_rates


def run(store, plans, rates, mailer, today, dry_run=False):
    if today.day != 1:
        return []
    period = month_period(today)
    issued = []
    for sub in store.active_subscriptions():
        if sub.scheduled_plan and sub.scheduled_on <= period.start:
            if dry_run or store.apply_scheduled_change(sub.id, sub.scheduled_plan):
                sub = replace(sub, plan=sub.scheduled_plan, scheduled_plan=None, scheduled_on=None)
        inv = build_invoice(plans, rates, sub, period, store.pending_adjustments(sub.id))
        if dry_run:
            print(f"[dry run] {inv.id} {sub.plan}: {format_usd(inv.total_cents)}")
        elif not store.save_invoice(inv):
            continue
        send_invoice(mailer, store, inv)
        issued.append(inv.id)
    return issued


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--db", required=True)
    p.add_argument("--plans", default="config/plans.json")
    p.add_argument("--tax", default="config/tax.json")
    p.add_argument("--date", type=date.fromisoformat, default=date.today())
    p.add_argument(
        "--dry-run", action="store_true",
        help="print the invoices the run would issue; write nothing, send nothing",
    )
    args = p.parse_args(argv)
    store = Store(connect(args.db))
    issued = run(
        store, load_plans(args.plans), load_rates(args.tax), PrintMailer(), args.date,
        dry_run=args.dry_run,
    )
    verb = "would issue" if args.dry_run else "issued"
    print(f"{verb} {len(issued)} invoice(s)")


if __name__ == "__main__":
    main()
__EOF__
cat > billing/emails.py <<'__EOF__'
from datetime import timedelta

from .money import format_usd


class PrintMailer:
    """Stand-in used by the CLI; production wires in the SMTP mailer."""

    def send(self, to, subject, body):
        print(f"To: {to}\nSubject: {subject}\n\n{body}\n")


def send_invoice(mailer, store, inv):
    to = store.account_email(inv.account_id)
    rows = "\n".join(
        f"  {l.description}: {format_usd(l.amount_cents)}" for l in inv.lines
    )
    body = (
        f"Your invoice for {inv.period_start:%B %Y}:\n{rows}\n"
        f"  Tax: {format_usd(inv.tax_cents)}\n"
        f"  Total: {format_usd(inv.total_cents)}\n"
    )
    mailer.send(to, f"Invoice {inv.id}", body)


def send_downgrade_scheduled(mailer, store, sub, old, new, effective):
    """`effective` is the first day on the new plan (a period's exclusive end),
    so the last day on the old plan is the day before."""
    to = store.account_email(sub.account_id)
    last_day = effective - timedelta(days=1)
    body = (
        f"You'll keep the {old.name} plan through {last_day:%B} {last_day.day}.\n"
        f"Your {new.name} plan starts on {effective:%B} {effective.day}, "
        f"at {format_usd(new.monthly_cents)} a month.\n"
        f"Changed your mind? Pick {old.name} again on the billing page.\n"
    )
    mailer.send(to, f"Your move to {new.name} is scheduled", body)
__EOF__
cat > billing/events.py <<'__EOF__'
"""Domain events are written to the outbox table in the caller's transaction.
A separate relay process publishes them, so an event exists only if the change
that produced it was committed."""
import json
from datetime import datetime, timezone

INVOICE_ISSUED = "invoice.issued"
PLAN_UPGRADED = "plan.upgraded"
PLAN_DOWNGRADE_SCHEDULED = "plan.downgrade_scheduled"


def emit(db, kind, payload):
    db.execute(
        "INSERT INTO outbox (kind, payload, created_at) VALUES (?, ?, ?)",
        (kind, json.dumps(payload, sort_keys=True), datetime.now(timezone.utc).isoformat()),
    )
__EOF__
cat > billing/invoicing.py <<'__EOF__'
from .models import Invoice, Line
from .tax import tax_for


def invoice_id(sub, period):
    return f"{sub.id}-{period.start:%Y%m}"


def build_invoice(plans, rates, sub, period, adjustments=()):
    """The invoice for `period`, plus any unbilled one-off adjustments."""
    plan = plans[sub.plan]
    lines = [Line(f"{plan.name} plan, {period.start:%B %Y}", plan.monthly_cents)]
    extra = max(0, sub.seats - plan.seats_included)
    if extra:
        lines.append(Line(f"{extra} extra seat(s)", extra * plan.seat_price_cents))
    for adjustment in adjustments:
        lines.append(Line(adjustment.description, adjustment.amount_cents))
    inv = Invoice(
        id=invoice_id(sub, period),
        account_id=sub.account_id,
        subscription_id=sub.id,
        period_start=period.start,
        period_end=period.end,
        lines=lines,
    )
    inv.tax_cents = tax_for(rates, sub.country, inv.subtotal_cents)
    return inv
__EOF__
cat > billing/models.py <<'__EOF__'
from dataclasses import dataclass, field
from datetime import date
from typing import Optional


@dataclass
class Subscription:
    id: str
    account_id: str
    plan: str
    seats: int
    country: str
    status: str = "active"
    # A downgrade waiting for the next period: the plan and the day it starts.
    scheduled_plan: Optional[str] = None
    scheduled_on: Optional[date] = None


@dataclass
class Adjustment:
    """A one-off charge billed on the next invoice (e.g. a prorated upgrade)."""

    id: int
    subscription_id: str
    description: str
    amount_cents: int


@dataclass
class Line:
    description: str
    amount_cents: int


@dataclass
class Invoice:
    id: str
    account_id: str
    subscription_id: str
    period_start: date
    period_end: date
    lines: list = field(default_factory=list)
    tax_cents: int = 0
    # Adjustments billed on this invoice; save_invoice marks them as billed.
    adjustment_ids: list = field(default_factory=list)

    @property
    def subtotal_cents(self):
        return sum(line.amount_cents for line in self.lines)

    @property
    def total_cents(self):
        return self.subtotal_cents + self.tax_cents
__EOF__
cat > billing/money.py <<'__EOF__'
"""Money is held as integer cents everywhere. Never use floats for amounts."""


def format_usd(cents):
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}${cents // 100:,}.{cents % 100:02d}"


def prorate(amount_cents, part, whole):
    """amount * part / whole, rounded half up to the cent, in integer math.

    Adding whole // 2 before the floor division is the integer form of
    round-half-up for non-negative values.
    """
    if amount_cents < 0 or part < 0 or whole <= 0:
        raise ValueError("prorate needs amount >= 0, part >= 0, whole > 0")
    return (amount_cents * part + whole // 2) // whole
__EOF__
cat > billing/plans.py <<'__EOF__'
import json
from dataclasses import dataclass, fields


@dataclass(frozen=True)
class Plan:
    name: str
    monthly_cents: int
    seat_price_cents: int
    seats_included: int = 0
    # Higher rank = bigger plan. Moving to a higher rank is an upgrade.
    rank: int = 0
    description: str = ""


_KNOWN = {f.name for f in fields(Plan)} - {"name"}


def load_plans(path):
    """Load config/plans.json. Keys this version does not know are ignored, so
    the marketing site can add fields to the shared file before we read them."""
    with open(path) as f:
        raw = json.load(f)
    return {
        name: Plan(name=name, **{k: v for k, v in p.items() if k in _KNOWN})
        for name, p in raw.items()
    }
__EOF__
cat > billing/proration.py <<'__EOF__'
"""Prorated charges for mid-period upgrades (rules: docs/billing.md)."""
from .money import prorate


def days_left(period, on):
    """Days from `on` to the end of the period, counting `on` itself."""
    return (period.end - on).days + 1


def upgrade_charge(old, new, period, on):
    """What the customer owes for using `new` instead of `old` from `on` to
    the end of `period`. Zero if the new plan is not more expensive."""
    if not period.contains(on):
        raise ValueError(f"{on} is outside the period {period.start}..{period.end}")
    if new.monthly_cents <= old.monthly_cents:
        return 0
    return prorate(new.monthly_cents - old.monthly_cents, days_left(period, on), period.days)
__EOF__
cat > billing/store.py <<'__EOF__'
from contextlib import contextmanager
from datetime import date, datetime, timezone

from .models import Adjustment, Invoice, Line, Subscription

_SUB_SELECT = (
    "SELECT s.id, s.account_id, s.plan, s.seats, s.status, "
    "s.scheduled_plan, s.scheduled_on, a.country "
    "FROM subscriptions s JOIN accounts a ON a.id = s.account_id"
)


def _sub(row):
    return Subscription(
        id=row["id"],
        account_id=row["account_id"],
        plan=row["plan"],
        seats=row["seats"],
        country=row["country"],
        status=row["status"],
        scheduled_plan=row["scheduled_plan"],
        scheduled_on=date.fromisoformat(row["scheduled_on"]) if row["scheduled_on"] else None,
    )


class Store:
    def __init__(self, db):
        self.db = db

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT")

    def get_subscription(self, sub_id):
        row = self.db.execute(_SUB_SELECT + " WHERE s.id = ?", (sub_id,)).fetchone()
        return _sub(row) if row else None

    def active_subscriptions(self):
        rows = self.db.execute(
            _SUB_SELECT + " WHERE s.status = 'active' ORDER BY s.id"
        ).fetchall()
        return [_sub(r) for r in rows]

    def account_email(self, account_id):
        row = self.db.execute(
            "SELECT email FROM accounts WHERE id = ?", (account_id,)
        ).fetchone()
        return row["email"] if row else None

    def set_seats(self, sub_id, seats):
        self.db.execute("UPDATE subscriptions SET seats = ? WHERE id = ?", (seats, sub_id))

    def update_subscription_plan(self, sub_id, expected_plan, new_plan):
        """Compare-and-set: switch plans only if the subscription is still on
        `expected_plan`, and drop any scheduled downgrade. Two upgrade requests
        sent from the same page both read the old plan; only the first may add
        a charge, the second gets False."""
        cur = self.db.execute(
            "UPDATE subscriptions SET plan = ?, scheduled_plan = NULL, scheduled_on = NULL "
            "WHERE id = ? AND plan = ?",
            (new_plan, sub_id, expected_plan),
        )
        return cur.rowcount == 1

    def schedule_plan_change(self, sub_id, plan, on):
        self.db.execute(
            "UPDATE subscriptions SET scheduled_plan = ?, scheduled_on = ? WHERE id = ?",
            (plan, on.isoformat(), sub_id),
        )

    def clear_scheduled_change(self, sub_id):
        self.db.execute(
            "UPDATE subscriptions SET scheduled_plan = NULL, scheduled_on = NULL WHERE id = ?",
            (sub_id,),
        )

    def apply_scheduled_change(self, sub_id, plan):
        """Move to the scheduled plan if it is still `plan`. True if applied."""
        cur = self.db.execute(
            "UPDATE subscriptions SET plan = scheduled_plan, scheduled_plan = NULL, "
            "scheduled_on = NULL WHERE id = ? AND scheduled_plan = ?",
            (sub_id, plan),
        )
        return cur.rowcount == 1

    def add_adjustment(self, sub_id, description, amount_cents):
        self.db.execute(
            "INSERT INTO adjustments (subscription_id, description, amount_cents, created_at) "
            "VALUES (?, ?, ?, ?)",
            (sub_id, description, amount_cents, datetime.now(timezone.utc).isoformat()),
        )

    def pending_adjustments(self, sub_id):
        rows = self.db.execute(
            "SELECT id, subscription_id, description, amount_cents FROM adjustments "
            "WHERE subscription_id = ? AND invoice_id IS NULL ORDER BY id",
            (sub_id,),
        ).fetchall()
        return [
            Adjustment(r["id"], r["subscription_id"], r["description"], r["amount_cents"])
            for r in rows
        ]

    def save_invoice(self, inv):
        """Insert the invoice and its lines and mark its adjustments as billed.
        False if the invoice already exists."""
        with self.transaction():
            cur = self.db.execute(
                "INSERT OR IGNORE INTO invoices VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    inv.id,
                    inv.account_id,
                    inv.subscription_id,
                    inv.period_start.isoformat(),
                    inv.period_end.isoformat(),
                    inv.subtotal_cents,
                    inv.tax_cents,
                    inv.total_cents,
                ),
            )
            if cur.rowcount == 0:
                return False
            for position, line in enumerate(inv.lines):
                self.db.execute(
                    "INSERT INTO invoice_lines VALUES (?, ?, ?, ?)",
                    (inv.id, position, line.description, line.amount_cents),
                )
            for adjustment_id in inv.adjustment_ids:
                self.db.execute(
                    "UPDATE adjustments SET invoice_id = ? WHERE id = ? AND invoice_id IS NULL",
                    (inv.id, adjustment_id),
                )
        return True

    def get_invoice(self, invoice_id):
        row = self.db.execute(
            "SELECT * FROM invoices WHERE id = ?", (invoice_id,)
        ).fetchone()
        if row is None:
            return None
        lines = self.db.execute(
            "SELECT description, amount_cents FROM invoice_lines "
            "WHERE invoice_id = ? ORDER BY position",
            (invoice_id,),
        ).fetchall()
        return Invoice(
            id=row["id"],
            account_id=row["account_id"],
            subscription_id=row["subscription_id"],
            period_start=date.fromisoformat(row["period_start"]),
            period_end=date.fromisoformat(row["period_end"]),
            lines=[Line(r["description"], r["amount_cents"]) for r in lines],
            tax_cents=row["tax_cents"],
        )

    def invoices_for(self, account_id):
        ids = self.db.execute(
            "SELECT id FROM invoices WHERE account_id = ? ORDER BY period_start",
            (account_id,),
        ).fetchall()
        return [self.get_invoice(r["id"]) for r in ids]
__EOF__
cat > config/plans.json <<'__EOF__'
{
  "basic": {
    "monthly_cents": 1000, "seats_included": 3, "seat_price_cents": 400, "rank": 1,
    "description": "For small teams getting started"
  },
  "pro": {
    "monthly_cents": 4900, "seats_included": 5, "seat_price_cents": 800, "rank": 2,
    "description": "Advanced reporting and SSO"
  },
  "team": {
    "monthly_cents": 9900, "seat_included": 10, "seat_price_cents": 700, "rank": 3,
    "description": "Unlimited projects and priority support"
  }
}
__EOF__
cat > docs/billing.md <<'__EOF__'
# Billing rules

- Money is stored as integer cents. No floats anywhere in the billing path.
- A billing period is a calendar month. `BillingPeriod.end` is exclusive (see
  `billing/dates.py`).
- Invoices are issued in advance: the run on the 1st bills the month that
  starts that day.
- Each plan includes some seats. Seats above that are billed at the plan's
  per-seat price.
- Tax is charged on the invoice subtotal at the account country's rate.
- The invoice run is safe to re-run: an invoice id is derived from the
  subscription and the month, and an invoice that already exists is skipped.

## Plan changes

- Plans have a `rank`. Moving to a higher rank is an upgrade, anything else is
  a downgrade.
- An upgrade takes effect at once. If this month was already invoiced at the
  old price, the customer owes the price difference for the days left in the
  month, counting the day of the change. That amount is stored as an
  adjustment and billed once, on the next invoice. If this month was not
  invoiced yet, the coming invoice bills the new plan and no adjustment is made.
- A downgrade takes effect on the 1st of the next month, so it never produces
  a credit. Until then the customer keeps the bigger plan. Choosing the
  current plan again cancels a scheduled downgrade; an upgrade replaces it.
- Prorated amounts are rounded half up to the cent.

## Dry run

`--dry-run` prints the invoices the run would issue. It writes nothing to the
database and sends no email.
__EOF__
cat > migrations/003_plan_changes.sql <<'__EOF__'
ALTER TABLE subscriptions ADD COLUMN scheduled_plan TEXT;
ALTER TABLE subscriptions ADD COLUMN scheduled_on TEXT;

CREATE TABLE adjustments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id TEXT NOT NULL REFERENCES subscriptions(id),
    description TEXT NOT NULL,
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
    created_at TEXT NOT NULL,
    invoice_id TEXT REFERENCES invoices(id)
);

CREATE INDEX adjustments_unbilled ON adjustments (subscription_id) WHERE invoice_id IS NULL;
__EOF__
cat > tests/helpers.py <<'__EOF__'
from billing.db import connect
from billing.plans import Plan
from billing.store import Store

PLANS = {
    "basic": Plan("basic", monthly_cents=1000, seats_included=3, seat_price_cents=400, rank=1),
    "pro": Plan("pro", monthly_cents=4900, seats_included=5, seat_price_cents=800, rank=2),
    "team": Plan("team", monthly_cents=9900, seats_included=10, seat_price_cents=700, rank=3),
}
RATES = {"US": 0, "DE": 1900}


class FakeMailer:
    def __init__(self):
        self.sent = []

    def send(self, to, subject, body):
        self.sent.append((to, subject, body))


def make_store():
    store = Store(connect(":memory:"))
    store.db.execute("INSERT INTO accounts VALUES ('a1', 'ann@example.com', 'DE')")
    store.db.execute("INSERT INTO accounts VALUES ('a2', 'bob@example.com', 'US')")
    store.db.execute(
        "INSERT INTO subscriptions (id, account_id, plan, seats) VALUES ('s1', 'a1', 'basic', 5)"
    )
    store.db.execute(
        "INSERT INTO subscriptions (id, account_id, plan, seats) VALUES ('s2', 'a2', 'pro', 2)"
    )
    return store
__EOF__
cat > tests/test_api.py <<'__EOF__'
import unittest
from datetime import date

from billing import api
from billing.auth import Forbidden, Session
from billing.cli import run
from tests.helpers import PLANS, RATES, FakeMailer, make_store

ANN = Session("a1", "ann@example.com")
BOB = Session("a2", "bob@example.com")
MID_MARCH = date(2026, 3, 16)


class ApiTests(unittest.TestCase):
    def test_update_seats(self):
        store = make_store()
        body = {"subscription_id": "s1", "seats": 7}
        self.assertEqual(api.update_seats(store, ANN, body), {"seats": 7})
        self.assertEqual(store.get_subscription("s1").seats, 7)

    def test_update_seats_other_account_forbidden(self):
        store = make_store()
        with self.assertRaises(Forbidden):
            api.update_seats(store, ANN, {"subscription_id": "s2", "seats": 7})

    def test_seats_must_be_positive_int(self):
        store = make_store()
        for bad in (0, -1, "3", True, None):
            with self.assertRaises(api.BadRequest):
                api.update_seats(store, ANN, {"subscription_id": "s1", "seats": bad})


class ChangePlanTests(unittest.TestCase):
    def setUp(self):
        self.store, self.mailer = make_store(), FakeMailer()

    def change(self, session, body):
        return api.change_plan(self.store, PLANS, self.mailer, session, body, MID_MARCH)

    def test_upgrade_applies_now_and_adds_a_charge(self):
        run(self.store, PLANS, RATES, FakeMailer(), date(2026, 3, 1))
        out = self.change(ANN, {"account_id": "a1", "subscription_id": "s1", "plan": "pro"})
        self.assertEqual(out["status"], "upgraded")
        self.assertEqual(self.store.get_subscription("s1").plan, "pro")
        [adj] = self.store.pending_adjustments("s1")
        self.assertEqual(adj.amount_cents, out["charge_cents"])

    def test_upgrade_before_month_is_invoiced_adds_no_charge(self):
        out = self.change(ANN, {"account_id": "a1", "subscription_id": "s1", "plan": "pro"})
        self.assertEqual(out["charge_cents"], 0)
        self.assertEqual(self.store.pending_adjustments("s1"), [])

    def test_downgrade_is_scheduled_for_next_period(self):
        out = self.change(BOB, {"account_id": "a2", "subscription_id": "s2", "plan": "basic"})
        self.assertEqual(out, {"status": "scheduled", "plan": "basic", "effective": "2026-04-01"})
        sub = self.store.get_subscription("s2")
        self.assertEqual((sub.plan, sub.scheduled_plan), ("pro", "basic"))
        self.assertIn("through March 31", self.mailer.sent[0][2])

    def test_picking_current_plan_cancels_scheduled_downgrade(self):
        self.change(BOB, {"account_id": "a2", "subscription_id": "s2", "plan": "basic"})
        self.change(BOB, {"account_id": "a2", "subscription_id": "s2", "plan": "pro"})
        self.assertIsNone(self.store.get_subscription("s2").scheduled_plan)

    def test_unknown_plan(self):
        with self.assertRaises(api.BadRequest):
            self.change(ANN, {"account_id": "a1", "subscription_id": "s1", "plan": "gold"})

    def test_other_account_forbidden(self):
        with self.assertRaises(Forbidden):
            self.change(ANN, {"account_id": "a2", "subscription_id": "s2", "plan": "team"})

    def test_stale_plan_is_a_conflict(self):
        self.assertFalse(self.store.update_subscription_plan("s1", "pro", "team"))


if __name__ == "__main__":
    unittest.main()
__EOF__
cat > tests/test_invoicing.py <<'__EOF__'
import unittest
from datetime import date

from billing.cli import run
from billing.dates import month_period
from billing.invoicing import build_invoice
from tests.helpers import PLANS, RATES, FakeMailer, make_store

APRIL_1 = date(2026, 4, 1)


class InvoicingTests(unittest.TestCase):
    def test_extra_seats_and_tax(self):
        store = make_store()
        sub = store.get_subscription("s1")
        inv = build_invoice(PLANS, RATES, sub, month_period(date(2026, 3, 1)))
        self.assertEqual(inv.subtotal_cents, 1000 + 2 * 400)
        self.assertEqual(inv.tax_cents, 342)

    def test_run_only_on_first_and_is_idempotent(self):
        store, mailer = make_store(), FakeMailer()
        self.assertEqual(run(store, PLANS, RATES, mailer, date(2026, 3, 2)), [])
        self.assertEqual(len(run(store, PLANS, RATES, mailer, date(2026, 3, 1))), 2)
        self.assertEqual(run(store, PLANS, RATES, mailer, date(2026, 3, 1)), [])
        self.assertEqual(len(mailer.sent), 2)

    def test_adjustment_is_billed_on_next_invoice(self):
        store = make_store()
        store.add_adjustment("s2", "Upgrade from basic to pro", 1950)
        run(store, PLANS, RATES, FakeMailer(), APRIL_1)
        inv = store.get_invoice("s2-202604")
        self.assertIn(1950, [line.amount_cents for line in inv.lines])

    def test_scheduled_downgrade_applies_on_the_first(self):
        store = make_store()
        store.schedule_plan_change("s2", "basic", APRIL_1)
        run(store, PLANS, RATES, FakeMailer(), APRIL_1)
        self.assertEqual(store.get_subscription("s2").plan, "basic")
        self.assertEqual(store.get_invoice("s2-202604").lines[0].amount_cents, 1000)

    def test_dry_run_saves_nothing(self):
        store = make_store()
        run(store, PLANS, RATES, FakeMailer(), APRIL_1, dry_run=True)
        self.assertIsNone(store.get_invoice("s1-202604"))


if __name__ == "__main__":
    unittest.main()
__EOF__
cat > tests/test_proration.py <<'__EOF__'
import unittest
from datetime import date

from billing.dates import month_period
from billing.money import prorate
from billing.proration import upgrade_charge
from tests.helpers import PLANS

MARCH = month_period(date(2026, 3, 1))


class ProrationTests(unittest.TestCase):
    def test_prorate_rounds_half_up(self):
        self.assertEqual(prorate(1000, 1, 3), 333)
        self.assertEqual(prorate(1000, 2, 3), 667)
        self.assertEqual(prorate(5, 1, 2), 3)
        self.assertEqual(prorate(3900, 31, 31), 3900)

    def test_prorate_rejects_bad_input(self):
        for args in ((-1, 1, 2), (1, -1, 2), (1, 1, 0)):
            with self.assertRaises(ValueError):
                prorate(*args)

    def test_mid_month_upgrade_charges_part_of_the_difference(self):
        charge = upgrade_charge(PLANS["basic"], PLANS["pro"], MARCH, date(2026, 3, 16))
        self.assertGreater(charge, 0)
        self.assertLess(charge, 3900)

    def test_no_charge_when_new_plan_is_not_dearer(self):
        self.assertEqual(upgrade_charge(PLANS["pro"], PLANS["basic"], MARCH, date(2026, 3, 9)), 0)

    def test_day_outside_period_rejected(self):
        with self.assertRaises(ValueError):
            upgrade_charge(PLANS["basic"], PLANS["pro"], MARCH, date(2026, 4, 1))


if __name__ == "__main__":
    unittest.main()
__EOF__

git add -A && git commit -qm 'Add plan changes with proration and an invoice dry run'
git diff HEAD~1 HEAD > pr.diff
