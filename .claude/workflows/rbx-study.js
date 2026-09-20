export const meta = {
  name: 'rbx-study',
  description: 'Understand a Roblox/Luau system before changing it: fan out parallel researchers across subsystems, then synthesize one architecture/answer map.',
  phases: [
    { title: 'Scope', detail: 'plan focused sub-investigations' },
    { title: 'Investigate', detail: 'parallel rbx-researcher per area' },
    { title: 'Synthesize', detail: 'merge into one cited answer' },
  ],
}

const question = typeof args === 'string' ? args : (args && (args.question || args.task)) || ''
if (!question) {
  log('rbx-study: no question provided — pass it as args.')
  return { error: 'no question provided' }
}

const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    investigations: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: { area: { type: 'string' }, find: { type: 'string' } },
        required: ['area', 'find'],
      },
    },
  },
  required: ['investigations'],
}

phase('Scope')
const plan = await agent(
  `Given this question about the Roblox/Luau codebase in the current working directory, propose 3-6 focused, non-overlapping sub-investigations (each: a subsystem/area + the specific thing to find there) that together fully answer it.\n\nFirst orient yourself: glob src/**/*.luau and read default.project.json to learn what subsystems actually exist here. Base the plan on the real tree, not on assumptions about how Roblox projects are usually organised. Be concrete about which files each investigation should target.\n\nQUESTION:\n${question}`,
  { agentType: 'rbx-researcher', phase: 'Scope', label: 'scope', schema: PLAN_SCHEMA }
)
const subs = (plan && plan.investigations) || []
if (!subs.length) return { error: 'no investigations planned', question }
log(`Planned ${subs.length} parallel investigations.`)

phase('Investigate')
// Pair each result with its own area BEFORE filtering. Filtering a bare array
// and then indexing subs[i] misattributes every finding after the first drop.
const results = (await parallel(subs.map((s) => () =>
  agent(
    `Investigate this slice of the codebase and report exact file paths, line numbers, and the data/control flow. Read ground truth from source — never infer a module's identity from its filename. Stay within your area; be precise and cite files.\n\nAREA: ${s.area}\nFIND: ${s.find}\n\nOVERALL QUESTION (context only): ${question}`,
    { agentType: 'rbx-researcher', phase: 'Investigate', label: `research:${s.area}` }
  ).then((text) => (text ? { area: s.area, text } : null))
))).filter(Boolean)

if (!results.length) return { error: 'all investigations failed', question, plannedAreas: subs.map((s) => s.area) }
if (results.length < subs.length) {
  log(`WARNING: ${subs.length - results.length} of ${subs.length} investigations returned nothing — synthesis will be incomplete.`)
}

phase('Synthesize')
const synthesis = await agent(
  `Synthesize these parallel research findings into ONE coherent answer to the question. Produce a clear architecture/flow map with exact file:line citations, resolve overlaps, and call out any contradictions or gaps. If the findings disagree, say so rather than silently picking one.\n\nQUESTION:\n${question}\n\nFINDINGS:\n${results.map((r, i) => `--- Finding ${i + 1} (${r.area}) ---\n${r.text}`).join('\n\n')}`,
  { agentType: 'rbx-researcher', phase: 'Synthesize', label: 'synthesize' }
)

return {
  question,
  plannedAreas: subs.map((s) => s.area),
  completedAreas: results.map((r) => r.area),
  synthesis,
}
