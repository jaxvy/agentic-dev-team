# Multi-Agent Pipeline & Orchestration Rules

This file is the shared source of truth for the PM → Architect → Coder → Tester
pipeline. Every agent and command file references this document. Project-specific
architecture, libraries, and verification rules live in the consuming project's
`AGENTS.md` (or `CLAUDE.md`).

The document has two halves:

- **Part A — Agent Protocol**: everything an `adt-*` agent must obey. Agents read
  Part A and stop there.
- **Part B — Orchestration & Tool Registration**: everything only the
  orchestrator (the parent agent or slash command driving a run) needs —
  subagent mappings, approval gates, the reviewer loop, and per-tool
  registration. Agents do not need it.

Commands and orchestrators read both halves.

---

# Part A — Agent Protocol

Applies to any LLM driving the pipeline (Claude Code, Antigravity, Codex,
Gemini, opencode, etc.) and to every `adt-*` agent it spawns.

## Artifact Layout

- **Artifact directory**: each feature gets its own subfolder `pipeline_artifacts/{feature-slug}/`.
  - The feature slug is short, lowercase, hyphen-separated (e.g. `background-link-checks`).
  - `adt-android-pm` writes `pipeline_artifacts/{slug}/feature.md`.
  - `adt-android-architect` writes `pipeline_artifacts/{slug}/implementation-plan.md`. Its `## 0. Verification Commands` block is the run's authority for the named commands below.
  - `adt-android-tester` writes `pipeline_artifacts/{slug}/test-results.md`.
  - `adt-android-coder` produces no markdown — only uncommitted code changes in the working tree.
  - `pipeline_artifacts/` must be git-ignored in the consuming project (install.sh adds it to the managed gitignore block automatically).

## Handoff Protocol

- **Read-before-write**: Every agent must read the prior phase artifact in full before starting. A missing required artifact is a STOP condition — report to the user, do not proceed by guessing.
- **No-commit rule for adt-android-coder**: The Coder must never run `git add`, `git commit`, or any staging command. Changes stay uncommitted for human review.
- **Manual verification**: `adt-android-tester` must perform manual verification through the `auto-mobile` MCP server when that server is available and the consuming project's `AGENTS.md` / `CLAUDE.md` requires it.

## The Three Named Commands

These are the only Gradle verification commands the pipeline runs. Refer to
them by name everywhere else — agent prompts and commands must not restate the
commands themselves.

- **The build gate** — the full end-of-work check. `adt-android-coder` runs it
  before declaring done, and `adt-android-code-reviewer` runs it as part of its
  review — unless it can prove the Coder's run still covers the current tree
  (see the DONE-marker contract below). Fix in-scope failures before handing off
  to `adt-android-tester`.

- **The cross-section check** — the cheaper between-groups check. The
  orchestrator runs it after each parallel coder group that contained more than
  one section, to catch cross-section issues before starting the next group. A
  group of exactly one section has no cross-section interaction and its coder
  has already run the build gate on that same tree, so the check is skipped
  there. It is the build gate minus the assemble task.

- **The install command** — how `adt-android-tester` puts the build on the
  device before driving it. A failure here is a STOP, not something to work
  around.

### Resolving Them

The commands are **project-specific and resolved per run** — never assumed.
Every agent resolves them in this order and uses the first that applies:

1. **The plan's Section 0** (`## 0. Verification Commands` in
   `implementation-plan.md`). `adt-android-architect` discovers the real
   commands against the consuming project and records them there; every
   downstream agent consumes them verbatim from that block. This is the normal
   path — once a plan exists, Section 0 is the authority.
2. **The consuming project's `AGENTS.md` / `CLAUDE.md`**, if it declares
   verification commands and no plan is available yet (for example an agent
   invoked standalone, outside a pipeline run).
3. **The defaults below**, which assume a single-module app with `lint` and
   `detekt` applied at the root:

   ```
   build gate:          ./gradlew assembleDebug lint detekt testDebugUnitTest
   cross-section check: ./gradlew lint detekt testDebugUnitTest
   install command:     ./gradlew installDebug
   ```

