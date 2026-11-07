import type { EngineInterface, Register } from 'claude-code'

// mh's one hooks module (GH #323, #334): an observer that records Claude Code's own cost ledger
// ($.session.usage().cost.usd, what /cost totals) after each main-loop turn, so cost-report can
// cross-check the transcript-priced costs.jsonl against it. It also writes one load-proof row per
// module load (#444) and, in an mh checkout, shows whether the cached copy matches the repo
// (#442). Reference: docs/reference/cost-ledger-module.md.
//
// Observer only: it never denies, asks, rewrites or answers for core. Every step sits in one
// try/catch and the hook always ends in `next(e)`, so a failure here costs one row, never the turn.
// The engine also skips a hook that throws, but this one does not rely on that.
//
// $.fs has no append, so a one-line `sh` appends the row (dotfiles effort-log's pattern); $HOME
// expands inside that shell, and `${HOME:?}` makes an unset HOME fail instead of writing under `/`.
const APPEND =
  ': "${HOME:?HOME unset}"; d="$HOME/.local/share/kbg/metrics"; mkdir -p "$d" && printf "%s\\n" "$@" >> "$d/cost-ledger.jsonl"'

// The ledger only grows inside one process. A drop means a new process took over the session id
// and started its ledger from zero, so everything it shows is new spend. The report applies the
// same rule to the file's `usd` sequence (skills/meta/cost-report/scripts/cost-report-dedup.js).
export const ledgerDelta = (prev: number | undefined, usd: number) =>
  prev === undefined || usd >= prev
    ? { delta: usd - (prev ?? 0), reset: false }
    : { delta: usd, reset: true }

// ponytail: the baseline is a module variable, so a reload (/reload-plugins, a settings change)
// restarts it and that load's first row reads `delta == usd`. The report recomputes from `usd`,
// so totals stay right; move it to $.state (needs a types contract in plugin.json) if per-row
// deltas start to matter.
let prev: number | undefined

const append = async ($: EngineInterface, row: string) => {
  try {
    const r = await $.process.run(['sh', '-c', APPEND, 'sh', row], { timeoutMs: 2000 })
    if (r.exitCode === 0) return true
    $.ui.log(`cost-ledger append exited ${r.exitCode}: ${r.stderr.trim().slice(0, 200)}`)
  } catch (err) {
    $.ui.log(`cost-ledger append failed: ${String(err).slice(0, 200)}`)
  }
  return false
}

type Manifest = { name?: string; version?: string; skills?: string[] }
const readText = async ($: EngineInterface, path: string): Promise<string | undefined> => {
  try {
    return await $.fs.read(path)
  } catch {
    return undefined
  }
}
const readManifest = async ($: EngineInterface, root: string): Promise<Manifest | undefined> => {
  try {
    return JSON.parse((await readText($, `${root}/.claude-plugin/plugin.json`)) ?? '')
  } catch {
    return undefined
  }
}
// The session's project root and its manifest, when it is a checkout of this plugin (an mh repo
// or worktree); undefined anywhere else.
const mhRepo = async ($: EngineInterface) => {
  const root = await $.session.root()
  const manifest = await readManifest($, root)
  return manifest?.name === $.plugin.name ? { root, manifest } : undefined
}

// GH #444: one load-proof row per module load and session id, from whichever hook runs first, so a
// session with modules off (no row) reads apart from one where the module loaded and stayed idle.
// /clear gives the same process a new session id, so the guard is per id, not once per load. A
// reload writes another; the report counts sessions, not rows.
let markedFor: string | undefined
const markLoaded = async ($: EngineInterface) => {
  try {
    const session = await $.session.id()
    if (markedFor === session) return
    markedFor = session
    const [cli, mh] = await Promise.all([
      $.session.version().then(v => v.version, () => undefined),
      readManifest($, $.plugin.root).then(m => m?.version),
    ])
    // append reports a failed write by returning false, not by throwing: unmark so the next call retries
    if (!(await append($, JSON.stringify({ t: new Date().toISOString(), session_id: session, loaded: true, cli, mh })))) markedFor = undefined
  } catch (err) {
    $.ui.log(`cost-ledger load marker failed: ${String(err).slice(0, 200)}`)
  }
}

