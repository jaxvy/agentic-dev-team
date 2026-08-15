# How It Works

This repo is a **shared configuration package**, not a library you import.
Each Android project that wants the pipeline links this repo's files into
its own `.claude/`, `.agents/`, and `.opencode/`.

The mechanics:

1. **Per-file symlinks, not per-directory.** Your project's `.claude/`,
   `.agents/`, and `.opencode/` stay real directories. You can keep adding
   your own commands/agents alongside our symlinks — they coexist freely.
2. **Claude Code discovery.** Claude Code scans `.claude/commands/` and
   `.claude/agents/` in the project by filename. Our symlinks live at
   those canonical paths, so `/build-auto`, `/build-auto-reviewed`,
   `/build-guided`, `/plan-research`, `/plan-design`, `@adt-android-pm`,
   `@adt-android-architect`, `@adt-android-architect-reviewer`,
   `@adt-android-coder`, `@adt-android-code-reviewer`, and `@adt-android-tester`
   are all available automatically.
3. **Antigravity discovery.** Antigravity scans `.agents/workflows/` for
   slash commands (our workflow files there are symlinks into
   `.claude/commands/` via the clone) and auto-loads `.agents/agents.md`
   into the system prompt as user_rules. install.sh inlines the persona
   stubs from `.agents/AGENTIC_DEV_TEAM.md` into a marker-fenced block
   inside your `agents.md`, so Antigravity sees them in-context without
   needing to load another file. The HTML-comment markers
   (`<!-- agentic-dev-team:start -->` / `<!-- agentic-dev-team:end -->`)
   are ignored by Antigravity.
4. **opencode discovery.** opencode scans `.opencode/commands/` for slash
   commands (our files there are symlinks into `.claude/commands/` via the
   clone) and `.opencode/agents/` for subagents. Each agent file is a
   `mode: subagent` stub whose body reads its canonical prompt at
   `.claude/agents/adt-*.md`, so the orchestrator can delegate to
   `@adt-android-architect`, `@adt-android-coder`, etc. with the identical
   persona. opencode runs every subagent on your currently selected model (the
   stubs set no per-role `model:`), matching Antigravity. No `agents.md`
   inlining is needed — the per-file agent definitions are the discovery
   mechanism.
5. **Cross-tool source of truth.** All three tools end up reading the same
   agent prompts and the same `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` for
   orchestration rules. Edits to those files in the clone propagate to
   every consuming project on the next file read — no install required
   for in-place edits.
6. **`.gitignore` block.** Symlink targets are per-developer absolute
   paths (`~/code/agentic-dev-team/...`) and would not resolve on a
   teammate's machine, so install.sh manages a small block in
   `.gitignore` listing them.

## What gets installed

For each file this repo owns, install.sh creates a symlink at the matching
path inside your project:

| Project path | → Symlink target (in your clone) |
|---|---|
| `.claude/commands/build-guided.md` | `<clone>/.claude/commands/build-guided.md` |
| `.claude/commands/build-auto.md` | `<clone>/.claude/commands/build-auto.md` |
| `.claude/commands/build-auto-reviewed.md` | `<clone>/.claude/commands/build-auto-reviewed.md` |
| `.claude/commands/plan-research.md` | `<clone>/.claude/commands/plan-research.md` |
| `.claude/commands/plan-design.md` | `<clone>/.claude/commands/plan-design.md` |
| `.claude/agents/adt-android-pm.md` | `<clone>/.claude/agents/adt-android-pm.md` |
| `.claude/agents/adt-android-architect.md` | `<clone>/.claude/agents/adt-android-architect.md` |
| `.claude/agents/adt-android-architect-reviewer.md` | `<clone>/.claude/agents/adt-android-architect-reviewer.md` |
| `.claude/agents/adt-android-coder.md` | `<clone>/.claude/agents/adt-android-coder.md` |
| `.claude/agents/adt-android-code-reviewer.md` | `<clone>/.claude/agents/adt-android-code-reviewer.md` |
| `.claude/agents/adt-android-tester.md` | `<clone>/.claude/agents/adt-android-tester.md` |
| `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` | `<clone>/.claude/AGENTIC_DEV_TEAM_PIPELINE.md` |
| `.agents/workflows/build-guided.md` | `<clone>/.agents/workflows/build-guided.md` |
| `.agents/workflows/build-auto.md` | `<clone>/.agents/workflows/build-auto.md` |
| `.agents/workflows/build-auto-reviewed.md` | `<clone>/.agents/workflows/build-auto-reviewed.md` |
| `.agents/workflows/plan-research.md` | `<clone>/.agents/workflows/plan-research.md` |
| `.agents/workflows/plan-design.md` | `<clone>/.agents/workflows/plan-design.md` |
| `.opencode/commands/build-guided.md` | `<clone>/.opencode/commands/build-guided.md` |
| `.opencode/commands/build-auto.md` | `<clone>/.opencode/commands/build-auto.md` |
| `.opencode/commands/build-auto-reviewed.md` | `<clone>/.opencode/commands/build-auto-reviewed.md` |
| `.opencode/commands/plan-research.md` | `<clone>/.opencode/commands/plan-research.md` |
| `.opencode/commands/plan-design.md` | `<clone>/.opencode/commands/plan-design.md` |
| `.opencode/agents/adt-android-pm.md` | `<clone>/.opencode/agents/adt-android-pm.md` |
| `.opencode/agents/adt-android-architect.md` | `<clone>/.opencode/agents/adt-android-architect.md` |
| `.opencode/agents/adt-android-architect-reviewer.md` | `<clone>/.opencode/agents/adt-android-architect-reviewer.md` |
| `.opencode/agents/adt-android-coder.md` | `<clone>/.opencode/agents/adt-android-coder.md` |
| `.opencode/agents/adt-android-code-reviewer.md` | `<clone>/.opencode/agents/adt-android-code-reviewer.md` |
| `.opencode/agents/adt-android-tester.md` | `<clone>/.opencode/agents/adt-android-tester.md` |