The defaults are a starting point, not a contract: `detekt` does not exist in a
project that has not applied the plugin, and a multi-module project may need
module-qualified tasks (`:app:assembleDebug`, `:app:lintDebug`). Running a task
the project does not define fails the whole invocation, so a resolved command
that names a non-existent task is a defect — never "the project's build is
broken".

## The Changed-File Manifest

The canonical inventory of what this run changed. `adt-android-code-reviewer`
builds it before reviewing anything, so that the set of files it reviews is
exactly the set this run touched.

```
git status --porcelain
git diff
git ls-files -o --exclude-standard
```

The manifest has four parts, and all four are in scope for review:

- **tracked modifications** — contents visible in `git diff`
- **tracked deletions and renames** — visible in `git status --porcelain`
- **untracked (new) files** — `git ls-files -o --exclude-standard` lists their
  paths; their **contents are not in `git diff` at all** and must be opened and
  read individually
- **staged changes**, if any exist — the Coder is forbidden from staging, so
  anything staged is itself a finding

The untracked leg is the one that gets missed. New source files are the common
case in feature work — a new repository, ViewModel, and screen are all untracked
until someone commits them — and `git diff` shows nothing for any of them. A
review that reads only `git diff` can approve a feature without having seen a
single line of its implementation.

**Invariant**: every file this run changed is in the manifest, and every file in
the manifest is reviewed.

## Verdict and DONE Markers

Each producing agent ends its turn with its own DONE marker; the orchestrator
waits on that marker before advancing.

- `adt-android-pm` → `✅ PM DONE`
- `adt-android-architect` → `✅ ARCHITECT DONE`
- `adt-android-coder` → `✅ CODER DONE`
- `adt-android-tester` → `✅ TESTER DONE`

Each reviewer ends with **exactly one** verdict marker as its final line:

- `adt-android-architect-reviewer` → `✅ PLAN APPROVED` or
  `🔧 PLAN CHANGES REQUESTED`
- `adt-android-code-reviewer` → `✅ CODE APPROVED` or
  `🔧 CODE CHANGES REQUESTED`

A `🔧 ... CHANGES REQUESTED` marker is followed by a numbered list of the
required changes.

## Review Currency

A `✅ CODE APPROVED` verdict applies to **the tree that existed when it was
issued**, not to the feature in the abstract. Any code mutation after that
verdict — including a Coder fix driven by the Tester — invalidates it, and the
mutated tree must be reviewed again before the run can be called complete. A
targeted re-review of just the new changes is enough; the original review's
budget is not restarted.

**Invariant**: the tree handed back to the developer has passed code review
after its last mutation.

This is why the Tester's fix loop re-enters the code reviewer (Part B). Without
it, a run can end on `READY TO MERGE` carrying implementation code no reviewer
ever saw — the tests prove the feature behaves, not that the code that makes it
behave is sound.

## Tester Findings: Blocking vs Observation

`adt-android-tester` classifies every finding, and only one class drives code
changes.

- **Blocking** — the behaviour violates the feature request, the approved plan
  (including its Manual Testing Plan and any Platform Notes), or the project's
  established conventions in `AGENTS.md` / `CLAUDE.md`; or it is a crash, data
  loss, security problem, or a regression in an existing surface. These fail
  their test case and drive the fix loop.
- **Observation** — everything the Tester noticed that no approved artifact
  asked for: UX opinions, unspecified edge cases, polish, behaviour that could
  reasonably go either way. Recorded in `test-results.md` for the human, and
  that is all.

The verdict follows mechanically: `NEEDS FIXES` if and only if there is at least
one blocking finding. Observations never flip the verdict and never reach the
Coder.

**Invariant**: the Tester discovers defects; it does not create requirements.
When a behaviour genuinely should be required and no artifact requires it, that
is an observation for the human to promote into a future feature request — not
something to fix mid-run.

## Producing-Agent Obligations During a Reviewer Loop

- Reviewers are read-only — they never edit the plan or the code. The producing
  agent applies every fix: `adt-android-architect` for plan feedback,
  `adt-android-coder` for code feedback.

---

# Part B — Orchestration & Tool Registration

Orchestrator-facing. The agents spawned by the pipeline do not need this half.

## Subagent Tool & Environment Mappings

