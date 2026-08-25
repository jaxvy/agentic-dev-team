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

If `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` does not exist in the project
(plugin-only install), read `${CLAUDE_PLUGIN_ROOT}/AGENTIC_DEV_TEAM_PIPELINE.md`
instead. Store the path that worked as PIPELINE_DOC and pass it to every
subagent you spawn, alongside the artifact paths you already pass.

This is the /build-auto flow — assumes the feature is already understood.
No PM phase. If the request is vague, suggest the user run /build-guided instead.

Design doc: **off** by default for this command. This is the speed path — no
human gate and no reviewer waits on the run, so nobody is reading a design
document while it happens, and generating one would cost tokens for an artifact
nothing consumes. `$ARGUMENTS` may carry `doc: on` (or an explicit `doc: off`)
anywhere in the text — read it, remove that token before you use the rest as the
feature request, and let it override the default. Store the result as
DESIGN_DOC (`on` or `off`).

Phase 1 — Architect:
  Delegate to the `adt-android-architect` subagent with the feature request
  (with the `doc:` token removed), PIPELINE_DOC, and the line `DESIGN_DOC: off`
  or `DESIGN_DOC: on` to match what you resolved above. Pass it explicitly —
  an Architect told nothing writes both documents.
  Wait for ✅ ARCHITECT DONE.
  Parse the artifact paths from the DONE message — it will say:
    "plan at pipeline_artifacts/{slug}/implementation-plan.md"
    "design doc at pipeline_artifacts/{slug}/design-doc.md" (present only when
    DESIGN_DOC is on)
  Store the plan path: PLAN_PATH = pipeline_artifacts/{slug}/implementation-plan.md
  Store the design doc path: DOC_PATH (on only)

Phase 2 — Coder (execution strategy is decided by the Architect):
  Read PLAN_PATH Section 3 ("Work Breakdown & Execution Strategy").
  Look at the **Parallel-safe** field.

  IF Parallel-safe is NO:
    Spawn ONE `adt-android-coder` subagent. Pass it PLAN_PATH with instructions to
    implement all sections sequentially in the order listed.
    Wait for ✅ CODER DONE.

  IF Parallel-safe is YES:
    Parallel-safety pre-check, before spawning anything: extract each
    section's file list from the plan and verify that no file appears in two
    sections of the same group. This is a mechanical comparison of the file
    lists, not a judgment call. On overlap, STOP naming the overlapping files
    and the sections that claim them — do not spawn coders against a plan
    with a parallelization bug.

    For each Execution Group in order (Group 1, then Group 2, etc):
      Spawn N `adt-android-coder` subagents IN PARALLEL — one per section in the group.
      Each coder receives:
        - PLAN_PATH
        - Explicit instruction: "Implement ONLY Section X. Do not touch
          files outside the file list for Section X. Other coders are
          working on other sections concurrently."
      Wait for ALL coders in the group to declare ✅ CODER DONE before
      starting the next group.
      After EVERY group — including a group that contained only one
      section — run the cross-section check (defined in the pipeline doc's
      Part A) once at the orchestrator level. Parallel coders run no Gradle
      themselves, so this check is the only verification that group gets;
      never skip it.
      On failure, follow "When the cross-section check fails" in Part A:
      attribute the failures to the owning sections, re-spawn those coders
      sequentially (one at a time) with the failing output, and re-check —
      at most 2 rounds, then STOP and report.

  If any coder reports a problem with its section (e.g. spec issue,
  unexpected file conflict), STOP rather than continuing.

Phase 3 — Tester:
  Delegate to the `adt-android-tester` subagent.
  Pass: PLAN_PATH
  Wait for ✅ TESTER DONE.

Phase 3F — Tester fix loop (max 2 iterations):
  Read the verdict from `test-results.md`. On READY TO MERGE, go to the
  summary. On NEEDS FIXES, iterate (N = 1, then 2):
    Spawn ONE `adt-android-coder` subagent with PLAN_PATH plus the test
    report's "Recommendations for Coder" section verbatim (blocking findings
    only — the Tester's Observations section is for the user and never drives
    a fix), instructing it to fix exactly those failures. Wait for
    ✅ CODER DONE.
    Re-run `adt-android-tester` with PLAN_PATH and the previous
    `test-results.md`, instructing it to re-run the failed cases and the
    happy path — other previously-passing cases only if the fix plausibly
    affects them. Wait for ✅ TESTER DONE.
    On READY TO MERGE, go to the summary.
  After the 2nd iteration still reports NEEDS FIXES, **STOP** — do not
  declare the run complete, and do not start a 3rd iteration.

Close the run — before the summary below, and on any exit path including a STOP:
  Only if DESIGN_DOC is on and the Architect wrote one — the default run
  produces no design doc and skips this entirely. Append to DOC_PATH's
  `## Implementation Notes` section what actually diverged from the document:
  Coder work that departed from the approach, and Tester fix-loop changes. You
  have this in your own run history; do not re-read the diff to reconstruct it.
  Edit that section only, and write "No divergence — the run implemented this
  document as written." when there is nothing to record. Report DOC_PATH with
  the summary.

When complete, summarise the final verdict from the test-results.md in the same
directory as PLAN_PATH, including how many fix iterations ran, and list any
Observations the Tester recorded — those are unrequested behaviours it noticed
and deliberately did not fix, for the user to accept or turn into a follow-up.
Also report whether parallel execution was used and how many adt-android-coder
subagents ran, so the user can gauge token cost.
