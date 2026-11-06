#!/usr/bin/env bash
mkdir -p src
cat > src/money.ts <<'FIXTURE_EOF'
export const CURRENCIES = Object.freeze(["USD", "EUR", "THB"] as const);
export type CurrencyCode = (typeof CURRENCIES)[number];

/**
 * An immutable amount in integer minor units of its currency (cents for USD and EUR, satang
 * for THB; all three have 2 decimal places). Negative amounts are allowed: they are refunds
 * or debts. Amounts stay within Number.MAX_SAFE_INTEGER, so all arithmetic is exact.
 */
export class Money {
  readonly minorUnits: number;
  readonly currency: CurrencyCode;

  // Every instance, from `of` or from arithmetic, passes these checks.
  private constructor(minorUnits: number, currency: CurrencyCode) {
    if (!Number.isSafeInteger(minorUnits)) {
      throw new RangeError(`minorUnits must be a safe integer, got ${minorUnits}`);
    }
    if (!CURRENCIES.includes(currency)) {
      throw new TypeError(`unknown currency: ${String(currency)}`);
    }
    this.minorUnits = minorUnits + 0; // turns -0 into 0
    this.currency = currency;
    Object.freeze(this);
  }

  static of(minorUnits: number, currency: CurrencyCode): Money {
    return new Money(minorUnits, currency);
  }

  add(other: Money): Money {
    this.assertSameCurrency(other);
    return new Money(this.minorUnits + other.minorUnits, this.currency);
  }

  subtract(other: Money): Money {
    this.assertSameCurrency(other);
    return new Money(this.minorUnits - other.minorUnits, this.currency);
  }

  equals(other: Money): boolean {
    return this.currency === other.currency && this.minorUnits === other.minorUnits;
  }

  private assertSameCurrency(other: Money): void {
    if (other.currency !== this.currency) {
      throw new TypeError(`currency mismatch: ${this.currency} vs ${other.currency}`);
    }
  }
}
FIXTURE_EOF
