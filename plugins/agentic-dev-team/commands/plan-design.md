---
name: plan-design
description: Produce an implementation plan from a feature spec or description (Architect only, no build)
---

You will run only the design phase of the Android pipeline for:
$ARGUMENTS

Before executing, read `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` for the shared
orchestration rules (handoff protocol, subagent mappings, approval gates) and
read the consuming project's `AGENTS.md` (or `CLAUDE.md`) for local conventions
(architecture, libraries, verification requirements). Both files are the source
of truth — do not duplicate their content here.

If `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` does not exist in the project
(plugin-only install), read `${CLAUDE_PLUGIN_ROOT}/AGENTIC_DEV_TEAM_PIPELINE.md`
instead. Store the path that worked as PIPELINE_DOC and pass it to every
subagent you spawn, alongside the artifact paths you already pass.

This is the /plan-design flow — it produces an implementation plan and stops.
There is no PM, Coder, or Tester phase. Use it when you already have a feature
spec (or a clear feature description) and want the Architect to design the
implementation without building it.

The argument is either:
- a path to an existing `feature.md` (e.g. from `/plan-research`), or
- a clear, already-specified feature description.

If the argument is too vague for the Architect to plan concretely, STOP and
suggest the user run `/plan-research` first.

Architect Phase:
  Delegate to the `adt-android-architect` subagent.
  Pass: the `feature.md` path or the feature description from $ARGUMENTS.
  Wait for ✅ ARCHITECT DONE. Parse the plan path from the DONE message:
    "plan at pipeline_artifacts/{slug}/implementation-plan.md"
  Store: PLAN_PATH = pipeline_artifacts/{slug}/implementation-plan.md

When complete, show the user the section headings of PLAN_PATH and STOP.
Tell the user the plan path and that they can feed it to `/build-auto` or
`/build-guided` to implement and verify it.

Do not proceed to any other phase — this command ends at the implementation
plan.
