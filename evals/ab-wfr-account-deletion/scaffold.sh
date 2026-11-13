#!/usr/bin/env bash
set -euo pipefail

cat > '.gitignore' <<'__ACCOUNTS_EOF__'
__pycache__/
*.sqlite3*
__ACCOUNTS_EOF__
cat > 'README.md' <<'__ACCOUNTS_EOF__'
# accounts

User accounts, sign-in sessions, API tokens and posts for the community
site. Plain Python 3.11+ and SQLite, no third-party packages.

    python -m accounts.cli init-db
    python -m accounts.cli create-user alice alice@example.com
    python -m unittest

`accounts.web.App` is the HTTP layer; the platform's WSGI adapter (not in
this repo) turns requests into `App.handle(method, path, headers, body)`.

Settings come from environment variables, see `accounts/config.py`.
__ACCOUNTS_EOF__
mkdir -p 'accounts'
: > 'accounts/__init__.py'
mkdir -p 'accounts'
cat > 'accounts/audit.py' <<'__ACCOUNTS_EOF__'
"""Audit log. Rows hold only the event, the user id and the date (docs/privacy.md)."""
import sqlite3
from datetime import datetime

from .clock import iso


def record(db: sqlite3.Connection, event: str, user_id: int | None, now: datetime) -> None:
    """Add a row. The caller commits."""
    db.execute(
        "INSERT INTO audit_log (at, event, user_id) VALUES (?, ?, ?)",
        (iso(now), event, user_id),
    )
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/cli.py' <<'__ACCOUNTS_EOF__'
"""Admin commands: python -m accounts.cli <command>."""
import argparse
import getpass
import sys

from . import clock, config, db, users


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="accounts")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init-db", help="create missing tables")
    cu = sub.add_parser("create-user")
    cu.add_argument("username")
    cu.add_argument("email")
    args = parser.parse_args(argv)

    settings = config.load()
    conn = db.connect(settings.db_path)
    if args.cmd == "init-db":
        db.init(conn)
        print(f"schema ready in {settings.db_path}")
    elif args.cmd == "create-user":
        try:
            uid = users.create_user(conn, args.username, args.email, getpass.getpass(), clock.utcnow())
        except users.UserError as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        print(f"created user {uid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/clock.py' <<'__ACCOUNTS_EOF__'
"""Time helpers. Every stored timestamp is UTC, written by iso()."""
from datetime import datetime, timezone


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    """Fixed-width UTC text, so stored timestamps compare correctly as strings."""
    return dt.astimezone(timezone.utc).isoformat(timespec="seconds")
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/config.py' <<'__ACCOUNTS_EOF__'
"""Settings, read from the environment."""
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    db_path: str = "accounts.sqlite3"
    session_days: int = 30


def load() -> Settings:
    return Settings(
        db_path=os.environ.get("ACCOUNTS_DB", Settings.db_path),
        session_days=int(os.environ.get("ACCOUNTS_SESSION_DAYS", Settings.session_days)),
    )
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/db.py' <<'__ACCOUNTS_EOF__'
"""SQLite connection setup."""
import sqlite3
from pathlib import Path

SCHEMA = Path(__file__).with_name("schema.sql")


def connect(path: str) -> sqlite3.Connection:
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout = 5000")
    if path != ":memory:":
        db.execute("PRAGMA journal_mode = WAL")
    return db


def init(db: sqlite3.Connection) -> None:
    """Create any missing tables."""
    db.executescript(SCHEMA.read_text())
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/passwords.py' <<'__ACCOUNTS_EOF__'
"""Password hashing (PBKDF2-SHA256)."""
import hashlib
import hmac
import os

ITERATIONS = 120_000


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, ITERATIONS)
    return f"pbkdf2${ITERATIONS}${salt.hex()}${digest.hex()}"


def verify(password: str, stored: str) -> bool:
    try:
        _, iters, salt, digest = stored.split("$")
    except ValueError:
        return False
    got = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(iters))
    return hmac.compare_digest(got.hex(), digest)
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/posts.py' <<'__ACCOUNTS_EOF__'
"""Posts. Every post is public."""
import sqlite3
from datetime import datetime

from .clock import iso

MAX_BODY = 5000


class PostError(ValueError):
    pass


def create_post(db: sqlite3.Connection, user_id: int, body: str, now: datetime) -> int:
    body = body.strip()
    if not body or len(body) > MAX_BODY:
        raise PostError(f"post must be 1-{MAX_BODY} characters")
    with db:
        cur = db.execute(
            "INSERT INTO posts (user_id, body, created_at) VALUES (?, ?, ?)",
            (user_id, body, iso(now)),
        )
    return cur.lastrowid


def get_post(db: sqlite3.Connection, post_id: int) -> sqlite3.Row | None:
    return db.execute("SELECT id, user_id, body, created_at FROM posts WHERE id = ?", (post_id,)).fetchone()


def posts_by_username(db: sqlite3.Connection, username: str) -> list[sqlite3.Row]:
    return db.execute(
        "SELECT p.id, p.body, p.created_at FROM posts p JOIN users u ON u.id = p.user_id "
        "WHERE u.username = ? ORDER BY p.id",
        (username,),
    ).fetchall()
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/schema.sql' <<'__ACCOUNTS_EOF__'
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    email         TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    ip         TEXT
);

