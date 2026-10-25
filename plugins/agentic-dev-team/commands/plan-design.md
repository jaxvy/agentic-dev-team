---
name: plan-design
description: Produce an implementation plan and/or a human-facing design doc — auto-detects the input and writes whichever artifact is missing
---

You will run only the design phase of the Android pipeline for:
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

Then do ORCHESTRATION_DOC, "Command Start", steps 1 and 5: the docs and the
config file (MODELS). This command uses no device, so it skips steps 2 to 4.

This is the /plan-design flow — it produces an implementation plan and/or the
design doc that goes with it, then stops. There is no PM, Coder, or Tester
phase. What it writes depends on what you give it.

Step 1 — Detect the input type.

  Examine `$ARGUMENTS`. Determine which of these four cases applies:

  A. **Existing plan** — `$ARGUMENTS` is a file path ending in
     `implementation-plan.md` (or a feature slug that resolves to
     `pipeline_artifacts/{slug}/implementation-plan.md`) and that file exists.
     → The plan already exists. Write only the design doc beside it.

  B. **Existing design doc** — `$ARGUMENTS` is a file path ending in
     `design-doc.md` and that file exists.
     → The design doc already exists. Write only the implementation plan beside
     it.

  C. **Feature spec** — `$ARGUMENTS` is a file path ending in `feature.md`
     and that file exists.
     → Write both the implementation plan and the design doc.

  D. **Idea** — anything else (free text).
     → Write both the implementation plan and the design doc. If the text is
     too vague for the Architect to plan concretely, STOP and suggest the user
     run `/plan-research` first.

  For cases C and D only: `$ARGUMENTS` may carry `doc: on` or `doc: off`
  anywhere in the text — read it, remove that token before you use the rest as
  the feature request, and let it override the default (`on`). Store the result
  as DESIGN_DOC (`on` or `off`). Never pass the token through to the Architect
  as part of the feature text. Cases A and B ignore `doc:` tokens — their
  output is fixed by what was given.

Step 2 — Pre-flight checks.

  Case A (existing plan → design doc):
    If `design-doc.md` already exists in PLAN_PATH's directory, tell the user
    and ask whether to overwrite it before going any further. Never overwrite it
    silently — it may hold Implementation Notes from a finished run.
    If the resolved plan file does not exist, STOP and tell the user the path
    you tried. Do not write a plan yourself.

  Case B (existing design doc → plan):
    If `implementation-plan.md` already exists in DOC_PATH's directory, tell the
    user and ask whether to overwrite it before going any further.
    If the resolved design doc file does not exist, STOP and tell the user the
    path you tried. Do not write a design doc yourself.

  Cases C and D: no pre-flight checks beyond the vagueness check for D.

Step 3 — Architect phase.

  Delegate to the `adt-android-architect` subagent. What you pass depends on
  the case:

  Case A (existing plan → design doc):
    Pass:
    - `DESIGN_DOC: only`
    - PLAN_PATH
    - PIPELINE_DOC
    - the instruction: "Read this plan in full and survey the codebase it
      describes. Write only `design-doc.md`, in the same directory as the plan.
      Do not modify the plan, do not re-plan, and do not create a new artifact
      directory."

  Case B (existing design doc → plan):
    Pass:
    - `DESIGN_DOC: from-design-doc`
    - DOC_PATH
    - PIPELINE_DOC
    - the instruction: "Read this design doc in full and survey the codebase it
      describes. Write only `implementation-plan.md`, in the same directory as
      the design doc. Do not modify the design doc and do not create a new
      artifact directory."

  Case C (feature.md):
    Pass: the `feature.md` path, PIPELINE_DOC, and the line
    `DESIGN_DOC: on` or `DESIGN_DOC: off` to match what you resolved above.

  Case D (idea):
    Pass: the feature description (with the `doc:` token removed), PIPELINE_DOC,
    and the line `DESIGN_DOC: on` or `DESIGN_DOC: off` to match what you
    resolved above.

  Wait for ✅ ARCHITECT DONE. Parse the artifact paths from the DONE message:
    "plan at pipeline_artifacts/{slug}/implementation-plan.md"
    "design doc at pipeline_artifacts/{slug}/design-doc.md"
  (one or both will be present depending on the case)
  Store: PLAN_PATH and/or DOC_PATH as applicable.

Step 4 — Report.

  Case A (wrote design doc for existing plan):
    Read DOC_PATH and show the user its **Summary** and **Alternatives
    Considered** sections, then report the path. State that the plan was left
    unmodified: the design doc is derived from it, and where the two disagree
    the plan wins (pipeline doc, Part A, "Anti-Drift Rule").

  Case B (wrote plan for existing design doc):
    Show the user the section headings of PLAN_PATH and report the path. State
    that the design doc was left unmodified.

  Cases C and D, with a design doc:
    Read DOC_PATH and show the user its **Summary** and **Alternatives
    Considered** sections, then report both paths — the design doc as the thing
    to read and agree with, the plan as the file-by-file detail behind it.

  Cases C and D, with `doc: off`:
    Show the user the section headings of PLAN_PATH and report that path.

Then STOP. Tell the user they can feed the plan to `/build-auto` or
`/build-guided` to implement and verify it.

Do not proceed to any other phase — this command ends at the design phase.
