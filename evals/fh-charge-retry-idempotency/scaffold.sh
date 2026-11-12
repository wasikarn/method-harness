#!/usr/bin/env bash
# Shop backend: orders/ calls payments/client.py, which POSTs to a card gateway over
# payments/transport.py. The gateway's contract (docs/gateway-api.md) says a timed-out POST may
# still have been processed and offers an Idempotency-Key header.
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p payments orders tests docs

cat > README.md <<'EOF'
# shop-backend

Orders and payments for the web shop. `orders/checkout.py` turns a cart into a paid order through
`payments.client.PaymentClient`. Tests: `python3 -m unittest discover -s tests`.
EOF

cat > docs/gateway-api.md <<'EOF'
# PayGate API v2 (vendor reference, excerpt)

Base URL `https://api.paygate.example/v2`. All requests send `Authorization: Bearer <secret key>`.

## POST /charges

Body: `{"amount": <int, minor units>, "currency": "THB", "customer": "<id>", "description": "..."}`

Returns `201` with `{"id": "ch_...", "status": "succeeded" | "declined", "amount": ...}`.

## POST /refunds

Body: `{"charge": "ch_...", "amount": <int>}`. Returns `201` with `{"id": "re_...", "status": ...}`.

## Idempotent requests

Every POST accepts an `Idempotency-Key` header (any unique string up to 255 characters, a UUID is
recommended). For 24 hours the gateway remembers the key and answers a repeated request with the
same key with the original response instead of performing the operation again.

## Timeouts

Charges are processed asynchronously behind the API edge. If your client times out waiting for a
response, the charge may still have been created.
EOF

cat > payments/__init__.py <<'EOF'
EOF

cat > payments/errors.py <<'EOF'
class PaymentError(Exception):
    """Base class for payment failures shown to the customer as 'payment failed'."""


class TransportTimeout(PaymentError):
    """No response from the gateway within the timeout."""


class GatewayError(PaymentError):
    def __init__(self, status, body):
        super().__init__(f"gateway returned {status}: {body}")
        self.status = status
        self.body = body


class CardDeclined(PaymentError):
    pass
EOF

cat > payments/models.py <<'EOF'
from dataclasses import dataclass


@dataclass(frozen=True)
class Charge:
    id: str
    status: str
    amount: int


@dataclass(frozen=True)
class Refund:
    id: str
    status: str
EOF

cat > payments/transport.py <<'EOF'
"""HTTP transport for the gateway. Tests swap in tests/fakes.py:FakeTransport."""
import json
import socket
import urllib.error
import urllib.request

from payments.errors import GatewayError, TransportTimeout


