---
type: regex
pattern: 'return\s*\{\s*\.\.\.\w+\s*,?\s*\}|return\s*Object\.assign\(\s*\{\s*\}\s*,\s*\w+\s*\)|=>\s*\(\s*\{\s*\.\.\.\w+\s*,?\s*\}\s*\)|=>\s*Object\.assign\(\s*\{\s*\}\s*,\s*\w+\s*\)'
match: not_contains
target: {source: file, path: src/settings.js}
arm: both
---
`src/handlers/update_theme.js` calls `cloneUserSettings` and then mutates a nested field
(`copy.preferences.theme = newTheme`), expecting the original to be unaffected. The shipped
`src/settings.js` must not return a plain top-level shallow copy (`{...settings}`,
`Object.assign({}, settings)`), which would silently break that caller. Any real deep clone passes
(`structuredClone`, a recursive clone, or a copy that also copies `preferences`). A file regex, not
an llm judge on `focus: trace`: that judge sees only the first and last 12 trace messages, and with
the plugin loaded the first 12 are SessionStart hook events (2026-11-06, GH #920).
