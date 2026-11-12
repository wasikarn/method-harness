---
type: regex
target: trace
pattern: 'renameSync|\.rename\(|write-file-atomic'
---
`src/tray.js` runs as a separate process and calls `loadSettings()` on every change event, and
`loadSettings()` throws on malformed JSON. A plain `fs.writeFileSync(FILE, ...)` truncates the file
first, so the tray can read an empty or half-written file and crash. The scaffold never renames a
file, so a match comes from the subject's own code.

Score 1: the trace shows the save writing to a temp file and moving it over `settings.json`
(`fs.renameSync` / `fs.rename` / `fs.promises.rename`), or using `write-file-atomic`.

Score 0: the save writes `settings.json` in place (`fs.writeFileSync(FILE, ...)` or
`fs.writeFile(FILE, ...)`) with no rename step.
