export const meta = {
  name: 'rbx-audit',
  description: 'Audit the current working diff from two angles in parallel — deep correctness/anti-exploit review + fast mechanical convention pass — merged into one prioritized report.',
  phases: [
    { title: 'Audit', detail: 'rbx-reviewer + rbx-consistency in parallel' },
    { title: 'Merge', detail: 'dedupe and prioritize findings' },
  ],
}

const scope = (args && args.scope) || (typeof args === 'string' ? args : '') || 'the current working diff'
const diff = (args && args.diff) || ''
const diffBlock = diff
  ? `\n\nDIFF:\n${diff}`
  : '\n\n(No diff text was passed — use Read/Grep on the changed files to inspect the change yourself.)'

phase('Audit')
const [review, consistency] = await parallel([
  () => agent(
    `Deep-review ${scope} in this Roblox/Luau repo for correctness bugs and server-authority/anti-exploit violations.\n\nRead the changed files in full, and read neighbouring files to establish what this repo's conventions actually are before flagging a convention breach — do not import conventions from other codebases. Anything stylua or selene already enforces is not a finding.\n\nReport findings with exact file:line and the rule broken.${diffBlock}`,
    { agentType: 'rbx-reviewer', phase: 'Audit', label: 'review' }
  ),
  () => agent(
    `Fast mechanical convention audit of ${scope}: file placement, PascalCase instance naming, module-contract correctness, idiom usage, and import-path roots.\n\nRead .claude/rules/ and the project docs for the rulebook, and check neighbouring files for the local pattern. Only flag a deviation you can tie to a documented rule or a consistent neighbouring pattern. Skip anything the formatter or linter owns.\n\nReport file:line findings only.${diffBlock}`,
    { agentType: 'rbx-consistency', phase: 'Audit', label: 'consistency' }
  ),
])

if (!review && !consistency) return { scope, error: 'both audit passes returned nothing' }
if (!review) log('WARNING: the deep review pass returned nothing — report covers the consistency pass only.')
if (!consistency) log('WARNING: the consistency pass returned nothing — report covers the deep review only.')

phase('Merge')
const merged = await agent(
  `Merge these two audit passes of ${scope} into ONE prioritized findings report. Dedupe overlaps, order by severity then file:line, and tag each finding with its source (review/consistency) and severity (blocking/major/minor/advisory). If a pass returned nothing, say so in the report rather than implying that area was clean.\n\n=== DEEP REVIEW ===\n${review || '(pass returned nothing — NOT a clean result)'}\n\n=== CONSISTENCY PASS ===\n${consistency || '(pass returned nothing — NOT a clean result)'}`,
  { agentType: 'rbx-reviewer', phase: 'Merge', label: 'merge' }
)

return { scope, review, consistency, merged }
