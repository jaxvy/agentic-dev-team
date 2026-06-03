---
name: plan-research
description: Refine a vague Android idea into an approved feature spec (PM only, no build)
---

You will run only the research/discovery phase of the Android pipeline for:
$ARGUMENTS

Before executing, read `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` for the shared
orchestration rules (handoff protocol, subagent mappings, approval gates) and
read the consuming project's `AGENTS.md` (or `CLAUDE.md`) for local conventions
(architecture, libraries, verification requirements). Both files are the source
of truth — do not duplicate their content here.

This is the /plan-research flow — it produces a feature spec and stops. There
is no Architect, Coder, or Tester phase. Use it when you want the PM to turn a
rough idea into a concrete, unambiguous `feature.md` you can review, hand off,
or sit on.

PM Phase:
  Delegate to the `adt-android-pm` subagent with the user's idea.
  The PM will ask clarifying questions iteratively. Relay each question to the
  user and pass each user response back to the PM until ✅ PM DONE.
  Parse the artifact directory from the DONE message — it will say:
    "feature description at pipeline_artifacts/{slug}/feature.md"
  Store: FEATURE_DIR = pipeline_artifacts/{slug}/

When complete, show the user a summary of FEATURE_DIR/feature.md and STOP.
Tell the user the `feature.md` path and that they can feed it to:
- `/plan-design <FEATURE_DIR/feature.md>` to produce an implementation plan, or
- `/build-auto` / `/build-guided` to run the rest of the pipeline.

Do not proceed to any other phase — this command ends at the feature spec.
