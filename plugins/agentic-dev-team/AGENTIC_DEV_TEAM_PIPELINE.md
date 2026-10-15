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
  - `adt-android-architect` also writes `pipeline_artifacts/{slug}/design-doc.md` — the human-facing design document — whenever the orchestrator asks for it. See "The Two Architect Artifacts" below.
  - `adt-android-test-writer` writes `pipeline_artifacts/{slug}/flows/` — one flow file per test case, plus `flows/INDEX.md` — and nothing else.
  - `adt.sh run` (run by the orchestrator) writes `pipeline_artifacts/{slug}/run-results.md` and the logs in `run-logs/`.
  - `adt.sh promote` (run by the orchestrator after a final `READY TO MERGE`) copies this run's passing flows into the project's regression suite, `e2e/flows/` — the one pipeline output that lives outside `pipeline_artifacts/` and is meant to be committed.
  - `adt-android-tester` writes `pipeline_artifacts/{slug}/test-results.md`.
  - `adt-android-coder` produces no markdown — only uncommitted code changes in the working tree.
  - `pipeline_artifacts/` must be git-ignored in the consuming project. Two mechanisms cover this, and they are deliberately redundant:
    - `install.sh` adds `/pipeline_artifacts/` to the managed `.gitignore` block. This covers the per-project install path only.
    - Whichever agent first creates the directory (`adt-android-pm`, or `adt-android-architect` in the auto flows) also writes `pipeline_artifacts/.gitignore` containing a single `*` line, which ignores the directory's contents and itself. This is the only thing covering a **plugin-only install**, where no `install.sh` run ever happened and the project's `.gitignore` is untouched.
    - Why it matters: artifacts left visible to git land in the changed-file manifest below as untracked files, and the Coder's no-commit rule means a developer running `git add -A` would commit the run's scratch files into their repository.

## Handoff Protocol

- **Read-before-write**: Every agent must read the prior phase artifact in full before starting. A missing required artifact is a STOP condition — report to the user, do not proceed by guessing.
- **No-commit rule for adt-android-coder**: The Coder must never run `git add`, `git commit`, or any staging command. Changes stay uncommitted for human review.
- **Manual verification**: `adt-android-tester` must perform manual verification through the project's test driver (see "The Test Driver" below) when its MCP server is available and the consuming project's `AGENTS.md` / `CLAUDE.md` requires it.

## The Two Architect Artifacts

`adt-android-architect` produces two documents in one invocation, and they have
different readers:

| Artifact | Read by | What it is |
|---|---|---|
| `design-doc.md` | **Humans only** — the approval gate, the PR reviewer, whoever maintains this later | Why this change, what the user sees, how it works, what was rejected. Prose plus one diagram. |
| `implementation-plan.md` | `adt-android-coder`, both reviewers, `adt-android-tester` | The build contract: file paths, line numbers, code, selectors, execution groups. |

No agent downstream of the Architect consumes the design doc; they all keep
reading the plan. The single exception is
`adt-android-architect-reviewer`, which reviews both because the rejected
alternatives live in the design doc.

**The orchestrator decides whether the design doc is written**, and says so
explicitly in the prompt it spawns the Architect with:

- `DESIGN_DOC: on` — write `design-doc.md` first, then `implementation-plan.md`.
- `DESIGN_DOC: off` — write `implementation-plan.md` only.
- `DESIGN_DOC: only` — a plan already exists; write `design-doc.md` beside it
  and do not modify that plan.
- `DESIGN_DOC: from-design-doc` — `implementation-plan.md` for the design doc path
  you were given — and **do not modify that design doc**.

An Architect invoked with no `DESIGN_DOC` value at all — a bare
`@adt-android-architect` mention, say — writes both. `/plan-design` auto-detects
the input and picks the right value. Per-command defaults are in Part B.

**The order is load-bearing.** The design doc is written **before** the plan,
never summarised from it. The Architect has just surveyed the codebase and
weighed the alternatives at that point; written afterwards, the document
degrades into a digest of the plan's headings, which is the one thing it must
not be.

### Anti-Drift Rule

`implementation-plan.md` remains the sole contract for implementation. The
design doc explains the change and links into the plan for detail; where the two
disagree, **the plan wins**. Never hand-edit `design-doc.md` expecting the change
to reach the Coder — feedback goes through the approval gate, which re-runs the
Architect and updates both together.

### Feedback Lands in the Documents

Feedback given at an approval gate must land in the documents. When a human
responds `revise: <feedback>`, the Architect re-runs and rewrites **both** files
in place: an accepted point changes the design doc and the plan; a **declined**
point — whether the human withdrew it or the Architect judged it out of scope —
is recorded under the design doc's **Non-Goals** with the justification for
declining it.

Feedback that lives only in the chat transcript is lost the moment the run ends,
and a design doc that silently absorbs every request is how scope creep enters.

## The Three Named Commands

These are the only Gradle verification commands the pipeline runs. Refer to
them by name everywhere else — agent prompts and commands must not restate the
commands themselves.

- **The build gate** — the full end-of-work check. Run by
  `adt-android-coder` before declaring done **in a sequential run**, and by
  `adt-android-code-reviewer` as part of every review. Fix in-scope failures
  before handing off to `adt-android-tester`.

  Coders running **in parallel do not run it** — see "Gradle in a Parallel Run"
  below. In a parallel run the gate is the orchestrator's job.

- **The cross-section check** — the between-groups check, run by the
  orchestrator after **every** parallel coder group, including a group that
  contained only one section. It is the build gate minus the assemble task;
  because its unit-test leg compiles the main sources, a compile error still
  fails it.

  It is never skipped in a parallel run. Parallel coders run no Gradle at all,
  so this check is the only thing standing between a group and the next one —
  a skipped check means that group's work was never verified by anything.

