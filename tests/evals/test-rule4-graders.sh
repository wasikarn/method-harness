#!/usr/bin/env bash
# test-rule4-graders.sh: the rule4-* cases' file graders accept the common correct fix shapes
# and reject wrong ones. A correct fix must not score 0 because of how it is written (an early
# return, `100 <= total`, a parameterized test), and an unfixed or still-exclusive bound must not
# pass. Known misses are listed in each grader's note, not here. Patterns are run through
# `new RegExp`, the call the eval runtime makes (see test-eval-cases.sh header), against the
# scaffold's own files with one line swapped in. The two cases' graders must stay byte-identical.
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

const CASES = ['rule4-bugfix-test-first', 'rule4-bugfix-terse-th'];
// Mirrors test-eval-cases.sh's single-quoted pattern decode and passes `flags:` on, as the runtime does.
function grader(dir, name) {
  const fm = fs.readFileSync(path.join(dir, 'graders', name), 'utf8').split('\n---\n')[0];
  const m = fm.match(/^pattern: '(.*)'$/m);
  if (!m) throw new Error(`${dir}/graders/${name}: no single-quoted pattern`);
  const flags = (fm.match(/^flags: (\w+)$/m) || [, ''])[1];
  const not = /^match: not_contains$/m.test(fm);
  return text => new RegExp(m[1].replace(/''/g, "'"), flags).test(text) !== not;
}
// A src/discount.js with the scaffold's comment and one body line; D is the discounted total.
const D = 'Math.round(total * 0.9 * 100) / 100';
const src = body => `// Promotion: 10% off orders of 100 baht or more.\nfunction applyDiscount(total) {\n  ${body.replace(/\bD\b/g, D)}\n}\n`;
const goodSrc = [
  'if (total >= 100) { return D; } return total;',
  'if (total < 100) return total; return D;',
  'if (100 <= total) { return D; } return total;',
  'if (100 > total) { return total; } return D;',
  'return total >= 100.0 ? D : total;',
];
const badSrc = [
  'if (total > 100) { return D; } return total;',
  'if (total <= 100) return total; return D;',
  'if (100 >= total) return total; return D;',
  'if (total > 100.0) { return D; } return total;',
  'if (total >= 1000) { return D; } return total;',
  'if (1100 <= total) { return D; } return total;',
  'if (total >= 100e1) { return D; } return total;',
  // The old bound left in place, in either operand order, fails old-bound-gone on purpose.
  'if (total > 100 || total >= 100) { return D; } return total;',
  'if (100 < total) { return D; } return total;',
  'if (100 < total || total >= 100) { return D; } return total;',
];
const head = "const test = require('node:test');\nconst assert = require('node:assert');\nconst { applyDiscount } = require('../src/discount');\n";
const goodTests = [
  "test('exactly 100 gets 10% off', () => { assert.strictEqual(applyDiscount(100), 90); });\n",
  "for (const [total, want] of [[50, 50], [100, 90], [150, 135]]) {\n  test(`${total}`, () => assert.strictEqual(applyDiscount(total), want));\n}\n",
];

for (const c of CASES) {
  const dir = path.join(evals, c);
  const fixed = grader(dir, 'bug-fixed.md'), gone = grader(dir, 'old-bound-gone.md');
  const reg = grader(dir, 'regression-test.md');
  for (const s of goodSrc) (fixed(src(s)) && gone(src(s)) ? ok : bad)(`${c}: correct fix passes: ${s}`);
  for (const s of badSrc) (!(fixed(src(s)) && gone(src(s))) ? ok : bad)(`${c}: wrong or old-bound-kept fix fails: ${s}`);
  for (const t of goodTests) (reg(head + t) ? ok : bad)(`${c}: regression test found: ${t.slice(0, 40)}`);
  const scaffold = fs.readFileSync(path.join(dir, 'scaffold.sh'), 'utf8').match(/discount\.test\.js <<'EOF'\n([\s\S]*?)\nEOF/)[1];
  (!reg(scaffold) ? ok : bad)(`${c}: the scaffold's own tests are not a regression test`);
}
const lists = CASES.map(c => fs.readdirSync(path.join(evals, c, 'graders')).sort());
(lists[0].join() === lists[1].join() ? ok : bad)(`both rule4 cases have the same grader files (${lists.map(l => l.length).join(' vs ')})`);
for (const f of lists[0].filter(f => lists[1].includes(f))) {
  const [a, b] = CASES.map(c => fs.readFileSync(path.join(evals, c, 'graders', f), 'utf8'));
  (a === b ? ok : bad)(`graders/${f} is identical in both rule4 cases`);
}
console.log(`test-rule4-graders: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
JS
