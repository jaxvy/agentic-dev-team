# Agentic Android Dev Team

Six specialist AI agents that work like an Android team. You describe a feature
in your editor's chat prompt, and they pass it down the line: product spec,
implementation plan, code, then testing on a real device. What comes back is an
uncommitted diff and a test report.

Works the same way in [Claude Code](https://claude.com/claude-code),
[Antigravity](https://antigravity.google), and [OpenCode](https://opencode.ai).

## How a run works

Every run is the same chain of handoffs. Each agent reads the previous agent's
output in full before it starts, so the spec constrains the plan, the plan
constrains the code, and the plan's test cases are what the Tester actually runs.

```
   PM   ->   Architect   ->   Coder   ->   Tester
feature.md  impl-plan.md    the code    test-results.md
```

You decide how much of that chain runs and who approves each step. One command
starts from a vague idea and pauses for your sign-off at every boundary, another
runs start to finish unattended, and a third puts an automated reviewer between
the phases. Two more run a single phase and stop.

Written artifacts land in a git-ignored folder for the feature. The code itself
stays uncommitted in your working tree, so you review it and commit on your own
terms.

## Why it is split up this way

A single agent asked to "build this feature" will plan it, write it, and grade
its own work in one pass. This project splits that job across agents with
separate mandates, and puts a reviewer between them.

* The Architect reads your codebase and writes the plan before any code exists.
  It names exact files and line numbers, and records the manual test plan up
  front.
* In the reviewed flow, code review always covers the final state of the tree,
  including fixes made after testing.
* The Tester drives the real app on a device or emulator, not a mocked harness.
* Retry loops are bounded. Reviewers get at most two rounds, the fix loop gets at
  most two, and a run that still fails stops and explains why instead of
  reporting success.
* Nothing is committed for you.

## The agents

| Agent | Role | Output |
|---|---|---|
| `adt-android-pm` | Principal Product Manager | `feature.md`, an unambiguous spec |
| `adt-android-architect` | Staff+ Android engineer | `implementation-plan.md`, with exact file changes and a manual test plan |
| `adt-android-architect-reviewer` | Plan reviewer, read-only | Approval, or a numbered list of required changes |
| `adt-android-coder` | Implementer | Uncommitted code in your working tree |
| `adt-android-code-reviewer` | Code reviewer, read-only | Approval, or a numbered list of required changes |
| `adt-android-tester` | Principal QA engineer | `test-results.md`, with a verdict from a real device |

Each agent reads your project's `AGENTS.md` (or `CLAUDE.md`) for stack,
architecture, and conventions, so the output matches your codebase rather than a
generic Android one.

## Commands

Five slash commands. Three run the full pipeline, two stop after a single phase.

| Command | Phases | Who approves | Use it for |
|---|---|---|---|
| `/build-guided` | PM, Architect, Coder, Tester | You, at every phase boundary | A rough idea you want shaped before code exists |
| `/build-auto` | Architect, Coder, Tester | Nobody, it runs start to finish | A feature you have already specified precisely |
| `/build-auto-reviewed` | Architect, Coder, Tester, plus a reviewer after the first two | Reviewer agents, with no human pause | An unattended run you want to trust. Costs more tokens |
| `/plan-research` | PM only | n/a | Turning a vague idea into a spec and nothing more |
| `/plan-design` | Architect only | n/a | Turning a spec into a plan and nothing more |

The two `plan-*` commands write their artifact and stop. Their output feeds
straight into a `build-*` command later, or into each other.

### /build-guided

```
/build-guided add a recently-played carousel to the home screen
```

The PM asks clarifying questions, writes a spec, and pauses. At each boundary you
reply `approve`, `revise: <feedback>`, or `stop`. Before the Coder runs, you also
see whether the Architect judged the work parallel-safe and how many coder agents
that implies. Reply `force-sequential` to override it and spend fewer tokens.

### /build-auto

```
/build-auto add a "save draft on background" hook to ComposeViewModel that
            persists the current input to Room every 2s and restores it on launch
```

No PM phase and no pauses. If the request turns out to be too vague for the
Architect to plan concretely, the run stops and points you at `/build-guided`.

### /build-auto-reviewed

```
/build-auto-reviewed add a "save draft on background" hook to ComposeViewModel
                     that persists input to Room every 2s and restores on launch
```

Same shape as `/build-auto`, with an automated reviewer after each producing
phase. The plan reviewer reads the plan. The code reviewer reads the full set of
changes, which includes every new untracked file, not just what shows up in
`git diff`.

When a reviewer requests changes, the producing agent re-runs with that feedback,
at most twice per gate. If the reviewer is still unsatisfied after the second
re-run, the pipeline stops and reports instead of shipping rejected work.

### /plan-research and /plan-design

```
/plan-research add a recently-played carousel to the home screen
/plan-design   pipeline_artifacts/recently-played-carousel/feature.md
```

These run the PM alone, or the Architect alone. Use them to think a feature
through, or to size the work, without committing to a build.

## What a run leaves behind

Artifacts land in `pipeline_artifacts/<feature-slug>/`, which is git-ignored:

```
pipeline_artifacts/recently-played-carousel/
├── feature.md              # the spec (PM phases only)
├── implementation-plan.md  # the plan, including the manual test plan
└── test-results.md         # per-case results, verdict, observations
```

Alongside that is the actual work: uncommitted changes in your working tree.
Review them, stage what you want, and commit on your own terms.

## Safeguards

### Testing cannot invent requirements

The Tester only sends work back for *blocking* findings: behaviour that
contradicts your request, the approved plan, or your project's conventions, plus
crashes, data loss, and regressions. Anything else it notices, such as a UX
opinion or an unspecified edge case, is recorded as an *observation* in
`test-results.md` for you to decide on. QA finds defects. It does not get to add
scope mid-run.

### Reviews cover the final code

An approval applies to the tree that existed when it was issued. When the Tester
finds a defect and the Coder patches it, a targeted re-review of that patch runs
before the re-test. The tree you are handed has passed review after its last
change, not before it.

### Build commands are discovered, not assumed

The Architect resolves your project's real build, lint, test, and install
commands against your Gradle setup and records them in the plan. A project
without `detekt`, or one that needs `:app:lintDebug` and a `demoDebug` variant,
runs its own commands instead of failing on tasks it never defined.

### Parallel work is checked before it starts

When the Architect marks sections parallel-safe, the orchestrator verifies
mechanically that no file is claimed by two sections in the same group before
spawning anyone, then verifies the result again after every group.

### The installer never overwrites anything

`install.sh` only creates symlinks for files this repo owns. If something of
yours already sits at one of those paths, it refuses and names the path.

## Requirements

* `git`
* One of [Claude Code](https://claude.com/claude-code),
  [Antigravity](https://antigravity.google), or [OpenCode](https://opencode.ai)
* An Android project with an `AGENTS.md` or `CLAUDE.md` describing its stack,
  architecture, conventions, and verification rules
* The [auto-mobile MCP server](https://github.com/kaeawc/auto-mobile) registered
  with your tool. The Tester drives the app on a device or emulator through it,
  and without it the Tester phase cannot finish its device verification.

## Installation

There are two paths, and they are not mutually exclusive.

### Install as a Claude Code plugin

The fastest path if you only use Claude Code. From inside the CLI:

```
/plugin marketplace add jaxvy/agentic-dev-team
/plugin install agentic-dev-team@adt-pipeline
```

This installs all six agents and all five commands with no per-project setup. It
does not wire up Antigravity or OpenCode.

### Install per project with install.sh

This is the only supported path for Antigravity and OpenCode, since neither has a
plugin marketplace. It also works alongside the plugin.

Clone the repo once, anywhere you like:

```bash
git clone https://github.com/jaxvy/agentic-dev-team.git ~/code/agentic-dev-team
```

Then run the installer from each Android project root:

```bash
cd /path/to/your-android-project
~/code/agentic-dev-team/install.sh
```

It links the agents and commands into the project's `.claude/`,
`.agents/workflows/`, and `.opencode/`. Your existing content in those
directories is never touched, modified, or migrated.

### Updating

```bash
cd ~/code/agentic-dev-team && git pull && cd /path/to/your-project
~/code/agentic-dev-team/install.sh
```

`git pull` refreshes edits to existing agents and commands, and those take effect
immediately because your project links to them. Re-running `install.sh` is what
picks up newly added files and clears out removed ones. It is a sync rather than
an append.

### Uninstalling

```bash
~/code/agentic-dev-team/install.sh --uninstall
```

This removes only what it created: its own symlinks, and its marker-fenced blocks
in `.gitignore` and `.agents/agents.md`. Your files and the clone are left alone.

## Further reading

[HOW_IT_WORKS.md](HOW_IT_WORKS.md) covers the pipeline phase by phase, the rules
that keep it honest, how the three tools discover the same files, everything
`install.sh` creates, how to add your own agents and commands, and
troubleshooting.

## Built with this pipeline

This project was used to build
[MaybeLater](https://play.google.com/store/apps/details?id=com.jaxvy.maybelater),
a shipped Android app, as a way to validate that the pipeline holds up on real
work rather than on examples written for a README. You can find the app at
[getmaybelater.app](https://getmaybelater.app) or on
[Google Play](https://play.google.com/store/apps/details?id=com.jaxvy.maybelater).

## License

See [LICENSE](LICENSE).