// Dotted versions compared part by part as numbers: '1.1.99' is older than '1.1.174'.
const olderThan = (a: string, b: string) => {
  const x = a.split('.').map(Number), y = b.split('.').map(Number)
  for (let i = 0; i < Math.max(x.length, y.length); i++)
    if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0)
  return false
}

// GH #442: skills whose repo SKILL.md differs from the cached copy that runs, toasted once each.
const toasted = new Set<string>()

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await markLoaded($)
    try {
      const repo = (await mhRepo($))?.manifest
      const cache = repo?.version ? await readManifest($, $.plugin.root) : undefined
      if (cache?.version && repo?.version)
        // GH #458: the engine styles every plugin status line as a warning, so only a stale cache
        // speaks; a match clears any earlier line (the ledger's load row proves the load).
        // GH #934: only a repo ahead of the cache is stale; an older branch checked out is not.
        $.ui.status(
          olderThan(cache.version, repo.version)
            ? `${$.plugin.name}: cache ${cache.version} is stale, repo ${repo.version} (bump + claude plugin update)`
            : undefined,
        )
    } catch (err) {
      $.ui.log(`cost-ledger version status failed: ${String(err).slice(0, 200)}`)
    }
    return next(e)
  })

  on('skill.prompt', async ($, e, next) => {
    await markLoaded($)
    try {
      const name = e.skill.split(':').pop() ?? ''
      const root = name && !toasted.has(name) ? (await mhRepo($))?.root : undefined
      if (root) {
        // plugin.json's `skills` lists parent folders (./skills/meta/) and skill folders alike.
        const dirs = ((await readManifest($, $.plugin.root))?.skills ?? []).map(d => d.replace(/^\.\//, '').replace(/\/$/, ''))
        const rels = dirs.flatMap(d => [`${d}/${name}/SKILL.md`, ...(d.split('/').pop() === name ? [`${d}/SKILL.md`] : [])])
        for (const rel of rels) {
          const cached = await readText($, `${$.plugin.root}/${rel}`)
          if (cached === undefined) continue
          const current = await readText($, `${root}/${rel}`)
          if (current !== undefined && current !== cached) {
            toasted.add(name)
            $.ui.toast(`${name}: the cached copy runs; repo ${rel} differs (bump + claude plugin update)`, { timeoutMs: 8000 })
          }
          break
        }
      }
    } catch (err) {
      $.ui.log(`cost-ledger skill check failed: ${String(err).slice(0, 200)}`)
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    await markLoaded($)
    if (e.agentId !== undefined) return next(e)
    let session = 'unknown'
    let row: string | undefined
    let usd: number | undefined
    try {
      session = await $.session.id()
      const u = (await $.session.usage()).cost?.usd
      // JSON.stringify writes NaN/Infinity as null; throwing here makes it an error row and keeps
      // `usd` undefined, so the baseline below is not set to NaN.
      if (typeof u === 'number' && !Number.isFinite(u)) throw new Error(`non-finite ledger usd: ${u}`)
      usd = u
      if (typeof usd === 'number') {
        const { delta, reset } = ledgerDelta(prev, usd)
        row = JSON.stringify({ t: new Date().toISOString(), session_id: session, turn_id: e.turnId, usd, delta, reset })
      }
    } catch (err) {
      row = JSON.stringify({ t: new Date().toISOString(), session_id: session, turn_id: e.turnId, error: String(err).slice(0, 200) })
    }
    if (row !== undefined && (await append($, row)) && usd !== undefined) prev = usd
    return next(e)
  })
}