- **The install command** — how the build reaches the device before
  `adt-android-tester` drives it. The orchestrator runs it, not the Tester,
  which has no shell (Part B, "The Test Phase"). A failure here is a STOP, not
  something to work around. The Tester refuses to test unless its prompt
  carries `BUILD_INSTALLED: <timestamp>`, the orchestrator's statement that the
  install succeeded — so a stale build is never tested by mistake, even when
  the Tester is invoked outside a build command.

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

## The Test Driver

A project tests through one of two drivers, each an MCP server that controls
the device:

- **auto-mobile** — the default, used when the project declares nothing.
- **Maestro** — declared with a `Test driver: maestro` line in the project's
  `AGENTS.md` or `CLAUDE.md`.

The orchestrator reads that line once, at the start of a build command, and
passes the matching **adapter** to every agent that drives the device as
`DRIVER_DOC`: `drivers/auto-mobile.md` or `drivers/maestro.md`, beside this
file in the plugin (`.claude/adt/drivers/` in a per-project install). An
adapter is the only place that names a driver's tools. Agent prompts say how to
test; the adapter says which tool does it. A capability one driver lacks — Maestro
cannot change font scale — makes the cases that need it `INCONCLUSIVE`, with
the reason, never a workaround.

The test plan does not depend on the driver: the Architect writes the same
selector-annotated cases either way.

## Flows

Every device test is written once, by one agent, at the right time. The
Architect writes each case **once**, as the spec: steps with selectors and an
Expected result, before any code exists. After the Coder,
`adt-android-test-writer` turns each case into
a **flow** — the same test as a file in the test driver's own format — reading
the code that now exists and checking each flow once on the run's device. A
script then runs every flow with no model in the loop, and `adt-android-tester`
judges the results.

- **Who writes what.** The Architect writes cases; the Test Writer writes
  flows; the Tester writes neither. A flow's assertions come only from its
  case's Expected — the Test Writer may add waits and scrolls the real app
  needs, never weaken a check to make it pass.
- **The plan's selectors are requirements.** A flow reaches each element with
  the selector the case names. When the app does not have it — a test tag the
  Coder left out — the flow keeps the plan's selector and fails there, and the
  Tester reports the missing selector as a blocking finding, since it
  contradicts the plan. The Test Writer never works around it with another
  selector, which would hide the defect and leave the suite depending on text.
- **Every check must be able to fail.** Where a step is meant to make
  something appear or disappear, the flow first checks that it is not already
  so. A check that would pass before the action proves nothing.
- **Crashes fail flows.** After each flow, the script reads Android's crash
  log for the window the flow ran in. A crash or ANR of the app fails the flow
  even when every check in it passed, and is never retried away as flaky.
- **What a flow is not.** It is not a Kotlin test and not part of the build
  gate. It lives in `pipeline_artifacts/{slug}/flows/`, beside the plan.
- **A failed flow** is driven by hand by the Tester, who decides whether the app
  or the flow is wrong. An app defect is a finding like any other. A flow
  defect is listed under "Flow Defects" in `test-results.md`, never sent to the
  Coder, and rewritten by the Test Writer before the next re-test.
- **Cases with no flow** — one that needs a credential, or whose Expected is a
  judgment a machine cannot check — are driven by hand by the Tester. A case
  the driver can check only in part gets a **partial** flow, marked in
  `flows/INDEX.md` with what it leaves out; the Tester checks just that part by
  hand, and the case counts as verified only after it has.
- **Coverage is reported, not implied.** `test-results.md` says, for every
  case, how it was verified — by a flow, by hand — or that it was not, and
  why. The verdict rule does not change: an unverified case is not a blocking
  finding. But a `READY TO MERGE` with cases nobody could verify says so in
  the summary the user reads.

## The Regression Suite

The flows one feature writes protect the next. After a run ends in
`READY TO MERGE`, its flows that passed are kept in the project at
`e2e/flows/<area>/<name>.yaml`, as new uncommitted files the developer commits
with the feature. Every later run replays part of that suite in the same script
call as its own flows, on the same device.

- **Tiers.** Each test case carries a priority the Architect chose: `p0` (the
  app is unusable if this fails), `p1` (the main path of one area), `p2` (edge
  cases), or `none` (not kept). The flow's header records it.
- **What a run replays.** Every P0 flow, always, plus the tiers the plan's
  Regression Scope names per area. So one feature replays only P0, another P0
  and P1 for checkout, another P0 and P2 for offline handling.
- **What is kept.** A flow of this run whose last result was `PASS` and whose
  tier is `p0`, `p1` or `p2`. A `FLAKY` flow, a failed one, and a `none` are
  not.
- **Changing behaviour.** A case whose Id matches a suite flow re-specifies
  it: the old flow is not replayed, and the new one replaces it if kept — or the
  old one is removed if not. A flow listed under Flows Retired is not replayed
  and is removed. A suite flow the Tester marks outdated or broken is removed.
  So a flow that pins old behaviour never outlives the change that removed it.
- **A failing suite flow** is driven by hand by the Tester. A real regression
  is a blocking finding like any other, and a Coder who finds nothing in its
  change could have caused it STOPs and reports it instead of editing unrelated
  code.
- **Speed.** Replaying is a script call with no model, P0 is kept small, and
  `run-results.md` warns once the P0 flows take more than three minutes.

`e2e/flows/` is changed only by `adt.sh promote`, and only after a final
`READY TO MERGE`. Its files are test assets, not code: they are outside code
review (see "Review Currency").

## Devices

