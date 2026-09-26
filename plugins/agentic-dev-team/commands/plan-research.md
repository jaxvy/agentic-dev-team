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
- `/build-auto` / `/build-guided` to run the rest of the pipeline.

Do not proceed to any other phase — this command ends at the feature spec.