CREATE TABLE IF NOT EXISTS api_tokens (
    token_hash TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS posts (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TEXT NOT NULL
);

-- No foreign key on user_id: audit rows outlive the account (docs/privacy.md).
CREATE TABLE IF NOT EXISTS audit_log (
    id      INTEGER PRIMARY KEY,
    at      TEXT NOT NULL,
    event   TEXT NOT NULL,
    user_id INTEGER
);
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/sessions.py' <<'__ACCOUNTS_EOF__'
"""Sign-in sessions. Only the SHA-256 of a session token is stored."""
import hashlib
import secrets
import sqlite3
from datetime import datetime, timedelta

from . import audit, passwords, users
from .clock import iso


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def login(db: sqlite3.Connection, email: str, password: str, ip: str, now: datetime) -> str | None:
    """Return a new session token, or None if the email or password is wrong."""
    user = users.get_by_email(db, email)
    if user is None or not passwords.verify(password, user["password_hash"]):
        return None
    token = secrets.token_urlsafe(32)
    with db:
        db.execute(
            "INSERT INTO sessions (token_hash, user_id, created_at, ip) VALUES (?, ?, ?, ?)",
            (_hash(token), user["id"], iso(now), ip),
        )
        audit.record(db, "login", user["id"], now)
    return token


def user_for_token(db: sqlite3.Connection, token: str, now: datetime, max_days: int) -> sqlite3.Row | None:
    row = db.execute(
        "SELECT u.*, s.created_at AS session_created FROM sessions s "
        "JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?",
        (_hash(token),),
    ).fetchone()
    if row is None:
        return None
    if datetime.fromisoformat(row["session_created"]) + timedelta(days=max_days) <= now:
        return None
    return row


def logout(db: sqlite3.Connection, token: str) -> None:
    with db:
        db.execute("DELETE FROM sessions WHERE token_hash = ?", (_hash(token),))
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/tokens.py' <<'__ACCOUNTS_EOF__'
"""API tokens for connected apps. Only the SHA-256 of a token is stored."""
import hashlib
import secrets
import sqlite3
from datetime import datetime

from . import audit
from .clock import iso


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create(db: sqlite3.Connection, user_id: int, name: str, now: datetime) -> str:
    token = "tok_" + secrets.token_urlsafe(32)
    with db:
        db.execute(
            "INSERT INTO api_tokens (token_hash, user_id, name, created_at) VALUES (?, ?, ?, ?)",
            (_hash(token), user_id, name, iso(now)),
        )
        audit.record(db, "token_created", user_id, now)
    return token


def user_for_token(db: sqlite3.Connection, token: str) -> sqlite3.Row | None:
    return db.execute(
        "SELECT u.* FROM api_tokens t JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?",
        (_hash(token),),
    ).fetchone()
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/users.py' <<'__ACCOUNTS_EOF__'
"""User accounts."""
import re
import sqlite3
from datetime import datetime

from . import audit, passwords
from .clock import iso

USERNAME = re.compile(r"^[a-z0-9_]{3,20}$")


class UserError(ValueError):
    pass


def create_user(db: sqlite3.Connection, username: str, email: str, password: str, now: datetime) -> int:
    if not USERNAME.match(username):
        raise UserError("username must be 3-20 of a-z, 0-9, _")
    if "@" not in email:
        raise UserError("invalid email")
    if len(password) < 10:
        raise UserError("password must be at least 10 characters")
    try:
        with db:
            cur = db.execute(
                "INSERT INTO users (username, email, password_hash, created_at) VALUES (?, ?, ?, ?)",
                (username, email.lower(), passwords.hash_password(password), iso(now)),
            )
            audit.record(db, "user_created", cur.lastrowid, now)
    except sqlite3.IntegrityError:
        raise UserError("username or email already taken") from None
    return cur.lastrowid


def get_user(db: sqlite3.Connection, user_id: int) -> sqlite3.Row | None:
    return db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()


def get_by_email(db: sqlite3.Connection, email: str) -> sqlite3.Row | None:
    return db.execute("SELECT * FROM users WHERE email = ?", (email.lower(),)).fetchone()


def get_by_username(db: sqlite3.Connection, username: str) -> sqlite3.Row | None:
    return db.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/web.py' <<'__ACCOUNTS_EOF__'
"""HTTP layer. handle() takes a parsed request and returns (status, content type, body)."""
import json
import sqlite3
from typing import Callable

from . import clock, posts, sessions, tokens, users
from .config import Settings

MAX_BODY = 1 << 20
JSON = "application/json"

Response = tuple[int, str, bytes]


def reply(status: int, payload) -> Response:
    return status, JSON, json.dumps(payload).encode()


class HTTPError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class App:
    def __init__(self, db: sqlite3.Connection, settings: Settings, now: Callable = clock.utcnow):
        self.db = db
        self.settings = settings
        self.now = now

    def handle(self, method: str, path: str, headers: dict[str, str], body: bytes) -> Response:
        try:
            return self._route(method, path, {k.lower(): v for k, v in headers.items()}, body)
        except HTTPError as e:
            return reply(e.status, {"error": str(e)})

    def _json(self, body: bytes) -> dict:
        if len(body) > MAX_BODY:
            raise HTTPError(413, "body too large")
        try:
            data = json.loads(body or b"{}")
        except ValueError:
            raise HTTPError(400, "bad JSON") from None
        if not isinstance(data, dict):
            raise HTTPError(400, "expected a JSON object")
        return data

    def _user(self, headers: dict[str, str]) -> sqlite3.Row:
        auth = headers.get("authorization", "")
        if auth.startswith("Bearer "):
            user = sessions.user_for_token(self.db, auth[7:], self.now(), self.settings.session_days)
        elif "x-api-token" in headers:
            user = tokens.user_for_token(self.db, headers["x-api-token"])
        else:
            user = None
        if user is None:
            raise HTTPError(401, "sign in first")
        return user

    def _route(self, method: str, path: str, headers: dict[str, str], body: bytes) -> Response:
        parts = path.strip("/").split("/")

        if (method, path) == ("POST", "/login"):
            data = self._json(body)
            token = sessions.login(
                self.db, str(data.get("email", "")), str(data.get("password", "")),
                headers.get("x-forwarded-for", ""), self.now(),
            )
            if token is None:
                raise HTTPError(401, "wrong email or password")
            return reply(200, {"token": token})

        if (method, path) == ("POST", "/logout"):
            auth = headers.get("authorization", "")
            if auth.startswith("Bearer "):
                sessions.logout(self.db, auth[7:])
            return reply(200, {})

        if (method, path) == ("GET", "/me"):
            u = self._user(headers)
            return reply(200, {"id": u["id"], "username": u["username"], "email": u["email"],
                               "created_at": u["created_at"]})

        if (method, path) == ("POST", "/tokens"):
            u = self._user(headers)
            name = str(self._json(body).get("name", "")).strip()
            if not name:
                raise HTTPError(400, "name is required")
            return reply(201, {"token": tokens.create(self.db, u["id"], name, self.now())})

        if (method, path) == ("POST", "/posts"):
            u = self._user(headers)
            try:
                post_id = posts.create_post(self.db, u["id"], str(self._json(body).get("body", "")), self.now())
            except posts.PostError as e:
                raise HTTPError(400, str(e)) from None
            return reply(201, {"id": post_id})

        if method == "GET" and len(parts) == 2 and parts[0] == "posts" and parts[1].isdigit():
            p = posts.get_post(self.db, int(parts[1]))
            if p is None:
                raise HTTPError(404, "no such post")
            return reply(200, dict(p))

        if method == "GET" and len(parts) == 3 and parts[0] == "users" and parts[2] == "posts":
            if users.get_by_username(self.db, parts[1]) is None:
                raise HTTPError(404, "no such user")
            return reply(200, [dict(p) for p in posts.posts_by_username(self.db, parts[1])])

        raise HTTPError(404, "not found")
__ACCOUNTS_EOF__
mkdir -p 'docs'
cat > 'docs/privacy.md' <<'__ACCOUNTS_EOF__'
# What we store and why

| Data | Where | Why |
|------|-------|-----|
| Username, email, password hash, sign-up date | `users` | To run your account |
| Sign-in sessions (date, IP address) | `sessions` | To keep you signed in and show your sign-in history |
| API tokens (hashed) | `api_tokens` | For apps you connect |
| Posts | `posts` | You published them |
| Audit log (event, user id, date) | `audit_log` | Security and legal records, kept for one year |

The audit log never holds your email, password or post text, only the
event name, your user id and the date.
__ACCOUNTS_EOF__
cat > 'pyproject.toml' <<'__ACCOUNTS_EOF__'
[project]
name = "accounts"
version = "1.4.0"
requires-python = ">=3.11"
dependencies = []
__ACCOUNTS_EOF__
mkdir -p 'tests'
: > 'tests/__init__.py'
mkdir -p 'tests'
cat > 'tests/helpers.py' <<'__ACCOUNTS_EOF__'
import json
from datetime import datetime, timezone

from accounts import db, users
from accounts.config import Settings
from accounts.web import App

T0 = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
PASSWORD = "correct horse battery"


class Clock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t


def fresh_db():
    conn = db.connect(":memory:")
    db.init(conn)
    return conn


def make_user(conn, name="alice"):
    return users.create_user(conn, name, f"{name}@example.com", PASSWORD, T0)


class Client:
    def __init__(self, conn, settings=None, clock=None):
        self.clock = clock or Clock()
        self.app = App(conn, settings or Settings(db_path=":memory:"), self.clock)

    def call(self, method, path, body=None, token=None):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        raw = json.dumps(body).encode() if body is not None else b""
        status, ctype, out = self.app.handle(method, path, headers, raw)
        return status, (json.loads(out) if ctype == "application/json" else out)

    def login(self, name="alice"):
        status, out = self.call("POST", "/login", {"email": f"{name}@example.com", "password": PASSWORD})
        assert status == 200, out
        return out["token"]
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/test_sessions.py' <<'__ACCOUNTS_EOF__'
import unittest
from datetime import timedelta

from accounts import sessions
from tests.helpers import PASSWORD, T0, fresh_db, make_user


class SessionTests(unittest.TestCase):
    def test_login_and_expiry(self):
        conn = fresh_db()
        uid = make_user(conn)
        token = sessions.login(conn, "alice@example.com", PASSWORD, "10.0.0.1", T0)
        self.assertEqual(sessions.user_for_token(conn, token, T0, 30)["id"], uid)
        self.assertIsNone(sessions.user_for_token(conn, token, T0 + timedelta(days=30), 30))

    def test_wrong_password(self):
        conn = fresh_db()
        make_user(conn)
        self.assertIsNone(sessions.login(conn, "alice@example.com", "nope", "", T0))


if __name__ == "__main__":
    unittest.main()
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/test_users.py' <<'__ACCOUNTS_EOF__'
import unittest

from accounts import users
from tests.helpers import T0, fresh_db, make_user


class UserTests(unittest.TestCase):
    def test_create_and_lookup(self):
        conn = fresh_db()
        uid = make_user(conn)
        self.assertEqual(users.get_by_email(conn, "ALICE@example.com")["id"], uid)

    def test_duplicate_username(self):
        conn = fresh_db()
        make_user(conn)
        with self.assertRaises(users.UserError):
            users.create_user(conn, "alice", "other@example.com", "long enough pw", T0)

    def test_bad_username(self):
        with self.assertRaises(users.UserError):
            users.create_user(fresh_db(), "../x", "x@example.com", "long enough pw", T0)


if __name__ == "__main__":
    unittest.main()
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/test_web.py' <<'__ACCOUNTS_EOF__'
import unittest

from tests.helpers import Client, fresh_db, make_user


class WebTests(unittest.TestCase):
    def setUp(self):
        self.conn = fresh_db()
        make_user(self.conn)
        self.c = Client(self.conn)

    def test_post_flow(self):
        token = self.c.login()
        status, out = self.c.call("POST", "/posts", {"body": "hello"}, token)
        self.assertEqual(status, 201)
        status, got = self.c.call("GET", f"/posts/{out['id']}")
        self.assertEqual((status, got["body"]), (200, "hello"))
        status, lst = self.c.call("GET", "/users/alice/posts")
        self.assertEqual(len(lst), 1)

    def test_me_needs_sign_in(self):
        self.assertEqual(self.c.call("GET", "/me")[0], 401)

    def test_logout(self):
        token = self.c.login()
        self.c.call("POST", "/logout", token=token)
        self.assertEqual(self.c.call("GET", "/me", token=token)[0], 401)

    def test_body_too_large(self):
        token = self.c.login()
        status, _ = self.c.call("POST", "/posts", {"body": "x" * (1 << 20)}, token)
        self.assertEqual(status, 413)


if __name__ == "__main__":
    unittest.main()
__ACCOUNTS_EOF__

git init -q . && git config user.email dev@example.com && git config user.name dev
git add -A && git commit -qm "accounts 1.4.0"

# --- pull request ---

cat > '.gitignore' <<'__ACCOUNTS_EOF__'
__pycache__/
*.sqlite3*
exports/
__ACCOUNTS_EOF__
cat > 'CHANGELOG.md' <<'__ACCOUNTS_EOF__'
# Changelog

## 1.5.0

- Self-service account deletion with a 14-day grace period
  (`POST /account/delete`, `POST /account/delete/cancel`). Accounts whose
  grace period is over are deleted by `python -m accounts.cli purge`, run
  hourly from cron.
- Data export: `POST /account/export` writes a JSON file and returns its
  download path, `GET /account/export/<name>` downloads it.
- New settings `ACCOUNTS_DELETION_GRACE_DAYS` and `ACCOUNTS_EXPORT_DIR`.
- Upgrade: run `python -m accounts.cli init-db` once; it adds the new
  `users` columns.

## 1.4.0

- API tokens for connected apps.
__ACCOUNTS_EOF__
cat > 'README.md' <<'__ACCOUNTS_EOF__'
# accounts

User accounts, sign-in sessions, API tokens and posts for the community
site. Plain Python 3.11+ and SQLite, no third-party packages.

    python -m accounts.cli init-db      # also after every upgrade
    python -m accounts.cli create-user alice alice@example.com
    python -m unittest

Cron runs `python -m accounts.cli purge` every hour to delete accounts whose
deletion grace period is over (see docs/privacy.md).

`accounts.web.App` is the HTTP layer; the platform's WSGI adapter (not in
this repo) turns requests into `App.handle(method, path, headers, body)`.

