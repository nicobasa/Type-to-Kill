# Subagent Model Policy: Fable = Orchestrator Only

**Fable may only ever act as the orchestrator (the main loop). It must NEVER be dispatched as a subagent / worker.**

The orchestrator's job is to think, plan, and delegate — not to make code changes directly. Workers do the actual editing. Workers run on **Opus 4.8** or **Sonnet 5** for substantive work, and **Haiku 4.5** only for cheap mechanical passes. Never Fable.

---

## Hard Rules

- [ ] **Never spawn a Fable subagent.** When calling the `Agent` tool, never set `model: "fable"`.
- [ ] **Never assign Fable in a `Workflow`.** In any `Workflow` script, never pass `model: 'fable'` to `agent()`, `pipeline()`, `parallel()`, or a phase's `model` field.
- [ ] **Beware `subagent_type: "fork"`.** Forks always inherit the parent model. If the orchestrator is running on Fable, do NOT use `fork` for worker tasks — spawn a fresh `opus` or `sonnet` agent instead, so the worker never ends up on Fable.
- [ ] **Never rely on `'inherit'` for a worker.** It resolves to the parent's model, so a Fable orchestrator produces a Fable worker — the exact outcome this policy exists to prevent. Name the model explicitly.
- [ ] **Custom agent definitions** in `.claude/agents/*.md` must never declare `model: fable` in their frontmatter.

## Division of Labor

- **Orchestrator (may be Fable):** reads context, plans, decomposes, dispatches workers, reviews their output, synthesizes. Avoids making file edits directly — delegates the actual changes to workers.
- **Workers (Opus 4.8 or Sonnet 5):** perform the implementation, edits, research, review, and verification the orchestrator assigns.

## Quick reference — allowed `model` values by role

| Role | Allowed | Forbidden |
|------|---------|-----------|
| Orchestrator (main loop) | `fable`, `opus`, `sonnet` | — |
| Worker — substantive (implement, review, research, verify) | `opus`, `sonnet` | `fable`, `inherit` |
| Worker — cheap mechanical pass (convention sweep, formatting audit) | `haiku` | `fable`, `inherit` |

Current agent roster and their tiers:

| Agent | Model | Why |
|---|---|---|
| `rbx-researcher` | `opus` | judgment-heavy tracing; wrong conclusions are expensive |
| `rbx-reviewer` | `opus` | the correctness/exploit gate |
| `rbx-verifier` | `opus` | must triage real failures from noise honestly |
| `rbx-implementer` | `sonnet` | pattern-following code, reviewed downstream |
| `rbx-consistency` | `haiku` | mechanical convention sweep — the sanctioned Haiku case |
