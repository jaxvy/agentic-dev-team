# Agentic Android Dev Team

A reusable PM → Architect → Coder → Tester pipeline for Android projects,
working identically in [Claude Code](https://claude.com/claude-code) and
[Antigravity](https://antigravity.google). Distributed as per-file symlinks
into each consuming project — no whole-dir symlinks, no forced migration
of your existing `.claude/` or `.agents/` content.

## How To Use It

Once installed in a project, open it in Claude Code or Antigravity and run a
slash command from the chat prompt. The `build-*` commands run the full
pipeline end to end (the suffix tells you whether a human is in the loop, and
whether automated reviewers gate each phase); the two `plan-*` commands run just
one early phase and stop, so you can research or design without committing to a
build.

### `/build-guided <vague idea>`

Human-in-the-loop variant. PM → Architect → Coder → Tester with approval
gates between phases. Use when the idea is rough and you want the PM to
refine it before any code is written.

```
/build-guided add a recently-played carousel to the home screen
```

The PM agent turns that into a concrete feature spec at
`pipeline_artifacts/<slug>/feature.md` and pauses for your sign-off. After
you approve, the Architect produces an implementation plan, the Coder
implements it, and the Tester verifies — each phase stops for review.

### `/build-auto <specified feature>`

Fully automatic variant. Architect → Coder → Tester, no gates. Use when
the feature is already specified.

```
/build-auto add a "Save draft on background" hook to ComposeViewModel that persists the current input to Room every 2s and restores it on launch
```

The Architect writes the plan, the Coder implements it, the Tester runs
verification on a device via the auto-mobile MCP server. Artifacts for
every run land under `pipeline_artifacts/<slug>/`.

### `/build-auto-reviewed <specified feature>`

Same shape as `/build-auto` (no PM phase, no human gates), but each producing
phase is followed by an automated reviewer that can send the work back. Use when
you want a higher-quality unattended run and are willing to spend more tokens for
it.

```
/build-auto-reviewed add a "Save draft on background" hook to ComposeViewModel that persists the current input to Room every 2s and restores it on launch
```

The Architect writes the plan, then `@adt-android-architect-reviewer` reviews
it; the Coder implements, then `@adt-android-code-reviewer` reviews the diff. On
each gate, if the reviewer requests changes, the producing agent is re-run with
the feedback — **at most twice** per gate. If a reviewer still isn't satisfied
after the second re-run, the pipeline **stops and reports** rather than shipping
work the reviewer rejected. A clean run then hands off to the Tester as usual.

### Planning-only commands

When you want a plan but not a build, run just one phase. Both stop after
writing their artifact, and their output chains into a build command (or each
other) later.

#### `/plan-research <vague idea>`

Runs only the PM. Turns a rough idea into a concrete, unambiguous feature spec
at `pipeline_artifacts/<slug>/feature.md`, asking clarifying questions along
the way — then stops.

```
/plan-research add a recently-played carousel to the home screen
```

Feed the resulting `feature.md` to `/plan-design`, `/build-auto`, or
`/build-guided` when you're ready.

#### `/plan-design <feature.md path | specified feature>`

Runs only the Architect. Produces an implementation plan at
`pipeline_artifacts/<slug>/implementation-plan.md` from either a `feature.md`
(e.g. from `/plan-research`) or a clear feature description — then stops.

```
/plan-design pipeline_artifacts/recently-played-carousel/feature.md
```

Feed the resulting plan to `/build-auto` or `/build-guided` to implement and
verify it.

### Running a single phase

You don't have to run the whole pipeline. To do just the early planning work,
use the planning-only commands — each runs a single phase and stops after
writing its artifact, and both work identically in Claude Code and Antigravity:

- **`/plan-research <vague idea>`** — runs the PM phase to research a rough idea
  into a concrete feature spec (`feature.md`).
- **`/plan-design <feature.md | feature description>`** — runs the Architect
  phase to produce an implementation plan (`implementation-plan.md`).

## Installation

Two paths:

- **Claude Code plugin** — installable from the Claude Code CLI via the plugin marketplace. Installs the `adt-*` agents and the `/build-auto`, `/build-auto-reviewed`, `/build-guided`, `/plan-research`, and `/plan-design` slash commands without per-project setup. Does **not** wire up Antigravity (no `.agents/workflows/` files, no `agents.md` persona stubs, no `.gitignore` block).
- **install.sh per-project (local repo install)** — works for both Claude Code and Antigravity. Materializes per-file symlinks inside each consuming project, manages a `.gitignore` block, and inlines persona stubs into `.agents/agents.md` for Antigravity. **This is the only supported path for Antigravity** — Antigravity has no plugin marketplace.

The two are not mutually exclusive — you can install the plugin in Claude Code and still run `install.sh` in Antigravity projects.

### Install via Claude Code marketplace (plugin)

From inside the Claude Code CLI:

```
/plugin marketplace add jaxvy/agentic-dev-team
/plugin install agentic-dev-team@adt-pipeline
```

Claude Code will prompt for an install scope:

| Scope | Storage | Committed to git? | Behavior |
|---|---|---|---|
| User (`Install for you`) | `~/.claude/` | No | Plugin available in every Claude Code session on your machine. |
| Project (`Install for all collaborators on this repository`) | `.claude/settings.json` in the repo | Yes | Anyone who clones the repo and runs `claude` is prompted to install. |
| Local (`Install for you, in this repo only`) | `.claude/settings.local.json` in the repo | No (gitignored) | Plugin active only in this repo, only for you. |

After install, `/build-auto`, `/build-auto-reviewed`, `/build-guided`, `/plan-research`, `/plan-design`, and the six `@adt-*` agents are available. To update, run `/plugin marketplace update adt-pipeline`. To remove, `/plugin uninstall agentic-dev-team@adt-pipeline`.

If you also want Antigravity support, additionally follow the install.sh path below — they coexist without conflict.

### Prerequisites

- `git`.
- A [Claude Code](https://claude.com/claude-code) or
  [Antigravity](https://antigravity.google) install.
- An Android project with an `AGENTS.md` or `CLAUDE.md` describing the
  app's stack, architecture, conventions, and verification rules. The
  pipeline agents look for either file.
- **auto-mobile MCP server** ([kaeawc/auto-mobile](https://github.com/kaeawc/auto-mobile))
  installed and registered with your tool. The `adt-android-tester` agent drives
  the running app on a device/emulator through this MCP — without it, the
  Tester phase of `/build-guided`, `/build-auto`, and `/build-auto-reviewed`
  cannot complete its device-verification step.

### One-time setup (per developer)

Clone this repo to a stable location on your machine. The path is a
suggestion — pick whatever you want:

```bash
git clone https://github.com/jaxvy/agentic-dev-team.git ~/code/agentic-dev-team
```

### Per-project install

From each Android project root, run install.sh directly from the clone:

```bash
cd /path/to/your-android-project
~/code/agentic-dev-team/install.sh
```

The installer is **completely non-destructive**: it only creates symlinks
for the specific files this repo provides. Your existing `.claude/` and
`.agents/` content is never touched, modified, or migrated.

### What gets installed

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


### Refusal behavior

If a real file or non-our-symlink already exists at one of our destinations,
install.sh refuses with the path and a clear "rename or delete, then re-run"
message. Nothing is ever overwritten silently. Pre-flight collision checks
run before any symlink is created, so a refusal leaves the install in a
clean state.

## Updating

The canonical update incantation (run after pulling new changes in the
clone):

```bash
cd ~/code/agentic-dev-team && git pull && cd /path/to/your-project
~/code/agentic-dev-team/install.sh
```

Why both steps:

- `git pull` refreshes the source files in the clone. Edits to existing
  agent prompts, commands, or `AGENTIC_DEV_TEAM_PIPELINE.md` are picked up
  immediately because your project's symlinks already point at them.
- **install.sh** must run again to materialize symlinks for any **newly
  added** files in the repo (e.g., a new agent like
  `adt-android-code-reviewer.md`, or a new command like
  `/build-auto-reviewed`), and to clean up stale
  symlinks for any **removed** files. It also refreshes the inlined
  persona stubs in `.agents/agents.md` from the latest
  `.agents/AGENTIC_DEV_TEAM.md`.

install.sh is a **sync**, not just an append: adds new symlinks, removes
stale ones (where the source no longer exists), and rewrites the marker
blocks to reflect current state.

Suggested shell function for one-shot updates across multiple projects:

```bash
agentic-dev-team-update() {
  (cd ~/code/agentic-dev-team && git pull) || return 1
  ~/code/agentic-dev-team/install.sh
}
```

## Uninstalling

From the project root:

```bash
~/code/agentic-dev-team/install.sh --uninstall
```

This removes only what install.sh created:

- Every symlink whose target resolves into the clone.
- The marker-fenced block in `.gitignore` (your other gitignore entries
  are preserved).
- The marker-fenced block in `.agents/agents.md` (and the file itself if
  it ends up empty).

Your own files, content outside the markers, and the clone at
`~/code/agentic-dev-team` are all untouched.

## How It Works

This repo is a **shared configuration package**, not a library you import.
Each Android project that wants the pipeline links this repo's files into
its own `.claude/` and `.agents/`.

The mechanics:

1. **Per-file symlinks, not per-directory.** Your project's `.claude/`
   and `.agents/` stay real directories. You can keep adding your own
   commands/agents alongside our symlinks — they coexist freely.
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
4. **Cross-tool source of truth.** Both tools end up reading the same
   agent prompts and the same `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` for
   orchestration rules. Edits to those files in the clone propagate to
   every consuming project on the next file read — no install required
   for in-place edits.
5. **`.gitignore` block.** Symlink targets are per-developer absolute
   paths (`~/code/agentic-dev-team/...`) and would not resolve on a
   teammate's machine, so install.sh manages a small block in
   `.gitignore` listing them.

## Extending the Pipeline

For maintainers / contributors who want to add new agents or commands:

- **Adding a new agent.** Create `.claude/agents/adt-<name>.md` in this
  repo (always use the `adt-` prefix to stay collision-free with
  developers' own agents). Add a short stub block to
  `.agents/AGENTIC_DEV_TEAM.md` using the `@adt-<name>` handle and
  referencing the new prompt. On the next `install.sh` run in each
  consuming project, the new agent becomes invocable as `@adt-<name>`
  and the persona-registry block in `agents.md` automatically updates
  with the new stub.
- **Adding a new command / workflow.** Create `.claude/commands/<name>.md`
  with the orchestration prompt. Create `.agents/workflows/<name>.md` as
  a symlink to `../../.claude/commands/<name>.md` so Antigravity sees it
  too. `/build-auto-reviewed` is built exactly this way: its workflow
  symlink points at the command, which orchestrates the two reviewer
  agents between the existing phases.
- **Updating shared orchestration rules.** Edit
  `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`. Because agent prompts reference
  it by path and the project's copy is a symlink into the clone, edits
  propagate the next time an agent reads the file — no install needed.
- **Removing or renaming files.** Just delete or rename in the repo.
  install.sh's sync logic removes stale symlinks from consuming projects
  on the next run.

## Project Context (`AGENTS.md` / `CLAUDE.md`)

Every `adt-*` agent reads the consuming project's `AGENTS.md` or `CLAUDE.md`
(whichever exists) for project-specific context: stack, architecture,
conventions, and verification rules. The pipeline agents look for either
file automatically — you don't need to document the pipeline itself in it.

## Roadmap

- **Reviewer gates for the guided flow** — `/build-auto-reviewed` already adds
  an architect-reviewer (after Architect) and a code-reviewer (after Coder) to
  the autonomous flow. A guided equivalent could surface the same reviewer
  feedback at the human approval gates, and a `pm-reviewer` could vet the
  feature spec before the Architect sees it.
- **Antigravity marketplace equivalent.** Antigravity doesn't yet have a
  plugin marketplace; once it does, ship an equivalent so the install.sh
  path becomes optional for Antigravity users too.

## Troubleshooting

- **"install.sh refused with 'real file at X'"** — you have your own file
  at one of our install paths. Rename or delete one side, then re-run.
- **"I pulled the repo but new commands aren't showing up"** — run
  `install.sh` in the project again; `git pull` alone doesn't materialize
  symlinks for newly added files.
- **"I see a broken symlink in `.claude/agents/`"** — likely a file was
  renamed or removed in the repo. Run `install.sh`; the sync removes
  stale symlinks.
- **"Both AGENTS.md and CLAUDE.md exist as real files"** — the pipeline
  agents will read whichever they find first. For consistency, pick one
  as canonical and keep them in sync (or delete one).