Settings come from environment variables, see `accounts/config.py`.
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/cli.py' <<'__ACCOUNTS_EOF__'
"""Admin commands: python -m accounts.cli <command>."""
import argparse
import getpass
import sys

from . import clock, config, db, deletion, migrations, users


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="accounts")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init-db", help="create missing tables and upgrade old ones")
    sub.add_parser("purge", help="delete accounts whose grace period is over (run hourly)")
    cu = sub.add_parser("create-user")
    cu.add_argument("username")
    cu.add_argument("email")
    args = parser.parse_args(argv)

    settings = config.load()
    conn = db.connect(settings.db_path)
    if args.cmd == "init-db":
        db.init(conn)
        migrations.migrate(conn)
        print(f"schema ready in {settings.db_path}")
    elif args.cmd == "purge":
        n = deletion.purge_due(conn, settings, clock.utcnow())
        print(f"purged {n} account(s)")
    elif args.cmd == "create-user":
        try:
            uid = users.create_user(conn, args.username, args.email, getpass.getpass(), clock.utcnow())
        except users.UserError as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        print(f"created user {uid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/config.py' <<'__ACCOUNTS_EOF__'
"""Settings, read from the environment."""
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    db_path: str = "accounts.sqlite3"
    session_days: int = 30
    deletion_grace_days: int = 14
    export_dir: str = "exports"


def load() -> Settings:
    return Settings(
        db_path=os.environ.get("ACCOUNTS_DB", Settings.db_path),
        session_days=int(os.environ.get("ACCOUNTS_SESSION_DAYS", Settings.session_days)),
        deletion_grace_days=int(os.environ.get("ACCOUNTS_DELETION_GRACE_DAYS", Settings.deletion_grace_days)),
        export_dir=os.environ.get("ACCOUNTS_EXPORT_DIR", Settings.export_dir),
    )
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/deletion.py' <<'__ACCOUNTS_EOF__'
"""Self-service account deletion with a grace period (docs/privacy.md)."""
import sqlite3
from datetime import datetime, timedelta

from . import audit, export, sessions, tokens
from .clock import iso
from .config import Settings


def request(db: sqlite3.Connection, user_id: int, now: datetime) -> bool:
    """Start the grace period, sign the user out everywhere and revoke their
    API tokens. Returns False if a deletion is already pending; its date
    stays as it was."""
    with db:
        cur = db.execute(
            "UPDATE users SET status = 'pending_deletion', deletion_requested_at = ? "
            "WHERE id = ? AND status = 'active'",
            (iso(now), user_id),
        )
        if cur.rowcount == 0:
            return False
        sessions.revoke_all(db, user_id)
        tokens.revoke_all(db, user_id)
        audit.record(db, "deletion_requested", user_id, now)
    return True


def cancel(db: sqlite3.Connection, user_id: int, now: datetime) -> bool:
    """Stop a pending deletion. Returns False if none is pending."""
    with db:
        cur = db.execute(
            "UPDATE users SET status = 'active', deletion_requested_at = NULL "
            "WHERE id = ? AND status = 'pending_deletion'",
            (user_id,),
        )
        if cur.rowcount == 0:
            return False
        audit.record(db, "deletion_cancelled", user_id, now)
    return True


def purge_due(db: sqlite3.Connection, settings: Settings, now: datetime) -> int:
    """Delete every account whose grace period is over. Cron runs it hourly."""
    cutoff = iso(now - timedelta(days=settings.deletion_grace_days))
    due = db.execute(
        "SELECT id, username FROM users WHERE status = 'pending_deletion' "
        "AND deletion_requested_at >= ? ORDER BY deletion_requested_at",
        (cutoff,),
    ).fetchall()
    for row in due:
        purge_user(db, settings, row["id"], row["username"], now)
    return len(due)


def purge_user(db: sqlite3.Connection, settings: Settings, user_id: int, username: str, now: datetime) -> None:
    # Posts, sessions and API tokens go with the user row: their user_id
    # columns are ON DELETE CASCADE (schema.sql). audit_log rows stay on
    # purpose: they hold no personal data and are kept for a year
    # (docs/privacy.md).
    # The export goes first: if removing it fails, the account is still
    # pending and the next run tries again.
    export.remove_export(settings, username)
    with db:
        cur = db.execute(
            "DELETE FROM users WHERE id = ? AND status = 'pending_deletion'", (user_id,)
        )
        if cur.rowcount == 0:
            return  # cancelled since purge_due listed it
        audit.record(db, "account_purged", user_id, now)
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/export.py' <<'__ACCOUNTS_EOF__'
"""Personal data export (docs/privacy.md)."""
import json
import os
import sqlite3
import tempfile
from contextlib import suppress
from datetime import datetime
from pathlib import Path

from . import posts
from .clock import iso
from .config import Settings


def build_export(db: sqlite3.Connection, user_id: int, now: datetime) -> dict:
    user = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    sign_ins = db.execute(
        "SELECT created_at, ip FROM sessions WHERE user_id = ? ORDER BY created_at",
        (user_id,),
    ).fetchall()
    return {
        "generated_at": iso(now),
        "profile": dict(user),
        "posts": [dict(p) for p in posts.posts_by_user_id(db, user_id)],
        "sign_ins": [dict(s) for s in sign_ins],
    }


def export_path(settings: Settings, name: str) -> Path | None:
    """The file for an export name, or None if the name could point outside
    the export directory. Names are '<username>.json'; usernames are only
    a-z, 0-9 and _ (users.USERNAME)."""
    if Path(name).name != name or not name.endswith(".json"):
        return None
    return Path(settings.export_dir) / name


def write_export(db: sqlite3.Connection, settings: Settings, user: sqlite3.Row, now: datetime) -> str:
    """Write the user's export (replacing an older one) and return its name."""
    name = f"{user['username']}.json"
    folder = Path(settings.export_dir)
    folder.mkdir(parents=True, exist_ok=True)
    data = json.dumps(build_export(db, user["id"], now), indent=2).encode()
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".export-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, folder / name)
    except BaseException:
        with suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    dir_fd = os.open(folder, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
    return name


def remove_export(settings: Settings, username: str) -> None:
    """Delete the user's export file. Most users never made one, so a
    missing file is the normal case, not an error."""
    with suppress(FileNotFoundError):
        os.remove(Path(settings.export_dir) / f"{username}.json")
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/migrations.py' <<'__ACCOUNTS_EOF__'
"""Upgrades for databases made by older versions. `cli init-db` runs them."""
import sqlite3


def migrate(db: sqlite3.Connection) -> None:
    cols = {row["name"] for row in db.execute("PRAGMA table_info(users)")}
    with db:
        if "status" not in cols:
            db.execute("ALTER TABLE users ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
        if "deletion_requested_at" not in cols:
            db.execute("ALTER TABLE users ADD COLUMN deletion_requested_at TEXT")
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/posts.py' <<'__ACCOUNTS_EOF__'
"""Posts. Every post is public."""
import sqlite3
from datetime import datetime

from .clock import iso

MAX_BODY = 5000


class PostError(ValueError):
    pass


def create_post(db: sqlite3.Connection, user_id: int, body: str, now: datetime) -> int:
    body = body.strip()
    if not body or len(body) > MAX_BODY:
        raise PostError(f"post must be 1-{MAX_BODY} characters")
    with db:
        cur = db.execute(
            "INSERT INTO posts (user_id, body, created_at) VALUES (?, ?, ?)",
            (user_id, body, iso(now)),
        )
    return cur.lastrowid


def get_post(db: sqlite3.Connection, post_id: int) -> sqlite3.Row | None:
    return db.execute("SELECT id, user_id, body, created_at FROM posts WHERE id = ?", (post_id,)).fetchone()


def posts_by_user_id(db: sqlite3.Connection, user_id: int) -> list[sqlite3.Row]:
    return db.execute(
        "SELECT id, body, created_at FROM posts WHERE user_id = ? ORDER BY id", (user_id,)
    ).fetchall()


def posts_by_username(db: sqlite3.Connection, username: str) -> list[sqlite3.Row]:
    return db.execute(
        "SELECT p.id, p.body, p.created_at FROM posts p JOIN users u ON u.id = p.user_id "
        "WHERE u.username = ? ORDER BY p.id",
        (username,),
    ).fetchall()
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/schema.sql' <<'__ACCOUNTS_EOF__'
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    email         TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    -- 'active' or 'pending_deletion' (accounts/deletion.py)
    status        TEXT NOT NULL DEFAULT 'active',
    deletion_requested_at TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    ip         TEXT
);

CREATE TABLE IF NOT EXISTS api_tokens (
    token_hash TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS posts (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TEXT NOT NULL
);

-- No foreign key on user_id: audit rows outlive the account (docs/privacy.md).
CREATE TABLE IF NOT EXISTS audit_log (
    id      INTEGER PRIMARY KEY,
    at      TEXT NOT NULL,
    event   TEXT NOT NULL,
    user_id INTEGER
);
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/sessions.py' <<'__ACCOUNTS_EOF__'
"""Sign-in sessions. Only the SHA-256 of a session token is stored."""
import hashlib
import secrets
import sqlite3
from datetime import datetime, timedelta

from . import audit, passwords, users
from .clock import iso


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def login(db: sqlite3.Connection, email: str, password: str, ip: str, now: datetime) -> str | None:
    """Return a new session token, or None if the email or password is wrong
    or the account is not active."""
    user = users.get_by_email(db, email)
    if user is None or user["status"] != "active" or not passwords.verify(password, user["password_hash"]):
        return None
    token = secrets.token_urlsafe(32)
    with db:
        db.execute(
            "INSERT INTO sessions (token_hash, user_id, created_at, ip) VALUES (?, ?, ?, ?)",
            (_hash(token), user["id"], iso(now), ip),
        )
        audit.record(db, "login", user["id"], now)
    return token


def user_for_token(db: sqlite3.Connection, token: str, now: datetime, max_days: int) -> sqlite3.Row | None:
    row = db.execute(
        "SELECT u.*, s.created_at AS session_created FROM sessions s "
        "JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?",
        (_hash(token),),
    ).fetchone()
    if row is None:
        return None
    if datetime.fromisoformat(row["session_created"]) + timedelta(days=max_days) <= now:
        return None
    return row


def revoke_all(db: sqlite3.Connection, user_id: int) -> None:
    """Sign the user out everywhere. The caller commits."""
    db.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))


def logout(db: sqlite3.Connection, token: str) -> None:
    with db:
        db.execute("DELETE FROM sessions WHERE token_hash = ?", (_hash(token),))
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/tokens.py' <<'__ACCOUNTS_EOF__'
"""API tokens for connected apps. Only the SHA-256 of a token is stored."""
import hashlib
import secrets
import sqlite3
from datetime import datetime

from . import audit
from .clock import iso


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create(db: sqlite3.Connection, user_id: int, name: str, now: datetime) -> str:
    token = "tok_" + secrets.token_urlsafe(32)
    with db:
        db.execute(
            "INSERT INTO api_tokens (token_hash, user_id, name, created_at) VALUES (?, ?, ?, ?)",
            (_hash(token), user_id, name, iso(now)),
        )
        audit.record(db, "token_created", user_id, now)
    return token


def revoke_all(db: sqlite3.Connection, user_id: int) -> None:
    """Revoke every API token of the user. The caller commits."""
    db.execute("DELETE FROM api_tokens WHERE user_id = ?", (user_id,))


def user_for_token(db: sqlite3.Connection, token: str) -> sqlite3.Row | None:
    return db.execute(
        "SELECT u.* FROM api_tokens t JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?",
        (_hash(token),),
    ).fetchone()
__ACCOUNTS_EOF__
mkdir -p 'accounts'
cat > 'accounts/web.py' <<'__ACCOUNTS_EOF__'
"""HTTP layer. handle() takes a parsed request and returns (status, content type, body)."""
import json
import sqlite3
from datetime import timedelta
from typing import Callable

from . import clock, deletion, export, passwords, posts, sessions, tokens, users
from .config import Settings

MAX_BODY = 1 << 20
JSON = "application/json"

Response = tuple[int, str, bytes]


def reply(status: int, payload) -> Response:
    return status, JSON, json.dumps(payload).encode()


class HTTPError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class App:
    def __init__(self, db: sqlite3.Connection, settings: Settings, now: Callable = clock.utcnow):
        self.db = db
        self.settings = settings
        self.now = now

    def handle(self, method: str, path: str, headers: dict[str, str], body: bytes) -> Response:
        try:
            return self._route(method, path, {k.lower(): v for k, v in headers.items()}, body)
        except HTTPError as e:
            return reply(e.status, {"error": str(e)})

    def _json(self, body: bytes) -> dict:
        if len(body) > MAX_BODY:
            raise HTTPError(413, "body too large")
        try:
            data = json.loads(body or b"{}")
        except ValueError:
            raise HTTPError(400, "bad JSON") from None
        if not isinstance(data, dict):
            raise HTTPError(400, "expected a JSON object")
        return data

    def _user(self, headers: dict[str, str]) -> sqlite3.Row:
        auth = headers.get("authorization", "")
        if auth.startswith("Bearer "):
            user = sessions.user_for_token(self.db, auth[7:], self.now(), self.settings.session_days)
        elif "x-api-token" in headers:
            user = tokens.user_for_token(self.db, headers["x-api-token"])
        else:
            user = None
        if user is None:
            raise HTTPError(401, "sign in first")
        return user

    def _route(self, method: str, path: str, headers: dict[str, str], body: bytes) -> Response:
        parts = path.strip("/").split("/")

        if (method, path) == ("POST", "/login"):
            data = self._json(body)
            token = sessions.login(
                self.db, str(data.get("email", "")), str(data.get("password", "")),
                headers.get("x-forwarded-for", ""), self.now(),
            )
            if token is None:
                raise HTTPError(401, "wrong email or password")
            return reply(200, {"token": token})

        if (method, path) == ("POST", "/logout"):
            auth = headers.get("authorization", "")
            if auth.startswith("Bearer "):
                sessions.logout(self.db, auth[7:])
            return reply(200, {})

        if (method, path) == ("GET", "/me"):
            u = self._user(headers)
            return reply(200, {"id": u["id"], "username": u["username"], "email": u["email"],
                               "created_at": u["created_at"]})

        if (method, path) == ("POST", "/tokens"):
            u = self._user(headers)
            name = str(self._json(body).get("name", "")).strip()
            if not name:
                raise HTTPError(400, "name is required")
            return reply(201, {"token": tokens.create(self.db, u["id"], name, self.now())})

        if (method, path) == ("POST", "/posts"):
            u = self._user(headers)
            try:
                post_id = posts.create_post(self.db, u["id"], str(self._json(body).get("body", "")), self.now())
            except posts.PostError as e:
                raise HTTPError(400, str(e)) from None
            return reply(201, {"id": post_id})

        if method == "GET" and len(parts) == 2 and parts[0] == "posts" and parts[1].isdigit():
            p = posts.get_post(self.db, int(parts[1]))
            if p is None:
                raise HTTPError(404, "no such post")
            return reply(200, dict(p))

        if method == "GET" and len(parts) == 3 and parts[0] == "users" and parts[2] == "posts":
            if users.get_by_username(self.db, parts[1]) is None:
                raise HTTPError(404, "no such user")
            return reply(200, [dict(p) for p in posts.posts_by_username(self.db, parts[1])])

        if (method, path) == ("POST", "/account/delete"):
            u = self._user(headers)
            if not passwords.verify(str(self._json(body).get("password", "")), u["password_hash"]):
                raise HTTPError(403, "wrong password")
            now = self.now()
            if not deletion.request(self.db, u["id"], now):
                raise HTTPError(409, "deletion already requested")
            purge_after = now + timedelta(days=self.settings.deletion_grace_days)
            return reply(202, {"purge_after": clock.iso(purge_after)})

        if (method, path) == ("POST", "/account/delete/cancel"):
            u = self._user(headers)
            if not deletion.cancel(self.db, u["id"], self.now()):
                raise HTTPError(409, "no deletion pending")
            return reply(200, {})

        if (method, path) == ("POST", "/account/export"):
            u = self._user(headers)
            name = export.write_export(self.db, self.settings, u, self.now())
            return reply(201, {"download": f"/account/export/{name}"})

        if method == "GET" and len(parts) == 3 and parts[:2] == ["account", "export"]:
            self._user(headers)
            file = export.export_path(self.settings, parts[2])
            if file is None or not file.is_file():
                raise HTTPError(404, "no such export")
            return 200, JSON, file.read_bytes()

        raise HTTPError(404, "not found")
__ACCOUNTS_EOF__
mkdir -p 'docs'
cat > 'docs/privacy.md' <<'__ACCOUNTS_EOF__'
# What we store and why

| Data | Where | Why |
|------|-------|-----|
| Username, email, password hash, sign-up date | `users` | To run your account |
| Sign-in sessions (date, IP address) | `sessions` | To keep you signed in and show your sign-in history |
| API tokens (hashed) | `api_tokens` | For apps you connect |
| Posts | `posts` | You published them |
| Data exports you asked for | export folder | So you can download them |
| Audit log (event, user id, date) | `audit_log` | Security and legal records, kept for one year |

The audit log never holds your email, password or post text, only the
event name, your user id and the date.

## Deleting your account

You can ask us to delete your account (Settings, *Delete account*, then
your password). Asking signs you out on every device and revokes your API
tokens.

Nothing is deleted for 14 days, so you can change your mind: sign in again
within those 14 days and choose *Cancel deletion*. Asking again while a
deletion is pending does not change the date.

After 14 days we delete your account, your posts, your sessions, your API
tokens and any export you made. The audit log keeps its rows (event, user
id, date) for one year, as described above.

## Exporting your data

You can download a copy of your data as a JSON file (Settings, *Export my
data*). It holds your profile (username, email, sign-up date), your posts
and your sign-in history (dates and IP addresses). It never holds your
password hash or any token. Only you can download your export.
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/helpers.py' <<'__ACCOUNTS_EOF__'
import json
from datetime import datetime, timezone

from accounts import db, users
from accounts.config import Settings
from accounts.web import App

T0 = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
PASSWORD = "correct horse battery"


class Clock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t


def settings(export_dir):
    return Settings(db_path=":memory:", export_dir=str(export_dir))


def fresh_db():
    conn = db.connect(":memory:")
    db.init(conn)
    return conn


def make_user(conn, name="alice"):
    return users.create_user(conn, name, f"{name}@example.com", PASSWORD, T0)


class Client:
    def __init__(self, conn, settings=None, clock=None):
        self.clock = clock or Clock()
        self.app = App(conn, settings or Settings(db_path=":memory:"), self.clock)

    def call(self, method, path, body=None, token=None):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        raw = json.dumps(body).encode() if body is not None else b""
        status, ctype, out = self.app.handle(method, path, headers, raw)
        return status, (json.loads(out) if ctype == "application/json" else out)

    def login(self, name="alice"):
        status, out = self.call("POST", "/login", {"email": f"{name}@example.com", "password": PASSWORD})
        assert status == 200, out
        return out["token"]
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/test_deletion.py' <<'__ACCOUNTS_EOF__'
import tempfile
import unittest
from datetime import timedelta

from accounts import deletion, sessions, tokens, users
from tests.helpers import PASSWORD, T0, fresh_db, make_user, settings


class DeletionTests(unittest.TestCase):
    def setUp(self):
        self.conn = fresh_db()
        self.uid = make_user(self.conn)
        self.tmp = tempfile.TemporaryDirectory()
        self.settings = settings(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_request_signs_out_everywhere(self):
        token = sessions.login(self.conn, "alice@example.com", PASSWORD, "", T0)
        api = tokens.create(self.conn, self.uid, "phone", T0)
        self.assertTrue(deletion.request(self.conn, self.uid, T0))
        self.assertIsNone(sessions.user_for_token(self.conn, token, T0, 30))
        self.assertIsNone(tokens.user_for_token(self.conn, api))
        self.assertEqual(users.get_user(self.conn, self.uid)["status"], "pending_deletion")

    def test_second_request_keeps_first_date(self):
        deletion.request(self.conn, self.uid, T0)
        self.assertFalse(deletion.request(self.conn, self.uid, T0 + timedelta(days=3)))
        self.assertEqual(users.get_user(self.conn, self.uid)["deletion_requested_at"], "2026-03-01T12:00:00+00:00")

    def test_cancel(self):
        deletion.request(self.conn, self.uid, T0)
        self.assertTrue(deletion.cancel(self.conn, self.uid, T0))
        user = users.get_user(self.conn, self.uid)
        self.assertEqual((user["status"], user["deletion_requested_at"]), ("active", None))
        self.assertFalse(deletion.cancel(self.conn, self.uid, T0))

    def test_purge_user(self):
        deletion.request(self.conn, self.uid, T0)
        deletion.purge_user(self.conn, self.settings, self.uid, "alice", T0 + timedelta(days=14))
        self.assertIsNone(users.get_user(self.conn, self.uid))
        events = [r["event"] for r in self.conn.execute("SELECT event FROM audit_log WHERE user_id = ?", (self.uid,))]
        self.assertEqual(events[-1], "account_purged")

    def test_purge_leaves_active_accounts(self):
        self.assertEqual(deletion.purge_due(self.conn, self.settings, T0 + timedelta(days=30)), 0)
        self.assertIsNotNone(users.get_user(self.conn, self.uid))


if __name__ == "__main__":
    unittest.main()
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/test_export.py' <<'__ACCOUNTS_EOF__'
import json
import tempfile
import unittest
from pathlib import Path

from accounts import export, posts, sessions, users
from tests.helpers import PASSWORD, T0, fresh_db, make_user, settings


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.conn = fresh_db()
        self.uid = make_user(self.conn)
        self.tmp = tempfile.TemporaryDirectory()
        self.settings = settings(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_build_export(self):
        posts.create_post(self.conn, self.uid, "first", T0)
        sessions.login(self.conn, "alice@example.com", PASSWORD, "10.0.0.9", T0)
        data = export.build_export(self.conn, self.uid, T0)
        self.assertEqual(data["profile"]["username"], "alice")
        self.assertEqual([p["body"] for p in data["posts"]], ["first"])
        self.assertEqual(data["sign_ins"][0]["ip"], "10.0.0.9")

    def test_write_and_remove(self):
        name = export.write_export(self.conn, self.settings, users.get_user(self.conn, self.uid), T0)
        path = Path(self.tmp.name) / name
        self.assertEqual(json.loads(path.read_text())["profile"]["email"], "alice@example.com")
        export.remove_export(self.settings, "alice")
        self.assertFalse(path.exists())
        export.remove_export(self.settings, "alice")  # no export left: still fine

    def test_export_path_stays_in_folder(self):
        for bad in ["../alice.json", "a/b.json", "/etc/passwd", "..", "alice.txt", ""]:
            self.assertIsNone(export.export_path(self.settings, bad), bad)
        self.assertEqual(export.export_path(self.settings, "alice.json"), Path(self.tmp.name) / "alice.json")


if __name__ == "__main__":
    unittest.main()
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/test_sessions.py' <<'__ACCOUNTS_EOF__'
import unittest
from datetime import timedelta

from accounts import deletion, sessions
from tests.helpers import PASSWORD, T0, fresh_db, make_user


class SessionTests(unittest.TestCase):
    def test_login_and_expiry(self):
        conn = fresh_db()
        uid = make_user(conn)
        token = sessions.login(conn, "alice@example.com", PASSWORD, "10.0.0.1", T0)
        self.assertEqual(sessions.user_for_token(conn, token, T0, 30)["id"], uid)
        self.assertIsNone(sessions.user_for_token(conn, token, T0 + timedelta(days=30), 30))

    def test_login_refused_while_deletion_pending(self):
        conn = fresh_db()
        uid = make_user(conn)
        deletion.request(conn, uid, T0)
        self.assertIsNone(sessions.login(conn, "alice@example.com", PASSWORD, "", T0))

    def test_wrong_password(self):
        conn = fresh_db()
        make_user(conn)
        self.assertIsNone(sessions.login(conn, "alice@example.com", "nope", "", T0))


if __name__ == "__main__":
    unittest.main()
__ACCOUNTS_EOF__
mkdir -p 'tests'
cat > 'tests/test_web.py' <<'__ACCOUNTS_EOF__'
import tempfile
import unittest

from tests.helpers import PASSWORD, Client, fresh_db, make_user, settings


class WebTests(unittest.TestCase):
    def setUp(self):
        self.conn = fresh_db()
        make_user(self.conn)
        self.tmp = tempfile.TemporaryDirectory()
        self.c = Client(self.conn, settings(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_post_flow(self):
        token = self.c.login()
        status, out = self.c.call("POST", "/posts", {"body": "hello"}, token)
        self.assertEqual(status, 201)
        status, got = self.c.call("GET", f"/posts/{out['id']}")
        self.assertEqual((status, got["body"]), (200, "hello"))
        status, lst = self.c.call("GET", "/users/alice/posts")
        self.assertEqual(len(lst), 1)

    def test_me_needs_sign_in(self):
        self.assertEqual(self.c.call("GET", "/me")[0], 401)

    def test_logout(self):
        token = self.c.login()
        self.c.call("POST", "/logout", token=token)
        self.assertEqual(self.c.call("GET", "/me", token=token)[0], 401)

    def test_body_too_large(self):
        token = self.c.login()
        status, _ = self.c.call("POST", "/posts", {"body": "x" * (1 << 20)}, token)
        self.assertEqual(status, 413)

    def test_delete_needs_password(self):
        token = self.c.login()
        self.assertEqual(self.c.call("POST", "/account/delete", {"password": "nope"}, token)[0], 403)
        status, out = self.c.call("POST", "/account/delete", {"password": PASSWORD}, token)
        self.assertEqual((status, out["purge_after"]), (202, "2026-03-15T12:00:00+00:00"))
        self.assertEqual(self.c.call("GET", "/me", token=token)[0], 401)

    def test_export_download(self):
        token = self.c.login()
        status, out = self.c.call("POST", "/account/export", token=token)
        self.assertEqual(status, 201)
        status, raw = self.c.call("GET", out["download"], token=token)
        self.assertEqual(status, 200)
        self.assertEqual(raw["profile"]["username"], "alice")
        self.assertEqual(self.c.call("GET", out["download"])[0], 401)
        self.assertEqual(self.c.call("GET", "/account/export/..", token=token)[0], 404)


if __name__ == "__main__":
    unittest.main()
__ACCOUNTS_EOF__

git add -A && git commit -qm "Account deletion with a grace period, and data export"
git diff HEAD~1 HEAD > pr.diff
