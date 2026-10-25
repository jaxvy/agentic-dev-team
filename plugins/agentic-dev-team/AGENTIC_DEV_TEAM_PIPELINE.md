# Multi-Agent Pipeline: Agent Protocol

This file is the shared source of truth for the PM → Architect → Coder → Tester
pipeline. Every agent reads it. Project-specific architecture, libraries, and
verification rules live in the consuming project's `AGENTS.md` (or `CLAUDE.md`).

The rules come in three files, so that each reader loads only what it needs:

- **This file, Part A (Agent Protocol)**: everything an `adt-*` agent must obey.
- **`AGENTIC_DEV_TEAM_ORCHESTRATION.md`, Part B (Orchestration & Tool
  Registration)**: everything only the orchestrator (the parent agent or slash
  command driving a run) needs: the start of every command, subagent mappings,
  approval gates, the reviewer loop, the test phase, and per-tool registration.
  Agents do not read it. Where this file says "Part B", it means that file.
- **`AGENTIC_DEV_TEAM_CONFIG.md`**: the optional config file
  (`.agentic-dev-team/config.yaml`) and configured runs. Only an orchestrator
  whose config file has an active setting reads it.

All three files sit side by side: at the plugin root, and in `.claude/` in a
per-project install.

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

## The Named Commands

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

- **The release check** (optional) — builds the release variant with R8 on, so
  a missing keep rule or a release-only compile error shows up before the
  developer ships, not in the first release build. It is `none — <reason>`
  when the release build is not minified. The orchestrator runs it in every
  test, through `adt.sh check` (Part B, "The Test Phase"); a failure is a
  blocking finding the Tester reports, and it goes to the Coder through the fix
  loop like any other. A Coder fixing that finding runs the release check
  itself after the build gate.

- **The device tests** (optional) — the instrumented tests the plan requires
  (`src/androidTest/`, for example a Room migration test), run on the run's
  device: the module's connected test task, filtered to the plan's test
  classes. It is `none — <reason>` when the plan requires no instrumented
  test. The orchestrator runs it in every test, before the install, because a
  connected test run uninstalls the app when it ends; a failure is a blocking
  finding the Tester reports. When it is not `none`, the build gate also
  assembles the instrumented test APK (for example
  `:app:assembleDebugAndroidTest`), so those tests compile in every review.

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
   release check:       none — no plan, so nothing says the release build is minified
   device tests:        none — no plan, so no instrumented test is required
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
`adt-android-test-writer` turns each case into a **flow** — the same test as a
file in the test driver's own format — from the plan and the code that now
exists, without running it. A script then runs every flow with no model in the
loop; the Test Writer is called back only for the run's own flows that failed,
to fix how they reach the app, and the script re-runs just those. Then
`adt-android-tester` judges the results.

- **Who writes what.** The Architect writes cases; the Test Writer writes
  flows, one per case and none of its own; the Tester writes neither. A flow's assertions come only from its
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
- **Cases with no flow** — one that needs a credential the project has not
  declared as a test secret ("Test Credentials" below), or whose Expected is a
  judgment a machine cannot check — are driven by hand by the Tester. A case
  the driver can check only in part gets a **partial** flow, marked in
  `flows/INDEX.md` with what it leaves out; the Tester checks just that part by
  hand, and the case counts as verified only after it has.
- **Coverage is reported, not implied.** `test-results.md` says, for every
  case, how it was verified — by a flow, by hand — or that it was not, and
  why. The verdict rule does not change: an unverified case is not a blocking
  finding. But a `READY TO MERGE` with cases nobody could verify says so in
  the summary the user reads.

## Test Cases a Flow Can Run

The Test Writer turns each of Section 4's cases into a flow, and a flow can do
only what both test drivers can: find one element by an exact value, act on it,
and check whether an exact element or text is on screen. A case that asks for
more cannot be run. So the Architect writes every case to these rules, and the
plan reviewer checks every case against all of them:

1. **Exact selectors.** Every step that acts, and every Expected, names its
   element by an exact test tag, content description or visible text, in the
   plan's notation: `[testTag=save_item_button]`, `[text="Save"]`. Never a
   pattern or wildcard (`duplicate_badge_*`), a position given as a selector
   ("the first row", "index 0", "the third match"), or one element found
   inside another ("the Delete button in Copy three's row"). A position built
   into the tag itself is fine (rule 2). Never a driver's own syntax; the Test
   Writer translates the plan's notation.
