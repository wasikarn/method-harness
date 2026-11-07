#!/usr/bin/env bash
set -euo pipefail
mkdir -p src tests

cat > package.json <<'EOF'
{
  "name": "shop",
  "version": "1.0.0",
  "private": true,
  "scripts": { "test": "node --test tests/" }
}
EOF

cat > src/discount.js <<'EOF'
// Promotion: 10% off orders of 100 baht or more.
function applyDiscount(total) {
  if (total > 100) {
    return Math.round(total * 0.9 * 100) / 100;
  }
  return total;
}

module.exports = { applyDiscount };
EOF

cat > tests/discount.test.js <<'EOF'
const test = require('node:test');
const assert = require('node:assert');
const { applyDiscount } = require('../src/discount');

test('small orders pay full price', () => {
  assert.strictEqual(applyDiscount(50), 50);
});

test('large orders get 10% off', () => {
  assert.strictEqual(applyDiscount(150), 135);
});
EOF

git init -q
git add -A
git -c user.email=eval@example.com -c user.name=eval commit -q -m "shop: discount promotion"
