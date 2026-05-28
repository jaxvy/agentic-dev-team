---
name: build-auto
description: Architect → Coder → Tester for an already-specified Android feature
---

You will run the Android development pipeline for: $ARGUMENTS

Before executing, read `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` for the shared
orchestration rules (handoff protocol, subagent mappings, approval gates,
build/lint gates) and read the consuming project's `AGENTS.md` (or `CLAUDE.md`)
for local
conventions (architecture, libraries, verification requirements). Both files
are the source of truth — do not duplicate their content here.

This is the /build-auto flow — assumes the feature is already understood.
No PM phase. If the request is vague, suggest the user run /build-hitl instead.

Phase 1 — Architect:
  Delegate to the `adt-android-architect` subagent with the feature request.
  Wait for ✅ ARCHITECT DONE.
  Parse the artifact directory from the DONE message — it will say:
    "plan at pipeline_artifacts/{slug}/implementation-plan.md"
  Store the plan path: PLAN_PATH = pipeline_artifacts/{slug}/implementation-plan.md

Phase 2 — Coder (execution strategy is decided by the Architect):
  Read PLAN_PATH Section 3 ("Work Breakdown & Execution Strategy").
  Look at the **Parallel-safe** field.

  IF Parallel-safe is NO:
    Spawn ONE `adt-android-coder` subagent. Pass it PLAN_PATH with instructions to
    implement all sections sequentially in the order listed.
    Wait for ✅ CODER DONE.

  IF Parallel-safe is YES:
    For each Execution Group in order (Group 1, then Group 2, etc):
      Spawn N `adt-android-coder` subagents IN PARALLEL — one per section in the group.
      Each coder receives:
        - PLAN_PATH
        - Explicit instruction: "Implement ONLY Section X. Do not touch
          files outside the file list for Section X. Other coders are
          working on other sections concurrently."
      Wait for ALL coders in the group to declare ✅ CODER DONE before
      starting the next group.
      After each group finishes, run `./gradlew lint detekt
      testDebugUnitTest` once at the orchestrator level to catch any
      cross-section issues before moving to the next group.

  If any coder reports a problem with its section (e.g. spec issue,
  unexpected file conflict), STOP the pipeline and report to the user
  rather than continuing.

Phase 3 — Tester:
  Delegate to the `adt-android-tester` subagent.
  Pass: PLAN_PATH
  Wait for ✅ TESTER DONE.

When complete, summarise the verdict from the test-results.md in the same
directory as PLAN_PATH. Also report whether parallel execution was used and
how many adt-android-coder subagents ran, so the user can gauge token cost.
If verdict is NEEDS FIXES, suggest re-running the adt-android-coder with the
recommendations section as input.
