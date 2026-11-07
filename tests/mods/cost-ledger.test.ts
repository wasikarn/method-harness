import { test, expect, type TestBody } from 'claude-code/testing'
import { ledgerDelta } from '../../hooks/mod/cost-ledger'

// Unit tests for hooks/mod/cost-ledger.ts, run by `claude plugin test .` from the repo root
// (tests/hooks/test-cost-ledger-module.sh wraps it). The hooks beneath stand for the engine:
// session.usage answers the ledger, process.run is the append, turn.complete is core.

test('ledgerDelta: first reading, growth, no change, drop', () => {
  expect(ledgerDelta(undefined, 0.25)).toEqual({ delta: 0.25, reset: false })
  expect(ledgerDelta(0.25, 1)).toEqual({ delta: 0.75, reset: false })
  expect(ledgerDelta(1, 1)).toEqual({ delta: 0, reset: false })
  // A new process took over the session id and its ledger started again from zero.
  expect(ledgerDelta(3, 0.5)).toEqual({ delta: 0.5, reset: true })
})

type Usage = { cost?: { usd: number } } | 'throw'

// Files the module reads: `cache` under $.plugin.root (the installed copy that runs), keyed by
// the path below it; `repo` under the session root, stubbed as /repo. A missing key rejects.
const manifest = (version: string, name = 'mh') =>
  JSON.stringify({ name, version, skills: ['./skills/meta/', './skills/workflow/ideate/'] })

