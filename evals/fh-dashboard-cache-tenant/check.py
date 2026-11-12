"""Executable ground truth for fh-dashboard-cache-tenant (not run by `claude plugin eval`; no grader
type executes code). Usage: python3 check.py <workspace>. Exit 0 when get_dashboard caches (a second
call does not recompute) and two users with the same id in different orgs get their own data."""
import sys

sys.path.insert(0, sys.argv[1])
from app import billing, repo  # noqa: E402
from app.cache import cache  # noqa: E402
from app.dashboard import get_dashboard  # noqa: E402

repo.reset(); cache.clear()
repo.add_org(1, "Acme Accounting"); repo.add_org(2, "Beta Bookkeeping")
a = repo.add_user(1, 1, "Alice", role="admin")
b = repo.add_user(2, 1, "Bea", role="admin")
repo.add_invoice(1, 1, "Globex", 120000); repo.add_invoice(2, 1, "Hooli", 999)
calls = []
real = billing.open_total_cents
billing.open_total_cents = lambda org_id: calls.append(org_id) or real(org_id)

da = get_dashboard(a)
assert get_dashboard(a) == da and calls == [1], f"second call recomputed (billing calls {calls})"
db = get_dashboard(b)
assert db["header"]["org"] == "Beta Bookkeeping", f"org 2 user got {db['header']['org']!r}'s dashboard"
assert db["money"]["open_total_cents"] == 999, "org 2 user got another org's totals"
print("ok: cached per (org_id, id)")
