#!/usr/bin/env bash
mkdir -p app
cat > app/gateway.py <<'FIXTURE_EOF'
import uuid


class GatewayError(Exception):
    pass


def charge(amount_cents: int) -> str:
    if amount_cents <= 0:
        raise GatewayError("amount must be positive")
    return "txn_" + uuid.uuid4().hex
FIXTURE_EOF
mkdir -p app
cat > app/billing.py <<'FIXTURE_EOF'
import logging

from app import gateway

log = logging.getLogger(__name__)


def charge_order(order) -> str:
    try:
        return gateway.charge(order.total_cents)
    except gateway.GatewayError:
        log.exception("charge failed for order %s", order.id)
        raise
FIXTURE_EOF
