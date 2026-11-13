import type { Register } from 'claude-code'

// Known-bad fixture for scripts/check-observer-contract.sh: hooks beyond turn.complete, a deny,
// an ask and a rewrite. Never loaded; only `claude plugin validate` reads it.
export const register: Register = on => {
  on('turn.complete', async ($, e, next) => next(e))
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (e.command === 'x') return { deny: 'no' }
    await $.ui.ask('ok?')
    return next({ ...e })
  })
  on('prompt.submit', async ($, e, next) => next({ ...e, text: 'y' }))
}
