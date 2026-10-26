---
name: build-auto
description: Architect → Coder → Tester for an already-specified Android feature. The agentic-dev-team /build-auto command, for Codex.
---

# build-auto

This skill runs the agentic-dev-team command `/build-auto` in Codex. Its
command file holds the whole procedure, the same one that Claude Code,
Antigravity and OpenCode follow. This skill only says where that file is and
how its words map to Codex. In any other tool, do not follow it: tell the
user to type `/build-auto` instead.

1. **ARGUMENTS** is the text of the user's message after this skill's name,
   which is `$build-auto`, or `$agentic-dev-team:build-auto` from the plugin.
   ARGUMENTS can be empty.
2. **The command file.** If `.claude/commands/build-auto.md` exists in the
   project root, this is an `install.sh` install: use that file. Otherwise
   this skill comes from the Codex plugin, and this file is
   `PLUGIN_ROOT/codex/skills/build-auto/SKILL.md`. PLUGIN_ROOT is the absolute
   path of this file without its last four parts (the directory that holds
   `commands/`, `agents/` and `scripts/`), and the command file is
   `PLUGIN_ROOT/commands/build-auto.md`.
3. **Follow it.** Read the command file in full, skip its YAML frontmatter,
   and follow it exactly, as the orchestrator. In the command file, and in
   every file it sends you to:
   - `$ARGUMENTS` means ARGUMENTS;
   - `${CLAUDE_PLUGIN_ROOT}` means PLUGIN_ROOT (only a plugin install uses
     it);
   - a command such as `/plan-design` is the skill `$plan-design` in Codex.
4. **Codex.** Before the first agent starts, read "Orchestration Workflow
   (Codex)" in ORCHESTRATION_DOC (the command file says where that file is).
   It says how to start each `adt-*` agent in Codex, and what else differs.
