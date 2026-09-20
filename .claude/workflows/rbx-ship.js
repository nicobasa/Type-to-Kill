export const meta = {
  name: 'rbx-ship',
  description: 'Implement a Roblox/Luau feature or fix, then review and verify it; loops back to the implementer on blocking findings.',
  phases: [
    { title: 'Implement', detail: 'rbx-implementer writes the change' },
    { title: 'Review', detail: 'rbx-reviewer checks correctness + server authority + conventions' },
    { title: 'Verify', detail: 'rbx-verifier runs the configured quality gates + runtime checks' },
  ],
}

const task = typeof args === 'string' ? args : (args && (args.task || args.scope)) || ''
if (!task) {
  log('rbx-ship: no task provided — pass the feature/fix description as args.')
  return { error: 'no task provided' }
}

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    summary: { type: 'string' },
    changedFiles: { type: 'array', items: { type: 'string' } },
    diff: { type: 'string', description: 'git diff output for the change (may be truncated if very large)' },
  },
  required: ['summary', 'changedFiles', 'diff'],
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    blocking: { type: 'boolean', description: 'true if any finding must be fixed before shipping' },
    findings: { type: 'string', description: 'full findings list with file:line and the rule broken' },
    summary: { type: 'string' },
  },
  required: ['blocking', 'findings'],
}
const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    pass: { type: 'boolean' },
    failures: { type: 'string', description: 'blocking failures with evidence (empty if pass)' },
    report: { type: 'string', description: 'gate-by-gate result table' },
  },
  required: ['pass', 'failures', 'report'],
}

const MAX_ROUNDS = 3
let impl = null, review = null, verify = null, blockers = '', round = 0

while (round < MAX_ROUNDS) {
  round++

  phase('Implement')
  const implPrompt = round === 1
    ? `Implement the following in this Roblox/Luau repo.\n\nBefore writing anything: read the project docs (CLAUDE.md / ARCHITECTURE.md / README.md if present), read 2-3 neighbouring files of the same kind to learn the local conventions, and check wally.toml for which libraries actually exist. Follow the patterns you find there — do not invent conventions or add dependencies that aren't already present.\n\nMake the actual file edits. Then run \`git --no-pager diff\` and return: a summary, the list of changed files, and the diff text.\n\nTASK:\n${task}`
    : `Your previous change to this repo has BLOCKING issues from review/verify. Fix them, keeping the rest of the change intact. Make the edits, then run \`git --no-pager diff\` and return summary + changed files + diff.\n\nTASK:\n${task}\n\nBLOCKING ISSUES TO FIX:\n${blockers}`
  impl = await agent(implPrompt, { agentType: 'rbx-implementer', phase: 'Implement', label: `implement r${round}`, schema: IMPL_SCHEMA })
  if (!impl) return { status: 'error', error: 'implementer failed', round }

  phase('Review')
  review = await agent(
    `Review this change (intent: ${task}). Read the changed files for full context, and read neighbouring files to establish what the local conventions actually are before flagging any convention breach. Report correctness bugs, server-authority/anti-exploit violations, and convention breaches with exact file:line and the rule broken. Set blocking=true if anything must be fixed before shipping.\n\nCHANGED FILES:\n${(impl.changedFiles || []).join('\n')}\n\nDIFF:\n${impl.diff || '(no diff returned)'}`,
    { agentType: 'rbx-reviewer', phase: 'Review', label: `review r${round}`, schema: REVIEW_SCHEMA }
  )

  // A dead reviewer is NOT an approval. Without this, a null review falls
  // through to Verify and ships an unreviewed change.
  if (!review) {
    blockers = 'The reviewer agent returned no verdict (it errored or was skipped). Re-run the review; do not treat silence as approval.'
    log(`Round ${round}: review returned NOTHING — treating as blocking.`)
    continue
  }
  if (review.blocking) {
    blockers = review.findings
    log(`Round ${round}: review BLOCKING — looping back to implementer.`)
    continue
  }

  phase('Verify')
  verify = await agent(
    `Verify the current change (intent: ${task}).\n\nDerive the gates from the repo's own config rather than assuming them: read rokit.toml for the pinned toolchain, selene.toml / stylua.toml / .luaurc for the configured rules, and default.project.json for the project file to build. Then run what actually exists (typically: selene src/ ; stylua --check src/ ; luau-lsp analyze with a regenerated sourcemap if structure changed ; rojo build to the scratchpad dir). Follow with a Studio runtime smoke check if Studio is reachable.\n\nMark any gate you could not run as NOT RUN with the reason — never imply a gate passed when it did not execute. Set pass=false if any genuine gate fails.\n\nCHANGED FILES:\n${(impl.changedFiles || []).join('\n')}`,
    { agentType: 'rbx-verifier', phase: 'Verify', label: `verify r${round}`, schema: VERIFY_SCHEMA }
  )
  if (verify && verify.pass) {
    log(`Round ${round}: VERIFIED PASS.`)
    return { status: 'shipped', rounds: round, impl, review, verify }
  }
  blockers = (verify && verify.failures) || 'verification returned no verdict (agent errored) — re-run the gates; do not treat silence as a pass'
  log(`Round ${round}: verify FAILED — looping back to implementer.`)
}

return { status: 'incomplete', rounds: round, impl, review, verify, note: `Hit MAX_ROUNDS=${MAX_ROUNDS} without a clean verify; last blockers: ${blockers}` }
