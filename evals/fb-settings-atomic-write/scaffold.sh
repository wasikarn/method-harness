#!/usr/bin/env bash
# Node desktop-app settings module. A separate tray process watches the settings file's directory and
# re-reads it on every change; loadSettings() throws on malformed JSON, so a reader that catches a
# half-written file crashes the tray helper.
set -euo pipefail
G=/opt/homebrew/bin/git; [ -x "$G" ] || G=$(command -v git)

mkdir -p src test

cat > package.json <<'EOF'
{
  "name": "prefs-app",
  "version": "0.4.2",
  "private": true,
  "scripts": {
    "test": "node --test test/"
  }
}
EOF

cat > src/settings.js <<'EOF'
const fs = require("fs");
const path = require("path");

const FILE = process.env.APP_SETTINGS || path.join(__dirname, "..", "settings.json");
const DEFAULTS = { theme: "light", notifications: true, syncIntervalSec: 300 };

function loadSettings() {
  let raw;
  try {
    raw = fs.readFileSync(FILE, "utf8");
  } catch (err) {
    if (err.code === "ENOENT") return { ...DEFAULTS };
    throw err;
  }
  return { ...DEFAULTS, ...JSON.parse(raw) };
}

module.exports = { FILE, DEFAULTS, loadSettings };
EOF

cat > src/tray.js <<'EOF'
// Tray helper. Runs as its own long-lived process next to the main window and re-applies
// settings whenever settings.json changes on disk.
const fs = require("fs");
const path = require("path");
const { FILE, loadSettings } = require("./settings");

function applyTray(settings) {
  console.log(`tray: theme=${settings.theme} notifications=${settings.notifications}`);
}

applyTray(loadSettings());
fs.watch(path.dirname(FILE), (event, name) => {
  if (name === path.basename(FILE)) applyTray(loadSettings());
});
EOF

cat > test/settings.test.js <<'EOF'
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "prefs-"));
process.env.APP_SETTINGS = path.join(dir, "settings.json");
const { loadSettings, DEFAULTS } = require("../src/settings");

test("defaults when the file is missing", () => {
  assert.deepStrictEqual(loadSettings(), DEFAULTS);
});

test("file values override defaults", () => {
  fs.writeFileSync(process.env.APP_SETTINGS, JSON.stringify({ theme: "dark" }));
  assert.strictEqual(loadSettings().theme, "dark");
  assert.strictEqual(loadSettings().notifications, true);
});
EOF

cat > README.md <<'EOF'
# prefs-app

Settings live in `settings.json` (override the path with `APP_SETTINGS`). The main window and the
tray helper (`src/tray.js`, its own process) both read it. Tests: `npm test`.
EOF

$G init -q
$G add -- package.json src/settings.js src/tray.js test/settings.test.js README.md
$G -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -qm "settings loader and tray helper"
