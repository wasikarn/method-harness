#!/usr/bin/env bash
set -euo pipefail

mkdir -p payouts tests

cat > README.md <<'EOF'
# payouts

Nightly job that pays out seller balances in batches through the bank-transfer
gateway, records each transfer, and emails the payee a receipt.

    python -m payouts.cli --db payouts.sqlite3
EOF

cat > payouts/__init__.py <<'EOF'
EOF

cat > payouts/gateway.py <<'EOF'
"""Thin client for the bank-transfer gateway."""
import json
import urllib.error
import urllib.request


class GatewayError(Exception):
    """The gateway rejected the transfer or could not be reached."""


class GatewayTimeout(GatewayError):
    """No answer in time. The transfer may or may not have been applied."""


class GatewayClient:
    def __init__(self, base_url, api_key, timeout=10):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def transfer(self, account, amount_cents, idempotency_key):
        """Move money to `account`. The gateway applies a given
        Idempotency-Key at most once. Returns the gateway transfer id."""
        body = json.dumps({"account": account, "amount_cents": amount_cents}).encode()
        req = urllib.request.Request(
            f"{self.base_url}/v1/transfers",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Idempotency-Key": idempotency_key,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.load(resp)["transfer_id"]
        except TimeoutError as e:
            raise GatewayTimeout(f"transfer to {account} timed out") from e
        except urllib.error.HTTPError as e:
            raise GatewayError(f"gateway returned {e.code} for {account}") from e
        except urllib.error.URLError as e:
            if isinstance(e.reason, TimeoutError):
                raise GatewayTimeout(f"transfer to {account} timed out") from e
            raise GatewayError(f"gateway unreachable: {e.reason}") from e
EOF

cat > payouts/sender.py <<'EOF'
import logging
import time
import uuid

from .gateway import GatewayTimeout

log = logging.getLogger(__name__)

MAX_ATTEMPTS = 3
BACKOFF_SECONDS = 2


def send_payout(gateway, payout, sleep=time.sleep):
    """Send one payout, retrying when the gateway is slow to answer.

    Returns the gateway transfer id.
    """
    for attempt in range(1, MAX_ATTEMPTS + 1):
        key = f"payout-{payout['id']}-{uuid.uuid4().hex}"
        try:
            return gateway.transfer(payout["account"], payout["amount_cents"], key)
        except GatewayTimeout:
            if attempt == MAX_ATTEMPTS:
                raise
            log.warning(
                "payout %s timed out (attempt %d/%d), retrying",
                payout["id"], attempt, MAX_ATTEMPTS,
            )
            sleep(BACKOFF_SECONDS * attempt)
EOF

cat > payouts/batch.py <<'EOF'
import logging

from .gateway import GatewayError
from .receipts import send_receipt
from .sender import send_payout

log = logging.getLogger(__name__)


def run_batch(store, gateway, mailer, batch_id):
    """Pay every pending payout in a batch, then close the batch."""
    payouts = store.pending_payouts(batch_id)
    sent = 0
    for payout in payouts:
        try:
            transfer_id = send_payout(gateway, payout)
        except GatewayError as e:
            log.debug("skipping payout %s: %s", payout["id"], e)
            continue
        store.record_transfer(payout["id"], transfer_id)
        send_receipt(mailer, store, payout)
        sent += 1
    store.close_batch(batch_id)
    log.info("batch %s closed, %d payouts sent", batch_id, sent)
    return sent
EOF

cat > payouts/receipts.py <<'EOF'
import logging

log = logging.getLogger(__name__)


def _body(payout):
    return f"We sent {payout['amount_cents'] / 100:.2f} to account {payout['account']}."


def send_receipt(mailer, store, payout):
    """Email the payee a receipt for a payout that has already been sent.

    Best-effort on purpose: the money has already moved, so a mail failure
    must not fail the payout or the batch. A failed receipt is logged and put
    in the outbox; retry_outbox() re-sends it at the start of the next run.
    """
    try:
        mailer.send(payout["email"], "Your payout is on its way", _body(payout))
    except Exception:
        log.exception("receipt for payout %s failed, queued for retry", payout["id"])
        store.enqueue_receipt(payout["id"])


def retry_outbox(mailer, store):
    """Re-send queued receipts. A receipt that fails again stays queued."""
    for payout in store.queued_receipts():
        try:
            mailer.send(payout["email"], "Your payout is on its way", _body(payout))
        except Exception:
            log.exception("receipt for payout %s failed again, still queued", payout["id"])
            continue
        store.dequeue_receipt(payout["id"])
EOF

cat > payouts/store.py <<'EOF'
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS batches (id TEXT PRIMARY KEY, status TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS payouts (
    id TEXT PRIMARY KEY,
    batch_id TEXT NOT NULL REFERENCES batches(id),
    account TEXT NOT NULL,
    email TEXT NOT NULL,
    amount_cents INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    transfer_id TEXT
);
CREATE TABLE IF NOT EXISTS receipt_outbox (payout_id TEXT PRIMARY KEY);
"""


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    def open_batches(self):
        return [r["id"] for r in self.db.execute("SELECT id FROM batches WHERE status = 'open'")]

    def pending_payouts(self, batch_id):
        rows = self.db.execute(
            "SELECT * FROM payouts WHERE batch_id = ? AND status = 'pending'", (batch_id,)
        )
        return [dict(r) for r in rows]

    def record_transfer(self, payout_id, transfer_id):
        with self.db:
            self.db.execute(
                "UPDATE payouts SET status = 'paid', transfer_id = ? WHERE id = ?",
                (transfer_id, payout_id),
            )

    def close_batch(self, batch_id):
        with self.db:
            # Settle whatever is left in the batch and close it.
            self.db.execute(
                "UPDATE payouts SET status = 'paid' WHERE batch_id = ? AND status = 'pending'",
                (batch_id,),
            )
            self.db.execute("UPDATE batches SET status = 'closed' WHERE id = ?", (batch_id,))

    def enqueue_receipt(self, payout_id):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO receipt_outbox VALUES (?)", (payout_id,))

    def queued_receipts(self):
        rows = self.db.execute(
            "SELECT p.* FROM payouts p JOIN receipt_outbox o ON o.payout_id = p.id"
        )
        return [dict(r) for r in rows]

    def dequeue_receipt(self, payout_id):
        with self.db:
            self.db.execute("DELETE FROM receipt_outbox WHERE payout_id = ?", (payout_id,))
EOF

cat > payouts/cli.py <<'EOF'
import argparse
import logging
import os

from .batch import run_batch
from .gateway import GatewayClient
from .receipts import retry_outbox
from .store import Store


class SmtpMailer:
    def __init__(self, host):
        self.host = host

    def send(self, to, subject, body):
        import smtplib
        from email.message import EmailMessage

        msg = EmailMessage()
        msg["To"], msg["From"], msg["Subject"] = to, "payouts@example.com", subject
        msg.set_content(body)
        with smtplib.SMTP(self.host, timeout=10) as smtp:
            smtp.send_message(msg)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)

    store = Store(args.db)
    gateway = GatewayClient(os.environ["GATEWAY_URL"], os.environ["GATEWAY_API_KEY"])
    mailer = SmtpMailer(os.environ.get("SMTP_HOST", "localhost"))

    retry_outbox(mailer, store)
    for batch_id in store.open_batches():
        run_batch(store, gateway, mailer, batch_id)


if __name__ == "__main__":
    main()
EOF

cat > tests/test_receipts.py <<'EOF'
import unittest

from payouts.receipts import retry_outbox, send_receipt
from payouts.store import Store


class BrokenMailer:
    def send(self, to, subject, body):
        raise ConnectionRefusedError("smtp down")


class OkMailer:
    def __init__(self):
        self.sent = []

    def send(self, to, subject, body):
        self.sent.append(to)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.store.db.execute("INSERT INTO batches VALUES ('b1', 'open')")
        self.store.db.execute(
            "INSERT INTO payouts (id, batch_id, account, email, amount_cents) "
            "VALUES ('p1', 'b1', 'ACC1', 'a@example.com', 1500)"
        )
        self.payout = self.store.pending_payouts("b1")[0]

    def test_failed_receipt_is_queued_then_resent(self):
        send_receipt(BrokenMailer(), self.store, self.payout)
        self.assertEqual(len(self.store.queued_receipts()), 1)
        mailer = OkMailer()
        retry_outbox(mailer, self.store)
        self.assertEqual(mailer.sent, ["a@example.com"])
        self.assertEqual(self.store.queued_receipts(), [])


if __name__ == "__main__":
    unittest.main()
EOF

git init -q . && git config user.email dev@example.com && git config user.name dev && git add -A && git commit -qm init