const setup = (...[$, on]: Parameters<TestBody>) => {
  const h = {
    rows: [] as Record<string, unknown>[],
    markers: [] as Record<string, unknown>[],
    logs: [] as string[],
    statuses: [] as (string | undefined)[],
    toasts: [] as string[],
    cache: { '.claude-plugin/plugin.json': manifest('1.1.174') } as Record<string, string>,
    repo: { '.claude-plugin/plugin.json': manifest('1.1.174') } as Record<string, string>,
    usage: { cost: { usd: 0 } } as Usage,
    fail: undefined as 'exit' | 'throw' | undefined,
    noVersion: false,
    id: 's1',
    completes: 0,
  }
  on('session.id', () => ({ value: h.id }))
  on('session.version', () => {
    if (h.noVersion) throw new Error('version broke')
    return { value: { version: '2.1.289', base: '2.1.289' } }
  })
  on('session.root', () => ({ value: '/repo' }))
  on('fs.read', (_$, e) => {
    const p = e.path
    const text = p.startsWith('/repo/')
      ? h.repo[p.slice(6)]
      : Object.entries(h.cache).find(([rel]) => p.endsWith('/' + rel))?.[1]
    if (text === undefined) throw new Error(`ENOENT: ${p}`)
    return { value: text }
  })
  on('ui.status', (_$, e) => (h.statuses.push(e.text), { value: undefined }))
  on('ui.toast', (_$, e) => (h.toasts.push(e.text), { value: undefined }))
  on('session.usage', () => {
    if (h.usage === 'throw') throw new Error('usage broke')
    return { value: { startedAt: 0, context: { window: 200000 }, rateLimits: [], ...h.usage } }
  })
  on('process.run', (_$, e) => {
    const mode = h.fail
    h.fail = undefined
    if (mode === 'throw') throw new Error('timed out')
    if (mode === undefined)
      for (const a of e.argv.slice(4)) {
        const r = JSON.parse(String(a))
        ;(r.loaded ? h.markers : h.rows).push(r)
      }
    const exitCode = mode === 'exit' ? 1 : 0
    return { value: { exitCode, stdout: '', stderr: exitCode ? 'disk full' : '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.log', (_$, e) => (h.logs.push(e.text), { value: undefined }))
  on('turn.complete', () => (h.completes++, { text: 'core' }))
  on('session.start', () => ({ cwd: '/core' }))
  on('skill.prompt', (_$, e) => ({ text: `core:${e.text}` }))
  const turn = (turnId: string, agentId?: string) =>
    $.turn.complete({ turnId, answer: '', durationMs: 0, isAborted: false, agentId, reason: 'answer' })
  const start = () => $.session.start({ cwd: '/repo', surface: null, isInteractive: false })
  const skill = (name: string) => $.skill.prompt({ skill: name, text: 'body' })
  return { h, turn, start, skill }
}

// GH #444: one load marker per module load, from whichever hook runs first, so "modules off" (no
// marker) can be told apart from "loaded but idle" (a marker, no ledger rows).
test('load marker: written once, by the first hook call, with the CLI and mh versions', async ($, on) => {
  const { h, turn } = setup($, on)
  h.cache['.claude-plugin/plugin.json'] = manifest('1.1.173')
  await turn('t1')
  await turn('t2')
  expect(h.markers.map(r => [r.session_id, r.loaded, r.cli, r.mh])).toEqual([['s1', true, '2.1.289', '1.1.173']])
  expect(typeof h.markers[0].t).toBe('string')
  expect(h.rows.map(r => r.turn_id)).toEqual(['t1', 't2'])
})

// Deep-audit: a failed first marker append must not mark the session as done, or the report calls a
// loaded module "modules off" for the rest of the session.
test('load marker: a failed append is retried on the next hook call', async ($, on) => {
  const { h, turn } = setup($, on)
  h.fail = 'exit'
  await turn('t1')
  expect(h.markers).toEqual([])
  await turn('t2')
  expect(h.markers.map(r => [r.session_id, r.loaded])).toEqual([['s1', true]])
})

// /clear gives the same process a new session id without reloading the module; that session has
// spend too, so it needs its own marker or the report calls it "modules off".
test('load marker: a new session id in the same process gets its own marker', async ($, on) => {
  const { h, turn } = setup($, on)
  await turn('t1')
  await turn('t2')
  h.id = 's2'
  await turn('t3')
  await turn('t4')
  expect(h.markers.map(r => r.session_id)).toEqual(['s1', 's2'])
})

test('load marker: session.start writes it before any turn', async ($, on) => {
  const { h, start, turn } = setup($, on)
  await start()
  expect(h.markers.length).toBe(1)
  await turn('t1')
  expect(h.markers.length).toBe(1)
})

test('load marker: failed CLI-version and manifest reads still write the marker, without those fields', async ($, on) => {
  const { h, turn } = setup($, on)
  h.cache = {}
  h.noVersion = true
  await turn('t1')
  expect(h.markers.length).toBe(1)
  expect(h.markers[0].session_id).toBe('s1')
  expect(h.markers[0].mh).toBeUndefined()
  expect(h.markers[0].cli).toBeUndefined()
  expect(h.completes).toBe(1)
})

// GH #442: on session.start in an mh checkout, the cached copy's version beside the repo's.
test('session.start: cache below the repo -> a status line naming both', async ($, on) => {
  const { h, start } = setup($, on)
  h.cache['.claude-plugin/plugin.json'] = manifest('1.1.173')
  expect(await start()).toEqual({ cwd: '/core' })
  expect(h.statuses.length).toBe(1)
  expect(h.statuses[0]).toContain('1.1.173')
  expect(h.statuses[0]).toContain('1.1.174')
  expect(h.statuses[0]).toContain('stale')
})

// GH #934: an older branch checked out (repo below the cache) is not a stale cache: no status line.
test('session.start: cache newer than the repo -> no status line', async ($, on) => {
  const { h, start } = setup($, on)
  h.cache['.claude-plugin/plugin.json'] = manifest('1.1.175')
  await start()
  expect(h.statuses).toEqual([undefined])
})

// GH #934: versions compare numerically per part, not as strings (1.1.99 is below 1.1.174).
test('session.start: numeric compare -> 1.1.99 cache below a 1.1.174 repo is stale', async ($, on) => {
  const { h, start } = setup($, on)
  h.cache['.claude-plugin/plugin.json'] = manifest('1.1.99')
  await start()
  expect(h.statuses.length).toBe(1)
  expect(h.statuses[0]).toContain('stale')
})

// PR #935 review: a part that is not a number (a prerelease suffix) cannot be ordered, so any difference
// warns as before GH #934, rather than hiding a cache that really is stale.
test('session.start: a non-numeric version part -> any difference still warns', async ($, on) => {
  const { h, start } = setup($, on)
  h.cache['.claude-plugin/plugin.json'] = manifest('1.1.174-beta')
  await start()
  expect(h.statuses.length).toBe(1)
  expect(h.statuses[0]).toContain('stale')
})

// GH #458: the engine draws every plugin status line warning-styled, so a healthy session says
// nothing (the load-proof row in the ledger covers "it loaded"); a leftover stale line is cleared.
test('session.start: same version -> no status line, any earlier one cleared', async ($, on) => {
  const { h, start } = setup($, on)
  await start()
  expect(h.statuses).toEqual([undefined])
})

test('session.start: not an mh checkout, or unreadable manifests -> no status, core still runs', async ($, on) => {
  const { h, start } = setup($, on)
  h.repo['.claude-plugin/plugin.json'] = manifest('9.9.9', 'other')
  expect(await start()).toEqual({ cwd: '/core' })
  h.repo = {}
  expect(await start()).toEqual({ cwd: '/core' })
  h.repo['.claude-plugin/plugin.json'] = 'not json'
  expect(await start()).toEqual({ cwd: '/core' })
  h.repo['.claude-plugin/plugin.json'] = manifest('1.1.174')
  h.cache = {}
  expect(await start()).toEqual({ cwd: '/core' })
  expect(h.statuses).toEqual([])
})

// GH #442: a skill whose repo SKILL.md differs from the cached copy gets one toast per session.
test('skill.prompt: repo SKILL.md differs -> one toast per skill, text passes through', async ($, on) => {
  const { h, skill } = setup($, on)
  h.cache['skills/meta/cost-report/SKILL.md'] = 'old'
  h.repo['skills/meta/cost-report/SKILL.md'] = 'new'
  h.cache['skills/workflow/ideate/SKILL.md'] = 'same'
  h.repo['skills/workflow/ideate/SKILL.md'] = 'same'
  expect(await skill('mh:cost-report')).toEqual({ text: 'core:body' })
  expect(await skill('cost-report')).toEqual({ text: 'core:body' })
  expect(await skill('ideate')).toEqual({ text: 'core:body' })
  expect(h.toasts.length).toBe(1)
  expect(h.toasts[0]).toContain('cost-report')
  expect(h.toasts[0]).toContain('cached')
})

test('skill.prompt: no toast for a skill not in mh, missing from the repo, or outside an mh checkout', async ($, on) => {
  const { h, skill } = setup($, on)
  h.cache['skills/meta/gone/SKILL.md'] = 'old'
  expect(await skill('commit')).toEqual({ text: 'core:body' })
  expect(await skill('gone')).toEqual({ text: 'core:body' })
  h.cache['skills/meta/cost-report/SKILL.md'] = 'old'
  h.repo['skills/meta/cost-report/SKILL.md'] = 'new'
  h.repo['.claude-plugin/plugin.json'] = manifest('1.1.174', 'other')
  expect(await skill('cost-report')).toEqual({ text: 'core:body' })
  expect(h.toasts).toEqual([])
})

test('records the cumulative ledger and the per-turn delta, main loop only', async ($, on) => {
  const { h, turn } = setup($, on)
  h.usage = { cost: { usd: 0.5 } }
  expect(await turn('t1')).toEqual({ text: 'core' })
  h.usage = { cost: { usd: 0.8 } }
  await turn('a1', 'agent-x') // a subagent's turn: no row, core still runs
  h.usage = { cost: { usd: 1.25 } }
  await turn('t2')
  h.usage = { cost: { usd: 0.1 } } // ledger restarted under the same session id
  await turn('t3')
  expect(h.rows.map(r => [r.session_id, r.turn_id, r.usd, r.delta, r.reset])).toEqual([
    ['s1', 't1', 0.5, 0.5, false],
    ['s1', 't2', 1.25, 0.75, false],
    ['s1', 't3', 0.1, 0.1, true],
  ])
  expect(h.completes).toBe(4)
  expect(typeof h.rows[0].t).toBe('string')
})

test('no cost on the usage: no row, core still runs', async ($, on) => {
  const { h, turn } = setup($, on)
  h.usage = {}
  expect(await turn('t1')).toEqual({ text: 'core' })
  expect(h.rows).toEqual([])
  expect(h.completes).toBe(1)
})

test('a throwing usage read becomes an error row, core still runs', async ($, on) => {
  const { h, turn } = setup($, on)
  h.usage = 'throw'
  expect(await turn('t1')).toEqual({ text: 'core' })
  expect(h.rows.length).toBe(1)
  expect(h.rows[0].session_id).toBe('s1')
  // The kit turns the throw beneath into "no implementation for session.usage".
  expect(String(h.rows[0].error)).toContain('session.usage')
  expect(h.rows[0].usd).toBeUndefined()
  // The failed read leaves the baseline alone: the next reading is still a first turn.
  h.usage = { cost: { usd: 0.4 } }
  await turn('t2')
  expect([h.rows[1].usd, h.rows[1].delta]).toEqual([0.4, 0.4])
  expect(h.completes).toBe(2)
})

// JSON.stringify writes NaN and both infinities as null, which the report once read as a $0 reset.
test('a non-finite reading becomes an error row and leaves the baseline alone', async ($, on) => {
  const { h, turn } = setup($, on)
  h.usage = { cost: { usd: 1 } }
  await turn('t1')
  h.usage = { cost: { usd: NaN } }
  expect(await turn('t2')).toEqual({ text: 'core' })
  h.usage = { cost: { usd: Infinity } }
  expect(await turn('t3')).toEqual({ text: 'core' })
  h.usage = { cost: { usd: 1.5 } }
  await turn('t4')
  expect(h.rows.map(r => [r.turn_id, r.usd, r.delta, r.reset])).toEqual([
    ['t1', 1, 1, false],
    ['t2', undefined, undefined, undefined],
    ['t3', undefined, undefined, undefined],
    ['t4', 1.5, 0.5, false],
  ])
  expect(String(h.rows[1].error)).toContain('non-finite')
  expect(String(h.rows[2].error)).toContain('non-finite')
  expect(h.completes).toBe(4)
})

test('a failed append is logged, never thrown, and core still runs', async ($, on) => {
  const { h, turn, start } = setup($, on)
  await start() // the load marker takes the first append
  h.usage = { cost: { usd: 0.5 } }
  h.fail = 'exit'
  expect(await turn('t1')).toEqual({ text: 'core' })
  h.fail = 'throw'
  expect(await turn('t2')).toEqual({ text: 'core' })
  expect(h.completes).toBe(2)
  expect(h.logs.length).toBe(2)
  expect(h.logs[0]).toContain('disk full')
  // A lost row does not move the baseline: the next row carries the whole growth.
  h.usage = { cost: { usd: 0.9 } }
  await turn('t3')
  expect(h.rows.map(r => [r.turn_id, r.delta])).toEqual([['t3', 0.9]])
})
