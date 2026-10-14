# How It Works

This document has two halves, and they are independent of each other.

**[The pipeline](#the-pipeline)** covers what happens during a run and the rules
that keep it honest. Read it to understand the product.

**[Distribution](#distribution)** covers how one repo delivers the same agents to
three different tools, what `install.sh` creates, and how to extend it. Read it
to understand the plumbing.

## The pipeline

### The shape of a run

Every run is the same chain of handoffs. The five commands differ only in which
links are present and who approves each one.

```
   PM   ->   Architect   ->   Coder   ->   Test Writer   ->   Tester   ->   your diff
feature.md  impl-plan.md    the code       flows/         test-results.md
            design-doc.md
```

| Command | PM | Architect | Plan review | Coder | Code review | Test Writer + Tester | Gates |
|---|:--:|:--:|:--:|:--:|:--:|:--:|---|
| `/build-guided` | yes | yes | | yes | | yes | Human, at every boundary |
| `/build-auto` | | yes | | yes | | yes | None |
| `/build-auto-reviewed` | | yes | yes | yes | yes | yes | Automated reviewers |
| `/plan-research` | yes | | | | | | Stops after the PM |
| `/plan-design` | | yes | | | | | Stops after the Architect |

The orchestrator is whatever agent your tool runs at the top level. It spawns
each specialist as a subagent, waits for that agent's DONE marker, and only then
advances.

### Phase outputs

Artifacts live in `pipeline_artifacts/{feature-slug}/`, one folder per feature,
with the slug lowercase and hyphenated (for example `background-link-checks`).

| Agent | Writes | DONE marker |
|---|---|---|
| `adt-android-pm` | `feature.md` | `✅ PM DONE` |
| `adt-android-architect` | `implementation-plan.md`, and `design-doc.md` when the command asks for one | `✅ ARCHITECT DONE` |
| `adt-android-coder` | Nothing. Only uncommitted code | `✅ CODER DONE` |
| `adt-android-test-writer` | `flows/`, one flow per test case, and `flows/INDEX.md` | `✅ TEST WRITER DONE` |
| `adt-android-tester` | `test-results.md` | `✅ TESTER DONE` |

The flow run between those two is not an agent. The orchestrator runs
`adt.sh run`, which writes `run-results.md` and `run-logs/`.

Reviewers write nothing at all. They are read-only by design, and each ends with
exactly one verdict marker.

| Agent | Verdicts |
|---|---|
| `adt-android-architect-reviewer` | `✅ PLAN APPROVED` or `🔧 PLAN CHANGES REQUESTED` |
| `adt-android-code-reviewer` | `✅ CODE APPROVED` or `🔧 CODE CHANGES REQUESTED` |

A `🔧 CHANGES REQUESTED` verdict is always followed by a numbered list. The
producing agent applies every fix, since a reviewer never edits what it reviewed.

### Artifacts and their audiences

Each artifact has exactly one intended reader, and that is what shapes how it is
written.

| Artifact | Written by | Read by |
|---|---|---|
| `feature.md` | PM | The Architect, and you at the spec gate |
| `implementation-plan.md` | Architect | The Coder, both reviewers, the Test Writer, and the Tester |
| `design-doc.md` | Architect | **You.** Whoever maintains this later |
| `flows/` | Test Writer | The flow run, and the Tester when a flow fails |
| `run-results.md` | `adt.sh run` | The Tester |
| `test-results.md` | Tester | The Coder on failures, the Test Writer on flow defects, and you |

```mermaid
flowchart LR
  A["architect"] --> P["implementation-plan.md"] --> C["coder"] --> T["tester"]
  A --> D["design-doc.md"] --> H["human review"]
  D -. "links into" .-> P
```

`implementation-plan.md` is a build contract: exact paths, line numbers, code,
and UI selectors. That is the right document for a Coder and the wrong one to
hand a senior engineer who has to decide whether the approach is sound. The
design doc is that second document — prose, one diagram, the alternatives that
lost, the blast radius, and the rollback story, in 1500 to 3500 words.

The Architect writes both in one phase, **the design doc first**. It has just
surveyed the codebase and weighed the alternatives at that point; a document
summarised from the plan afterwards degrades into a digest of the plan's
headings, which is the one thing it must not be.

Nothing downstream consumes the design doc. The Coder, the Tester, and the code
reviewer all keep reading the plan. The plan reviewer also reviews the design doc
when one was generated.

Which commands produce one, and how to override that per run, is in
[README.md](README.md#the-design-doc). The rules the Architect and the
orchestrator follow are in Part A of the pipeline doc, under "The Two Architect
Artifacts".

### Handoff rules

**Read before write.** Every agent reads the prior phase's artifact in full
before starting. A missing required artifact is a stop condition, not something
to guess around.

**The Coder never commits.** No `git add`, no `git commit`, no staging of any
kind. Work stays uncommitted for you to review, and anything found staged is
itself a review finding.

**The plan wins.** Two documents describing one feature is one chance to
disagree, so `implementation-plan.md` stays the sole contract for
implementation. The design doc explains the change and links into the plan for
detail, and where the two differ the plan is what the Coder builds. Hand-editing
`design-doc.md` never reaches the Coder.

**Feedback lands in the documents.** Answering an approval gate with
`revise: <feedback>` re-runs the Architect, which rewrites both files in place.
Scope that is *declined* — by you withdrawing it, or by the Architect judging it
out of scope — is recorded under the design doc's **Non-Goals** with the
justification, rather than dropped. Feedback that lives only in the chat
transcript is lost the moment the run ends, and a design doc that absorbs every
request without argument is how scope creep enters.

**Artifacts stay out of git.** `pipeline_artifacts/` is ignored two redundant
ways. `install.sh` adds it to the managed `.gitignore` block, and whichever agent
first creates the directory also writes `pipeline_artifacts/.gitignore`
containing a single `*` line. The second mechanism is what covers a plugin-only
install, where no `install.sh` run ever happened. Without either one, run scratch
files would show up in the reviewer's changed-file manifest, and in the commit of
anyone who ran `git add -A` over the Coder's uncommitted tree.

### Review currency

A `✅ CODE APPROVED` verdict applies to the tree that existed when it was issued,
not to the feature in the abstract. Any code change after that verdict
invalidates it.

That is why the Tester's fix loop re-enters the code reviewer:

```
Tester -> NEEDS FIXES -> Coder -> targeted re-review -> Tester -> ...
```

The re-review is targeted rather than a repeat of the full gate. It sees only
what changed since the last approval, plus the fix instructions the Coder worked
from, and it gets one Coder re-run. If the reviewer still objects, the run stops.
Unreviewed code is never re-tested.

> **Invariant:** the tree handed back to you passed code review after its last
> change.

Without that rule a run can reach `READY TO MERGE` carrying code no reviewer ever
read. Tests prove the feature behaves, not that the code making it behave is
sound.

### Required unit tests

Unit tests are specified by the Architect and written by the Coder. No other
agent authors them — reviewers are read-only, the Test Writer writes device
flows rather than Kotlin, and the Tester writes no tests at all.

The requirement travels in the plan. Section 1 records the project's **Test
Stack**, discovered from its version catalog and an existing test, so the Coder
uses the libraries the project already has rather than picking its own. Each
section in Section 3 then carries a **Tests required** field naming the test
file and one case per line.

Every case is phrased GIVEN / WHEN / THEN — starting state, the single action
under test, observable result — and that line becomes the test's name
unchanged, with the body repeating the three steps as commented blocks:

```kotlin
@Test
fun `GIVEN the cache holds items WHEN the refresh fails THEN the cached items are returned`() = runTest {
    // GIVEN
    val repository = NewsRepository(api = FailingApi(), cache = cache)

    // WHEN
    val result = repository.refresh()

    // THEN
    assertThat(result).isEqualTo(cachedItems)
}
```

The point is not ceremony. A case that cannot be phrased this way usually is
not a behaviour, so the format catches empty tests at planning time, before
anyone writes them. And when one fails months later, the name alone says which
behaviour broke and under what starting state.

| Field value | What the Coder does |
|---|---|
| Concrete cases | Writes exactly those, with the Test Stack's libraries |
| `None — <reason>` | Writes none, and says so in its DONE marker |
| Empty or missing | Caught by the plan reviewer as a blocker |

Both reviewers hold a side of this. The plan reviewer checks the fields were
filled in and that the cases are worth writing — a case that only asserts a
constructor assigned its arguments is flagged as fluff, and a `None` on a
ViewModel full of state transitions is a blocker. The code reviewer then checks
the tests actually exist and that each one would fail if the logic were wrong.

> **Invariant:** every unit test the plan requires exists in the tree you are
> handed, and no agent adds a testing dependency the plan did not name.

The build gate runs the project's unit-test task, but that only executes tests
that exist — it can never fail for one that was never written. That is why the
requirement lives in the plan and is checked by a reviewer instead.

### Device tests: cases, flows and results

Every device test is written once, by one agent, at the moment it can be
written well.

| Step | Who | When | What |
|---|---|---|---|
| The case | Architect | Before the code | Steps with selectors, and an Expected result. The spec the Coder builds to |
| The flow | Test Writer | After the Coder, on the run's emulator | The same case as a file in the test driver's format, checked with one run |
| The run | `adt.sh run` | Every test and re-test | Every flow, with no model in the loop. A failure gets one retry; a pass on the retry is `FLAKY` |
| The verdict | Tester | After the run | Passing flows need nothing. A failing one is driven by hand to decide: the app is wrong, or the flow is |

Three rules keep it honest:

* **A flow's checks come only from its case's Expected.** The Test Writer may
  add a wait or a scroll the real app needs. It never loosens a check to make it
  pass; if the app does not show what the case expects, the flow fails, and
  that is the Tester's call.
* **The agent that judges never writes the test.** The Tester never creates or
  edits a flow. A flow that fails while the case passes by hand is listed under
  "Flow Defects" in `test-results.md`, never sent to the Coder, and rewritten
  by the Test Writer before the next re-test.
* **Every flow starts from the same device.** It first turns Airplane mode off,
  sets portrait and the light theme, then launches the installed app with clean
  data, so a flow that failed halfway cannot leave the next one offline or
  sideways.

Cases that need a credential, or whose Expected is a judgment a machine cannot
check, get no flow. The Tester drives those by hand, and `flows/INDEX.md` says
why each one has none.

### Blocking findings and observations

The Tester classifies everything it finds, and only one class drives code
changes.

| | Blocking | Observation |
|---|---|---|
| **What it is** | Behaviour contradicting the request, the approved plan (including its test plan and platform notes), or the project's conventions. Also crashes, data loss, security problems, and regressions. | Anything no approved artifact asked for: UX opinions, unspecified edge cases, polish, judgment calls. |
| **What it does** | Fails its test case and drives the fix loop | Gets recorded in `test-results.md`, and nothing else |

The verdict follows mechanically. It is `NEEDS FIXES` if and only if there is at
least one blocking finding. Observations never flip the verdict and never reach
the Coder.

> **Invariant:** the Tester discovers defects. It does not create requirements.

When a behaviour genuinely should be required and no artifact requires it, that
is an observation for you to promote into a future request. In `/build-guided`
you can promote one on the spot by feeding it back through `revise:`, which makes
it a real requirement because you created it.

### Retry budgets

Nothing retries forever. Each budget is separate, and exhausting one stops the
pipeline with a report rather than advancing.

| Loop | Budget | On exhaustion |
|---|---|---|
| Plan review gate | 2 re-runs, so 3 attempts | Stops, reporting the gate and the unresolved feedback |
| Code review gate | 2 re-runs, so 3 attempts | Stops, reporting the same |
| Targeted re-review | 1 re-run, per fix iteration | Stops. Does not re-test, and does not spend the remaining Tester iteration |
| Tester fix loop | 2 iterations | Stops. Never declares a `NEEDS FIXES` feature complete |
| Cross-section check | 2 rounds | Stops, reporting the failing output and the sections involved |

On a gate's second re-run, the producing agent receives all prior feedback from
both rounds, with previously accepted items marked resolved.

### The changed-file manifest

Before reviewing anything, the code reviewer builds a canonical inventory of what
the run touched:

```bash
git status --porcelain
git diff
git ls-files -o --exclude-standard
```

The manifest has four parts, and all four are in scope: tracked modifications,
tracked deletions and renames, untracked new files, and anything staged (which is
a finding in itself).

The untracked part is the one that gets missed, and it is the one that matters
most in feature work. A new repository, ViewModel, and screen are all untracked
until someone commits them, and `git diff` shows nothing for any of them. A
review that reads only `git diff` can approve a feature without seeing a single
line of its implementation.

> **Invariant:** every file the run changed is in the manifest, and every file in
> the manifest is reviewed.

### Verification commands

Three named commands are the only Gradle the pipeline runs.

| Name | What it is | Who runs it |
|---|---|---|
| Build gate | The full end-of-work check | The Coder in a sequential run, before declaring done. Also the code reviewer, as part of every review |
| Cross-section check | The build gate minus the assemble task | The orchestrator, after every parallel coder group |
| Install command | Puts the build on the device | The orchestrator, through `adt.sh install`, right before every test and re-test, on the run's own device only. A failure here is a stop condition. The Tester has no shell, so it refuses to test unless the orchestrator confirms the install with a `BUILD_INSTALLED` timestamp |

The cross-section check still catches compile errors, because its unit-test leg
compiles the main sources.

The commands are resolved per project and never assumed. Every agent resolves
them in this order and uses the first that applies:

1. **The plan's `## 0. Verification Commands` block.** The Architect discovers the
   real commands against your project and records them there. Once a plan exists
   this is the authority, and downstream agents consume it verbatim.
2. **Your `AGENTS.md` or `CLAUDE.md`**, if it declares verification commands and no
   plan exists yet, such as when an agent is invoked standalone.
3. **The defaults**, which assume a single-module app with `lint` and `detekt`
   applied at the root:

   ```
   build gate:          ./gradlew assembleDebug lint detekt testDebugUnitTest
   cross-section check: ./gradlew lint detekt testDebugUnitTest
   install command:     ./gradlew installDebug
   ```

Those defaults are a starting point, not a contract. `detekt` does not exist in a
project that never applied the plugin, and a multi-module project may need
`:app:assembleDebug` or `:app:lintDebug`. Naming a task the project does not
define fails the whole invocation, so a resolved command that names a missing
task is a defect in the resolution, not a broken build.

### Parallel execution

The Architect decides. Section 3 of the plan carries a **Parallel-safe** field,
and when it is YES the sections are grouped into Execution Groups.

Before spawning anything, the orchestrator runs a pre-check: extract each
section's file list and confirm no file appears in two sections of the same
group. This is a mechanical comparison rather than a judgment call. On overlap it
stops and names the overlapping files and the sections claiming them. It will not
run coders against a plan with a parallelization bug, and in `/build-guided` it
will not even ask you to approve one.

Only the orchestrator runs Gradle, because parallel coders share one working tree
and one Gradle project.

| Role | Runs Gradle? |
|---|---|
| Parallel coder | No. It implements its section, confirms nothing is staged, and declares done |
| Sequential coder (`Parallel-safe: NO`, a reviewer-driven fix, or a Tester-driven fix) | Yes, the build gate. It is the only agent touching the tree, so the result means something |
| Orchestrator | Yes, the cross-section check, after every group |

This is not a style preference. Concurrent Gradle invocations against one project
directory contend on the locks under `.gradle/` and write to the same `build/`
outputs, which produces lock timeouts and non-deterministic failures. Each
coder's build would also be compiling files its siblings are still editing, so a
failure would say nothing about the coder that ran it.

That is why the cross-section check runs after every group, including a group
with only one section. Parallel coders run no Gradle at all, so a skipped check
means that group's work was verified by nothing.

### When the cross-section check fails

A failure here is in scope for the run, since catching it is what the check
exists for. The orchestrator resolves it rather than reporting and stopping:

1. Attribute each failure to the section that owns the file, using the plan's
   per-section file lists. A failing unit test is attributed the same way, by
   the section whose file list holds that test file.
2. Re-spawn the owning coder, one at a time and never concurrently. A sequential
   fix coder does run the build gate.
3. Re-run the check. Allow at most 2 rounds, then stop.
4. If a failure cannot be attributed to a single section, because it is a genuine
   integration defect or two sections' public interfaces contradict each other,
   stop and report it as a plan defect. Do not guess which coder should absorb
   it.

### Test drivers

The Tester never talks to a device directly. It goes through a *test driver*,
an MCP server: auto-mobile by default, or Maestro when the project's
`AGENTS.md` or `CLAUDE.md` says `Test driver: maestro`. The orchestrator reads
that line once, at the start of a build command, and stops if it names anything
else.

Everything driver-specific lives in one **adapter** file per driver,
`drivers/auto-mobile.md` and `drivers/maestro.md`. The orchestrator passes the
right one to the Tester as `DRIVER_DOC`. The Tester's own prompt says how to
test; the adapter says which tool does it — how to bind to the run's device,
change device settings, tap, type and read the screen. Adding a third driver
means writing a third adapter, not editing the agents.

The Architect's test plan is the same for both: steps with test-tag selectors.
For a Compose app the Architect also makes sure the root composable sets
`testTagsAsResourceId`, because both drivers find elements by resource id.

### Devices

Each build command leases one device for its whole run, through a small script,
`adt.sh`. Normally it boots a headless, read-only copy of one of your AVDs for
that run alone, so two features in two git worktrees can be tested at the same
time.

```
first test:  device-acquire  ->  install  ->  Tester
re-test:                         install  ->  Tester      (same device)
run ends:    device-release                               (also on any stop)
```

* **One device per run.** The first test leases it; every re-test reuses it,
  so a fix loop never waits for a second boot. It stays up while a Coder fixes
  something, and in `/build-guided` while the run waits for you.
* **Installs land only there.** The install command runs with `ANDROID_SERIAL`
  set to the run's device.
* **The Tester uses only that device.** It receives the serial as `DEVICE`,
  binds to it in its first call, and never starts, stops or switches devices.
* **Leases are per project and feature.** A lease belongs to the project
  directory and the feature slug together, so two worktrees never share a
  device. Leases live in `~/.adt/leases/`.
* **Your emulator is never touched.** An attached device is used only when you
  set `ADT_DEVICE_MODE=reuse`, or when no AVD can be booted (none exists, or
  every one is open normally). The script says which device it took and why,
  and never stops a device it did not start.

The settings and the one-time AVD setup are in the README, under
[Testing on a device](README.md#testing-on-a-device).

### Model selection

Each agent file records a recommended model: `opus` for the PM, the Architect,
and both reviewers, and `sonnet` for the Coder, the Test Writer and the
Tester.

Claude Code honours those per agent. Antigravity and OpenCode do not support
per-subagent model selection, so every subagent inherits your globally selected
model. Select the strongest model available before a full pipeline run in those
tools.

## Distribution

### How the three tools find the files

This repo is a shared configuration package rather than a library you import.
Each Android project that wants the pipeline links this repo's files into its own
`.claude/`, `.agents/`, and `.opencode/`. Six mechanics make that work.

1. **Per-file symlinks, never per-directory.** Your `.claude/`, `.agents/`, and
   `.opencode/` stay real directories. You can keep adding your own commands and
   agents alongside ours, and they coexist freely.
2. **Claude Code discovery.** Claude Code scans `.claude/commands/` and
   `.claude/agents/` by filename. Our symlinks sit at those canonical paths, so
   all five commands and all seven `@adt-*` agents are available automatically.
3. **Antigravity discovery.** Antigravity scans `.agents/workflows/` for slash
   commands and auto-loads `.agents/agents.md` into the system prompt as
   user_rules. `install.sh` inlines the persona stubs from this repo's
   `.agents/AGENTIC_DEV_TEAM.md` into a marker-fenced block in your `agents.md`,
   so Antigravity sees them in context without loading another file. The
   HTML-comment markers are ignored by Antigravity itself.
4. **OpenCode discovery.** OpenCode scans `.opencode/commands/` for slash commands
   and `.opencode/agents/` for subagents. Each agent file is a `mode: subagent`
   stub whose body reads its canonical prompt from `.claude/agents/adt-*.md`, so
   the orchestrator can delegate to `@adt-android-architect` and the rest with an
   identical persona. No `agents.md` inlining is needed, because the per-file
   definitions are the discovery mechanism.
5. **One source of truth across all three.** Every tool ends up reading the same
   agent prompts and the same `AGENTIC_DEV_TEAM_PIPELINE.md`. Edit those in the
   clone and every consuming project picks the change up on the next file read,
   with no re-install required for in-place edits.
6. **A managed `.gitignore` block.** Symlink targets are per-developer absolute
   paths such as `~/code/agentic-dev-team/...`, which would not resolve on a
   teammate's machine, so `install.sh` maintains a small block listing them.

### What install.sh creates

For every file this repo owns, `install.sh` creates a symlink at the matching
path inside your project.

| Project path | Symlink target in your clone |
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
| `.claude/agents/adt-android-test-writer.md` | `<clone>/.claude/agents/adt-android-test-writer.md` |
| `.claude/agents/adt-android-tester.md` | `<clone>/.claude/agents/adt-android-tester.md` |
| `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` | `<clone>/.claude/AGENTIC_DEV_TEAM_PIPELINE.md` |
| `.claude/adt/scripts/adt.sh` | `<clone>/.claude/adt/scripts/adt.sh` |
| `.claude/adt/drivers/auto-mobile.md` | `<clone>/.claude/adt/drivers/auto-mobile.md` |
| `.claude/adt/drivers/maestro.md` | `<clone>/.claude/adt/drivers/maestro.md` |
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
| `.opencode/agents/adt-android-test-writer.md` | `<clone>/.opencode/agents/adt-android-test-writer.md` |
| `.opencode/agents/adt-android-tester.md` | `<clone>/.opencode/agents/adt-android-tester.md` |

The canonical `AGENTIC_DEV_TEAM_PIPELINE.md`, `scripts/adt.sh` and `drivers/`
live in `plugins/agentic-dev-team/` so the Claude Code plugin can package them;
the clone's `.claude/adt/scripts` and `.claude/adt/drivers` are symlinks to
those directories. The clone's
`.claude/AGENTIC_DEV_TEAM_PIPELINE.md` is a symlink to it, which leaves the
project-side path above unchanged, so installed projects need no re-install.

Two further changes happen through marker-fenced managed blocks rather than
symlinks.

**`.gitignore`** gains a block listing the symlink paths above, plus
`/pipeline_artifacts/`. This block only exists on the `install.sh` path. See
"Handoff rules" above for what covers a plugin-only install.

**`.agents/agents.md`** gains a block containing the inlined persona stubs from
this repo's `.agents/AGENTIC_DEV_TEAM.md`. The file is created if it does not
exist, and your content outside the markers is left untouched.

After install, `ls -la .claude/commands/` makes ownership obvious. Our entries
show an arrow pointing into the clone, and yours do not.

### Refusal behavior

If a real file, or a symlink that is not ours, already sits at one of our
destinations, `install.sh` refuses with the path and a "rename or delete, then
re-run" message. Nothing is ever overwritten silently. Collision checks run
pre-flight, before any symlink is created, so a refusal leaves the install in a
clean state.

### Extending the pipeline

This section is for maintainers and contributors.

**Adding an agent.** Create `.claude/agents/adt-<name>.md`, always with the
`adt-` prefix so it never collides with a developer's own agents. Add a short
stub to `.agents/AGENTIC_DEV_TEAM.md` using the `@adt-<name>` handle and
referencing the new prompt, for Antigravity. Create
`.opencode/agents/adt-<name>.md` as a `mode: subagent` stub whose body reads the
canonical prompt, for OpenCode. On the next `install.sh` run in each project,
`@adt-<name>` becomes invocable in all three tools and the `agents.md` block
updates itself.

**Adding a command.** Create `.claude/commands/<name>.md` with the orchestration
prompt, then create `.agents/workflows/<name>.md` and
`.opencode/commands/<name>.md` as symlinks to `../../.claude/commands/<name>.md`.
`/build-auto-reviewed` was built exactly this way. Its workflow symlinks point at
the command, which orchestrates the two reviewers between the existing phases.

**Changing shared orchestration rules.** Edit the canonical
`plugins/agentic-dev-team/AGENTIC_DEV_TEAM_PIPELINE.md`. Agent prompts reference
it by path and the project copy is a symlink, so edits propagate the next time an
agent reads the file, with no install needed. Agent-facing rules go in Part A and
orchestrator-only rules in Part B, since agents are told to read Part A and stop
there.

**Removing or renaming files.** Just do it in the repo. The sync logic in
`install.sh` removes stale symlinks from consuming projects on the next run.

### Project context

Every `adt-*` agent reads your project's `AGENTS.md` or `CLAUDE.md`, whichever
exists, for stack, architecture, conventions, and verification rules. You do not
need to document the pipeline itself in there, because the agents bring their own
instructions. What they need from you is what makes your codebase specific.

### Troubleshooting

**install.sh refused with "real file at X".** You have your own file at one of our
install paths. Rename or delete one side, then re-run.

**I pulled the repo but new commands are not showing up.** Run `install.sh` in the
project again. `git pull` refreshes files that are already symlinked, but it
cannot materialize symlinks for newly added ones.

**There is a broken symlink in `.claude/agents/`.** A file was probably renamed or
removed upstream. Run `install.sh` and the sync will clear stale symlinks.

**An agent's persona looks out of date in Antigravity.** Persona stubs are inlined
into `.agents/agents.md` at install time rather than symlinked, so re-run
`install.sh` to refresh that block. Agent prompts and the pipeline doc are
symlinked and never need this.

**Both `AGENTS.md` and `CLAUDE.md` exist.** Agents read whichever they find first.
Pick one as canonical and keep them in sync, or delete one.

**The Tester stops saying its driver's tools are missing.** The test driver's
MCP server is not registered with your tool, or not under the expected name.
auto-mobile must be registered as `auto-mobile` and Maestro as `maestro`; the
README's [Choosing a test driver](README.md#choosing-a-test-driver) has the
commands. In OpenCode both belong in `opencode.json` under the `mcp` key.

**The run stopped at the start, naming the test driver.** Your `AGENTS.md` or
`CLAUDE.md` has a `Test driver:` line with a value other than `auto-mobile` or
`maestro`. Fix the line, or delete it to use auto-mobile.

**Rotation, dark mode, permission or offline cases come back inconclusive.** The
Tester has no shell, so it only uses the test driver's own tools. Under
auto-mobile, the ones that change device settings are hidden until they are
switched on: check the `AUTOMOBILE_ENABLED_TOOLS` value and the pinned version
from the README's [Choosing a test driver](README.md#choosing-a-test-driver),
then restart auto-mobile's background service once
(`bunx @kaeawc/auto-mobile@0.0.84 --daemon restart`) and start a new session.
Under Maestro, font-scale cases are always inconclusive, because Maestro cannot
change the font scale.

**The Tester stopped saying the build was not installed.** It only tests a build
the orchestrator has just installed, which the orchestrator confirms with a
`BUILD_INSTALLED` line. When you call the Tester yourself, outside a build
command, install the build first and pass that line with the plan path.

**"No usable AVD", or the run took my attached phone.** Testing needs an AVD
it can boot read-only, and a read-only copy cannot start while the same AVD is
open normally. Create a second AVD in Android Studio's Device Manager, or close
the one you have open, or set `ADT_AVD` to an AVD you do not use day to day.

**An emulator was left running.** A session that dies mid-run leaves its
emulator up. Running the same command again for the same feature picks it back
up. To stop it instead, list the leases and release the one you want:

```bash
bash .claude/adt/scripts/adt.sh device-list
bash .claude/adt/scripts/adt.sh device-release --serial emulator-5556
```

With the Claude Code plugin and no per-project install, the script is in the
plugin's directory instead, under `scripts/adt.sh`.

**A flow fails, but the Tester says the case passes by hand.** The flow
expressed a step or a wait wrongly, not the app. The Tester lists it under
"Flow Defects", and the Test Writer rewrites it before the next re-test. If no
re-test happens, the run is still judged by the Tester's hand check, and the
flow is left as it was.

**The flow run fails with "Timed out waiting for concurrent daemon restart".**
An older auto-mobile background service is still running, and the pinned
version cannot take over from it. Restart it on the pinned version:

```bash
bunx @kaeawc/auto-mobile@0.0.84 --daemon restart
```

If that refuses with "could not verify the live PID", the old service predates
the pinned version's restart protocol. Find it and stop it by hand, then start
a new session:

```bash
ps aux | grep 'auto-mobile.*--daemon-mode'
kill <pid>
```

**A run stopped mid-pipeline.** That is the intended behaviour. Every loop is
bounded, as described under "Retry budgets", and a stop reports the gate, the
unresolved feedback, and the current state of the artifacts and diff. The work so
far is still in `pipeline_artifacts/` and in your working tree.