2. **Predictable tags for repeated elements.** An element that appears once per
   item — a row, a chip, a badge — gets a tag the case can know in advance:
   from its index in the list it belongs to (`duplicate_badge_0` for the first
   item, built from the list's index) or from a value the case itself enters,
   such as a title it types. Never from an id generated at run time: a UUID, a
   database id, a timestamp. The code sample builds the tag, and the UI
   Selectors table records the scheme. A lazy list (`LazyColumn`,
   `RecyclerView`) has only the rows on screen, so a case that checks a row
   below the first screen scrolls to it first:
   `Scroll [testTag=duplicate_list] until [testTag=duplicate_badge_7] is visible`.
3. **Screen-wide checks.** A check says whether something is on screen, not
   where it is. When an Expected depends on where — "the sheet lists the other
   two copies, not this one" — give the elements inside that container their
   own tags (`duplicate_sheet_row_0`) and check those, state the claim for the
   whole screen, or mark that clause *checked by hand*.
4. **Each case stands alone.** Every flow starts from a clean launch with the
   app's data cleared, and runs on its own, in any order. A case creates
   everything it needs in its own steps. It never continues from another case
   ("continue from TC1") or relies on data another case left behind. Steps
   several cases share can be written once as a named **Shared setup** — itself
   a list of steps with selectors — and each case starts by naming it.
   Clearing the app's data also resets its runtime permissions and brings back
   its first-run screens: onboarding, a consent dialog, the notification
   permission prompt on Android 13 and later. Write those once, as a Shared
   setup named "First launch", from the app's code, and start every case with
   it. Whether the driver grants permissions at launch is in its adapter.
5. **Preconditions are steps or device state.** "Three bookmarks exist" is the
   steps that create them, or a **test hook** the project declares (below).
   Device state — offline, dark mode, a permission, a rotation — goes in
   **Setup**. "Signed in" is a Shared setup that types the project's **test
   secrets** by name, `Type "${TEST_EMAIL}" into [testTag=email_field]`, never a
   value ("Test Credentials" below). With no declared secret for it, say so,
   and the case is driven by hand.

   A project declares both in its `AGENTS.md` (or `CLAUDE.md`):

   ```
   Test secrets: TEST_EMAIL, TEST_PASSWORD
   Test hooks:
   - myapp://debug/seed?bookmarks=3: adds 3 bookmarks (debug builds only)
   - Fake backend: the `fake` flavor answers every request from local data
   ```

   A test hook is used as a step, `Open link "myapp://debug/seed?bookmarks=3"`,
   and never invented: a hook the project does not declare is an Open Question
   in the plan, not a step. When the project declares a fake backend, the
   plan's install command installs that build, so the flows do not depend on a
   live server and never change shared test data.
6. **What no machine can check is marked.** A clause only a person can judge
   ("the layout looks right in dark mode"), or one the drivers cannot check
   (which field has focus), is marked *checked by hand*. The Test Writer leaves
   it out of the flow and marks the flow partial, and the Tester checks that
   clause.
7. **Timing is stated.** A step that must happen within a short window, such as
   tapping Undo before a snackbar disappears, says how long the window is.
8. **Every window exposes its test tags.** In a Compose app, a `testTag` is a
   resource id, which is what the drivers find, only under
   `Modifier.semantics { testTagsAsResourceId = true }`. That must be set at the
   root of each window's content: the Activity's `setContent`, and every
   `ModalBottomSheet`, `Dialog` and `Popup`, which compose in a window of their
   own.

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

**Exception:** files under `.agentic-dev-team/` are the developer's pipeline
configuration, not part of any run's changes. They are normally git-ignored
and do not appear. If they appear (the developer un-ignored the config and
has not committed it yet), leave them out of the review and do not report
them.

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

### Instrumented tests

A JVM test is the default: it runs in the build gate, in seconds, on every
review. A case that needs a real Android runtime is marked `(instrumented)`
in **Tests required**, with its file under `src/androidTest/`, and it runs as
the **device tests** (above) on the run's device. Use it only where a JVM test
(with Robolectric, when the project has it) cannot prove the behaviour. The
same rules apply: the plan names it, the Coder writes it (and cannot run it,
since the Coder has no device; the build gate compiles it), and the reviewers
check it.

### Data that outlives an update

A user's data survives an app update, so a change to how it is stored must be
proven against the old format. **When a section changes a Room schema** (a new
or changed entity, column, index or table, or a new database version), the
plan must:

- add the migration (a `Migration`, or an `@AutoMigration` with its spec), and
  never `fallbackToDestructiveMigration` for user data unless the feature
  request asks for it;
- keep `exportSchema = true` with a schema location (add `room.schemaLocation`
  in Section 2.3 when the project has none), and list the new schema JSON in
  that section's **Files**;
- name an instrumented migration test with Room's `MigrationTestHelper`: create
  the old version, insert rows, run the migration, and check the rows and the
  new schema. Its dependency (`androidx.room:room-testing`) is in Section 2 when
  the project lacks it.

The same holds for other stored formats the app reads after an update, such as
a renamed DataStore key or a changed serialized model: name a test that reads
data in the old format. A schema change without its migration test is a
blocker for both reviewers.

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
launcher and reads exactly like a feature that does not respond, so a run
could report a pass on a feature it never saw.

Nothing the plan asks for needs the shell:

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

These values stay in the conversation, and the tool you run keeps the
conversation's transcript (Claude Code stores it on disk). Use test accounts and
a device PIN you can lose, never a real one.

### Test secrets for flows

A flow runs with no model in the loop, so it cannot ask. For the cases that
sign in, a project declares **test secrets** instead: their names in
`AGENTS.md` (`Test secrets: TEST_EMAIL, TEST_PASSWORD`), and their values in
`.agentic-dev-team/secrets.env`, one `NAME=value` per line, on the developer's
machine only.

- **Agents use names, never values.** The Architect writes `${TEST_EMAIL}` in a
  step, the Test Writer copies it into the flow, and neither reads
  `secrets.env`. No agent ever opens that file, the Tester included: it is not
  a credential handed to the run.
- **The script fills them in.** `adt.sh run` gives auto-mobile the flow with
  each `${NAME}` replaced by its value, and gives Maestro `-e NAME=value`. A
  flow that uses a name the file does not set fails before it runs, with that
  name.
- **Nothing keeps a value.** The script scrubs every value from the run's logs
  and from `run-results.md`, and refuses to run when `secrets.env` is tracked by
  git or not git-ignored. The flow files, and the suite in `e2e/flows/`, hold
  only names.
- **Test accounts only**, as above. The values are visible to other processes
  of the same user while a flow runs (they are command-line arguments), so a
  secret is never a real person's password.

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