Each build command leases **one device for its whole run** through `adt.sh`
(Part B, "The Test Phase"). Normally that is a headless, read-only emulator
the run boots for itself, so two features can be tested at the same time — in
two git worktrees — without touching each other or the developer's own
emulator.

- The orchestrator passes the device's serial to `adt-android-tester` as
  `DEVICE`. The Tester binds to that serial in its first device call and uses
  nothing else: it never starts, stops or switches devices.
- The install command runs through the script with `ANDROID_SERIAL` set to
  that serial, so the build lands on this run's device only.
- A lease belongs to the project directory and the slug together, so two
  worktrees, or two apps, that happen to share a slug never share a device.
- The device is kept for every re-test in the run and released when the
  command ends.

## Gradle in a Parallel Run

When the orchestrator spawns several `adt-android-coder` subagents for one
Execution Group, they all share a single working tree and a single Gradle
project. **Only the orchestrator runs Gradle in that mode. Parallel coders run
none.**

This is not a style preference — concurrent Gradle invocations against one
project directory contend on the locks under `.gradle/` and write to the same
`build/` outputs, so they produce lock timeouts and non-deterministic failures
rather than a trustworthy result. Worse, each coder's build would be compiling
files its siblings are still editing, so a failure would say nothing about the
coder that ran it.

The division of labour:

- **Parallel coder**: implements its section, runs `git status` to confirm
  nothing is staged, and declares `✅ CODER DONE`. No `./gradlew`.
- **Sequential coder** (the `Parallel-safe: NO` path, a reviewer-driven fix
  re-run, or a Tester-driven fix): runs the build gate as normal. It is the only
  agent touching the tree, so the result is meaningful.
- **Orchestrator**: runs the cross-section check after every group.

### When the cross-section check fails

A failure here is in scope for the run — it is what the check exists to catch —
so the orchestrator resolves it rather than reporting and stopping:

1. Attribute each failure to the section that owns the file, using the plan's
   per-section file lists. A failing unit test is attributed the same way, by
   the section whose file list holds that test file — which is why the
   Architect lists each section's test files there alongside its source files.
2. Re-spawn the owning `adt-android-coder` — one at a time, sequentially, never
   concurrently — passing the plan path, its section, and the failing output.
   A sequential fix coder *does* run the build gate, per the rule above.
3. Re-run the cross-section check. Allow **at most 2 such rounds**; if it still
   fails, STOP and report the failing output and the sections involved.
