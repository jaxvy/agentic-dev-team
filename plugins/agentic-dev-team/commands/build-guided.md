---
name: build-guided
description: PM → Architect → Coder → Tester for a vague Android idea, with human gates
allowed-tools:
  - Bash(bash .claude/adt/scripts/adt.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/adt.sh *)
  - mcp__auto-mobile__*
  - mcp__maestro__*
---

You will run the full Android pipeline with human approval gates for:
$ARGUMENTS

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

This is the /build-guided flow — starts with the PM to refine the idea.
After each phase, pause and ask the user to type one of:
- `approve` — proceed to next phase
- `revise: <feedback>` — re-run the current phase with the feedback
- `stop` — halt the pipeline

Phase 4B, the blocked-Tester gate, is the one exception to that vocabulary: it
takes `resume` or `stop`, since a run that could not finish is not something to
approve or to send the Coder back over.

Design doc: **on** by default for this command — the plan gate is where a human
decides whether the approach is right, so it is the gate that most needs one.
`$ARGUMENTS` may carry `doc: on` or `doc: off` anywhere in the text — read it,
remove that token before you use the rest as the user's idea, and let it
override the default. Store the result as DESIGN_DOC (`on` or `off`).

Test credentials: there is no `creds:` argument, and deliberately so — a PIN or
password is free-form text with no terminator, so it cannot be told apart from
the user's idea without guessing. Instead the Tester asks for what it needs when
it needs it, at the Phase 4B gate, and the user's reply carries the value. See
the pipeline doc's Part A, "Test Credentials". Whatever they supply there goes
to the `adt-android-tester` subagent and nowhere else: not to another agent, not
into `pipeline_artifacts/`, not into the code, not into your summary.
Flows never ask: they type the project's declared test secrets by name, and
the script supplies the values (Part A, "Test secrets for flows").

Input — before Phase 1, look at the user's idea (`$ARGUMENTS` with the `doc:`
token removed). It may be a file another command wrote:
  - **An existing `feature.md`** (from `/plan-spec`, where the user
    already approved it): set FEATURE_DIR to its directory, skip Phase 1, and
    start at Phase 2.
  - **An existing `design-doc.md`** with no plan beside it: skip Phase 1. In
    Phase 2, pass the Architect `DESIGN_DOC: from-design-doc` and that path
    instead of a feature.md; DOC_PATH is that path. Then the plan gate.
  - **An existing `implementation-plan.md`** (from `/plan-design`): set
    PLAN_PATH to it, and DOC_PATH to the `design-doc.md` beside it when one
    exists (DESIGN_DOC on), else DESIGN_DOC off. Skip Phase 1 and the
    Architect run of Phase 2, and go straight to the plan gate with these
    documents: the user approves the plan in this run before any code.
  - **Anything else** is the user's idea, as below.
  A path ending in one of those names that does not exist is a STOP: name the
  path you tried.

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
  Pass: the path FEATURE_DIR/feature.md, PIPELINE_DOC, and the line
  `DESIGN_DOC: on` or `DESIGN_DOC: off` to match what you resolved above.
  When ✅ ARCHITECT DONE, parse the artifact paths from the DONE message:
    "plan at pipeline_artifacts/{slug}/implementation-plan.md"
    "design doc at pipeline_artifacts/{slug}/design-doc.md" (present only when
    DESIGN_DOC is on)
  Store: PLAN_PATH = pipeline_artifacts/{slug}/implementation-plan.md
  Store: DOC_PATH = pipeline_artifacts/{slug}/design-doc.md (on only)

  The plan gate — this is a design decision, so present the design doc, not a
  heading dump. Read DOC_PATH and show the user, in this order:
    - its **Summary**
    - **What the User Sees**
    - **Alternatives Considered**
    - **Blast Radius**
    - the **Parallel-safe** decision and the number of Coders it implies —
      orchestrator facts, read from PLAN_PATH Section 3, not from the design doc
    - the path to DOC_PATH (to read in full) and to PLAN_PATH (for the
      file-by-file detail)
  With `doc: off`, fall back to showing the section headings of PLAN_PATH.
  Then ask: "Approve the plan to proceed to Coder, or revise?"

  On `revise: <feedback>`, re-run the `adt-android-architect` subagent with
  PLAN_PATH, DOC_PATH, and the feedback as a numbered list, instructing it to
  rewrite **both** files in place. Feedback it does not adopt must come back
  recorded under the design doc's Non-Goals with the reason — see the pipeline
  doc's Part A, "Feedback Lands in the Documents". Then return to this gate with
  the revised documents. Keep a note of what each revision changed; it belongs
  in the design doc's Implementation Notes at the end of the run (Phase 5).

