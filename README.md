# Agentic Android Dev Team

A reusable PM → Architect → Coder → Tester pipeline for Android projects,
working identically in [Claude Code](https://claude.com/claude-code),
[Antigravity](https://antigravity.google), and [opencode](https://opencode.ai).
Distributed as per-file symlinks into each consuming project — no whole-dir
symlinks, no forced migration of your existing `.claude/`, `.agents/`, or
`.opencode/` content.

## How To Use It

Once installed in a project, open it in Claude Code, Antigravity, or opencode
and run a slash command from the chat prompt. The `build-*` commands run the full
pipeline end to end (the suffix tells you whether a human is in the loop, and
whether automated reviewers gate each phase); the two `plan-*` commands run just
one early phase and stop, so you can research or design without committing to a
build.

If the Tester ends on `NEEDS FIXES`, the Coder gets up to **two** fix-and-retest
attempts, each one code-reviewed before it is re-tested. If it still fails, the
run stops and says so rather than reporting a feature that doesn't work.

The Tester only sends the Coder back for **blocking** findings — behaviour that
contradicts your request, the approved plan, or the project's own conventions,
plus crashes, data loss, and regressions. Anything else it notices (a UX
opinion, an edge case nobody specified) is recorded as an **observation** in
`test-results.md` for you to decide on. QA finds defects; it doesn't get to
invent requirements mid-run.

Each project's build, lint, test, and install commands are **discovered per
project**, not assumed. The Architect resolves them against your Gradle setup
and records them in the plan's Section 0, so a project without `detekt`, or one
that needs `:app:lintDebug` and a `demoDebug` variant, runs its own commands
rather than failing on tasks it never defined.

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
it; the Coder implements, then `@adt-android-code-reviewer` reviews the full set
of changes — the diff *and* every new untracked file, which `git diff` doesn't
show. On each gate, if the reviewer requests changes, the producing agent is
re-run with the feedback — **at most twice** per gate. If a reviewer still isn't
satisfied after the second re-run, the pipeline **stops and reports** rather
than shipping work the reviewer rejected. A clean run then hands off to the
Tester as usual.

Fixes made *after* that review are reviewed too. When the Tester finds a defect
and the Coder patches it, a **targeted re-review** of the patch runs before the
re-test — so the tree you're handed has passed code review after its last
change, not before it. Without that step, a fix could reach `READY TO MERGE`
having been tested but never read.

### Planning-only commands

When you want a plan but not a build, run just one phase — each runs a single
phase, stops after writing its artifact, and works identically in Claude Code,
Antigravity, and opencode. Their output chains into a build command (or each
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

## Installation

Two paths:

- **Claude Code plugin** — installable from the Claude Code CLI via the plugin marketplace. Installs the `adt-*` agents and the `/build-auto`, `/build-auto-reviewed`, `/build-guided`, `/plan-research`, and `/plan-design` slash commands without per-project setup. Does **not** wire up Antigravity or opencode (no `.agents/workflows/` or `.opencode/` files, no `agents.md` persona stubs, no `.gitignore` block).
- **install.sh per-project (local repo install)** — works for Claude Code, Antigravity, and opencode. Materializes per-file symlinks inside each consuming project (`.claude/`, `.agents/workflows/`, and `.opencode/`), manages a `.gitignore` block, and inlines persona stubs into `.agents/agents.md` for Antigravity. **This is the only supported path for Antigravity and opencode** — neither has a Claude Code plugin marketplace.

The two are not mutually exclusive — you can install the plugin in Claude Code and still run `install.sh` in Antigravity or opencode projects.

### Install via Claude Code marketplace (plugin)

From inside the Claude Code CLI:

```
/plugin marketplace add jaxvy/agentic-dev-team
/plugin install agentic-dev-team@adt-pipeline
```

### Prerequisites

- `git`.
- A [Claude Code](https://claude.com/claude-code),
  [Antigravity](https://antigravity.google), or [opencode](https://opencode.ai)
  install.
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
for the specific files this repo provides. Your existing `.claude/`,
`.agents/`, and `.opencode/` content is never touched, modified, or migrated.
See [HOW_IT_WORKS.md](HOW_IT_WORKS.md) for the full list of symlinks and
managed blocks it creates, and its refusal behavior on collisions.

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

See [HOW_IT_WORKS.md](HOW_IT_WORKS.md) for the mechanics (per-tool discovery,
symlink layout, cross-tool source of truth), the full list of what install.sh
installs and its refusal behavior, how to extend the pipeline with new agents
or commands, project context (`AGENTS.md` / `CLAUDE.md`), and troubleshooting.
