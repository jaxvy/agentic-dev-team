# Agentic Android Dev Team

Reusable PM → Architect → Coder → Tester pipeline for Android projects. Works
with both [Claude Code](https://claude.com/claude-code) and
[Antigravity](https://antigravity.google) — the same agent prompts and slash
commands are exposed to each tool via its native configuration directory.

## How To Use It

Once installed, open the Android project in Claude Code or Antigravity and run
either slash command from the chat prompt. The exact same flows work in both
tools.

### `/review <vague idea>`

Use this when you have a rough idea and want the team to think it through
before any code is written. Runs PM → Architect → Coder → Tester with human
approval gates between phases.

```
/review users keep losing their draft when the app is killed mid-typing
```

The PM agent turns that into a concrete feature spec
(`pipeline_artifacts/<slug>/feature.md`) and pauses for your sign-off. After
you approve, the Architect produces an implementation plan, the Coder
implements it, and the Tester verifies — each phase stops for review.

### `/build <specified feature>`

Use this when the feature is already specified and you just want it built.
Skips the PM phase and goes straight to Architect → Coder → Tester.

```
/build add a "Save draft on background" hook to ComposeViewModel that persists the current input to Room every 2s and restores it on launch
```

The Architect writes the plan, the Coder implements it, and the Tester runs
the verification steps from `AGENTS.md`. Artifacts for every run land under
`pipeline_artifacts/<slug>/` so you can audit decisions later.

### Invoking a single agent

You can also call any agent directly without running the full pipeline — handy
for one-off questions or partial work. In Claude Code, address it by name:

```
@architect can you sketch a plan for X?
```

## How This Works

This repo is a *shared configuration package*, not a library you import. Each
Android project that wants the pipeline runs `install.sh`, which links this
repo's agent definitions and slash commands into the project so both Claude
Code and Antigravity can find them.

The mechanics:

1. `install.sh` clones this repo into the consuming project as `.agent-config/`
   (gitignored, treated like a vendored tool).
2. It then symlinks `.claude -> .agent-config/.claude` and
   `.agents -> .agent-config/.agents` at the project root. The `.agent-config/`
   intermediate dir exists because this repo holds *both* `.claude/` and
   `.agents/` plus its own `README.md`/`install.sh`/`.git/` — cloning once
   into `.agent-config/` and symlinking the two subdirs lets a single
   `git pull` update both tools and keeps repo cruft out of the host project
   root.
3. **Claude Code** discovers agents and slash commands by scanning `.claude/` in
   the working directory — so `/review` and `/build` become available
   automatically, and the `pm`, `architect`, `coder`, and `tester` subagents
   can be invoked by name.
4. **Antigravity** discovers teams and workflows by scanning `.agents/` in the
   working directory — the `.agents/agents.md` file registers the same agents
   and the `.agents/workflows/` directory exposes the same `/review` and
   `/build` flows.
5. Both tools read `AGENTS.md` (and the `CLAUDE.md -> AGENTS.md` symlink the
   installer creates) as the project's engineering context. The agents combine
   that project-specific context with the shared orchestration rules in
   `.claude/PIPELINE.md` to produce code that matches the host project's
   conventions.
6. To update the pipeline across all consuming projects, push to this repo and
   re-run `install.sh` (it fast-forwards `.agent-config/`). No per-project
   migration needed.

The result: the consuming Android project's repo stays clean — no agent
prompts checked in, no duplication between Claude Code and Antigravity — and
running `/review` or `/build` in either tool drives the same PM → Architect →
Coder → Tester pipeline.

## What This Provides

- `.claude/agents/{pm,architect,coder,tester}.md` — agent prompts.
- `.claude/commands/{review,build}.md` — `/review` and `/build` slash commands for Claude Code.
- `.claude/PIPELINE.md` — shared orchestration rules (handoff protocol, approval gates, subagent mappings, build/lint gates).
- `.agents/agents.md` + `.agents/workflows/` — Antigravity team and workflow registration (symlinked to the same command files).
- `install.sh` — wires the shared repo into a consuming project as an ignored local clone with `.claude` and `.agents` symlinks.

Each consuming project keeps its own `AGENTS.md` with app-specific architecture,
libraries, ViewModel/MVI rules, and verification requirements.

## Install Into A Project

From the consuming project's root:

```bash
curl -fsSL https://raw.githubusercontent.com/jaxvy/agentic-dev-team/main/install.sh | bash
```

Or clone first and run locally:

```bash
git clone https://github.com/jaxvy/agentic-dev-team.git /path/to/agentic-dev-team
/path/to/agentic-dev-team/install.sh
```

The installer:

1. Clones (or fast-forwards) this repo into `.agent-config/`.
2. Creates `.claude -> .agent-config/.claude` and `.agents -> .agent-config/.agents` symlinks.
3. Creates `CLAUDE.md -> AGENTS.md` if `AGENTS.md` exists and `CLAUDE.md` does not.
4. Adds `/.agent-config/`, `/.claude`, and `/.agents` to `.gitignore`.

It refuses to overwrite existing real `.claude` or `.agents` directories — back them up or migrate first.

### Migrating Existing `.claude` Or `.agents` Content

If the project already has its own `.claude/` or `.agents/` directory, the
installer will exit with a `Refusing to overwrite existing ...` error rather
than touch your files — so **nothing is lost automatically**. To keep your
custom agents and commands alongside the shared pipeline, you have a few
options:

- **Move custom agents/commands to user scope.** Claude Code also reads
  `~/.claude/agents/` and `~/.claude/commands/` (user-level config). Anything
  you move there survives the install and stays available across all
  projects. Antigravity has the same pattern at `~/.agents/`.
- **Fork this repo.** If your custom agents/commands are project-specific and
  meant to be shared with collaborators, fork `agentic-dev-team`, drop your
  files into the fork's `.claude/` and `.agents/`, and run the installer with
  `CONFIG_REPO=https://github.com/<you>/<fork>.git ./install.sh`. Your fork
  becomes the source of truth for the project.
- **Contribute upstream.** If the custom pieces are generally useful, PR them
  into this repo so every consuming project picks them up on the next
  `install.sh` run.

The simplest migration:

```bash
mv .claude .claude.bak
mv .agents .agents.bak   # if present
./install.sh             # now succeeds — sets up the symlinks
# then move any custom files from .claude.bak / .agents.bak into ~/.claude/
# (user scope) or into your fork of this repo
```

## After Installing

- Create or update `AGENTS.md` in the project root with the app's engineering conventions and a short `## Shared Agent Pipeline` section pointing at `.claude/PIPELINE.md`.
- Add `/pipeline_artifacts/` to `.gitignore` (the agents write per-feature artifacts there).
- Use `/review <vague idea>` for ideation flows and `/build <specified feature>` for direct implementation.

### Sample `AGENTS.md`

```markdown
# AGENTS.md

## Stack
- Kotlin, Android Gradle Plugin 8.x, min SDK 26, target SDK 34.
- Jetpack Compose for UI; Material 3 theming.
- Hilt for DI; Coroutines + Flow for async; Room for persistence; Retrofit + OkHttp for networking.

## Architecture
- MVI per screen: `UiState` (immutable data class), `UiEvent` (sealed), `UiEffect` (sealed, one-shot).
- ViewModels expose `StateFlow<UiState>` and a single `onEvent(UiEvent)` entry point. No business logic in Composables.
- Repositories return `Flow` or `Result<T>`; never throw across layer boundaries.
- Package by feature: `feature/<name>/{ui,domain,data}`.

## Conventions
- New screens go under `feature/<name>/ui/` with a `<Name>Screen.kt` + `<Name>ViewModel.kt` pair.
- Strings live in `res/values/strings.xml`; no hardcoded user-facing text.
- Public APIs and ViewModel events get KDoc; private helpers do not.

## Verification
- `./gradlew lint testDebugUnitTest` must pass before any handoff.
- Compose previews required for new screens.
- Manual smoke test on a Pixel 6 emulator (API 34) for any UI-touching change.

## Shared Agent Pipeline
This project uses the shared PM → Architect → Coder → Tester pipeline.
See `.claude/PIPELINE.md` for handoff protocol, approval gates, and artifact locations.
Run `/review <idea>` for ideation or `/build <feature>` for direct implementation.
```

## Additional Info

The current agent set is targeted at **Android development**. The `tester`
agent specifically assumes [kaeawc/auto-mobile](https://github.com/kaeawc/auto-mobile)
is installed and available as an MCP server for driving the app on a device or
emulator.

Planned additions:

- More agent types — code reviewer, implementation-plan reviewer, and other
  quality-gate roles.
- More slash commands — `/fix-bug`, `/test-feature`, and other task-specific
  flows alongside the existing `/review` and `/build`.
- Platform-specific agent sets — web, backend, and iOS variants alongside the
  existing Android lineup.
