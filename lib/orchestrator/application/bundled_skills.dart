/// Skills genéricas do Orchestrator-AI copiadas para `.ai/skills` ao
/// preparar um projeto. Fonte: josuemoraisgh/orchestrator
/// (`vscode-extension/skills`), licença MIT. Copyright (c) 2026
/// Orchestrator-AI contributors.
const orqBundledSkills = <String, String>{
  'delegation-and-handoff': '''---
name: delegation-and-handoff
description: Delegate independent work through lich and preserve concise cross-agent continuation context with ai-memory.
---

# Delegation and handoff

1. Delegate only a task that can be completed independently with a concrete deliverable and a bounded scope.
2. Use lich to inspect current sessions first. Avoid two agents editing the same files; prefer a separate worktree for concurrent changes.
3. Include relevant spec paths, constraints, and required evidence in the delegated task. Ask the worker to report files, commands, results, and unresolved issues.
4. Inspect the worker's diff and verify its claims before integrating anything.
5. At a meaningful pause or completion, use ai-memory's handoff flow so another supported agent can resume. Keep the handoff focused on current state, last result, blocker, next action, and files to inspect.
   Keep one stable task identifier across sequential agents. Use the AI Memory workstream/session/handoff tools actually exposed by the configured integration; verify that the receiving agent can read the task context before treating the handoff as complete. Workstreams are scoped to repository/worktree identity, so do not assume separate Lich worktrees share a workstream. If AI Memory access is unavailable, report the gap and include the handoff in the explicit Lich task prompt as a fallback, without claiming it was saved to memory.
6. Store cross-project preferences in the user's memory profile; keep project architecture and decisions in that project's `.ai/specs/`.
''',
  'implementation-cycle': '''---
name: implementation-cycle
description: Implement a scoped change through source tracing, minimal edits, relevant validation, and adversarial review.
---

# Implementation cycle

1. Trace the requested behavior to its current implementation and identify the smallest failure or missing behavior.
2. Use a bounded experiment when it can distinguish competing causes before editing.
3. Make the smallest correction that addresses evidence; preserve public interfaces unless the spec authorizes a change.
4. Run the project's declared build and focused tests. Run broader gates when the change reaches shared infrastructure or release behavior.
5. Review the diff for unrelated edits, unsafe defaults, missing failure paths, and claims unsupported by results.
6. Report exact commands and outcomes. Do not say “passed” if a gate was skipped.
''',
  'project-discovery': '''---
name: project-discovery
description: Map an unfamiliar project's structure, build flow, constraints, and verification gates before making changes.
---

# Project discovery

1. Find the workspace root and read its agent instructions, README, package/build manifests, and CI workflows.
2. Inspect Git status before reading deeply; identify user changes and preserve them.
3. Locate the real application entry points, build targets, test commands, and project-specific release gates. Prefer declared scripts over guessed commands.
4. Read `.ai/specs/` for current behavior and requirements. Record only durable project-specific facts there; use ai-memory for cross-session handoffs.
5. Report the production path from source change through build, tests, packaging, and release. Mark unknown steps explicitly.
''',
  'spec-driven-change': '''---
name: spec-driven-change
description: Turn a production request into a small, falsifiable specification and acceptance criteria before implementation.
---

# Spec-driven change

1. State the user-visible result and affected interfaces.
2. Separate requirements, constraints, and assumptions. Do not invent a product domain.
3. Define observable acceptance criteria, relevant tests, and failure conditions.
4. Save substantial or cross-cutting specs in `.ai/specs/` with scope, decision history, and status.
5. Choose the smallest implementation that meets the criteria. Revise the spec when evidence changes it.
''',
  'upstream-before-build': '''---
name: upstream-before-build
description: Keep configured upstream source repositories current before compiling while preserving reproducibility and local work.
---

# Upstream before build

1. Inspect the upstream list in the Orquestrador Settings view. Do not ask the user to edit `.ai/orchestrator.json` manually.
2. Call `#syncProjectUpstreams` before a build. It fetches and applies fast-forward-only updates and records resulting HEADs.
3. Stop if an upstream has local changes, diverged history, a missing remote, or a failed fetch. Preserve the tree and report the exact blocker.
4. Run `#syncAndBuildProject` to make sync-before-build one operation. Do not compile against a partially synchronized set.
5. Report each upstream commit and build command/output so the result is reproducible. Never use reset, force, or clean as an update strategy.
''',
};
