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

Agent configuration: set PROJECT_ROOT to the absolute path of the
directory this command started in (your working directory at the start;
your tool shows it, no shell command is needed). All paths below are
relative to PROJECT_ROOT, whatever the shell's current directory is later.
Set ADT_ROOT to PROJECT_ROOT/.claude if
PROJECT_ROOT/.claude/scripts/adt-run-agent.sh exists, otherwise to
`${CLAUDE_PLUGIN_ROOT}` if `${CLAUDE_PLUGIN_ROOT}/scripts/adt-run-agent.sh`
exists, otherwise leave it empty. For every "exists" check in this
paragraph, read that exact path with your file-read tool, only its first
line (for example a line limit of 1). Never use a file-search tool:
search tools skip git-ignored files, and both the script link in an
`install.sh` project and the config file are git-ignored. Never use a
shell command for these checks.
Then read PROJECT_ROOT/.agentic-dev-team/config.yaml the same way. There
are exactly three outcomes:
(a) The read succeeds (an empty file counts as success): the file exists.
    Skip the init step.
(b) The read reports that the file does not exist, in any wording (for
    example "File does not exist.", "file not found", "no such file"):
    treat the file as missing. If ADT_ROOT is set, run
    `bash "ADT_ROOT/scripts/adt-run-agent.sh" --init-config "PROJECT_ROOT"`
    (with the real paths in place of the names, each in double quotes);
    if ADT_ROOT is empty, skip it. (A broken link is also reported as "not
    found"; the script then prints `ADT_INIT status=unreadable`, see
    below.)
(c) The read fails for a reason other than "the file does not exist"
    (the path is a directory, or no permission):
    a config error. Do not run the init step. STOP the command before the
    first agent and say: "agentic-dev-team:
    .agentic-dev-team/config.yaml exists but cannot be read; fix or
    delete it."
The init step creates the optional, git-ignored config once. After it:
- `ADT_INIT status=created` or `status=exists`: continue.
- `ADT_INIT status=unreadable`: a config error; STOP the command before
  the first agent and show the script's message.
- The permission was declined, the tool reported an error, or
  `ADT_INIT status=failed`: print this line once and continue. (When the
  init step was skipped, print nothing.)
"The optional config file .agentic-dev-team/config.yaml was not created. To
stop this question, allow the command, or create two files yourself:
.agentic-dev-team/.gitignore with the single line *, and
.agentic-dev-team/config.yaml copied from <TEMPLATE>."
where <TEMPLATE> is only the one that applies: in a plugin install
(ADT_ROOT is not PROJECT_ROOT/.claude), the real path of
ADT_ROOT/config.example.yaml; in an install.sh install (ADT_ROOT is
PROJECT_ROOT/.claude), the text "plugins/agentic-dev-team/config.example.yaml
in your agentic-dev-team clone".
Then follow PIPELINE_DOC Part B, "Agent Configuration": read and validate
that file, and set MODELS. If PIPELINE_DOC has no "Agent Configuration"
section (an older install) and ADT_ROOT is set, read that section, and
"Configured Runs", from ADT_ROOT/AGENTIC_DEV_TEAM_PIPELINE.md instead, so
the rules and the scripts are the same version. If neither file has the
section, do not use the config file at all, and, only when the file has
an active setting, print one line: "agentic-dev-team: the installed
pipeline doc is older than the config file support, so
.agentic-dev-team/config.yaml was not used." When the config file has no
active setting, none of this changes anything. When MODELS is on, follow Part B, "Agent
Configuration", every time you start an `adt-*` subagent in this command:
it says which model to pass, and when to pass none (it can turn model
passing off). When MODELS is off, ignore every rule that names MODELS: the
run is exactly as it would be without this paragraph.

This is the /build-auto flow — assumes the feature is already understood.
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
  Pass: PLAN_PATH. On a first run you have no credentials to pass — the Tester
  asks for one only if it hits a gate, at Phase 3B below.
  Wait for ✅ TESTER DONE **or** ⛔ TESTER BLOCKED. The Tester ends on one or
  the other; a blocked run never emits the DONE marker, so do not wait on it.

Phase 3B — Tester blocked (⛔ TESTER BLOCKED, max 2 resumes):
  A gate stopped the Tester before it could finish — one it had no credential
  for, or a device that would not accept input. Follow "The Blocked Path" in
  the pipeline doc's Part B: it defines the whole procedure — what to show the
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

  On `stop`, or after the 2nd resume still comes back blocked, **STOP** and
  report per the Blocked Path, saying plainly that the feature is untested.
  Run "Close the run" below on the way out.

Phase 3F — Tester fix loop (max 2 iterations):
  Read the verdict from `test-results.md`. On READY TO MERGE, go to the
  summary. On NEEDS FIXES, iterate (N = 1, then 2):
    Spawn ONE `adt-android-coder` subagent with PLAN_PATH plus the test
    report's "Recommendations for Coder" section verbatim (blocking findings
    only — the Tester's Observations section is for the user and never drives
    a fix), instructing it to fix exactly those failures. Wait for
    ✅ CODER DONE.
    Re-run `adt-android-tester` with PLAN_PATH, the previous
    `test-results.md`, and any `TEST CREDENTIALS` a resume supplied,
    instructing it to re-run the failed cases and the happy path — other
    previously-passing cases only if the fix plausibly affects them. Wait for
    ✅ TESTER DONE or ⛔ TESTER BLOCKED; on the latter, go to Phase 3B.
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
directory as PLAN_PATH, including how many fix iterations ran, and report any raw `adb`
fallbacks the Tester declared (the count is on its DONE line — they signal an
auto-mobile gap, not a failure), and list any
Observations the Tester recorded — those are unrequested behaviours it noticed
and deliberately did not fix, for the user to accept or turn into a follow-up.
Also report whether parallel execution was used and how many adt-android-coder
subagents ran, so the user can gauge token cost.
