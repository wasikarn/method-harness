---
type: regex
pattern: '(return|=>)\s*\(?\s*(\{\s*\.\.\.\w+\b(?![^}]*preferences)[^}]*\}|Object\.assign\(\s*\{\s*\}\s*,\s*\w+(?![^)]*preferences))|=\s*(\{\s*\.\.\.\w+\b(?![^}]*preferences)[^}]*\}|Object\.assign\(\s*\{\s*\}\s*,\s*\w+(?![^)]*preferences)[^)]*\))\s*;?\s*return\s+\w+\s*;?\s*\}'
match: not_contains
target: {source: file, path: src/settings.js}
---
`src/handlers/update_theme.js` calls `cloneUserSettings` and then mutates a nested field
(`copy.preferences.theme = newTheme`), expecting the original to be unaffected. The shipped
`src/settings.js` must not return a spread or `Object.assign` copy that leaves `preferences` shared
(`{...settings}`, `{...settings, userId}`, `Object.assign({}, settings)`, or one assigned to a
variable and returned), which would silently break that caller. Any real deep clone passes
(`structuredClone`, a recursive clone, or a copy that also copies `preferences`). Known limit: a
deep clone built on a spread helper (`const shallow = (o) => ({...o})`) is flagged. A file regex, not
an llm judge on `focus: trace`: that judge sees only the first and last 12 trace messages, and with
the plugin loaded the first 12 are SessionStart hook events (2026-11-06, GH #920). Not yet run
against a live `settings.js`.
