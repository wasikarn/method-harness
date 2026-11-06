#!/usr/bin/env bash
mkdir -p shop
cat > shop/models.py <<'FIXTURE_EOF'
from dataclasses import dataclass
from typing import Literal


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


@dataclass(frozen=True)
class Item:
    unit_price_cents: int
    qty: int

    def __post_init__(self):
        if not _is_int(self.unit_price_cents) or self.unit_price_cents < 0:
            raise ValueError("unit_price_cents must be an int >= 0")
        if not _is_int(self.qty) or self.qty <= 0:
            raise ValueError("qty must be an int > 0")


@dataclass(frozen=True)
class Order:
    # The order's own id from the order store: the same order always carries the same id, however
    # many times it is loaded, so it is safe to use as the payment idempotency key.
    id: str
    items: tuple[Item, ...]
    currency: Literal["USD"] = "USD"

    def __post_init__(self):
        if not isinstance(self.id, str) or not self.id.strip():
            raise ValueError("id must be a non-empty string")
        if not isinstance(self.items, tuple) or not self.items:
            raise ValueError("items must be a non-empty tuple")
        if not all(isinstance(i, Item) for i in self.items):
            raise ValueError("items must all be Item")
        if self.currency != "USD":
            raise ValueError("only USD is supported")
FIXTURE_EOF
cat > shop/pricing.py <<'FIXTURE_EOF'
from collections.abc import Iterable

from shop.models import Item


def order_total(items: Iterable[Item]) -> int:
    """Return the order total in cents."""
    return sum(i.unit_price_cents * i.qty for i in items)
FIXTURE_EOF
cat > shop/payments.py <<'FIXTURE_EOF'
from shop import pricing
from shop.gateway import Gateway
from shop.models import Order


def pay(order: Order, gateway: Gateway) -> str:
    total_cents = pricing.order_total(order.items)
    return gateway.charge(amount_cents=total_cents, currency=order.currency, idempotency_key=order.id)
FIXTURE_EOF
cat > shop/gateway.py <<'FIXTURE_EOF'
class Gateway:
    """The shop's payment backend: an in-process ledger. There is no external provider."""

    def __init__(self) -> None:
        self.ledger: dict[str, tuple[int, str]] = {}

    def charge(self, amount_cents: int, currency: str, idempotency_key: str) -> str:
        """Record a charge of `amount_cents` (minor units) and return its transaction id.

        Idempotent per key: a retry with the same key records nothing new and returns the same id.
        A zero amount is a free order; it is recorded and gets an id like any other.
        """
        if not isinstance(amount_cents, int) or isinstance(amount_cents, bool) or amount_cents < 0:
            raise ValueError("amount_cents must be an int >= 0")
        if currency != "USD":
            raise ValueError("only USD is supported")
        if not isinstance(idempotency_key, str) or not idempotency_key.strip():
            raise ValueError("idempotency_key must be a non-empty string")
        prior = self.ledger.setdefault(idempotency_key, (amount_cents, currency))
        if prior != (amount_cents, currency):
            raise ValueError(f"idempotency key {idempotency_key!r} reused for a different charge")
        return f"txn_{idempotency_key}"
FIXTURE_EOF