When defining subagents via the `define_subagent` tool, parse the configuration
from `.claude/agents/adt-*.md` and configure tools as follows:

- `adt-android-pm`: system prompt from `.claude/agents/adt-android-pm.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-architect`: system prompt from `.claude/agents/adt-android-architect.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-coder`: system prompt from `.claude/agents/adt-android-coder.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-tester`: system prompt from `.claude/agents/adt-android-tester.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = true`.
- `adt-android-architect-reviewer`: system prompt from `.claude/agents/adt-android-architect-reviewer.md`; `enable_write_tools = true` (for read-only Bash inspection — the reviewer never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-code-reviewer`: system prompt from `.claude/agents/adt-android-code-reviewer.md`; `enable_write_tools = true` (for `git diff` and the build gate — the reviewer never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.

Antigravity does not support per-subagent model selection. The recommended models
in each agent file (`opus` for adt-android-pm/adt-android-architect and both
reviewers, `sonnet` for adt-android-coder and adt-android-tester) are documented
for reference; in Antigravity, all subagents inherit the user's globally selected
model — select the strongest available model for full pipeline runs.

## Approval Gates

For `/build-guided`, pause for explicit user approval between PM, Architect,
Coder, and Tester phases. Accept `approve`, `revise: <feedback>`, or `stop`.

For `/build-auto`, skip the PM phase. If the feature description is too vague
for the Architect to produce a concrete plan, stop and suggest `/build-guided`
instead.

For `/build-auto-reviewed`, skip the PM phase and run no human gates — but
insert an automated reviewer after each producing phase, per the Reviewer-Loop
Protocol below.

## Reviewer-Loop Protocol

Used by `/build-auto-reviewed`. After a producing agent finishes, the
orchestrator delegates to that agent's reviewer before proceeding:

- `adt-android-architect` → reviewed by `adt-android-architect-reviewer`
  (reviews `implementation-plan.md`).
- `adt-android-coder` (all coding complete) → reviewed by
  `adt-android-code-reviewer` (reviews the uncommitted diff against the plan).

Act on the reviewer's verdict marker (the markers are defined in Part A):
- `✅ PLAN APPROVED` / `✅ CODE APPROVED` → proceed to the next phase.
- `🔧 PLAN CHANGES REQUESTED` / `🔧 CODE CHANGES REQUESTED` → re-run the
  producing agent with the reviewer's numbered feedback, then review again.

On the 2nd re-run, pass the producing agent all prior numbered feedback (both
rounds), marking items the reviewer previously accepted as resolved.

Each gate allows **at most 2 re-runs** (3 production attempts total). If the
reviewer still requests changes after the 2nd re-run, the orchestrator **STOPS
the entire pipeline** and reports to the user: the gate, the unresolved
feedback, and the current artifact/diff state. It does not advance to later
phases. Reviewers are
read-only and the producing agent applies all fixes — see Part A,
"Producing-Agent Obligations During a Reviewer Loop".

### The Targeted Re-Review

Per Part A's Review Currency rule, a Coder fix driven by the Tester invalidates
the `✅ CODE APPROVED` verdict. Each iteration of the Tester fix loop therefore
runs a **targeted re-review** between the Coder and the re-test:

```
Tester → NEEDS FIXES → Coder → targeted re-review → Tester → …
```

It differs from the full gate in scope and budget, not in authority:

- **Scope**: only what changed since the last approved review — the reviewer is
  told this is a targeted re-review and given the fix instructions the Coder
  worked from. It does not re-review the whole feature.
- **Budget**: **at most 1 Coder re-run per iteration**. If the reviewer still
  requests changes after that re-run, STOP and report — do not proceed to the
  re-test with unreviewed code, and do not spend the Tester's remaining
  iterations on it.
- **Verdict markers**: the same `✅ CODE APPROVED` / `🔧 CODE CHANGES
  REQUESTED`. Only an approval lets the re-test start.

A run may only reach `READY TO MERGE` with an approval that post-dates the last
code mutation. If the loop exits any other way, it exits through a STOP.

## Orchestration Workflow (Antigravity)

When the user invokes `/build-guided`, `/build-auto`, or `/build-auto-reviewed`, the parent agent acts as orchestrator:

1. **Define Subagents**: Dynamically register any required subagents using `define_subagent` if they aren't already defined, using the mappings above. For `/build-auto-reviewed`, also register `adt-android-architect-reviewer` and `adt-android-code-reviewer`.
2. **Execute Phases**:
   - **PM Phase** (`/build-guided` only): Invoke `adt-android-pm` with the user request. Pass messages back and forth between the user and the PM subagent until it outputs `✅ PM DONE`.
   - **Architect Phase**: Invoke `adt-android-architect` with the PM's `feature.md` path (or the feature description for the auto flows). Wait until it outputs `✅ ARCHITECT DONE`.
   - **Architect Review Gate** (`/build-auto-reviewed` only): Invoke `adt-android-architect-reviewer` with the plan path and apply the Reviewer-Loop Protocol above before proceeding.
   - **Coder Phase**: Read the execution strategy from the implementation plan. If parallel-safe, verify mechanically that no file appears in two sections of the same group, then invoke multiple `adt-android-coder` subagents in parallel. Otherwise, invoke a single `adt-android-coder`. When you run the cross-section check yourself between groups, take its command from the plan's Section 0 like every other agent — not from Part A's defaults.
   - **Code Review Gate** (`/build-auto-reviewed` only): After all coding is complete, invoke `adt-android-code-reviewer` with the plan path and apply the Reviewer-Loop Protocol above before proceeding.
   - **Tester Phase**: Invoke `adt-android-tester` with the plan path. It runs manual verification via `auto-mobile` and writes `test-results.md`.
   - **Tester Fix Loop**: on a `NEEDS FIXES` verdict, run the bounded
     Coder → targeted re-review → re-test loop the command file defines (max 2
     iterations), then STOP and report if it is still
     failing. In `/build-auto-reviewed` the targeted re-review is mandatory —
     see "The Targeted Re-Review" above; the code that ships must have been
     reviewed after its last mutation. A run never ends by declaring a
     `NEEDS FIXES` feature complete.
3. **Gates**: For `/build-guided`, pause at each phase boundary for explicit user approval. For `/build-auto-reviewed`, the gates are the automated reviewer loops (no human pause). For `/build-auto`, there are no gates.

## Native Workflow Registration

`/build-auto`, `/build-auto-reviewed`, and `/build-guided` slash commands (along
with `/plan-research` and `/plan-design`) are registered natively in Antigravity
via symlinks in `.agents/workflows/` that point to `.claude/commands/`. Team personas are inlined into the consuming project's
`.agents/agents.md` (inside a marker-fenced block managed by install.sh),
sourced from `.agents/AGENTIC_DEV_TEAM.md` in this repo. Each persona stub
references the canonical detailed prompt at `.claude/agents/adt-*.md`.

## Orchestration Workflow (opencode)

opencode drives the same pipeline through its native per-file discovery, wired
up by the same install.sh run:

1. **Commands**: the five slash commands live in `.opencode/commands/` as
   symlinks to the canonical `.claude/commands/*.md` bodies — opencode reads the
   same orchestration prompts (`$ARGUMENTS` and `` `adt-android-*` subagent ``
   delegation are both opencode-native).
2. **Subagents**: each role is a `mode: subagent` agent file in
   `.opencode/agents/adt-android-*.md`. The orchestrator (primary agent)
   delegates to them automatically by description or via `@adt-android-<role>`
   mention; each stub reads its canonical prompt at `.claude/agents/adt-*.md`
   before acting, so the persona is identical across tools.
3. **Models**: opencode runs every subagent on the user's currently selected
   model (the agent files set no per-role `model:`), matching Antigravity's
   behavior. Select the strongest available model for full pipeline runs.
4. **Tester MCP**: the `auto-mobile` MCP (an HTTP server) is registered in
   `opencode.json` under the `mcp` key (`type: "remote"`, with auto-mobile's
   `url`); the Tester reaches it like any other tool.
5. **Rules**: agents and commands reference `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`
   and the project's `AGENTS.md`/`CLAUDE.md` by path (both present in the project
   tree), so opencode reads the same sources of truth as the other tools.
