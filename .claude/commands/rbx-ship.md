---
description: Implement → review → verify a feature/fix end-to-end (loops back on blocking findings)
argument-hint: <feature or fix to ship>
---
Run the project workflow `rbx-ship` to deliver this change end-to-end.

Invoke the **Workflow** tool with `{ name: "rbx-ship" }` and `args` set to the task text below (as a plain string). The workflow will: implement via `rbx-implementer` → review via `rbx-reviewer` → verify via `rbx-verifier`, looping back to the implementer on any blocking finding (max 3 rounds).

When it returns, report to the user: final status (shipped / incomplete), number of rounds, the verifier's gate results, and any unresolved blockers. If the verifier marked a gate `NOT RUN`, surface that — do not present it as a pass.

Task to ship:
$ARGUMENTS
