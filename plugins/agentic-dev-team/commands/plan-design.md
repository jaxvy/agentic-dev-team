---
name: plan-design
description: Produce an implementation plan and/or a human-facing design doc — auto-detects the input and writes whichever artifact is missing
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
