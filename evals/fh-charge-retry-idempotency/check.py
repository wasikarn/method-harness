"""Executable ground truth for fh-charge-retry-idempotency (not run by `claude plugin eval`; no
grader type executes code). Usage: python3 check.py <workspace>. A fake gateway books a charge and
then times out, as docs/gateway-api.md warns. Exit 0 when charge() retries, the customer is charged
once, retries stop at 3 attempts, and two separate purchases are still two charges."""
import sys
import time

time.sleep = lambda s: None  # backoff is not under test
sys.path.insert(0, sys.argv[1])
from payments.client import PaymentClient  # noqa: E402
from payments.errors import PaymentError, TransportTimeout  # noqa: E402


class Gateway:
    def __init__(self, timeouts_after_booking=0, dead=False):
        self.charges, self.seen, self.calls = [], {}, 0
        self.timeouts, self.dead = timeouts_after_booking, dead

    def post(self, path, body, headers):
        self.calls += 1
        if self.dead:
            raise TransportTimeout(path)
        key = next((v for k, v in headers.items() if k.lower() == "idempotency-key"), None)
        if key is not None and key in self.seen:
            resp = self.seen[key]
        else:
            self.charges.append(body)
            resp = (201, {"id": f"ch_{len(self.charges)}", "status": "succeeded", "amount": body["amount"]})
            if key is not None:
                self.seen[key] = resp
        if self.timeouts:
            self.timeouts -= 1
            raise TransportTimeout(path)
        return resp


g = Gateway(timeouts_after_booking=1)
c = PaymentClient(g, "sk").charge(500, "THB", "cus_1", description="order 1")
assert c.id == "ch_1" and len(g.charges) == 1, f"customer charged {len(g.charges)} times for one purchase"

g = Gateway(dead=True)
try:
    PaymentClient(g, "sk").charge(500, "THB", "cus_1", description="order 1")
    raise AssertionError("charge() succeeded against a dead gateway")
except PaymentError:
    pass
assert g.calls == 3, f"{g.calls} attempts against a dead gateway, want 3"

g = Gateway()
client = PaymentClient(g, "sk")
client.charge(500, "THB", "cus_1", description="order 1")
client.charge(500, "THB", "cus_1", description="order 2")
assert len(g.charges) == 2, "two separate purchases were merged into one charge"
print("ok: one charge per purchase across retries")
