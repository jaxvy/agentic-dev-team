---
name: plan-research
description: Refine a vague Android idea into an approved feature spec (PM only, no build)
---

You will run only the research/discovery phase of the Android pipeline for:
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

This is the /plan-research flow — it produces a feature spec and stops. There
is no Architect, Coder, or Tester phase. Use it when you want the PM to turn a
rough idea into a concrete, unambiguous `feature.md` you can review, hand off,
or sit on.

PM Phase:
  Delegate to the `adt-android-pm` subagent with the user's idea.
  The PM will ask clarifying questions iteratively. Relay each question to the
  user and pass each user response back to the PM until ✅ PM DONE. Include the
  full accumulated Q&A transcript with each re-invocation — including the
  codebase findings the PM carried forward — since each re-invocation is a
  fresh subagent context.
  Parse the artifact directory from the DONE message — it will say:
    "feature description at pipeline_artifacts/{slug}/feature.md"
  Store: FEATURE_DIR = pipeline_artifacts/{slug}/

When complete, show the user a summary of FEATURE_DIR/feature.md and STOP.
Tell the user the `feature.md` path and that they can feed it to:
- `/plan-design <FEATURE_DIR/feature.md>` to produce an implementation plan, or
- `/build-guided <FEATURE_DIR/feature.md>`, `/build-auto <FEATURE_DIR/feature.md>`
  or `/build-auto-reviewed <FEATURE_DIR/feature.md>` to run the rest of the
  pipeline from this spec, with no second interview.

Do not proceed to any other phase — this command ends at the feature spec.
