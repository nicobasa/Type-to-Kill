---
description: Understand a system before changing it — parallel researchers → one cited architecture map
argument-hint: <how/where/why question about the codebase>
---
Run the project workflow `rbx-study` to investigate this question.

Invoke the **Workflow** tool with `{ name: "rbx-study" }` and `args` set to the question text below (as a plain string). The workflow plans focused sub-investigations, fans out parallel `rbx-researcher` agents, and synthesizes one answer with file:line citations.

When it returns, present the synthesized architecture/answer map (with citations) to the user. If `completedAreas` is shorter than `plannedAreas`, say which areas returned nothing — an incomplete map should not be presented as a complete one.

Question:
$ARGUMENTS