Phase 3 — Coder (after approval, execution strategy decided by Architect):
  Early boot — first, once PLAN_PATH gives the slug S: run
  `bash <ADT_SH> device-acquire --slug S --background`. It returns at once and
  boots this run's emulator while the Coder works; the test phase's own
  `device-acquire` waits for it. From here on, every exit releases the device
  (see "Release the device" below).

  Read PLAN_PATH Section 3. Check the **Parallel-safe** field.

  If Parallel-safe is YES, run the parallel-safety pre-check before anything
  else: extract each section's file list from the plan and verify that no
  file appears in two sections of the same group. This is a mechanical
  comparison of the file lists, not a judgment call. On overlap, STOP naming
  the overlapping files and the sections that claim them — do not spawn
  coders against a plan with a parallelization bug, and do not ask the user
  to approve one.

  Before spawning coders, tell the user. The plan gate already showed them this
  decision; this gate is where they approve the token cost of executing it:
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
        Each receives PLAN_PATH and explicit "implement ONLY Section X"
        instructions.
        Wait for all coders in the group to declare ✅ CODER DONE.
        Run the cross-section check (defined in the pipeline doc's Part A)
        after EVERY group, including a group that contained only one
        section. Parallel coders run no Gradle themselves, so this check is
        the only verification that group gets; never skip it.
        On failure, follow "When the cross-section check fails" in Part A:
        attribute the failures to the owning sections, re-spawn those coders
        sequentially (one at a time) with the failing output, and re-check —
        at most 2 rounds (counter `cross_section_rounds_g<n>`), then STOP and report to the user.

  When all coders are done, show the user the list of modified files
  (grouped by which coder produced them) and ask:
    "Approve the implementation to proceed to Tester, or revise?"

Phase 4 — Tester (after approval):
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
  gate, at Phase 4B below.
  Wait for ✅ TESTER DONE **or** ⛔ TESTER BLOCKED. The Tester ends on exactly
  one of them, never both.
  The device stays up while you wait at the gates below, so a `revise:` or a
  `resume` re-tests without a new boot.

  **On ⛔ TESTER BLOCKED, go straight to Phase 4B and skip the rest of this
  phase.** Everything below assumes the plan's cases actually ran. Presenting a
  blocked report as "the final test results" and offering `approve` is precisely
  how an untested feature gets signed off as done.

  On ✅ TESTER DONE:
  Summarise the final test results for the user from the test-results.md
  in the same directory as PLAN_PATH: first its "Verified V of N plan cases;
  U not verified" line (count it from its Coverage section if the line is
  missing) and each unverified case with its reason, then the
  flow counts from RUN_RESULTS (passed, failed, flaky). Present blocking findings and Observations
  separately: blocking findings are defects against the plan;
  Observations are unrequested behaviours the Tester noticed and did not fix,
  which only you — the user — can promote into requirements.
  Then ask the user: `approve` to finish, `revise: <feedback>` to send the
  failures back to the Coder, or `stop`.

  On `revise:`, run the fix loop (max 2 iterations, counter `fix_iterations`):
    Spawn ONE `adt-android-coder` subagent with PLAN_PATH, the user's
    feedback, and the test report's "Recommendations for Coder" section
    verbatim, instructing it to fix exactly those failures. An Observation
    the user explicitly asked for in their `revise:` feedback is fair game —
    that is the user creating a requirement, which is allowed; the Tester
    doing it on its own is not. Wait for ✅ CODER DONE.
    Re-run the test phase (ORCHESTRATION_DOC, "The Test Phase") on the same device —
    install included, so the re-test sees the fixed build. The Test Writer runs
    again only if the previous `test-results.md` lists Flow Defects (pass
    those flows and the Tester's notes as FIX), and `adt.sh run` re-runs every
    flow. Pass
    `adt-android-tester` PLAN_PATH, PIPELINE_DOC, DRIVER_DOC, `DEVICE`, the new
    `BUILD_INSTALLED`, `RUN_RESULTS` and `CHECKS` lines, the previous `test-results.md`
    and the same `TEST CREDENTIALS` block if a resume supplied one,
    instructing it to judge every flow result again and to drive by hand only
    the cases without a flow that failed before or that the fix plausibly
    affects. Wait for ✅ TESTER DONE, then return to this gate with the fresh
    results. On ⛔ TESTER BLOCKED, go to Phase 4B.
    After the 2nd iteration still reports NEEDS FIXES, STOP — do not start a
    3rd iteration.

Phase 4B — Tester blocked (⛔ TESTER BLOCKED, max 2 resumes, counter `resumes`):
  A gate stopped the Tester before it could finish — one it had no credential
  for, or a device that would not accept input. Follow "The Blocked Path" in
  ORCHESTRATION_DOC: it defines the whole procedure — what to show the
  user, why no Coder is spawned, the `resume` / `stop` vocabulary, how a
  supplied credential reaches the Tester, and the 2-resume budget.

  If the gate itself is the defect — the app should not be demanding a login at
  that point — that is a blocking finding for the Tester to record on resume,
  not a `revise:` for the Coder.

  Where the resumed run lands:
    - ✅ TESTER DONE → return to the Phase 4 gate and handle it like any other
      run: summarise the results and ask for `approve`, `revise:` or `stop`. A
      `revise:` enters Phase 4's fix loop with its 2 iterations untouched — a
      block consumed a resume, not a fix iteration.
    - ⛔ TESTER BLOCKED → back to the top of this phase.

  A resume re-invokes only the Tester, on the same device, with the same
  DEVICE, BUILD_INSTALLED, RUN_RESULTS and CHECKS: the build did not change, so the
  flows do not run again.

  On `stop`, or after the 2nd resume still comes back blocked, STOP and report
  per the Blocked Path. Never present a blocked run as a pass; the feature is
  untested until a Tester run executes the cases.

Keep the passing flows — when the user answers `approve` at Phase 4 and the
last verdict was READY TO MERGE: run the promote step of ORCHESTRATION_DOC,
"The Test Phase" (`adt.sh promote`, with one `--remove` per Flows
Retired row and per "Suite Flows to Remove" entry in the last test-results.md),
before releasing the device. Never on `stop`, after NEEDS FIXES, or on a STOP.

Release the device — whenever the run ends from Phase 3 on, since the early
boot may already have leased one: on `approve` at Phase 4, on `stop` at any
gate, and on a STOP of your own. Run the
release step of ORCHESTRATION_DOC, "The Test Phase", before anything
else in Phase 5. It is separate from Phase 5, which is skipped when there is no
design doc.

Phase 5 — Close the run (whenever the run ends: on `approve` at Phase 4, on
`stop`, or on a STOP of your own — a stop out of Phase 4B included):
  Skip this phase entirely when there is no design doc to close out — DESIGN_DOC
  is off, or the run stopped before the Architect wrote one.
  Otherwise append to DOC_PATH's `## Implementation Notes` section
  what actually diverged from the document — Architect revisions the user asked
  for after the plan gate, Coder work that departed from the approach, and any
  Tester fix-loop changes. You have all of this in your own run history; do not
  re-read the diff to reconstruct it. Edit that section only, leave every other
  section as the Architect wrote it, and write "No divergence — the run
  implemented this document as written." when there is nothing to record.
  Then report DOC_PATH to the user as the document to review this work from,
  alongside the test verdict and the list of changed files.

Whenever the run ends, include the test driver, the device the run tested on,
any preflight warnings, and for each test phase how long the Test Writer, the flow run and the Tester
took (ORCHESTRATION_DOC, "The Test Phase") in what you report — plus the regression
counts, any P0 warning, and the suite flows promote added, replaced and
removed, with a reminder to commit `e2e/flows/` alongside the feature.
