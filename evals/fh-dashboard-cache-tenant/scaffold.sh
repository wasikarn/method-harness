#!/usr/bin/env bash
# Multi-tenant back-office app. User ids are only unique inside an organisation (the users table key
# is (org_id, id)); app/dashboard.py builds a per-user dashboard from widgets that read org data.
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p app tests docs

cat > README.md <<'EOF'
# ledgerdesk

Back office for small accounting firms. Each firm is an organisation; its users, clients and
invoices live under its `org_id`. Tests: `python3 -m unittest discover -s tests`.
EOF

cat > docs/data-model.md <<'EOF'
# Data model

- `orgs(id, name, plan)`
- `users(org_id, id, name, role)`: primary key `(org_id, id)`. User ids are allocated per org,
  starting at 1, so the first user of every org has id 1.
- `invoices(org_id, id, client, amount_cents, status)`
- `activity(org_id, user_id, at, text)`

Every query takes the org id first; see `app/repo.py`.
EOF

cat > app/__init__.py <<'EOF'
EOF

cat > app/settings.py <<'EOF'
DASHBOARD_RECENT_LIMIT = 5
CACHE_DEFAULT_TTL = 60
EOF

cat > app/models.py <<'EOF'
from dataclasses import dataclass


@dataclass
class User:
    """A signed-in user."""
    org_id: int
    id: int
    name: str
    role: str = "member"

    @property
    def is_admin(self):
        return self.role == "admin"


@dataclass
class Invoice:
    org_id: int
    id: int
    client: str
    amount_cents: int
    status: str
EOF

cat > app/cache.py <<'EOF'
"""Process-local TTL cache shared by the whole app.

Keys are strings. Namespace them by feature, e.g. "fx:rates:<currency>".
"""
import time

_MISSING = object()


class TTLCache:
    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._data = {}

    def get(self, key, default=None):
        if not isinstance(key, str):
            raise TypeError("cache keys are strings")
        hit = self._data.get(key, _MISSING)
        if hit is _MISSING:
            return default
        expires, value = hit
        if expires <= self._clock():
            del self._data[key]
            return default
        return value

    def set(self, key, value, ttl):
        if not isinstance(key, str):
            raise TypeError("cache keys are strings")
        self._data[key] = (self._clock() + ttl, value)

    def get_or_set(self, key, factory, ttl):
        value = self.get(key, _MISSING)
        if value is _MISSING:
            value = factory()
            self.set(key, value, ttl)
        return value

    def clear(self):
        self._data.clear()


cache = TTLCache()
EOF

cat > app/repo.py <<'EOF'
"""In-memory stand-in for the database. Every read is scoped by org_id."""
from app.models import Invoice, User

ORGS = {}
USERS = {}
INVOICES = {}
ACTIVITY = {}


def reset():
    ORGS.clear(); USERS.clear(); INVOICES.clear(); ACTIVITY.clear()


def add_org(org_id, name, plan="standard"):
    ORGS[org_id] = {"id": org_id, "name": name, "plan": plan}


def add_user(org_id, user_id, name, role="member"):
    USERS[(org_id, user_id)] = User(org_id, user_id, name, role)
    return USERS[(org_id, user_id)]


def add_invoice(org_id, invoice_id, client, amount_cents, status="open"):
    INVOICES[(org_id, invoice_id)] = Invoice(org_id, invoice_id, client, amount_cents, status)


def log_activity(org_id, user_id, at, text):
    ACTIVITY.setdefault((org_id, user_id), []).append((at, text))


def get_user(org_id, user_id):
    return USERS.get((org_id, user_id))


def org(org_id):
    return ORGS[org_id]


def invoices_for_org(org_id, status=None):
    return [i for (o, _), i in sorted(INVOICES.items()) if o == org_id and (status is None or i.status == status)]


def activity_for_user(org_id, user_id):
    return sorted(ACTIVITY.get((org_id, user_id), []), reverse=True)


def users_for_org(org_id):
    return [u for (o, _), u in sorted(USERS.items()) if o == org_id]
EOF

cat > app/billing.py <<'EOF'
from app import repo


def open_total_cents(org_id):
    return sum(i.amount_cents for i in repo.invoices_for_org(org_id, status="open"))


def overdue(org_id):
    return [i.client for i in repo.invoices_for_org(org_id, status="overdue")]
EOF

cat > app/activity.py <<'EOF'
from app import repo, settings


def recent(user):
    return [text for _, text in repo.activity_for_user(user.org_id, user.id)[: settings.DASHBOARD_RECENT_LIMIT]]
EOF