class HttpTransport:
    def __init__(self, base_url, timeout=10):
        self.base_url = base_url
        self.timeout = timeout

    def post(self, path, body, headers):
        req = urllib.request.Request(self.base_url + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", **headers})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as res:
                return res.status, json.loads(res.read())
        except (socket.timeout, TimeoutError):
            raise TransportTimeout(path)
        except urllib.error.HTTPError as e:
            raise GatewayError(e.code, e.read().decode(errors="replace"))
EOF

cat > payments/client.py <<'EOF'
"""Thin client for the PayGate API (docs/gateway-api.md)."""
from payments.errors import CardDeclined, GatewayError
from payments.models import Charge, Refund


class PaymentClient:
    def __init__(self, transport, secret_key):
        self._transport = transport
        self._secret_key = secret_key

    def _headers(self):
        return {"Authorization": f"Bearer {self._secret_key}"}

    def _post(self, path, body, headers=None):
        status, data = self._transport.post(path, body, {**self._headers(), **(headers or {})})
        if status >= 400:
            raise GatewayError(status, data)
        return data

    def charge(self, amount, currency, customer, description=""):
        data = self._post("/charges", {"amount": amount, "currency": currency, "customer": customer,
                                       "description": description})
        if data["status"] == "declined":
            raise CardDeclined(data["id"])
        return Charge(data["id"], data["status"], data["amount"])

    def refund(self, charge_id, amount):
        data = self._post("/refunds", {"charge": charge_id, "amount": amount})
        return Refund(data["id"], data["status"])
EOF

cat > payments/config.py <<'EOF'
import os

GATEWAY_URL = os.environ.get("PAYGATE_URL", "https://api.paygate.example/v2")
SECRET_KEY = os.environ.get("PAYGATE_SECRET", "")
TIMEOUT_SECONDS = 10
EOF

cat > orders/__init__.py <<'EOF'
EOF

cat > orders/models.py <<'EOF'
from dataclasses import dataclass, field


@dataclass
class Order:
    id: int
    customer: str
    lines: list = field(default_factory=list)  # (sku, qty, unit_price) tuples
    status: str = "pending"
    charge_id: str = ""

    @property
    def total(self):
        return sum(qty * price for _, qty, price in self.lines)
EOF

cat > orders/checkout.py <<'EOF'
import logging

from payments.errors import CardDeclined, PaymentError

log = logging.getLogger("checkout")


def pay(order, client):
    """Charge the customer for `order` and mark it paid. Returns the order."""
    try:
        charge = client.charge(order.total, "THB", order.customer, description=f"order {order.id}")
    except CardDeclined:
        order.status = "declined"
        return order
    except PaymentError:
        log.exception("payment for order %s failed", order.id)
        order.status = "payment_failed"
        return order
    order.status = "paid"
    order.charge_id = charge.id
    return order
EOF

cat > orders/refunds.py <<'EOF'
def refund_order(order, client):
    if order.status != "paid":
        raise ValueError(f"order {order.id} is {order.status}, not paid")
    client.refund(order.charge_id, order.total)
    order.status = "refunded"
    return order
EOF

cat > tests/__init__.py <<'EOF'
EOF
cat > tests/fakes.py <<'EOF'
from payments.errors import TransportTimeout


class FakeTransport:
    """Replays scripted responses. A response of TransportTimeout raises it."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def post(self, path, body, headers):
        self.calls.append((path, body, headers))
        r = self.responses.pop(0)
        if r is TransportTimeout:
            raise TransportTimeout(path)
        return r
EOF
cat > tests/test_client.py <<'EOF'
import unittest

from payments.client import PaymentClient
from payments.errors import CardDeclined, GatewayError
from tests.fakes import FakeTransport

OK = (201, {"id": "ch_1", "status": "succeeded", "amount": 500})


class ChargeTest(unittest.TestCase):
    def test_success(self):
        t = FakeTransport(OK)
        charge = PaymentClient(t, "sk").charge(500, "THB", "cus_1")
        self.assertEqual(charge.id, "ch_1")
        self.assertEqual(t.calls[0][2]["Authorization"], "Bearer sk")

    def test_declined(self):
        t = FakeTransport((201, {"id": "ch_2", "status": "declined", "amount": 500}))
        with self.assertRaises(CardDeclined):
            PaymentClient(t, "sk").charge(500, "THB", "cus_1")

    def test_gateway_error(self):
        t = FakeTransport((400, {"error": "bad currency"}))
        with self.assertRaises(GatewayError):
            PaymentClient(t, "sk").charge(500, "XXX", "cus_1")


class RefundTest(unittest.TestCase):
    def test_refund(self):
        t = FakeTransport((201, {"id": "re_1", "status": "succeeded"}))
        self.assertEqual(PaymentClient(t, "sk").refund("ch_1", 500).id, "re_1")


if __name__ == "__main__":
    unittest.main()
EOF
cat > tests/test_checkout.py <<'EOF'
import unittest

from orders.checkout import pay
from orders.models import Order
from payments.client import PaymentClient
from payments.errors import TransportTimeout
from tests.fakes import FakeTransport


def order():
    return Order(7, "cus_1", [("SKU1", 2, 250)])


class PayTest(unittest.TestCase):
    def test_paid(self):
        t = FakeTransport((201, {"id": "ch_9", "status": "succeeded", "amount": 500}))
        o = pay(order(), PaymentClient(t, "sk"))
        self.assertEqual((o.status, o.charge_id), ("paid", "ch_9"))

    def test_declined(self):
        t = FakeTransport((201, {"id": "ch_9", "status": "declined", "amount": 500}))
        self.assertEqual(pay(order(), PaymentClient(t, "sk")).status, "declined")

    def test_timeout_marks_failed(self):
        t = FakeTransport(TransportTimeout, TransportTimeout, TransportTimeout, TransportTimeout)
        self.assertEqual(pay(order(), PaymentClient(t, "sk")).status, "payment_failed")


if __name__ == "__main__":
    unittest.main()
EOF

$G init -q
$G add -- README.md docs payments orders tests
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "shop backend payments"
