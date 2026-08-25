---
name: build-auto-reviewed
description: Architect → Coder → Tester with automated reviewer gates (architect-reviewer + code-reviewer) that bounce work back on feedback
---

You will run the reviewer-gated Android development pipeline for: $ARGUMENTS

Before executing, read `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` for the shared
orchestration rules (handoff protocol, subagent mappings, approval gates,
build/lint gates, reviewer-loop protocol) and read the consuming project's
`AGENTS.md` (or `CLAUDE.md`) for local conventions (architecture, libraries,
verification requirements). Both files are the source of truth — do not
duplicate their content here.

If `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` does not exist in the project
(plugin-only install), read `${CLAUDE_PLUGIN_ROOT}/AGENTIC_DEV_TEAM_PIPELINE.md`
instead. Store the path that worked as PIPELINE_DOC and pass it to every
subagent you spawn, alongside the artifact paths you already pass.

This is the /build-auto-reviewed flow — same shape as /build-auto (no PM phase,
no human gates), but each producing phase is followed by an automated reviewer
that can send the work back. It assumes the feature is already understood. If
the request is vague, suggest the user run /build-guided instead.

Design doc: **off** by default for this command. This is an unattended auto flow,
so no design doc is generated unless explicitly requested. `$ARGUMENTS` may carry
`doc: on` (or `doc: off`) anywhere in the text — read it, remove that token before
you use the rest as the feature request, and let it override the default. Store the
result as DESIGN_DOC (`on` or `off`).

**Reviewer-loop protocol (applies to every gate below):**
- After the producing agent finishes, delegate to its reviewer.
- If the reviewer ends with `✅ ... APPROVED`, proceed to the next phase.
- If the reviewer ends with `🔧 ... CHANGES REQUESTED`, re-run the producing
  agent, passing it the reviewer's numbered feedback, and review again.
- A gate allows **at most 2 re-runs** (3 production attempts total). If the
  reviewer still requests changes after the 2nd re-run, **STOP the whole
  pipeline** and report the phase and the unresolved feedback. Do not proceed
  to later phases.

Phase 1 — Architect:
  Delegate to the `adt-android-architect` subagent with the feature request
  (with the `doc:` token removed), PIPELINE_DOC, and the line `DESIGN_DOC: on`
  or `DESIGN_DOC: off` to match what you resolved above.
  Wait for ✅ ARCHITECT DONE.
  Parse the artifact paths from the DONE message — it will say:
    "plan at pipeline_artifacts/{slug}/implementation-plan.md"
    "design doc at pipeline_artifacts/{slug}/design-doc.md" (present only when
    DESIGN_DOC is on)
  Store the plan path: PLAN_PATH = pipeline_artifacts/{slug}/implementation-plan.md
  Store the design doc path: DOC_PATH = pipeline_artifacts/{slug}/design-doc.md
  (on only)

Phase 1R — Architect review gate (max 2 re-runs):
  Delegate to the `adt-android-architect-reviewer` subagent. Pass PLAN_PATH and,
  when DESIGN_DOC is on, DOC_PATH — the rejected alternatives live in the design
  doc, so a reviewer without it cannot check them.
  - On `✅ PLAN APPROVED`: continue to Phase 2.
  - On `🔧 PLAN CHANGES REQUESTED`: re-run `adt-android-architect` with the
    reviewer's feedback and the instruction to revise PLAN_PATH in place — and
    DOC_PATH with it, in the same invocation, so the document a human ends up
    reading is the approved version rather than the first draft. Then review
    again. After the 2nd failed re-run, STOP and report (see protocol).
    Note which bounces changed the approach; that belongs in the design doc's
    Implementation Notes at the end of the run.

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

Phase 2R — Code review gate (max 2 re-runs):
  After ALL coding for the feature is complete, delegate to the
  `adt-android-code-reviewer` subagent. Pass PLAN_PATH (it reviews the
  uncommitted diff against the plan and the project's conventions).
  - On `✅ CODE APPROVED`: continue to Phase 3.
  - On `🔧 CODE CHANGES REQUESTED`: re-run the Coder to address the feedback —
    spawn ONE `adt-android-coder` subagent with PLAN_PATH and the reviewer's
    numbered feedback, instructing it to fix exactly those points (regardless of
    the parallel-safety decision; fixes are usually small and cross-cutting).
    Wait for ✅ CODER DONE, then review again. After the 2nd failed re-run,
    STOP and report (see protocol).

Phase 3 — Tester:
  Delegate to the `adt-android-tester` subagent.
  Pass: PLAN_PATH
  Wait for ✅ TESTER DONE.

Phase 3F — Tester fix loop (max 2 iterations):
  Read the verdict from `test-results.md`. On READY TO MERGE, go to the
  summary. On NEEDS FIXES, iterate (N = 1, then 2):
    Spawn ONE `adt-android-coder` subagent with PLAN_PATH plus the test
    report's "Recommendations for Coder" section verbatim (blocking findings
    only — the Tester's Observations section never drives a fix), instructing
    it to fix exactly those failures. Wait for ✅ CODER DONE.

    Targeted re-review — the Coder just mutated code that Phase 2R approved,
    which invalidates that approval (pipeline doc Part A, "Review Currency").
    Delegate to `adt-android-code-reviewer`, stating that this is a TARGETED
    RE-REVIEW and passing: PLAN_PATH and the fix instructions the Coder was
    given.
    - On `✅ CODE APPROVED`: proceed to the re-test below.
    - On `🔧 CODE CHANGES REQUESTED`: re-run the Coder once with that numbered
      feedback, then re-review. This targeted loop allows **at most 1 re-run**.
      If the reviewer still requests changes, **STOP** — do not re-test
      unreviewed code and do not spend the remaining Tester iteration on it.

    Re-run `adt-android-tester` with PLAN_PATH and the previous
    `test-results.md`, instructing it to re-run the failed cases and the
    happy path — other previously-passing cases only if the fix plausibly
    affects them. Wait for ✅ TESTER DONE.
    On READY TO MERGE, go to the summary.
  After the 2nd iteration still reports NEEDS FIXES, **STOP** — do not
  declare the run complete, and do not start a 3rd iteration.

  The targeted re-review is what keeps the final tree bound to a code review:
  a run may only reach READY TO MERGE with an approval that post-dates the last
  code mutation. Its 1-re-run budget is per iteration and separate from Phase
  2R's — a targeted re-review never re-opens Phase 2R's own budget, and never
  re-reviews the whole feature.

Close the run — before the summary below, and on any exit path including a STOP:
  Skip this entirely when there is no design doc to close out — DESIGN_DOC is
  off, or the run stopped before the Architect wrote one. Otherwise append to
  DOC_PATH's `## Implementation Notes` section what actually diverged from the
  document — architect-reviewer bounces that changed the approach, code-reviewer
  feedback that changed it, and Tester fix-loop changes. You have all of this in
  your own run history; do not re-read the diff to reconstruct it. Edit that
  section only, leave every other section as the Architect wrote it, and write
  "No divergence — the run implemented this document as written." when there is
  nothing to record.

When complete, summarise the final verdict from the test-results.md in the same
directory as PLAN_PATH, report DOC_PATH — when the run produced one — as the
document to review this work from, and include how many fix iterations ran and,
for each one,
the targeted re-review's verdict — so the user can see the final tree was
reviewed after its last change. Note any Observations the Tester recorded as
non-blocking, since those are decisions waiting on the user rather than work the
pipeline did. Also report, for each review gate, how many re-runs were needed
(0, 1, or 2) and whether parallel execution was used and how many
adt-android-coder subagents ran, so the user can gauge token cost.
