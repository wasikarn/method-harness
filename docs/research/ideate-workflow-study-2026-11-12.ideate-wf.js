export const meta = {
  name: 'ideate-wf',
  description: 'Divergent ideation: one context scout, five isolated frame agents, one fresh-context critic',
  whenToUse: 'An open-ended design question where a wide option set is wanted before committing. Pass the question as args.',
  phases: [
    { title: 'Context', detail: 'one agent reads the repo for constraints' },
    { title: 'Diverge', detail: 'five isolated agents, one frame each' },
    { title: 'Focus', detail: 'mh:ideate-critic scores, clusters, ranks, deepens' },
  ],
}

// Frames are copied from skills/workflow/ideate/references/frames.md. Default pick for a code-shaped problem:
// four tagged code or design plus one tagged wild. Pass args.frames (five ids) to change the pick.
const FRAMES = {
  'hardware-eyes': 'Think in latency, memory layout, and physical constraints. Re-ask as a hardware/firmware problem. What does the bus topology, the cache, the timing budget tell you?',
  'regulator': 'Audit for compliance and failure modes. What must be provable, traceable, or refusable here?',
  'ten-year-old': 'A curious 10-year-old who has never seen software. Naive but unencumbered approaches. Ignore convention.',
  'adversary': 'Hostile competitor or attacker. Approaches that exploit, fail, or sabotage the obvious solution — then invert into ideas.',
  'biology': 'Transplant a mechanism from biology — immune systems, neural plasticity, cell signaling, evolution, gut flora. Force-fit it.',
  'logistics': 'Steal from logistics: queues, batching, just-in-time, hub-and-spoke, returns, last-mile. Apply literally.',
  'game-design': 'Game designer. What are the loops, rewards, friction, save-states, speedrun tricks? Treat the user/system as a player.',
  'markets': 'Treat the problem as a market. Buyers, sellers, market-makers. What does an auction, a futures contract, a clearing house look like here?',
  'inversion': 'Ask the OPPOSITE question. If goal is X, brainstorm "how would we guarantee NOT-X" — then negate each answer back.',
  'extreme-zero': 'No money, no team, one hour. Crudest version that still does the load-bearing thing. Hacks, hardcoded values, manual loops welcome.',
  'extreme-infinite': 'Infinite compute, infinite engineers, a decade. What is the maximalist version? What would only be possible at that scale?',
  'remove-assumption': 'Name the thing everyone treats as fixed (framework, database, request/response model, network). Imagine it is gone. What is possible?',
  'speedrunner': 'Find glitches, skips, out-of-bounds tricks, frame-perfect shortcuts. What is the abusive-but-legal path?',
  'ant-colony': 'No central planner. Many dumb agents, local rules, pheromone trails. How does the problem solve itself emergently?',
  'ops-3am': 'On-call engineer woken at 3am when this breaks. What design would let you not get paged? Runbook-shaped solution.',
}
const DEFAULT_PICK = ['inversion', 'ops-3am', 'adversary', 'logistics', 'remove-assumption']

const DIVERGENT = [
  'You are in DIVERGENT mode. You are a generator, not a critic.',
  'Generate 6 short distinct ideas under this frame. Each idea is',
  'one phrase or one sentence. Do not evaluate. Do not rank. Do',
  'not hedge. The first three obvious answers everyone would',
  'give are banned. Push past them into the awkward middle.',
].join('\n')

const RENDER = [
  'Render in this order; the structure is the point, never a wall of prose.',
  '1. Brief: the problem in 1-2 lines, the five frames, any failed branch, the cost line ("7 agents: 1 context, 5 diverge, 1 critic").',
  '2. Wide set: the critic clusters with their angle labels, one phrase per idea, score chips like [N7 V8 F9]; note "N frames converged here" beside any cluster with frameCount 3 or more.',
  '3. Converge: the shortlist with the critic shortlistReasons verbatim, a star on nonObviousPick with nonObviousPickReason, confidence, runnerUp in one line if not null, traps listed separately with their one-line reasons.',
  '4. Focus: the deepened branches (sketch, load-bearing risk, first concrete step, child ideas).',
  '5. Provocation: the critic provocation.',
  'Then answer what the user asked: if they asked which option you would pick, commit to one, and check it against the facts in `context` before you do. The critic is the same model class as the generators; its ranking is advice, and the user decides.',
].join('\n')