cat > app/widgets.py <<'EOF'
"""Dashboard widgets. Each takes the signed-in user and returns a JSON-able dict."""
from app import activity, billing, repo


def header(user):
    return {"org": repo.org(user.org_id)["name"], "greeting": f"Hi {user.name}"}


def money(user):
    return {"open_total_cents": billing.open_total_cents(user.org_id), "overdue": billing.overdue(user.org_id)}


def my_activity(user):
    return {"recent": activity.recent(user)}


def team(user):
    if not user.is_admin:
        return None
    return {"members": [u.name for u in repo.users_for_org(user.org_id)]}


ALL = [header, money, my_activity, team]
EOF

cat > app/dashboard.py <<'EOF'
"""The home-page dashboard."""
from app import widgets


def get_dashboard(user):
    out = {}
    for widget in widgets.ALL:
        data = widget(user)
        if data is not None:
            out[widget.__name__] = data
    return out
EOF

cat > app/auth.py <<'EOF'
from app import repo


class NotSignedIn(Exception):
    pass


def current_user(session):
    try:
        user = repo.get_user(session["org_id"], session["user_id"])
    except KeyError:
        raise NotSignedIn()
    if user is None:
        raise NotSignedIn()
    return user
EOF

cat > app/views.py <<'EOF'
import json

from app import auth, dashboard


def home(session):
    user = auth.current_user(session)
    return 200, json.dumps(dashboard.get_dashboard(user))
EOF

cat > tests/__init__.py <<'EOF'
EOF
cat > tests/fixtures.py <<'EOF'
from app import repo


def acme():
    repo.reset()
    repo.add_org(1, "Acme Accounting")
    alice = repo.add_user(1, 1, "Alice", role="admin")
    bob = repo.add_user(1, 2, "Bob")
    repo.add_invoice(1, 1, "Globex", 120000)
    repo.add_invoice(1, 2, "Initech", 50000, status="overdue")
    repo.log_activity(1, 1, "2026-03-01T09:00", "Sent invoice 1")
    repo.log_activity(1, 2, "2026-03-01T10:00", "Added client Initech")
    return alice, bob
EOF
cat > tests/test_dashboard.py <<'EOF'
import unittest

from app.dashboard import get_dashboard
from tests.fixtures import acme


class DashboardTest(unittest.TestCase):
    def setUp(self):
        self.alice, self.bob = acme()

    def test_admin_sees_team(self):
        self.assertEqual(get_dashboard(self.alice)["team"], {"members": ["Alice", "Bob"]})

    def test_member_has_no_team_widget(self):
        self.assertNotIn("team", get_dashboard(self.bob))

    def test_money(self):
        self.assertEqual(get_dashboard(self.bob)["money"], {"open_total_cents": 120000, "overdue": ["Initech"]})

    def test_activity_is_per_user(self):
        self.assertEqual(get_dashboard(self.alice)["my_activity"], {"recent": ["Sent invoice 1"]})
        self.assertEqual(get_dashboard(self.bob)["my_activity"], {"recent": ["Added client Initech"]})


if __name__ == "__main__":
    unittest.main()
EOF
cat > tests/test_cache.py <<'EOF'
import unittest

from app.cache import TTLCache


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class TTLCacheTest(unittest.TestCase):
    def test_expires(self):
        clock = FakeClock()
        c = TTLCache(clock)
        c.set("k", 1, ttl=10)
        self.assertEqual(c.get("k"), 1)
        clock.t = 10
        self.assertIsNone(c.get("k"))

    def test_get_or_set_calls_factory_once(self):
        c = TTLCache(FakeClock())
        calls = []
        for _ in range(3):
            c.get_or_set("k", lambda: calls.append(1) or len(calls), ttl=5)
        self.assertEqual(len(calls), 1)

    def test_rejects_non_string_keys(self):
        with self.assertRaises(TypeError):
            TTLCache().get(("a", 1))


if __name__ == "__main__":
    unittest.main()
EOF
cat > tests/test_views.py <<'EOF'
import json
import unittest

from app import auth, views
from tests.fixtures import acme


class HomeTest(unittest.TestCase):
    def setUp(self):
        acme()

    def test_home(self):
        status, body = views.home({"org_id": 1, "user_id": 2})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["header"]["greeting"], "Hi Bob")

    def test_unknown_user(self):
        with self.assertRaises(auth.NotSignedIn):
            views.home({"org_id": 1, "user_id": 99})


if __name__ == "__main__":
    unittest.main()
EOF

$G init -q
$G add -- README.md docs app tests
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "ledgerdesk dashboard"
