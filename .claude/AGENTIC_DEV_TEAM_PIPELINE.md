# Multi-Agent Pipeline & Orchestration Rules

This file is the shared source of truth for the PM → Architect → Coder → Tester
pipeline. Every agent and command file references this document. Project-specific
architecture, libraries, and verification rules live in the consuming project's
`AGENTS.md` (or `CLAUDE.md`).

## Subagent Tool & Environment Mappings

When defining subagents via the `define_subagent` tool, parse the configuration
from `.claude/agents/adt-*.md` and configure tools as follows:

- `adt-pm`: system prompt from `.claude/agents/adt-pm.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-architect`: system prompt from `.claude/agents/adt-architect.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-coder`: system prompt from `.claude/agents/adt-coder.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-tester`: system prompt from `.claude/agents/adt-tester.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = true`.

Antigravity does not support per-subagent model selection. The recommended models
in each agent file (`opus` for adt-pm/adt-architect, `sonnet` for adt-coder,
`haiku` for adt-tester) are documented for reference; in Antigravity, all
subagents inherit the user's globally selected model — select the strongest
available model for full pipeline runs.

## Handoff Protocol

Applies to any LLM driving the pipeline (Claude Code, Antigravity, Codex,
Gemini, opencode, etc.).

- **Artifact directory**: each feature gets its own subfolder `pipeline_artifacts/{feature-slug}/`.
  - The feature slug is short, lowercase, hyphen-separated (e.g. `background-link-checks`).
  - `adt-pm` writes `pipeline_artifacts/{slug}/feature.md`.
  - `adt-architect` writes `pipeline_artifacts/{slug}/implementation-plan.md`.
  - `adt-tester` writes `pipeline_artifacts/{slug}/test-results.md`.
  - `adt-coder` produces no markdown — only uncommitted code changes in the working tree.
  - `pipeline_artifacts/` must be git-ignored in the consuming project (install.sh adds it to the managed gitignore block automatically).
- **Read-before-write**: Every agent must read the prior phase artifact in full before starting. A missing required artifact is a STOP condition — report to the user, do not proceed by guessing.
- **No-commit rule for adt-coder**: The Coder must never run `git add`, `git commit`, or any staging command. Changes stay uncommitted for human review.
- **Build/lint gate**: Before `adt-coder` declares done, run `./gradlew assembleDebug` and `./gradlew lint detekt testDebugUnitTest`. Between parallel coder groups, the orchestrator runs `./gradlew lint detekt testDebugUnitTest` to catch cross-section issues. Fix in-scope failures before handing off to `adt-tester`.
- **Manual verification**: `adt-tester` must perform manual verification through the `auto-mobile` MCP server when that server is available and the consuming project's `AGENTS.md` / `CLAUDE.md` requires it.

## Approval Gates

For `/build-hitl`, pause for explicit user approval between PM, Architect,
Coder, and Tester phases. Accept `approve`, `revise: <feedback>`, or `stop`.

For `/build-auto`, skip the PM phase. If the feature description is too vague
for the Architect to produce a concrete plan, stop and suggest `/build-hitl`
instead.

## Orchestration Workflow (Antigravity)

When the user invokes `/build-hitl` or `/build-auto`, the parent agent acts as orchestrator:

1. **Define Subagents**: Dynamically register any required subagents using `define_subagent` if they aren't already defined, using the mappings above.
2. **Execute Phases**:
   - **PM Phase**: Invoke `adt-pm` with the user request. Pass messages back and forth between the user and the PM subagent until it outputs `✅ PM DONE`.
   - **Architect Phase**: Invoke `adt-architect` with the PM's `feature.md` path. Wait until it outputs `✅ ARCHITECT DONE`.
   - **Coder Phase**: Read the execution strategy from the implementation plan. If parallel-safe, invoke multiple `adt-coder` subagents in parallel. Otherwise, invoke a single `adt-coder`.
   - **Tester Phase**: Invoke `adt-tester` with the plan path. It runs manual verification via `auto-mobile` and writes `test-results.md`.
3. **Approval Gates**: At each phase boundary, pause and ask the user for explicit approval before proceeding.

## Native Workflow Registration

`/build-auto` and `/build-hitl` slash commands are registered natively in
Antigravity via symlinks in `.agents/workflows/` that point to
`.claude/commands/`. Team personas are inlined into the consuming project's
`.agents/agents.md` (inside a marker-fenced block managed by install.sh),
sourced from `.agents/AGENTIC_DEV_TEAM.md` in this repo. Each persona stub
references the canonical detailed prompt at `.claude/agents/adt-*.md`.
