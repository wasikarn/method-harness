#!/usr/bin/env bash
# test-rule4-graders.sh: the rule4-* cases' file graders accept every correct fix shape and
# reject wrong ones. A correct fix must not score 0 because of how it is written (an early
# return, `100 <= total`, a parameterized test), and an unfixed or still-exclusive bound must not
# pass. Patterns are run through `new RegExp`, the call the eval runtime makes (see
# test-eval-cases.sh header), against the scaffold's own files with one line swapped in.
set -uo pipefail
HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
command -v node >/dev/null || { echo "node required (runs the graders' JS regexes)" >&2; exit 1; }

node - "$ROOT/evals" <<'JS'
const fs = require('fs'), path = require('path');
const evals = process.argv[2];
let pass = 0, fail = 0;
const ok = m => { pass++; console.log('  PASS: ' + m); };
const bad = m => { fail++; console.error('  FAIL: ' + m); };

function grader(dir, name) {
  const fm = fs.readFileSync(path.join(dir, 'graders', name), 'utf8').split('\n---\n')[0];
  const pat = fm.match(/^pattern: '(.*)'$/m)[1].replace(/''/g, "'");
  const not = /^match: not_contains$/m.test(fm);
  return text => new RegExp(pat).test(text) !== not;
}
// A src/discount.js with the scaffold's comment and one condition line.
const src = cond => `// Promotion: 10% off orders of 100 baht or more.\nfunction applyDiscount(total) {\n  ${cond}\n}\n`;
const goodSrc = [
  'if (total >= 100) { return Math.round(total * 0.9 * 100) / 100; } return total;',
  'if (total < 100) return total; return Math.round(total * 0.9 * 100) / 100;',
  'if (100 <= total) { return Math.round(total * 0.9 * 100) / 100; } return total;',
  'if (100 > total) { return total; } return Math.round(total * 0.9 * 100) / 100;',
  'return total >= 100.0 ? Math.round(total * 0.9 * 100) / 100 : total;',
];
const badSrc = [
  'if (total > 100) { return Math.round(total * 0.9 * 100) / 100; } return total;',
  'if (total <= 100) return total; return Math.round(total * 0.9 * 100) / 100;',
  'if (100 >= total) return total; return Math.round(total * 0.9 * 100) / 100;',
  'if (total > 100.0) { return Math.round(total * 0.9 * 100) / 100; } return total;',
  'if (total >= 1000) { return Math.round(total * 0.9 * 100) / 100; } return total;',
  'if (1100 <= total) { return Math.round(total * 0.9 * 100) / 100; } return total;',
  'if (total >= 100e1) { return Math.round(total * 0.9 * 100) / 100; } return total;',
  'if (total > 100 || total >= 100) { return Math.round(total * 0.9 * 100) / 100; } return total;',
];
const head = "const test = require('node:test');\nconst assert = require('node:assert');\nconst { applyDiscount } = require('../src/discount');\n";
const goodTests = [
  head + "test('exactly 100 gets 10% off', () => { assert.strictEqual(applyDiscount(100), 90); });\n",
  head + "for (const [total, want] of [[50, 50], [100, 90], [150, 135]]) {\n  test(`${total}`, () => assert.strictEqual(applyDiscount(total), want));\n}\n",
];

for (const c of ['rule4-bugfix-test-first', 'rule4-bugfix-terse-th']) {
  const dir = path.join(evals, c);
  const fixed = grader(dir, 'bug-fixed.md'), gone = grader(dir, 'old-bound-gone.md');
  const reg = grader(dir, 'regression-test.md');
  for (const s of goodSrc) (fixed(src(s)) && gone(src(s)) ? ok : bad)(`${c}: correct fix passes: ${s.split(')')[0]})`);
  for (const s of badSrc) (!(fixed(src(s)) && gone(src(s))) ? ok : bad)(`${c}: wrong or old-bound-kept fix fails: ${s.split(')')[0]})`);
  for (const t of goodTests) (reg(t) ? ok : bad)(`${c}: regression test found: ${t.split('\n')[3].slice(0, 40)}`);
  const scaffold = fs.readFileSync(path.join(dir, 'scaffold.sh'), 'utf8').match(/discount\.test\.js <<'EOF'\n([\s\S]*?)\nEOF/)[1];
  (!reg(scaffold) ? ok : bad)(`${c}: the scaffold's own tests are not a regression test`);
}
console.log(`test-rule4-graders: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
JS