const input = typeof args === 'string' ? { problem: args } : (args || {})
const problem = input.problem
if (!problem) return { stopped: 'no problem statement: pass the question as args (a string, or {problem, frames?, repo_dir?})' }
const pick = Array.isArray(input.frames) && input.frames.length === 5 ? input.frames : DEFAULT_PICK
const unknown = pick.filter(f => !FRAMES[f])
if (unknown.length) return { stopped: `unknown frame ids: ${unknown.join(', ')}` }
const where = input.repo_dir ? `the repository at ${input.repo_dir}` : 'the repository in the current working directory'

phase('Context')
const scout = await agent(
  `Read ${where} to find what constrains an answer to the question below. Read the README, the docs, config and deploy files, data files and the code the question points at; follow references one or two steps. Do not propose solutions.\n\n` +
  `QUESTION:\n${problem}\n\n` +
  `Return a context brief of at most 250 words: what exists today, and every hard constraint or fact in the repo that would rule an approach in or out, each with its file path. If the directory holds no project files, say so in one line.`,
  { label: 'context', phase: 'Context', schema: {
    type: 'object',
    properties: {
      context: { type: 'string' },
      files_read: { type: 'array', items: { type: 'string' } },
    },
    required: ['context', 'files_read'],
  } }
)
const context = scout && scout.context ? scout.context : ''

phase('Diverge')
const IDEAS = { type: 'object', properties: { ideas: { type: 'array', items: {
  type: 'object', properties: { text: { type: 'string' }, rationale: { type: 'string' } }, required: ['text', 'rationale'],
} } }, required: ['ideas'] }
// Isolation: each branch gets the problem, the context and its own frame only. No tools are needed to answer.
const branches = await parallel(pick.map(id => () => agent(
  `${DIVERGENT}\n\nPROBLEM:\n${problem}\n\n${context ? `CONTEXT:\n${context}\n\n` : ''}FRAME — ${id}:\n${FRAMES[id]}\n\nGenerate 6 ideas under this frame. Do not read files or call tools other than the one that returns your answer; the context above is all you get.`,
  { label: `diverge:${id}`, phase: 'Diverge', schema: IDEAS, effort: 'medium' }
)))
const failedBranches = []
const ideas = []
branches.forEach((b, i) => {
  const list = b && Array.isArray(b.ideas) ? b.ideas.filter(x => x && x.text) : []
  if (!list.length) { failedBranches.push(pick[i]); return }
  list.forEach(x => ideas.push({ id: `i${ideas.length + 1}`, frameId: pick[i], frameLabel: pick[i], text: x.text, rationale: x.rationale || '' }))
})
if (failedBranches.length) log(`failed branches: ${failedBranches.join(', ')}`)
if (pick.length - failedBranches.length < 3) {
  return { stopped: `only ${pick.length - failedBranches.length} of 5 branches returned ideas`, failedBranches, context, ideas }
}

phase('Focus')
const envelope = JSON.stringify({ problem, context, ideas, options: { topK: 3 } })
const raw = await agent(envelope, { label: 'critic', phase: 'Focus', agentType: 'mh:ideate-critic' })
let critic = null
let criticParseError = null
if (typeof raw === 'string') {
  const a = raw.indexOf('{')
  const b = raw.lastIndexOf('}')
  try { critic = JSON.parse(a === 0 && b === raw.trim().length - 1 ? raw.trim() : raw.slice(a, b + 1)) } catch (e) { criticParseError = String(e && e.message || e) }
  if (critic && (a !== 0 || b !== raw.trim().length - 1)) criticParseError = 'critic wrapped its JSON in other text; parsed the braces only'
} else {
  criticParseError = 'critic returned nothing'
}

return {
  problem,
  frames: pick,
  failedBranches,
  context,
  ideas,
  critic,
  criticParseError,
  criticRaw: critic ? undefined : raw,
  render: RENDER,
}
