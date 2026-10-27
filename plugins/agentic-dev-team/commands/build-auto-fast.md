---
name: build-auto-fast
description: Architect → Coder → Tester for an already-specified Android feature
allowed-tools:
  - Bash(bash .claude/adt/scripts/adt.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/adt.sh *)
  - mcp__auto-mobile__*
  - mcp__maestro__*
---

You will run the Android development pipeline for: $ARGUMENTS

Before executing, find and read two files in full. PIPELINE_DOC is
`AGENTIC_DEV_TEAM_PIPELINE.md` (Part A: the rules every agent obeys).
ORCHESTRATION_DOC is `AGENTIC_DEV_TEAM_ORCHESTRATION.md` (Part B: your rules
as the orchestrator). Find each one at `.claude/<file>` in the project, or else
at `${CLAUDE_PLUGIN_ROOT}/<file>` (a plugin-only install). If ORCHESTRATION_DOC
is in neither place, STOP: the installed files are older than this command, so
tell the user to re-run `install.sh` (or update the plugin). Also read the
consuming project's `AGENTS.md` (or `CLAUDE.md`) for local conventions
(architecture, libraries, verification requirements). These files are the
source of truth; do not duplicate their content here.

Then do ORCHESTRATION_DOC, "Command Start", steps 1 to 5: the docs, the test
driver (DRIVER_DOC), the device script (ADT_SH), the preflight, and the config
file (MODELS). Do all of them before any agent runs.

Run ledger: record this run as ORCHESTRATION_DOC, "The Run Ledger", says: the
command, paths and driver once the slug is known, the phase at the start of
every phase below, and each Tester verdict. Before each re-run that a budget
below limits, bump the counter the budget names; exit 17 is that budget's
STOP. At every exit, after the device release, record how the run ended, as
that section's "At the end" says. If `$ARGUMENTS` is exactly `resume <slug>`,
follow "Resume" in that section instead of starting at the first phase.

This is the /build-auto-fast flow — assumes the feature is already understood.
No PM phase. If the request is vague, suggest the user run /build-guided instead.

Design doc: **off** by default for this command. This is the speed path — no
human gate and no reviewer waits on the run, so nobody is reading a design
document while it happens, and generating one would cost tokens for an artifact
nothing consumes. `$ARGUMENTS` may carry `doc: on` (or an explicit `doc: off`)
anywhere in the text — read it, remove that token before you use the rest as the
feature request, and let it override the default. Store the result as
DESIGN_DOC (`on` or `off`).

Test credentials: there is no `creds:` argument, and deliberately so — a PIN or
password is free-form text with no terminator, so it cannot be told apart from
the feature request without guessing. Instead the Tester asks for what it needs
when it needs it, at the Phase 3B gate, and the user's reply carries the value.
See the pipeline doc's Part A, "Test Credentials". Whatever they supply there
goes to the `adt-android-tester` subagent and nowhere else.
Flows never ask: they type the project's declared test secrets by name, and
the script supplies the values (Part A, "Test secrets for flows").

Input — before Phase 1, look at the feature request (`$ARGUMENTS` with the
`doc:` token removed). It may be a file another command wrote:
  - **An existing `implementation-plan.md`** (from `/plan-design`, say): set
    PLAN_PATH to it, and DOC_PATH to the `design-doc.md` beside it when one
    exists (DESIGN_DOC on), else DESIGN_DOC off; a `doc:` token changes
    nothing here. Skip Phase 1: the plan is already written. Start at
    Phase 2.
  - **An existing `design-doc.md`** with no plan beside it: in Phase 1, pass
    the Architect `DESIGN_DOC: from-design-doc` and that path instead of a
    feature request. DOC_PATH is that path.
  - **An existing `feature.md`** (from `/plan-spec`): in Phase 1, pass the
    Architect that path as the feature spec. It writes into that directory.
  - **Anything else** is the feature request, as below.
  A path ending in one of those names that does not exist is a STOP: name the
  path you tried.

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
  Early boot — first, once PLAN_PATH gives the slug S: run
  `bash <ADT_SH> device-acquire --slug S --background`. It returns at once and
  boots this run's emulator while the Coder works; the test phase's own
  `device-acquire` waits for it. From here on, every exit releases the device
  (see "Release the device" below).

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
      at most 2 rounds (counter `cross_section_rounds_g<n>`), then STOP and report.

  If any coder reports a problem with its section (e.g. spec issue,
  unexpected file conflict), STOP rather than continuing.

Phase 3 — Tester:
  Run the test phase exactly as ORCHESTRATION_DOC, "The Test Phase",
  defines it:
    1. lease this run's device with `adt.sh device-acquire` (DEVICE);
    2. run the plan's device tests with `adt.sh check`, when Section 0 has
       them (a failure continues, for the Tester), then install the build with
       `adt.sh install` (BUILD_INSTALLED; release and STOP if it fails);
    3. delegate to the `adt-android-test-writer` subagent, which writes one
       flow per test case from the plan and the code, without a device (you
       may run step 2 while it writes), and wait for ✅ TEST WRITER DONE;
    4. run the flows with `adt.sh run` (RUN_RESULTS) — this run's own flows
       plus the regression suite: one `--area` per row of PLAN_PATH's
       Regression Scope, one `--exclude` per row of its Flows Retired;
    5. if any of this run's own flows failed for a reason other than a crash
       or an ANR, send just those back to the Test Writer to fix (`FIX`), then
       re-run the ones it fixed with `adt.sh run --only`;
    6. delegate to the `adt-android-tester` subagent.
  Pass the Tester: PLAN_PATH, PIPELINE_DOC, DRIVER_DOC, `DEVICE: <serial>`,
  `BUILD_INSTALLED: <timestamp>`, `RUN_RESULTS: <path>`, and `CHECKS: <path>`
  when the device tests ran. On a first run you
  have no credentials to pass — the Tester asks for one only if it hits a
  gate, at Phase 3B below.
  Wait for ✅ TESTER DONE **or** ⛔ TESTER BLOCKED. The Tester ends on one or
  the other; a blocked run never emits the DONE marker, so do not wait on it.