The canonical `AGENTIC_DEV_TEAM_PIPELINE.md` lives in
`plugins/agentic-dev-team/` (so the Claude Code plugin packages it); the
clone's `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` is a symlink to it, so the
project-side path in the table above is unchanged and installed projects
need no re-install.

Two additional changes happen via **marker-fenced managed blocks** (not symlinks):

- `.gitignore` gains a small block listing the symlink paths above (since
  the symlink targets are per-developer absolute paths and can't be
  committed) plus `/pipeline_artifacts/`.
- `.agents/agents.md` gains a block containing the inlined persona stubs
  from this repo's `.agents/AGENTIC_DEV_TEAM.md`. Antigravity auto-loads
  `agents.md` into the system prompt as user_rules, so this is how
  Antigravity discovers the team. If the file doesn't exist, it's created.
  If it does exist, your existing content outside the markers is left
  untouched.

After install, `ls -la .claude/commands/` makes ownership obvious — each
of our entries shows an `->` arrow pointing at the clone. Your own files
in the same directories have no arrow.

## Refusal behavior

If a real file or non-our-symlink already exists at one of our destinations,
install.sh refuses with the path and a clear "rename or delete, then re-run"
message. Nothing is ever overwritten silently. Pre-flight collision checks
run before any symlink is created, so a refusal leaves the install in a
clean state.

## Extending the Pipeline

For maintainers / contributors who want to add new agents or commands:

- **Adding a new agent.** Create `.claude/agents/adt-<name>.md` in this
  repo (always use the `adt-` prefix to stay collision-free with
  developers' own agents). Add a short stub block to
  `.agents/AGENTIC_DEV_TEAM.md` using the `@adt-<name>` handle and
  referencing the new prompt (for Antigravity). Create
  `.opencode/agents/adt-<name>.md` as a `mode: subagent` stub whose body
  reads the canonical `.claude/agents/adt-<name>.md` (for opencode). On the
  next `install.sh` run in each consuming project, the new agent becomes
  invocable as `@adt-<name>` in all three tools, and the persona-registry
  block in `agents.md` automatically updates with the new stub.
- **Adding a new command / workflow.** Create `.claude/commands/<name>.md`
  with the orchestration prompt. Create `.agents/workflows/<name>.md` and
  `.opencode/commands/<name>.md` as symlinks to
  `../../.claude/commands/<name>.md` so Antigravity and opencode see it too.
  `/build-auto-reviewed` is built exactly this way: its workflow symlinks
  point at the command, which orchestrates the two reviewer agents between
  the existing phases.
- **Updating shared orchestration rules.** Edit the canonical file,
  `plugins/agentic-dev-team/AGENTIC_DEV_TEAM_PIPELINE.md` (the clone's
  `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` is a symlink to it). Because agent
  prompts reference it by path and the project's copy is a symlink into the
  clone, edits propagate the next time an agent reads the file — no install
  needed. Agent-facing rules go in **Part A**, orchestrator-only rules in
  **Part B**: agents are told to read Part A and skip Part B.
- **Removing or renaming files.** Just delete or rename in the repo.
  install.sh's sync logic removes stale symlinks from consuming projects
  on the next run.

## Project Context (`AGENTS.md` / `CLAUDE.md`)

Every `adt-*` agent reads the consuming project's `AGENTS.md` or `CLAUDE.md`
(whichever exists) for project-specific context: stack, architecture,
conventions, and verification rules. The pipeline agents look for either
file automatically — you don't need to document the pipeline itself in it.

## Troubleshooting

- **"install.sh refused with 'real file at X'"** — you have your own file
  at one of our install paths. Rename or delete one side, then re-run.
- **"I pulled the repo but new commands aren't showing up"** — run
  `install.sh` in the project again; `git pull` alone doesn't materialize
  symlinks for newly added files.
- **"I see a broken symlink in `.claude/agents/`"** — likely a file was
  renamed or removed in the repo. Run `install.sh`; the sync removes
  stale symlinks.
- **"An agent's persona looks out of date in Antigravity"** — the persona
  stubs are *inlined* into the project's `.agents/agents.md` at install time,
  not symlinked. When this repo's `.agents/AGENTIC_DEV_TEAM.md` changes,
  re-run `install.sh` in the project to refresh that block; `git pull` alone
  doesn't rewrite it. (Agent prompts and the pipeline doc are symlinked, so
  they need no re-install.)
- **"Both AGENTS.md and CLAUDE.md exist as real files"** — the pipeline
  agents will read whichever they find first. For consistency, pick one
  as canonical and keep them in sync (or delete one).
