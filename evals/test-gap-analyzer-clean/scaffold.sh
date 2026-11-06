#!/usr/bin/env bash
mkdir -p src
cat > src/discount.py <<'FIXTURE_EOF'
def apply_discount(price_cents: int, pct: int) -> int:
    """Return `price_cents` less `pct` percent, rounded half-up to a whole cent."""
    if pct < 0 or pct > 100:
        raise ValueError("pct must be within 0..100")
    if price_cents < 0:
        raise ValueError("price must be non-negative")
    return (price_cents * (100 - pct) + 50) // 100
FIXTURE_EOF
mkdir -p tests
: > tests/__init__.py
cat > tests/test_discount.py <<'FIXTURE_EOF'
import pytest

from src.discount import apply_discount


def test_ten_percent_off():
    assert apply_discount(1000, 10) == 900


def test_pct_boundaries_zero_and_full():
    assert apply_discount(1000, 0) == 1000
    assert apply_discount(1000, 100) == 0


@pytest.mark.parametrize("pct", [-1, 101])
def test_out_of_range_pct_raises(pct):
    with pytest.raises(ValueError, match="pct"):
        apply_discount(1000, pct)


def test_negative_price_raises():
    with pytest.raises(ValueError, match="price"):
        apply_discount(-1, 10)


def test_zero_price_is_allowed():
    assert apply_discount(0, 50) == 0


@pytest.mark.parametrize(
    ("price_cents", "pct", "expected"),
    [
        (5, 50, 3),     # 2.5 -> 3: a tie rounds up (round() would give 2)
        (15, 50, 8),    # 7.5 -> 8: a tie rounds up
        (1, 10, 1),     # 0.9 -> 1 (floor would give 0)
        (49, 99, 0),    # 0.49 -> 0: just under half rounds down
        (999, 5, 949),  # 949.05 -> 949 (ceil would give 950)
    ],
)
def test_rounds_half_up_to_whole_cent(price_cents, pct, expected):
    assert apply_discount(price_cents, pct) == expected


def test_large_price_stays_exact():
    # 2**53 + 1 has no exact float, so float division would return 2**53.
    assert apply_discount(2**53 + 1, 0) == 2**53 + 1
FIXTURE_EOF
