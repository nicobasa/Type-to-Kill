---
description: Audit the current working diff — deep review + mechanical convention pass, merged into one prioritized report
argument-hint: [optional scope note]
---
Audit the current working changes.

1. Capture the working diff first: run `git --no-pager diff` (and `git --no-pager diff --staged` if there are staged changes). If the combined diff is empty, tell the user there are no changes to audit and stop.
2. Invoke the **Workflow** tool with `{ name: "rbx-audit" }` and `args` set to an object: `{ "scope": "<short description — use the note below if provided, else 'the current working diff'>", "diff": "<the captured diff text>" }`.
3. When it returns, present the merged, prioritized findings report (blocking → advisory), each finding with its file:line and source (review/consistency). If either pass returned nothing, say so — that area was not audited, not proven clean.

Optional scope note: $ARGUMENTS
