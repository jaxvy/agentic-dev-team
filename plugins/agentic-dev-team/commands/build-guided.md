---
name: build-guided
description: PM → Architect → Coder → Tester for a vague Android idea, with human gates
---

You will run the full Android pipeline with human approval gates for:
$ARGUMENTS

Before executing, read `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` for the shared
orchestration rules (handoff protocol, subagent mappings, approval gates,
build/lint gates) and read the consuming project's `AGENTS.md` (or `CLAUDE.md`)
for local
conventions (architecture, libraries, verification requirements). Both files
are the source of truth — do not duplicate their content here.

If `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` does not exist in the project
(plugin-only install), read `${CLAUDE_PLUGIN_ROOT}/AGENTIC_DEV_TEAM_PIPELINE.md`
instead. Store the path that worked as PIPELINE_DOC and pass it to every
subagent you spawn, alongside the artifact paths you already pass.

This is the /build-guided flow — starts with the PM to refine the idea.
After each phase, pause and ask the user to type one of:
- `approve` — proceed to next phase
- `revise: <feedback>` — re-run the current phase with the feedback
- `stop` — halt the pipeline

Every STOP below means: stop the pipeline and report using the **structured STOP
report** defined in the pipeline doc's Part B.

Phase 1 — PM (kickoff):
  Delegate to the `adt-android-pm` subagent with the user's idea.
  The PM will ask clarifying questions iteratively. Pass each user response
  back to the PM until ✅ PM DONE. Include the full accumulated Q&A transcript
  with each re-invocation — including the codebase findings the PM carried
  forward — since each re-invocation is a fresh subagent context.
  Parse the artifact directory from the DONE message — it will say:
    "feature description at pipeline_artifacts/{slug}/feature.md"
  Store: FEATURE_DIR = pipeline_artifacts/{slug}/
  Then show the user a summary of FEATURE_DIR/feature.md and ask:
  "Approve the feature description to proceed to Architect, or revise?"
  Do not proceed until the user responds.

Phase 2 — Architect (after approval):
  Delegate to the `adt-android-architect` subagent.
  Pass: the path FEATURE_DIR/feature.md
  When ✅ ARCHITECT DONE, parse the plan path from the DONE message:
    "plan at pipeline_artifacts/{slug}/implementation-plan.md"
  Store: PLAN_PATH = pipeline_artifacts/{slug}/implementation-plan.md
  Show the user the section headings of PLAN_PATH and ask:
  "Approve the plan to proceed to Coder, or revise?"

Phase 3 — Coder (after approval, execution strategy decided by Architect):
  Read PLAN_PATH Section 3. Check the **Parallel-safe** field.

  If Parallel-safe is YES, run the parallel-safety pre-check before anything
  else: extract each section's file list from the plan and verify that no
  file appears in two sections of the same group. This is a mechanical
  comparison of the file lists, not a judgment call. On overlap, STOP naming
  the overlapping files and the sections that claim them — do not spawn
  coders against a plan with a parallelization bug, and do not ask the user
  to approve one.

  Before spawning coders, tell the user:
    "The Architect decided this feature is [Parallel-safe: YES/NO].
    [If YES] I will spawn N adt-android-coder subagents in parallel across M groups.
    This will use more tokens than sequential execution. Type `approve`
    to proceed, `force-sequential` to override to a single coder, or
    `revise: <feedback>` to send back to the Architect."

  After approval:
    IF Parallel-safe is NO or user typed `force-sequential`:
      Spawn ONE `adt-android-coder` subagent. Pass it PLAN_PATH for all sections
      sequentially.

    IF Parallel-safe is YES and user approved:
      For each Execution Group in order:
        Spawn N `adt-android-coder` subagents in parallel — one per section.
        Each receives PLAN_PATH, explicit "implement ONLY Section X"
        instructions, and this reading scope: "Read the plan's Section 1,
        every section's Files list in Section 3, your own assigned section in
        full (its files, public interface, and tests required), and the Public
        Interface blocks of any sections yours depends on. You may skip the
        Section 2.2 code samples belonging to files outside your own file
        list."
        Wait for all coders in the group to declare ✅ CODER DONE.
        Run the cross-section check (defined in the pipeline doc's Part A)
        between groups — unless the group contained exactly one section, in
        which case skip it: there is no cross-section interaction within a
        single section, and the next group's boundary (or the final build
        gate) covers it.

  When all coders are done, show the user the list of modified files
  (grouped by which coder produced them) and ask:
    "Approve the implementation to proceed to Tester, or revise?"

Phase 4 — Tester (after approval):
  Delegate to the `adt-android-tester` subagent.
  Pass: PLAN_PATH
  Wait for ✅ TESTER DONE.
  Summarise the final test results for the user from the test-results.md
  in the same directory as PLAN_PATH.
  Then ask the user: `approve` to finish, `revise: <feedback>` to send the
  failures back to the Coder, or `stop`.

  On `revise:`, run the fix loop (max 2 iterations):
    Spawn ONE `adt-android-coder` subagent with PLAN_PATH, the user's
    feedback, and the test report's "Recommendations for Coder" section
    verbatim, instructing it to fix exactly those failures. Wait for
    ✅ CODER DONE.
    Re-run `adt-android-tester` with PLAN_PATH and the previous
    `test-results.md`, instructing it to re-run the failed cases and the
    happy path — other previously-passing cases only if the fix plausibly
    affects them. Wait for ✅ TESTER DONE, then return to this gate with the
    fresh results.
    After the 2nd iteration still reports NEEDS FIXES, STOP — do not start a
    3rd iteration.
