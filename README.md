# Agentic Android Dev Team

Reusable PM → Architect → Coder → Tester pipeline for Android projects, usable
from Claude Code and Antigravity.

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

## After Installing

- Create or update `AGENTS.md` in the project root with the app's engineering conventions and a short `## Shared Agent Pipeline` section pointing at `.claude/PIPELINE.md`.
- Add `/pipeline_artifacts/` to `.gitignore` (the agents write per-feature artifacts there).
- Use `/review <vague idea>` for ideation flows and `/build <specified feature>` for direct implementation.