4. If a failure cannot be attributed to any one section (a genuine integration
   defect, or a contradiction between two sections' public interfaces), STOP and
   report it as a plan defect — do not guess which coder should absorb it.

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

## Required Unit Tests

Unit tests are **specified by `adt-android-architect` and written by
`adt-android-coder`**. No other agent authors them: reviewers are read-only, and
`adt-android-tester` drives the running app and writes no Kotlin at all. The
contract runs through the plan, so every link has to hold:

- **Section 1** of `implementation-plan.md` records the project's **Test
  Stack** — the assertion, mocking, coroutine, and runner libraries the project
  already uses, plus an existing test to mirror. Discovered from the version
  catalog and test source sets, never assumed.
- **Section 3** gives every section a **Tests required** field: the test file
  path and one GIVEN / WHEN / THEN line per case, or `None — <reason>` where
  the section holds no logic worth testing. `None` is a legitimate answer for
  pure wiring; padding a section with tests that cannot fail is not.
- **`adt-android-coder`** implements those cases as part of the section, using
  only the libraries the plan names. Each test is named with the plan's case
  line and structured as `// GIVEN`, `// WHEN`, `// THEN` blocks in that order,
  one action per WHEN. A section whose required tests are missing is not done.
- **`adt-android-code-reviewer`** verifies they exist and are meaningful. A
  missing case is a finding; so is a test that passes regardless of whether the
  logic is correct; so is one that departs from the GIVEN / WHEN / THEN name or
  structure; so is a testing dependency the plan never named.
- **`adt-android-architect-reviewer`** verifies the fields were filled in at
  all, since an empty field ships a section with no tests and nothing
  downstream would notice.

**Invariant**: every unit test the plan requires exists in the tree the
developer is handed, and no agent introduces a testing dependency the plan did
not name.

The build gate's unit-test leg runs whatever tests exist in the tree — it
cannot fail for a test that was never written. That is precisely why the
requirement is carried in the plan and checked by a reviewer, rather than left
to the gate.

## Verdict and DONE Markers

Each producing agent ends its turn with its own DONE marker; the orchestrator
waits on that marker before advancing.

- `adt-android-pm` → `✅ PM DONE`
- `adt-android-architect` → `✅ ARCHITECT DONE`
- `adt-android-coder` → `✅ CODER DONE`
- `adt-android-test-writer` → `✅ TEST WRITER DONE`
- `adt-android-tester` → `✅ TESTER DONE`, or `⛔ TESTER BLOCKED` when the
  device stopped it from executing the plan's cases (see "When the Tester Is
  Blocked" below). These are alternatives, not a sequence: a blocked run emits
  the blocked marker and nothing else, and an orchestrator waiting only on
  `✅ TESTER DONE` will wait forever.

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

One exemption: files under `e2e/` are regression-suite flows, not code. The
orchestrator adds them after the final verdict ("The Regression Suite"), and
`adt-android-code-reviewer` leaves them out of its manifest, so neither their
promotion nor flows left uncommitted from an earlier run re-opens a review.

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

## When the Tester Is Blocked

A run can end without the Tester ever getting to the plan's cases: the emulator
stops accepting input, a gate needs a credential the run does not have, a
biometric prompt appears that nothing can satisfy. That outcome has its own
verdict and its own marker, because it is neither of the other two.

| Verdict | Marker | What it means | What the orchestrator does |
|---|---|---|---|
| `READY TO MERGE` | `✅ TESTER DONE` | Cases ran; no blocking findings | Close the run |
| `NEEDS FIXES` | `✅ TESTER DONE` | Cases ran; at least one blocking finding | Tester fix loop |
| `BLOCKED` | `⛔ TESTER BLOCKED` | The run could not be finished | The Blocked Path (Part B) |

`BLOCKED` is never `READY TO MERGE` — a case that did not run is not a case
that passed — and it does not enter the Tester fix loop, because a fix cannot
be re-tested on a device that will not take input. **A blocked run is a request
for a human, not a defect report.**

### When Both Rules Fire

A run can find a blocking defect and *then* be stopped: TC2 fails, and at TC5
the emulator quits responding. The `NEEDS FIXES` iff-rule and the blocked rule
both apply, so one has to win.

**BLOCKED outranks NEEDS FIXES.** The fact the orchestrator must act on is that
the run cannot continue — routing to the fix loop would send a Coder at code
whose fix nothing can then verify.

**The finding is not dropped.** It stays in `test-results.md` classified as it
was, the `⛔ TESTER BLOCKED` line says how many blocking findings are waiting,
and the orchestrator names them when it escalates. Once the human clears the
gate, a resumed run carries them forward (Part B, "The Blocked Path") and they
drive the verdict as usual.

This is also why BLOCKED reads "the run could not be finished" rather than "no
case ever ran": the report template counts `Not executed (device blocked)` and
asks *where* the block happened, which only a partial block can answer.

The blocked report carries a **Human Assistance Needed** section — what stopped
it, where, what it already tried, and the one concrete thing it needs — and the
`⛔ TESTER BLOCKED` line repeats that need in one line, so the orchestrator can
relay it without opening the file.

**Invariant**: a `BLOCKED` verdict reaches the human. It is never absorbed by
the orchestrator, retried silently until the budget runs out, or rounded to a
pass because the unit suite was green.

## No Raw adb

`adt-android-tester` and `adt-android-test-writer` have no shell, so neither
can reach for `adb`. That is deliberate. A raw `adb` command operates on the
*device*, not the app under test: `keyevent 26` (POWER) locks the screen and
`keyevent 3` (HOME) backgrounds the app, after which every tap lands on the
launcher and reads exactly like a feature that does not respond. That is how a
real run once reported a pass on a feature it never saw.

Nothing the plan asks for needs the shell any more:

- **Device state** — rotation, dark mode, permissions, offline, backgrounding,
  process death, force-stop — has a driver tool for each, named in the
  driver's adapter ("The Test Driver").
- **Installing the build, and reading Android's crash log** are done by
  `adt.sh`, which the orchestrator runs (Part B, "The Test Phase").
- **What the driver cannot do** makes the case `INCONCLUSIVE`, with the reason.
  **A gate a human can open** — a PIN, a sign-in, a device that stopped
  responding — makes the run `BLOCKED` ("When the Tester Is Blocked").

Neither is ever worked around. And whatever tool sent it, an interaction that
seemed to do nothing is first checked against the obvious explanation: is the
app still in the foreground?

**Invariant**: no agent that judges or tests the app runs a shell command
against the device.

## Test Credentials

The pipeline drives development builds on development devices, so the gates
guarding them — a keyguard PIN or pattern, a device passcode, a test-account
email and password, a 2FA code — are gates the Tester is allowed to pass. It
just has to be given the values.

**The Tester asks; it is never pre-armed.** There is no command-line syntax for
a credential and deliberately so. A credential is free-form text with no
natural terminator, so a token carrying one through `$ARGUMENTS` cannot be
parsed apart from the feature request without guessing — and guessing wrong is
how a PIN ends up in the Architect's prompt and from there in
`implementation-plan.md` on disk. The blocked path already provides a channel
with none of that ambiguity: the Tester names what it needs, the human answers
that question, and the whole reply is the answer.

The flow is exactly the blocked path (Part B), with the human's reply carrying
a value:

```
Tester hits a keyguard  →  ⛔ TESTER BLOCKED, "I need the device PIN"
                        →  orchestrator relays the ask
                        →  human replies `resume: the PIN is 1234`
                        →  orchestrator re-invokes the Tester with it
```

- **Only the Tester receives them**, and only in a `TEST CREDENTIALS` block in
  the spawn prompt of a resumed run. No other agent has a use for one, and no
  agent upstream of the Tester ever sees one, because none of them runs after
  the human answers.
- **Every build command can answer.** The blocked gate is the one point where
  the unattended commands pause for a human too (Part B, "The Blocked Path"),
  so a locked device costs one reply rather than a discarded run, whichever
  command started it.
- **They are run-scoped and never persisted.** They do not go into
  `pipeline_artifacts/`, into `test-results.md`, into a screenshot, into a
  flow file, into the code, or into the orchestrator's final
  summary. Artifacts record *that* a sign-in happened; the value stays in the
  conversation.
- **The Tester never sources its own.** A credential it was not handed is one
  it does not have — it does not guess a PIN, read one out of the repository or
  the environment, or reuse another app's stored session. It asks, by name, and
  stops.
- **Test accounts only.** A gate demanding what is plainly a real person's
  account or production access is a `BLOCKED`, not a sign-in, however the
  credential was supplied.

**Invariant**: every credential the Tester types was handed to it by a human
for this run, and none of them survives the run in a file.

## Review-Driven Fixes Are In Scope

A code-review finding usually has no fix in the plan. The plan is written before
the code exists, so it cannot anticipate the missing null check, the lifecycle
correction, or the unhandled error branch a reviewer catches by reading the
actual implementation. Under a strict reading of "build exactly what the plan
specifies", the Coder would have to STOP on every such finding and the gate
could never clear: the reviewer blocks on a real defect, the Coder is forbidden
to fix it, and the run dies after three attempts having changed nothing.

So: **a change made to satisfy a numbered item in a `🔧 CODE CHANGES REQUESTED`
list is in scope by definition, whether or not the plan specifies it.** It is
not scope creep, and `adt-android-code-reviewer` must not flag it as plan
infidelity on a later pass — its own review asked for it.

Four bounds keep this from becoming "the Coder does as it likes":

1. **Only what the finding names.** The minimal fix for that item — no adjacent
   cleanup, no opportunistic refactor of code the finding merely sits near.
2. **Only from a reviewer.** The carve-out covers numbered items a reviewer
   handed the Coder. It never licenses the Coder's own initiative during a first
   implementation pass, where "stay in the plan" applies in full.
3. **No new dependencies.** Section 2 of the plan owns the dependency set. A fix
   needing a library the plan never named is an architectural decision, not a
   fix — STOP and report it.
4. **Correctness wins over the plan, and the departure is stated.** Where the
   fix contradicts something the plan explicitly specifies — a named API that
   does not exist, two sections whose public interfaces do not meet — the Coder
   writes the correct code and says so plainly in its `✅ CODER DONE` marker.
   The plan itself is not edited mid-run: it is the Tester's contract too, and
   rewriting it under a run in progress leaves other agents reading a document
   that changed beneath them.

**Invariant**: a genuine defect the reviewer found is fixed in the tree the
developer is handed, and anywhere the fix departed from the plan is named in the
run's final summary rather than left for the developer to discover.

This section applies only where a code reviewer exists, which is
`/build-auto-reviewed`. It changes nothing in `/build-auto` or `/build-guided`,
whose Coders never receive a code-review finding.

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
- `adt-android-test-writer`: system prompt from `.claude/agents/adt-android-test-writer.md`; `enable_write_tools = true` (for writing flow files — its prompt forbids a shell); `enable_subagent_tools = false`; `enable_mcp_tools = true`.
- `adt-android-tester`: system prompt from `.claude/agents/adt-android-tester.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = true`.
- `adt-android-architect-reviewer`: system prompt from `.claude/agents/adt-android-architect-reviewer.md`; `enable_write_tools = true` (for read-only Bash inspection — the reviewer never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-code-reviewer`: system prompt from `.claude/agents/adt-android-code-reviewer.md`; `enable_write_tools = true` (for `git diff` and the build gate — the reviewer never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.

Antigravity does not support per-subagent model selection. The recommended models
in each agent file (`opus` for adt-android-pm/adt-android-architect and both
reviewers, `sonnet` for adt-android-coder, adt-android-test-writer and adt-android-tester) are documented
for reference; in Antigravity, all subagents inherit the user's globally selected
model — select the strongest available model for full pipeline runs.

## Approval Gates

For `/build-guided`, pause for explicit user approval between PM, Architect,
Coder, and Tester phases. Accept `approve`, `revise: <feedback>`, or `stop`.
The blocked gate is the one exception to that vocabulary: a `⛔ TESTER BLOCKED`
run is not something to approve or revise, so it accepts `resume` (optionally
carrying a credential) or `stop` instead — see "The Blocked Path" below.
At the Architect gate the artifact presented is `design-doc.md` — the plan is a
link for anyone who wants the file-by-file detail. A `revise:` there re-runs the
Architect under Part A's "Feedback Lands in the Documents" rule.

For `/build-auto`, skip the PM phase. If the feature description is too vague
for the Architect to produce a concrete plan, stop and suggest `/build-guided`
instead.

For `/build-auto-reviewed`, skip the PM phase and run no human gates — but
insert an automated reviewer after each producing phase, per the Reviewer-Loop
Protocol below.

**Both auto flows have exactly one human pause: the blocked Tester gate.** It
is not an approval gate — it approves nothing and can only answer a question
the run cannot proceed without. See "The Blocked Path".

## Design Doc Defaults Per Command

The rule is **the design doc follows review intent**: a flow with a review step
gets one, and the pure-speed flow does not.

| Command | Default | Where the human reads it |
|---|---|---|
| `/plan-design` | auto-detected from input | printed to chat upon completion |
| `/build-guided` | on | at the plan approval gate, before any code is written |
| `/build-auto-reviewed` | off | not generated |
| `/build-auto` | off | not generated |

`doc: on` / `doc: off` anywhere in `$ARGUMENTS` overrides the default in the
pipeline commands. The orchestrator strips that token from the text before
using the rest as the feature request, and translates it into the `DESIGN_DOC`
value it passes to the Architect (Part A, "The Two Architect Artifacts").

**Implementation Notes at end of run.** In the three build commands, when a
design doc was produced, the orchestrator — not an agent — appends to the
document's `## Implementation Notes` section what actually diverged from it:
reviewer bounces that changed the approach, Tester fix-loop changes, and any
approved `revise:` that landed after the plan gate. It has this in its own run
history; no re-reading of the diff is required. It edits that section only, and
writes "No divergence — the run implemented this document as written." when
there is nothing to record.

## Reviewer-Loop Protocol

Used by `/build-auto-reviewed`. After a producing agent finishes, the
orchestrator delegates to that agent's reviewer before proceeding:

- `adt-android-architect` → reviewed by `adt-android-architect-reviewer`
  (reviews `implementation-plan.md`, plus `design-doc.md` when the run produced
  one — pass both paths).
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

## Before the Run

Testing should never be the first place a broken setup shows up. Before any
agent runs, each build command:

1. **Resolves the script**, `adt.sh`, the same way PIPELINE_DOC was resolved:
   the relative path `.claude/adt/scripts/adt.sh`, kept exactly like that, if
   it exists in the project, otherwise `${CLAUDE_PLUGIN_ROOT}/scripts/adt.sh`.
   It is always run as one plain command — `bash <adt.sh> …`, from the project
   root, with no `cd`, no `&&`, no variables in front and no absolute form of
   the relative path — so the pre-approved permission rule matches it (see
   "Permissions" below).
2. **Runs the preflight**, `bash <adt.sh> preflight --driver <the test
   driver>`. It checks `adb`, the emulator and the AVDs it would boot (or the
   attached device), and the driver: for auto-mobile, that its background
   service is on the pinned version or can be started, which it then does; for
   Maestro, the CLI's version and Java. Each problem is a `FAIL` line that says
   how to fix it, and exit 16 means STOP before planning or coding anything.
   `warn` lines go into the final summary.
3. **Checks its own tool list** for the driver's MCP tools. None means the
   server is not registered: STOP. Under auto-mobile, a missing
   `mcp__auto-mobile__rotate`, `setDeviceState` or `executePlan` means its
   hidden tools are not switched on, which the run reports at the start and in
   the summary.

Then, as soon as the plan names the slug `S` and before the Coder starts, the
command **boots the run's device early**:
`bash <adt.sh> device-acquire --slug S --background`. It returns at once, and
the emulator boots while the Coder works. The test phase's own
`device-acquire` waits for it, so the boot costs no extra time. From this
point on, every exit releases the device.

**Permissions.** `install.sh` adds the pipeline's own rules to the project's
`.claude/settings.local.json`: `Bash(bash .claude/adt/scripts/adt.sh *)`,
`mcp__auto-mobile__*` and `mcp__maestro__*`. The build commands also list them
under `allowed-tools`. So Claude Code does not stop a run to ask about the
script or the driver's tools. An agent never adds permission rules itself;
only a person runs `install.sh` or `adt.sh allow`.

**Long-running calls.** `device-acquire`, `install` and `run` can each take
several minutes — a cold boot, a Gradle install, a long suite. Give them a
long timeout (in Claude Code, the Bash tool's maximum, ten minutes), or run
them in the background and wait for them to finish.

## The Test Phase

The three build commands test the same way. A run leases one device for its
whole life (Part A, "Devices"), and each test — the first one and every
re-test in the fix loop — goes through the same steps. Below, `S` is the
feature's slug, the `{slug}` in PLAN_PATH, and `<adt.sh>` is the script
resolved in "Before the Run".

Each test:

1. **Lease the device — the run's first test only.**
   `bash <adt.sh> device-acquire --slug S`. It returns the device the early
   boot started, waiting for it to finish booting; without an early boot, it
   boots a headless emulator of the run's own (never one the developer has
   open). It prints the serial on its last line: that is `DEVICE`. Running it
   again for the same slug in the same project returns the same device, so a
   re-run of a command that died picks its emulator back up. If it fails,
   release the device (an early boot may hold one), then STOP and report its
   message.
2. **Install — every test.**
   `bash <adt.sh> install --slug S -- <the install command from the plan's Section 0>`.
   It installs on `DEVICE` only, and prints a UTC timestamp on its last line:
   that is `BUILD_INSTALLED`. If it fails, release the device (below), then
   STOP and report the build error. Never test a stale build.
3. **Write the flows — the run's first test, and a re-test with flow
   defects.** Delegate to `adt-android-test-writer` with PLAN_PATH,
   PIPELINE_DOC, DRIVER_DOC, `DEVICE` and `BUILD_INSTALLED`, and wait for
   ✅ TEST WRITER DONE. Before a re-test, run it again only if the previous
   `test-results.md` lists Flow Defects, passing those cases and the Tester's
   notes as `CASES`; otherwise skip this step — the flows are already written.
   If it STOPs, release the device, then STOP and report.
4. **Run the flows.**
   `bash <adt.sh> run --slug S --driver <the test driver> --area <area>:<tiers> … --exclude <id> …`,
   with one `--area` per row of the plan's Regression Scope (its tiers joined
   by commas, `--area checkout:p1,p2`) and one `--exclude` per row of Flows
   Retired. It runs this run's own flows plus the regression suite flows it
   selects — every P0, the named tiers per area, never a flow this run
   re-specifies — on `DEVICE` with no model in the loop, and writes
   `pipeline_artifacts/S/run-results.md`. After each flow it reads Android's
   crash log, so a crash or ANR of the app fails that flow even when every
   check in it passed. Exit 0 means every flow passed and exit 1 that at least
   one failed — both continue, because judging failures is the Tester's job.
   Any other exit: release the device, then STOP and report its message. Each
   flow may run for up to `ADT_FLOW_TIMEOUT_S` (300 s by default), so this is
   one of the long-running calls in "Before the Run".
5. **Test.** Delegate to `adt-android-tester` with PLAN_PATH, PIPELINE_DOC,
   DRIVER_DOC, `DEVICE: <serial>`, `BUILD_INSTALLED: <timestamp>`,
   `RUN_RESULTS: pipeline_artifacts/S/run-results.md`, and whatever the command
   adds for a re-test. Wait for **either** `✅ TESTER DONE` **or**
   `⛔ TESTER BLOCKED` — both end its turn. On `⛔ TESTER BLOCKED`, take "The
   Blocked Path" below instead of the fix loop.

The device stays leased between tests — while a Coder fixes, while a reviewer
re-reviews, and in `/build-guided` while the run waits for the user — so a
re-test needs no new boot.

**Release the device when the run ends.** Once a device is leased, every exit
from the command releases it first: before the final summary, before
reporting any STOP, and when the user answers `stop`:
`bash <adt.sh> device-release --slug S`. If that exits non-zero, report the
serial it names and carry on. This is deliberately its own step, not part of
"Close the run", which is skipped whenever a run has no design doc.

**Keep the passing flows — once, at the end.** After the run's final verdict
is `READY TO MERGE` (in `/build-guided`, when the user answers `approve` and the
last verdict was `READY TO MERGE`), run
`bash <adt.sh> promote --slug S --remove <id> …`, with one `--remove` per row of
Flows Retired and per entry in the last `test-results.md`'s "Suite Flows to
Remove". It copies the flows to keep into `e2e/flows/` and prints what it
added, replaced and removed. Never promote after `NEEDS FIXES`, `BLOCKED` or a
STOP. If it fails, report it; the verdict stands.

Note the time around steps 3, 4 and 5. The final summary names the test
driver and the device, and reports, for each test, how long the Test Writer,
the flow run and the Tester took, so the user can see where the run's time
went. It repeats the preflight's warnings, and the Tester's Coverage: how many
cases were verified by a flow, by hand, or not at all, with each unverified
case and why — so `READY TO MERGE` always says how sure it is. It also gives the last run's regression counts (replayed, failed, flaky),
any P0 warning from `run-results.md`, and the suite flows promote added,
replaced and removed — reminding the user to commit `e2e/flows/` with the
feature.

**Running the Tester outside a build command.** Lease and install with the
script yourself (`device-acquire`, then `install`), invoke
`adt-android-tester` with PLAN_PATH, DRIVER_DOC, `DEVICE` and
`BUILD_INSTALLED`, and run `device-release` when you are done. Without `BUILD_INSTALLED` the Tester stops
and says the build was not installed. Without `RUN_RESULTS` it drives every
case by hand; to use flows instead, run the Test Writer and `adt.sh run` first.

**Script exit codes.** 0 success, 1 a flow failed (`run` only), 2 usage, 10 no
usable device, 11 the emulator did not start or boot, 12 the install command
failed, 13 a device could not be stopped, 14 the driver's command line is not
installed, 15 no device is leased for this run, 16 the preflight found a
problem. Its messages say what to do;
report them verbatim.

**The Tester and the Test Writer have no shell.** Their tool lists hold file
tools and the two drivers' MCP tools, so they cannot reach for `adb` — every
device action goes through the tools the adapter names, and a case that needs
anything else is reported `INCONCLUSIVE`. Claude Code enforces the tool list.
In Antigravity the one setting that grants a shell, `enable_write_tools`, is
also what lets the Tester write `test-results.md` and the Test Writer write
flows, so their mappings keep it; there, and in OpenCode, the no-shell rule is
enforced by their prompts only.

## The Blocked Path

When the Tester ends on `⛔ TESTER BLOCKED` (Part A, "When the Tester Is
Blocked"), the orchestrator takes this path instead of the fix loop:

1. **Do not spawn a Coder over a device gate.** A keyguard disproves nothing
   about the code, and the fix could not be re-tested anyway. The exception is
   a block whose cause *is* the code — a failing install command is a build
   break, not a device problem — which the human routes like any other build
   failure.
2. **Do not re-invoke the Tester on the same conditions.** The device that
   ignored it will ignore it again; a second attempt only spends tokens. The
   one thing that changes the outcome is the human.
3. **Relay the ask verbatim** — the line on the `⛔ TESTER BLOCKED` marker, and
   the report's **Human Assistance Needed** section. State the artifact path so
   they can read the rest.
4. **Report the true state of the tree, which depends on how you got here.**
   A block on the first Tester run means coded and unverified. A block on a
   *re-test inside the fix loop* means something else entirely: blocking
   defects were proven, a Coder attempted fixes, and those fixes were never
   verified. Say which, and carry the earlier run's blocking findings into what
   you show the human — never tell them "nothing about the code was disproved"
   on a path where something was.
5. **Ask the human, and wait — in every command.** Present the ask and take one
   of two replies:
   - `resume` — carrying what the Tester asked for when it named a credential
     (`resume: the device PIN is 1234`), or on its own once the human has
     cleared the gate themselves. Re-invoke the Tester with `PLAN_PATH`,
     PIPELINE_DOC, DRIVER_DOC, the same `DEVICE`, `BUILD_INSTALLED` and
     `RUN_RESULTS`, the previous `test-results.md`, any `TEST CREDENTIALS` they
     just supplied, and the instruction to resume from the case it stopped at,
     carrying the earlier results forward. The device stays leased while the
     run waits, and the flows do not run again: nothing about the build
     changed.
   - `stop` — halt, reporting as in step 4, and release the device.

   There is no `approve` and no `revise:` here. A run that could not finish its
   cases is not something to approve, and the Coder is not the answer to a
   locked screen.

   **The unattended commands pause here too, and that is not a contradiction.** What
   makes `/build-auto` and `/build-auto-reviewed` unattended is the absence of
   *approval* gates — nobody signs off on the plan, the code, or the results.
   This gate approves nothing. The run has hit a wall it cannot pass, and the
   only two options are to wait for one short answer or to throw the run away.
   Stopping costs strictly more: it discards a finished Architect phase and a
   finished Coder phase that a re-run has to pay for all over again. If nobody
   is watching, the run waits, and nothing is lost that stopping would have
   saved.

6. **A resumed run rejoins the normal flow.** `✅ TESTER DONE` is handled on
   its verdict like any other run — `READY TO MERGE` closes the run,
   `NEEDS FIXES` enters the Tester fix loop with its iteration budget
   untouched, because a block consumed a resume rather than a fix. Only another
   `⛔ TESTER BLOCKED` comes back here.
7. **Close the run as usual** on the way out — Implementation Notes when a
   design doc exists, per "Design Doc Defaults Per Command". A STOP is an exit
   path like any other.

A resumed Tester may block again — on the same gate, if the human's fix did not
take, or on the next one. Allow **at most 2 resumes** in every command; after
that, report and stop, so a device that cannot be made to cooperate does not
turn into an unbounded loop.

Never report a blocked run as a pass, and never let it exit silently. The
failure this path exists to prevent is a green summary on a feature no one ever
saw run.

## Orchestration Workflow (Antigravity)

When the user invokes `/build-guided`, `/build-auto`, or `/build-auto-reviewed`, the parent agent acts as orchestrator:

1. **Define Subagents**: Dynamically register any required subagents using `define_subagent` if they aren't already defined, using the mappings above — including `adt-android-test-writer`, which every build command uses. For `/build-auto-reviewed`, also register `adt-android-architect-reviewer` and `adt-android-code-reviewer`.
2. **Execute Phases**:
   - **PM Phase** (`/build-guided` only): Invoke `adt-android-pm` with the user request. Pass messages back and forth between the user and the PM subagent until it outputs `✅ PM DONE`.
   - **Architect Phase**: Invoke `adt-android-architect` with the PM's `feature.md` path (or the feature description for the auto flows) and the `DESIGN_DOC` value this command defaults to (see "Design Doc Defaults Per Command"). Wait until it outputs `✅ ARCHITECT DONE`, and parse the artifact paths out of that marker — the plan path always, and the design doc path when one was requested.
   - **Architect Review Gate** (`/build-auto-reviewed` only): Invoke `adt-android-architect-reviewer` with the plan path (and the design doc path if one was requested), and apply the Reviewer-Loop Protocol above before proceeding. A bounce re-runs the Architect, which re-emits the artifacts, so any document a human ends up reading is always the approved one.
   - **Coder Phase**: Read the execution strategy from the implementation plan. If parallel-safe, verify mechanically that no file appears in two sections of the same group, then invoke multiple `adt-android-coder` subagents in parallel. Otherwise, invoke a single `adt-android-coder`. Parallel coders run no Gradle — you own the verification, via the cross-section check after **every** group (Part A, "Gradle in a Parallel Run"). Take its command from the plan's Section 0 like every other agent — not from Part A's defaults — and on failure follow Part A's "When the cross-section check fails".
   - **Code Review Gate** (`/build-auto-reviewed` only): After all coding is complete, invoke `adt-android-code-reviewer` with the plan path and apply the Reviewer-Loop Protocol above before proceeding.
   - **Before the run**: resolve the test driver and the script, run the preflight, and check the driver's MCP tools ("Before the Run" above). After the Architect, start the early boot.
   - **Tester Phase**: Run "The Test Phase" above: lease the run's device, install the build on it, invoke `adt-android-test-writer` to write the flows, run them with `adt.sh run`, then invoke `adt-android-tester` with the plan path, `DRIVER_DOC`, `DEVICE`, `BUILD_INSTALLED`, `RUN_RESULTS`, and any `TEST CREDENTIALS` the human supplied for this run (Part A, "Test Credentials"). It judges the flow results, drives what no flow covers, and writes `test-results.md`. Wait for **either** `✅ TESTER DONE` **or** `⛔ TESTER BLOCKED` — both end its turn.
   - **Tester Blocked**: on `⛔ TESTER BLOCKED`, take "The Blocked Path" above instead of the fix loop, and do not advance.
   - **Tester Fix Loop**: on a `NEEDS FIXES` verdict, run the bounded
     Coder → targeted re-review → re-test loop the command file defines (max 2
     iterations) — each re-test is a run of "The Test Phase" on the same
     device, install included — then STOP and report if it is still
     failing. In `/build-auto-reviewed` the targeted re-review is mandatory —
     see "The Targeted Re-Review" above; the code that ships must have been
     reviewed after its last mutation. A run never ends by declaring a
     `NEEDS FIXES` feature complete.
3. **Gates**: For `/build-guided`, pause at each phase boundary for explicit user approval — `approve`, `revise: <feedback>`, or `stop`, except at a blocked Tester gate, which takes `resume` or `stop` (see "Approval Gates" and "The Blocked Path"). For `/build-auto-reviewed`, the gates are the automated reviewer loops (no human pause). For `/build-auto`, there are no gates.
4. **Close the run**: release the run's device (see "The Test Phase"), on every exit including a STOP. When a design doc was produced, append its Implementation Notes before reporting the final summary (see "Design Doc Defaults Per Command"), and report the design doc path alongside the verdict.

## Native Workflow Registration

`/build-auto`, `/build-auto-reviewed`, and `/build-guided` slash commands (along
with `/plan-research` and `/plan-design`) are registered natively
in Antigravity via symlinks in `.agents/workflows/` that point to
`.claude/commands/`. Team personas are inlined into the consuming project's
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
4. **Tester MCP**: the test driver's MCP server is registered in
   `opencode.json` under the `mcp` key — auto-mobile as an HTTP server
   (`type: "remote"`, with auto-mobile's `url`), Maestro as a local one
   (`type: "local"`, `command: ["maestro", "mcp"]`); the Tester reaches it like
   any other tool.
5. **Rules**: agents and commands reference `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`
   and the project's `AGENTS.md`/`CLAUDE.md` by path (both present in the project
   tree), so opencode reads the same sources of truth as the other tools.
