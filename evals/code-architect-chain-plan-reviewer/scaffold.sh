#!/usr/bin/env bash
set -euo pipefail
mkdir -p src/domain src/api

cat > src/domain/credit_ledger.py <<'EOF'
class CreditLedger:
    def add_credit(self, user_id, amount, reason: str) -> None:
        ...
EOF

cat > src/domain/user.py <<'EOF'
class User:
    def __init__(self, id, email, referred_by=None):
        self.id = id
        self.email = email
        self.referred_by = referred_by
EOF

cat > src/api/signup_routes.py <<'EOF'
from src.domain.user import User


def handle_signup(email: str, referral_code=None) -> User:
    user = User(id=_generate_id(), email=email, referred_by=referral_code)
    _save_user(user)
    return user


def _generate_id():
    ...


def _save_user(user):
    ...
EOF