Phase 3B — Tester blocked (⛔ TESTER BLOCKED, max 2 resumes, counter `resumes`):
  A gate stopped the Tester before it could finish — one it had no credential
  for, or a device that would not accept input. Follow "The Blocked Path" in
  ORCHESTRATION_DOC: it defines the whole procedure — what to show the
  user, why no Coder is spawned, the `resume` / `stop` vocabulary, how a
  supplied credential reaches the Tester, and the 2-resume budget.

  **This flow is unattended, and the blocked gate is its one exception.** It
  approves nothing: nobody signs off on the plan, the code, or the results
  here. The run has hit a wall it cannot pass, and the only choice is between
  waiting for one short answer and throwing the run away. Stopping costs
  strictly more — it discards a finished Architect phase and a finished Coder
  phase that a re-run pays for again. If nobody is watching, the run waits,
  and nothing is lost that stopping would have saved.

  Where the resumed run lands:
    - ✅ TESTER DONE → Phase 3F, handled on its verdict like any other run.
      NEEDS FIXES enters the fix loop with its 2 iterations untouched — a block
      consumed a resume, not a fix iteration.
    - ⛔ TESTER BLOCKED → back to the top of this phase.

  A resume re-invokes only the Tester, on the same device, with the same
  DEVICE, BUILD_INSTALLED, RUN_RESULTS and CHECKS: the build did not change, so the
  flows do not run again.

  On `stop`, or after the 2nd resume still comes back blocked, **STOP** and
  report per the Blocked Path, saying plainly that the feature is untested.
  Release the device and run "Close the run" below on the way out.

Phase 3F — Tester fix loop (max 2 iterations, counter `fix_iterations`):
  Read the verdict from `test-results.md`. On READY TO MERGE, go to "Keep the
  passing flows" below. On NEEDS FIXES, iterate (N = 1, then 2):
    Spawn ONE `adt-android-coder` subagent with PLAN_PATH plus the test
    report's "Recommendations for Coder" section verbatim (blocking findings
    only — the Tester's Observations section is for the user and never drives
    a fix), instructing it to fix exactly those failures. Wait for
    ✅ CODER DONE.
    Re-run the test phase (ORCHESTRATION_DOC, "The Test Phase") on the same device —
    install included, so the re-test sees the fixed build. The Test Writer runs
    again only if the previous `test-results.md` lists Flow Defects (pass
    those flows and the Tester's notes as FIX), and `adt.sh run` re-runs every
    flow. Pass
    `adt-android-tester` PLAN_PATH, PIPELINE_DOC, DRIVER_DOC, `DEVICE`, the new
    `BUILD_INSTALLED`, `RUN_RESULTS` and `CHECKS` lines, the previous `test-results.md`
    and any `TEST CREDENTIALS` a resume supplied, instructing it to judge every
    flow result again and to drive by hand only the cases without a flow that
    failed before or that the fix plausibly affects. Wait for ✅ TESTER DONE
    or ⛔ TESTER BLOCKED; on the latter, go to Phase 3B.
    On READY TO MERGE, go to "Keep the passing flows" below.
  After the 2nd iteration still reports NEEDS FIXES, **STOP** — do not
  declare the run complete, and do not start a 3rd iteration.

Keep the passing flows — only when the final verdict is READY TO MERGE: run
the promote step of ORCHESTRATION_DOC, "The Test Phase" (`adt.sh
promote`, with one `--remove` per Flows Retired row and per "Suite Flows to
Remove" entry in the last test-results.md). Never after NEEDS FIXES or a STOP.

Release the device — on every exit from Phase 2 on, since the early boot may
already have leased one: before the summary below, and before reporting any
STOP. Run the release step of the
ORCHESTRATION_DOC, "The Test Phase". It is separate from "Close the run",
which is skipped when there is no design doc.

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
directory as PLAN_PATH — starting with its "Verified V of N plan cases; U not
verified" line (count it from its Coverage section if the line is missing) and
each unverified case with its reason — including how many
fix iterations ran, any preflight warnings, and list any
Observations the Tester recorded — those are unrequested behaviours it noticed
and deliberately did not fix, for the user to accept or turn into a follow-up.
Also report whether parallel execution was used and how many adt-android-coder
subagents ran, so the user can gauge token cost, the test driver and the device
the run tested on, the flow counts from the last `run-results.md` (including
the regression suite's, and any P0 warning), the suite flows promote added,
replaced and removed — with a reminder to commit `e2e/flows/` alongside the
feature — and for each test phase how long the Test Writer, the flow run and
the Tester took (ORCHESTRATION_DOC, "The Test Phase").
