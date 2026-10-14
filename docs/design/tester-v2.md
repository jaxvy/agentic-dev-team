# Tester v2: one emulator per feature, a Test Writer after the Coder, two drivers, and a regression suite

**Status**: proposal, nothing implemented · **Date**: 2026-10-13 · **Owner**: jaxvy

## What this gives you

- **No `adb`.** The Tester uses its driver's own tools and has no shell.
- **One emulator per feature.** Each build command boots its own headless
  emulator. It uses that emulator for every test and re-test in the run, and
  stops it at the end. Two features can build at the same time without
  touching each other.
- **Fast test execution.** Each test case becomes a flow file, and a script
  runs the flows with no model between steps. A re-test after a fix re-runs
  every flow in one script call.
- **A regression suite with P0, P1 and P2.** Flows that pass are kept in the
  project. Each later feature replays the tiers its plan picks, in the same
  script call. There is no separate command.
- **Maestro at the same level as auto-mobile.** A project picks one. Either
  driver drives the hand checks, writes and runs flows, and replays the suite.

The work is five pull requests, merged in order. Each one is testable on its
own and leaves the pipeline working.

| PR | What it does |
|---|---|
| **1** | The Tester uses auto-mobile's own tools for device state, and loses its shell |
| **2** | Each feature run gets its own emulator |
| **3** | Maestro becomes a second driver, at the same level as auto-mobile |
| **4** | A new Test Writer turns each test case into a flow after the Coder, and a script runs the flows |
| **5** | A regression suite with P0, P1 and P2 tiers |

Part 1 explains the design, Part 2 is the pull requests, and Part 3 says what
was verified.

---

# Part 1 — What changes and why

## 1. Who writes what

| Agent | Writes | When |
|---|---|---|
| Architect | Each test case **once**: steps with selectors, and the expected result. From PR 5, also its id and tier. | Before the code, as today |
| Coder | The code, and the unit tests the plan specifies | As today |
| **Test Writer** (new in PR 4) | One runnable flow per test case, checked against the running app | After the Coder, on the feature's emulator |
| Tester | No tests. It reads the flow results, investigates each failure on the device, drives the cases that have no flow, and gives the verdict. | After the flows run |

Why the work is split this way:

- **The Architect's test case is the spec, not the test.** It says what must
  be true, and it names the test tags the Coder must add. It has to exist
  before the code, exactly like the plan's GIVEN / WHEN / THEN lines for unit
  tests. It is written once, and it does not change from today.
- **The runnable test is also written once, after the code exists.** The Test
  Writer reads the new screens' code, writes the flow, and runs it on the
  emulator. So the waits, the texts and the navigation come from the real app,
  not from a guess about an app that does not exist yet.
- **The Tester stays independent.** The agent that judges the app never writes
  the checks it judges by.

The other options, and why they lost:

| Option | Why not |
|---|---|
| The Architect writes the flows too | The case is written twice, once as steps and once as a flow. The flow is written before the app exists, so its waits, texts and screen transitions are guesses. |
| The Coder writes the flows | The Coder has no device, so it guesses in the same way. It also makes the Coder's job and the code review bigger. |
| The Tester writes or records the flows | The agent that gives the verdict would write its own checks. A recording also captures what the app did, not what the case expected. |
| No flows; the Tester stays faster at driving by hand | Driving by hand costs a model round trip per step on every run, and leaves nothing to replay. |

**Prior art.** [Playwright Test Agents](https://playwright.dev/docs/test-agents)
splits the work the same way. A planner writes a Markdown test plan. A
generator turns it into tests while checking them against the live app. A
healer repairs failing tests. Here the Architect is the planner and the Test
Writer is the generator. The healer is left out: the Tester reports a broken
flow, and the Test Writer rewrites it before the next re-test.
[Arbigent](https://github.com/takahirom/arbigent) is an Android test agent
built on Maestro. [BMAD Test Architect](https://github.com/bmad-code-org/bmad-method-test-architecture-enterprise)
uses risk tiers from P0 to P3.

## 2. Summary

| | Today | After all five PRs |
|---|---|---|
| `adb` | Used ad hoc | The Tester and the Test Writer have no shell |
| Device | Whatever is attached; STOP if none | Each run boots its own headless emulator and keeps it until the run ends |
| Two features at once | They collide | Separate emulators |
| Running a test case | A model round trip per step | A flow run by a script, with no model between steps |
| Re-test after a fix | The Tester drives the failed cases again | The script re-runs every flow; the Tester looks only at failures |
| After the feature ships | Test steps are deleted with the run | Passing flows stay in `e2e/flows/` |
| Regression check | One adjacent screen, checked by hand | All P0 flows, plus P1 and P2 where the plan points |
| Driver | auto-mobile | auto-mobile or Maestro |

**What is not faster.** The first test of a feature takes about as long as
today. The Test Writer does once what the Tester used to do on every run. The
gains come on every re-test and on every later feature.

## 3. What is wrong today

File references are under `plugins/agentic-dev-team/`.

| Symptom | Cause | Evidence |
|---|---|---|
| Uses `adb` instead of auto-mobile | The plan requires airplane-mode, force-stop, permission and rotate/dark-mode cases, but the auto-mobile tools for them are hidden by default. The Tester has unrestricted `Bash`, so `adb` is the only route it can see. | `agents/adt-android-architect.md:737-751`, `agents/adt-android-tester.md:9`. In this session auto-mobile advertised 30 of about 80 tools; `rotate`, `displayConfig`, `setAppPermissions` and `setDeviceState` were not among them. |
| Slow | The Tester drives each case live, with one model round trip per step, and each step returns a screen observation. | `agents/adt-android-tester.md:139-149` |
| Slow on re-test | The replay path depends on `executePlan` and three recording tools that are also hidden by default. The prompt calls it best-effort, so it never runs. | `agents/adt-android-tester.md:150-156` |
| Tests are not reused | Cases live in `pipeline_artifacts/`, which is git-ignored, and nothing keeps them. | `AGENTIC_DEV_TEAM_PIPELINE.md:35`, `agents/adt-android-tester.md:70-73` |
| Relies on an existing emulator | "No device or emulator is available" is a STOP. Nothing boots one. | `agents/adt-android-tester.md:97` |
| Cannot run two features at once | No device ownership, and the install command names no device. | `AGENTIC_DEV_TEAM_PIPELINE.md:125-127` |
| Tied to one driver | auto-mobile is named in the Tester's frontmatter and prompt. | `agents/adt-android-tester.md:9` |

Two more things found on this machine:

- **The auto-mobile version floats.** The MCP registration runs
  `bunx @kaeawc/auto-mobile@latest`. The global install is 0.0.28 and the
  latest release is 0.0.84. A new release picked up mid-run can restart the
  shared daemon under another run. The fix is to pin the version.
- **auto-mobile's online docs are ahead of its release.** They describe its
  main branch. Two things in them are not in 0.0.84: an `executePlan` option
  called `holdSessionOnFailure`, and the rule that a device held by one session
  refuses calls from another. This design uses neither. Section 18 lists what
  was checked against the 0.0.84 package itself.

## 4. A run, end to end, after PR 5

```
Architect: the plan, with each test case written once
        |
Coder, then code review
        |
        v
1  lease an emulator (first test only), install the build    script
        |
        v
2  Test Writer: one flow per case, each run once              model, first test only
        |
        v
3  pick the regression flows the plan asks for                script
        |
        v
4  run the feature's flows and the regression flows           script, no model
        |
        v
5  Tester: investigates failures, drives the cases            model
   with no flow, gives the verdict
        |
        v
6  NEEDS FIXES? -- yes --> Coder fix (and review), back to 1 on the same
        |                  emulator: install again; the Test Writer runs
        no                 again only for flows the Tester found broken
        |
        v
7  keep the passing flows in e2e/flows/                       script
        |
        v
8  release the emulator (also before any STOP)                script
```

PR 1 and PR 2 build steps 1 and 8 around today's Tester. PR 4 adds steps 2 and
4. PR 5 adds steps 3 and 7.

## 5. auto-mobile's own tools, and no shell (PR 1)

auto-mobile hides most of its tools until they are enabled. Setting
`AUTOMOBILE_ENABLED_TOOLS` on the auto-mobile server advertises the ones the
Tester needs. The Tester's prompt gains a short table, so it never has to guess
which tool does what:

| Case needs | auto-mobile tool |
|---|---|
| Rotation | `rotate` with `orientation` |
| Dark mode, font scale | `displayConfig` with `theme` or `fontScale` |
| Grant, revoke or reset a permission | `setAppPermissions` |
| Offline | `setDeviceState` with `connectivity: {airplaneMode: true}`, confirmed with `getDeviceState` |
| Background, then process death | `appLifecycle` |
| Force stop | `terminateApp` |
| Clean app state | `launchApp` with `clearAppData` |
| Deep link | `openLink` |

**Offline is confirmed, not assumed.** After switching Airplane mode on, the
Tester reads `getDeviceState`. It judges an offline case only once Airplane
mode reads as on. If it does not, the case is `INCONCLUSIVE`, never `FAIL`. The
Tester switches Airplane mode off again before the next case. auto-mobile also
has a network-condition setting, but its docs call that best-effort on
emulators, so the design uses the Airplane mode toggle instead.

**No shell.** The Tester's tool list becomes `Read, Write,
mcp__auto-mobile__*`. `Write` stays for `test-results.md`. A case that needs
something not in the table is `INCONCLUSIVE` with the reason, and is never
worked around. Removing the shell takes `adb` away, so PR 1 is merged only
after its tests show two things: the table's tools actually reach the Tester,
and offline can be confirmed without a shell.

**The stale-build guard stays with the Tester.** Today the Tester installs the
build itself and refuses to test if that fails. Without a shell it cannot
install, so it refuses to test unless its caller says the build was installed.
The orchestrator passes `BUILD_INSTALLED: <timestamp>`, and without that line
the Tester STOPs. That keeps the guard on every route to the Tester, including
a direct request to "test the build".

**Enforcement.** Claude Code enforces the tool list. In Antigravity the
Tester's mapping stays as it is. The one setting that grants a shell there,
`enable_write_tools`, is also what lets the Tester write `test-results.md`. So
in Antigravity and OpenCode the no-`adb` rule is enforced by the prompt only.

## 6. One emulator per feature run (PR 2)

The emulator's `-read-only` flag lets several instances of one AVD run at once,
each with disposable state. Each instance takes an even console port from 5554
to 5584, plus the port above it for adb, and its serial is `emulator-<port>`.
So the script picks a free pair of ports and knows the serial before the device
is up.

Measured on this machine: two headless read-only instances of one AVD booted
at the same time. Each reached `sys.boot_completed` in about 21 seconds from a
cold boot, held its own state, and shut down cleanly.

One constraint is absolute: **a read-only instance cannot start while a normal
instance of the same AVD is running.** On this machine `Pixel_10_Pro_XL` is
open in normal mode, so the script must use another AVD. It handles this
itself:

- By default it picks the first AVD that has no normal instance running, boots
  it headless and read-only, and stops it when the run ends.
- An attached device is used in exactly two cases: you set
  `ADT_DEVICE_MODE=reuse`, or no AVD can be used for a known reason (none
  exists, or every one is open in normal mode). The script names the device and
  the reason, and never stops a device it did not start.
- An emulator that fails to start for any other reason is retried once on
  other ports and then reported. It never falls back to your own device.
- If nothing can be used, the run stops with the reason.

**For the whole run.** The emulator is leased at the run's first test. It is
kept for every re-test, and released when the command ends: before the final
summary, and before any STOP once it is leased. In `/build-guided` it stays up
while the run waits for you at the gate after testing, so a `revise:` re-tests
without a new boot. The cost is one idle headless emulator's memory while a
Coder fixes something or you decide. Nothing is leased before the run's first
test.

Four things make two features safe at the same time:

1. **Device.** Each run claims a port with an atomic `mkdir` under
   `~/.adt/leases/`.
2. **Ownership.** A lease belongs to a project directory and a slug together.
   So two worktrees, or two apps, that happen to share a slug never share a
   lease.
3. **Install.** The install command runs with `ANDROID_SERIAL` set to the
   leased serial, so Gradle installs only there.
4. **Driver.** Every agent that touches the device binds to its serial and
   never starts, stops or switches devices. The isolation comes from each run
   using only its own serial. It does not depend on the driver refusing anyone
   else.

Two features built at once also need a git worktree each, because one checkout
has one Gradle project. The pipeline doc already explains why concurrent Gradle
in one tree is unsafe.

**If a session dies mid-run,** its emulator keeps running. Running the same
command again for the same feature, in the same checkout, picks it up again,
because acquiring is idempotent for a project and slug. Otherwise
`adt.sh device-list` shows it, and `adt.sh device-release --serial <serial>`
stops it.

**One-time setup per AVD.** auto-mobile installs a helper service on a device
the first time it binds to it. A read-only instance forgets everything at
shutdown, but it starts from the AVD's saved state. So pick one AVD for the
pipeline, boot it normally once, let auto-mobile bind to it, close it, and set
`ADT_AVD` to its name. Every later read-only instance then starts with the
service already installed. Without `ADT_AVD` the script may pick a different
AVD from run to run, and each unprepared one pays the install again. Maestro
needs no setup of this kind.

## 7. Two drivers (PR 3)

**The seam.** The Tester's prompt keeps its rules about how to test. Everything
that names a driver's tools moves into an adapter file, `drivers/auto-mobile.md`
or `drivers/maestro.md`. Each adapter has the same six headings:

1. Requirements and registration
2. Binding to the leased device
3. Device state
4. Driving the app and looking at the screen
5. Flows: the format, the reset each flow starts with, and assertions (added in
   PR 4)
6. How the script runs flows (added in PR 4)

From PR 4, the Test Writer reads the same adapter.

**Choosing a driver.** A project declares `Test driver: maestro` or
`Test driver: auto-mobile` in its `AGENTS.md` or `CLAUDE.md`, which is already
where the pipeline reads project facts. With no declaration it is auto-mobile,
so existing projects do not change. Any other value STOPs the run at its
start, naming the two valid values. The orchestrator passes the
adapter's path as `DRIVER_DOC`. The Architect does not need to know the driver,
because its test cases do not depend on it.

**The two side by side.**

| | auto-mobile | Maestro |
|---|---|---|
| Registered as | MCP server `auto-mobile`, `@kaeawc/auto-mobile@0.0.84` | MCP server `maestro`, `maestro mcp`, CLI 2.11.0 or later |
| Bind to the device | `getAndroid(deviceId)` for an emulator, `setActiveDevice(deviceId)` for a phone, once | `device_id` on every call |
| Tap, type, swipe | `tapOn`, `sendKeys`, `swipeOn` | `run` with inline commands: `tapOn`, `inputText`, `swipe` |
| Look at the screen | `observe`, settled and full (below) | `inspect_screen` |
| Rotate | `rotate` | `setOrientation` |
| Dark mode | `displayConfig` with `theme` | `setDarkMode` |
| Font scale | `displayConfig` with `fontScale` | None: the case is `INCONCLUSIVE` |
| Offline | `setDeviceState`, confirmed with `getDeviceState` | `setAirplaneMode`; it cannot be read back |
| Permissions | `setAppPermissions` | `setPermissions` |
| Process death | `appLifecycle` | `killApp` |
| Force stop | `terminateApp` | `stopApp` |
| Clean app state | `launchApp` with `clearAppData` | `launchApp` with `clearState` |
| Deep link | `openLink` | `openLink` |
| A Compose test tag | `testTag` selector | `id:`, which needs `testTagsAsResourceId` |

The rule from PR 1 covers both drivers: a case that needs something its
driver cannot do is `INCONCLUSIVE` with the reason. Under Maestro that means
font-scale cases. It also covers offline cases if Maestro's Airplane mode
switch turns out not to work on an emulator; PR 3's tests check this.

**When looking at the screen by hand** under auto-mobile, the Tester uses one
`observe` that waits for the screen to stop changing and returns the whole
hierarchy: `waitFor: {for: "stable"}`, `project: "full"`, `screenshot: "none"`.
The default `observe` returns only tappable elements and does not wait. So it
would miss a plain label, and could read the screen before a save finished.

**Compose apps need test tags exposed as resource ids.** Maestro finds elements
by resource id, and from PR 4 auto-mobile's flow assertions do too. That takes
one line at the root composable (`testTagsAsResourceId = true`). In PR 3 the
Architect checks for it and adds the change to the plan if it is missing. Apps
built with Views already have resource ids and need nothing.

## 8. The Test Writer, and flows run by a script (PR 4)

**What a flow is.** A flow is one test case as a file that checks itself. It
holds the case's actions, and its assertions as steps that fail when the
expected element does not appear. Flows are written in the project's driver's
own format. Here is one case as an auto-mobile flow:

```yaml
# adt:driver: auto-mobile
# adt:case: 3 — Pay with a saved card
name: 03-pay-with-saved-card
steps:
  - tool: setDeviceState
    connectivity:
      airplaneMode: false
      wifiEnabled: true
  - tool: rotate
    orientation: portrait
  - tool: displayConfig
    theme: light
    fontScale: default
  - tool: launchApp
    appId: com.example.app.debug
    clearAppData: true
  - tool: tapOn
    selector:
      testTag: checkout_pay_button
  - tool: observe
    waitFor:
      elementId: order_confirmation_title
      timeout: 10000
```

and as a Maestro flow:

```yaml
# adt:driver: maestro
# adt:case: 3 — Pay with a saved card
appId: com.example.app.debug
---
- setAirplaneMode: disabled
- setOrientation: PORTRAIT
- setDarkMode: false
- launchApp:
    clearState: true
- tapOn:
    id: checkout_pay_button
- assertVisible:
    id: order_confirmation_title
```

**What the Test Writer does.** It runs once per feature, after the Coder, on
the feature's emulator, with the build installed. For each case in the plan:

1. It reads the case, the plan's UI Selectors table, and the screens' code that
   the plan's Section 3 names. So it knows the real texts, tags and navigation.
2. It writes the flow to `pipeline_artifacts/{slug}/flows/`.
3. It runs the flow once on the emulator. If a step before an assertion fails,
   because of a wrong selector, a missing scroll or a short wait, it looks at
   the screen and fixes that step. It does this at most three times.
4. If the flow fails at an assertion, it looks at the screen. If the expected
   element is there but the assertion missed it, for example because the wait
   was too short, it fixes how the assertion looks for it, never what it
   checks. If the expected element is not there, the app may be wrong. It keeps
   the assertion as written and records "fails at Expected" for the Tester.
5. It records each case in `flows/INDEX.md`: the flow file, or `none` with the
   reason, and what its run showed.

Five rules shape every flow:

- **Assertions come from the case's Expected, and only from it.** The Test
  Writer may add waits, scrolls and keyboard dismissals that the real app
  needs. It never weakens, removes or rewrites an assertion to match what the
  app does.
- **It starts from the same device.** A flow may change device settings, and a
  flow that fails stops before its last step. So every flow begins by putting
  back each setting that a flow in its driver can change: Airplane mode off,
  portrait orientation, light theme, and under auto-mobile Wi-Fi on and the
  default font scale. Only then does it launch the app with clean data.
- **It launches the installed app.** The app id is the application id of the
  debug build that was installed, including any `applicationIdSuffix`. The Test
  Writer reads it from the app module's Gradle file and confirms the app is
  installed on the emulator.
- **It holds no secrets.** A flow never contains a password, token or other
  credential. A case that needs one, such as a case that starts signed in, gets
  no flow, and the Tester drives it by hand.
- **Its Expected can be asserted.** A case whose Expected is a judgment, such as
  "the layout looks right in dark mode", also gets no flow. The Tester drives
  it.

The Test Writer touches nothing but `pipeline_artifacts/{slug}/flows/`. It never
edits the app, the plan or the project's tests.

**How the flows run.** A script runs them, not a model. `adt.sh run` runs every
flow in `pipeline_artifacts/{slug}/flows/` on the run's emulator through the
driver's command line:

| | auto-mobile | Maestro |
|---|---|---|
| Command | `auto-mobile --cli executePlan`, one call per flow, with the flow as `planContent` and the leased serial as `deviceId` | `maestro --device <serial> test`, one call for all flows, with a JUnit report |
| Pass or fail | The result's `success`, and `failedStep` on a failure | Each flow's entry in the report |

A failed flow is run once more. One that passes the second time is `FLAKY`,
which does not fail the run. The script writes one row per flow to
`pipeline_artifacts/{slug}/run-results.md`, with the result, the failing step,
the duration and the path of the log.

**What the Tester does with the results.**

1. A `PASS` row: the case passed.
2. A `FAIL` row: it drives the case by hand from the failing step, and decides
   which is wrong:
   - **The app.** The case fails as written. That is a finding, classified as
     today.
   - **The flow.** The case passes when driven by hand. The Tester records a
     flow defect naming the step, and the case counts as passed. It never edits
     the flow.
3. A `FLAKY` row: an observation.
4. A case with no flow: it drives the case by hand, as today.

Before a re-test, the Test Writer runs again only for the cases the Tester
recorded as flow defects. Every other flow is simply run again by the script.

**What it costs.** One more agent, run once per feature and again only for
flows the Tester found broken, plus one script call per test. In return a passing case costs no model call at all, and a re-test
costs one script call and a Tester that looks only at failures. This replaces
the record-and-replay paragraph in today's Tester prompt, which never ran.

## 9. The regression suite (PR 5)

**The idea.** The flows written for one feature are kept after that feature
passes, and later features replay them in the same script call that runs their
own flows.

**Tiers.** The Architect gives each case a tier with a one-clause reason, and an
id of the form `<area>/<name>`. The Test Writer names the flow after the id and
puts the tier in its header (`# adt:priority: p1`).

| Tier | Meaning |
|---|---|
| **P0** | The app is unusable if this fails: launch, sign-in, the core loop. Keep this tier small. |
| **P1** | The main path of one feature area. |
| **P2** | Edge cases: offline, process death, configuration change, error states. |
| **none** | Tested in this run, not kept. |

**What each feature replays.** P0 always runs. The plan's Regression Scope adds
the other tiers per area:

```
### Regression Scope
| Area     | Tiers | Why                                 |
|----------|-------|-------------------------------------|
| checkout | p1 p2 | this feature changes checkout       |
| cart     | p1    | shares CartRepository with checkout |
```

That is how one feature replays only P0, another P0 and P1, and another P0 and
P2. The Architect writes this table, and the plan reviewer checks it.

**How a flow gets into the suite.** After a final `READY TO MERGE`, the script
copies each of this run's flows that has a tier and whose last result was
`PASS` into `e2e/flows/<area>/<name>.yaml`. A `FLAKY` flow is not kept. The
copies are new, uncommitted files, exactly like the feature's code, and you
commit them together. There is no manifest: a flow's id and area come from its
path, and its header carries the rest. So two features that add flows in
parallel never edit the same file.

**Features that change existing behaviour.**

- **Update.** A case in the plan whose id matches a flow in `e2e/flows/`
  replaces that flow. The Architect finds these by searching `e2e/flows/` for
  the tags and screens the plan changes. The old flow is not replayed in that
  run. Its replacement is kept if it passed, and the old flow is removed
  otherwise. So a flow that pins old behaviour never survives the change that
  removed it.
- **Retire.** The plan's Flows Retired table lists flows whose behaviour the
  feature removes. They are not replayed, and they are deleted at the end.
- **Missed.** If the Architect misses one, the flow fails. The Tester checks
  it against the plan. If the failure is the plan's intended new behaviour, the
  Tester marks it `OUTDATED`, citing the plan's line. That does not block the
  run, and the flow is removed at the end. The summary names it, so you can ask
  a later feature to cover it again.
- **Broken.** A suite flow that fails twice while its case passes when driven
  by hand is a flow defect. It does not block the run either, and it is also
  removed at the end and named in the summary. Otherwise it would fail in every
  later run.

**How it stays fast.**

- A replayed flow is a script command, with no model call.
- Selection keeps the list short: all of P0, and other tiers only where the
  plan points.
- The replay shares the feature's script call and emulator, so it needs no
  second agent and no second boot.
- The summary reports the replay's duration, and warns when the P0 flows alone
  took more than three minutes. What to demote is your call.

**A regression that is not this feature's fault.** Any other regression flow
that fails twice, and fails when the Tester drives it by hand, is a blocking
finding. The Coder gets it like any other finding. A Coder that finds its
change cannot have caused the failure STOPs and reports it, instead of editing
unrelated code. The flow is then fixed or deleted by hand, and the
troubleshooting guide says so.

**No separate command.** The suite runs inside the three build commands. To run
it by hand, use the script: `device-acquire`, `install`, `select`, `run`, then
`device-release`.

## 10. What does not change

- What the Architect decides to test, the six risk categories, the selectors,
  and the unit tests it specifies for the Coder.
- How the Tester classifies findings as blocking or observation, and the
  verdict rule.
- The Tester writes no tests.
- The fix loop and its budgets.
- The Coder and the code reviewer, apart from one sentence each in PR 5.

---

# Part 2 — The pull requests

Paths are relative to the repository root. `plugins/agentic-dev-team/` is the
plugin root. `.claude/agents` and `.claude/commands` are symlinks into it.

## 11. At a glance

| PR | Bundles | Touches | Needs |
|---|---|---|---|
| **1** | auto-mobile's hidden tools switched on; the Tester uses them and loses its shell; the orchestrator installs the build | README, `HOW_IT_WORKS.md`, Tester prompt, persona file, pipeline doc, three commands | — |
| **2** | A script that leases and releases emulators; each run leases one for all its tests; the Tester binds to it | New script and its tests, `install.sh`, Tester prompt, pipeline doc, three commands, README, `HOW_IT_WORKS.md` | PR 1 |
| **3** | Driver adapters; Maestro as a second driver; the driver chosen per project | Two adapter files, Tester prompt, Architect, plan reviewer, `install.sh`, OpenCode stub, pipeline doc, three commands, README, `HOW_IT_WORKS.md` | PR 2 |
| **4** | The Test Writer; flows for both drivers; `adt.sh run`; the Tester reads results | New agent and its OpenCode stub, both adapters, Tester prompt, script and its tests, persona file, pipeline doc, three commands, README, `HOW_IT_WORKS.md` | PR 3 |
| **5** | Tiers and ids in the plan; selection; passing flows kept in `e2e/flows/` | Architect, plan reviewer, Test Writer, Tester, Coder, code reviewer, script and its tests, pipeline doc, three commands, README, `HOW_IT_WORKS.md` | PR 4 |

You can stop after any PR. The undo note in each PR assumes the later PRs are
not merged; revert later ones first.

**Before PR 1, keep a baseline.** Run one feature that has a rotate case, a
permission case and an offline case through the current pipeline, and keep the
transcript. From its timestamps, note how long the Tester phase took, and count
its `adb` commands. PR 1 and PR 4 are judged against it.

Bump the version in `.claude-plugin/marketplace.json` with whichever PR you
release.

## 12. PR 1 — auto-mobile's own tools, and no shell

**What it does.** Switches on the auto-mobile tools the Tester has been
replacing with `adb`, tells the Tester to use them, and removes the Tester's
shell. The orchestrator runs the install command instead, on whatever device is
attached, exactly as the Tester did, and tells the Tester it has done so.

| File | Change |
|---|---|
| `README.md` | In Requirements, the auto-mobile entry gives a registration that runs `@kaeawc/auto-mobile@0.0.84`, the version these tool names were read from, and sets `AUTOMOBILE_ENABLED_TOOLS=rotate,displayConfig,setAppPermissions,setDeviceState,getDeviceState,openLink`. It says three more things. For a remote registration, as OpenCode uses, the variable goes in the environment of the process that starts the auto-mobile server, not in the client's config. After changing either value, restart the auto-mobile daemon once while no run is active (`bunx @kaeawc/auto-mobile@0.0.84 --daemon restart`). And re-run this PR's tests after moving the pin, because tool names can change between releases. |
| `agents/adt-android-tester.md` | The `tools` line becomes `Read, Write, mcp__auto-mobile__*`, and the description says the caller installs the build. A new "Device-state tools" section holds the table and the offline confirmation rule from section 5, and the rule that a case needing something not in the table is `INCONCLUSIVE`, with the reason. New input `BUILD_INSTALLED: <timestamp>`. Operating Principle 4 and Process steps 1 and 2 no longer read or run the install command. The stop condition "the install command fails" becomes "the prompt has no `BUILD_INSTALLED` line: STOP and say the build was not installed and that you cannot install it". In `test-results.md`, `Date` is the `BUILD_INSTALLED` timestamp, and `App version / build` reads "installed by the orchestrator at" that timestamp, because the Tester has no clock and no Gradle output of its own. |
| `commands/build-auto.md`, `build-auto-reviewed.md`, `build-guided.md` | Before the Tester is delegated to, the first time and before every re-test: run the install command from the plan's Section 0. If it fails, STOP and report the build error. Otherwise take a UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) and pass `BUILD_INSTALLED: <timestamp>` to the Tester. Note the time before delegating and after the Tester returns, and report "Tester phase: N seconds" in the final summary. |
| `AGENTIC_DEV_TEAM_PIPELINE.md` | Part A: the install command is run by the orchestrator, and the Tester requires `BUILD_INSTALLED`. Part B: the Tester Phase and Tester Fix Loop bullets of "Orchestration Workflow (Antigravity)" gain the install step and the `BUILD_INSTALLED` line. The Tester's mapping is unchanged. The enforcement paragraph from section 5 is added, and one new paragraph says how to run the Tester outside a build command: install the build, then pass `BUILD_INSTALLED`. |
| `.agents/AGENTIC_DEV_TEAM.md` | The Tester persona says who installs the build. |
| `HOW_IT_WORKS.md` | The install-command row says who runs it now. One troubleshooting entry: the Tester reports a missing device-state tool, so check the variable, the pin and the daemon restart. |

**How to test**

1. Register auto-mobile as the README now says, restart its daemon, and start a
   new session. The auto-mobile tools are present at all, which shows the
   server started with that list.
2. In the main session, list the auto-mobile tools. `rotate`, `displayConfig`,
   `setAppPermissions`, `setDeviceState`, `getDeviceState` and `openLink` are
   there. If they are not, the server did not pick up the variable. Fix that
   before going on, because the next step would tell you nothing.
3. Ask the Tester subagent to list its tools. The same six are there, and
   `Bash` is not.
4. If you use OpenCode or Antigravity, repeat steps 2 and 3 there.
5. Run the baseline feature again. The orchestrator installs, then the Tester
   starts testing without installing. The rotate and permission cases use the
   tools from the table, the transcript has no `adb` command at all, and the
   final summary shows the Tester phase's duration.
6. The baseline's offline case runs with Airplane mode confirmed on, and the
   app's offline behaviour is observed.
7. Break the build on purpose. The orchestrator STOPs before spawning the
   Tester.
8. Force a `NEEDS FIXES`. After the Coder's fix, the orchestrator installs
   again before the re-test.
9. Ask the Tester directly to "test the build", with no `BUILD_INSTALLED`. It
   STOPs and says why.

**Do not merge** if step 3 fails in a tool you use, or if step 6 comes back
`INCONCLUSIVE` on your emulator. In both cases the Tester would lose something
it can do today through `adb`.

**To undo:** revert the PR. The registration change is harmless on its own.

## 13. PR 2 — One emulator per feature run

**What it does.** Adds `adt.sh`, which leases and releases emulators. Each
build command leases one at its first test, installs only on it, tells the
Tester which device is its own, keeps it for every re-test, and releases it
when the command ends.

| File | Change |
|---|---|
| `plugins/agentic-dev-team/scripts/adt.sh` | New. Specified below. |
| `.claude/adt/scripts` | New symlink to that directory, so `install.sh` can link the script into a project. |
| `install.sh` | One glob added to `build_desired_pairs`: `"$REPO_DIR"/.claude/adt/scripts/*.sh`. |
| `tests/adt.test.sh`, `tests/shims/` | New. Tests that run the script against fake `adb` and `emulator` commands. The tests start the script as `/bin/bash <script>`, so on macOS it runs under bash 3.2 whatever `bash` is first on `PATH`. |
| `commands/build-auto.md`, `build-auto-reviewed.md`, `build-guided.md` | Resolve the script path beside `PIPELINE_DOC`: `.claude/adt/scripts/adt.sh` if it exists, otherwise `${CLAUDE_PLUGIN_ROOT}/scripts/adt.sh`, always run as `bash <path>`. The install instruction from PR 1 becomes the steps below. A new block, separate from "Close the run": once a device is leased, every exit from the command releases it first, whether that is the final summary, a STOP of the command's own, or the user's `stop` in `/build-guided`. The final summary names the device. |
| `agents/adt-android-tester.md` | New input `DEVICE`. The description says the caller leases the device. The first call binds to it: `getAndroid(deviceId: DEVICE)` when `DEVICE` is an emulator serial (`emulator-<port>`), `setActiveDevice(deviceId: DEVICE)` for any other device. New operating principle: use only `DEVICE`; never start, stop or switch devices; if a call is refused because the device session is gone, bind to the same serial again. The stop condition "no device or emulator is available" becomes "`DEVICE` is missing, or auto-mobile does not list it". The Device line in `test-results.md` records the serial and the AVD. |
| `AGENTIC_DEV_TEAM_PIPELINE.md` | Part A: a new Devices section. One leased device per run; every agent that drives it binds to it and to nothing else; it is kept for re-tests and released when the command ends. The install command runs through the script with `ANDROID_SERIAL` set. Part B: the Tester Phase and Tester Fix Loop bullets of "Orchestration Workflow (Antigravity)" follow the steps below, and the paragraph on running the Tester outside a build command gains acquire, `DEVICE` and release. |
| `README.md`, `HOW_IT_WORKS.md` | Requirements gain the Android SDK emulator and platform tools, the one-time AVD setup with `ADT_AVD` from section 6, and the four environment variables. Troubleshooting gains "no usable AVD" and "an emulator was left running" (`adt.sh device-list`, then `adt.sh device-release --serial <serial>`). |

The test phase in each command then reads:

| Step | Action | On failure |
|---|---|---|
| **1** | First test of the run only: `adt.sh device-acquire --slug S`. Before every test: `adt.sh install --slug S -- <install command from Section 0>` | Release, then STOP |
| **2** | Delegate to the Tester with `PLAN_PATH`, `PIPELINE_DOC`, `DEVICE: <serial>` and `BUILD_INSTALLED: <timestamp>` | — |
| **3** | Handle the verdict as today. On `NEEDS FIXES`, the existing fix loop returns to step 1, which installs again on the same device. | Budget exhausted: release, then STOP |
| **On exit** | `adt.sh device-release --slug S`, before the final summary or any STOP | Report the serial it names, and continue |

The release is deliberately not part of "Close the run". All three commands
skip that block when the run produced no design doc, which is the default for
`/build-auto` and `/build-auto-reviewed`.

### The script

It must run under bash 3.2, the macOS system shell: no associative arrays, no
`mapfile`, no `${var,,}`.

```
adt.sh device-acquire --slug <slug>
adt.sh install        --slug <slug> -- <install command…>
adt.sh device-release --slug <slug> | --serial <serial>
adt.sh device-list
```

Exit codes: 0 success, 2 usage, 10 no device, 11 the emulator did not start or
boot, 12 install failed, 13 a device could not be stopped.

Environment: `ADT_AVD` (which AVD to boot), `ADT_DEVICE_MODE=reuse` (use an
attached device and boot nothing), `ADT_HEADLESS=0` (show the emulator window),
`ADT_BOOT_TIMEOUT_S` (default 240).

**Leases**

- A lease is a directory, `~/.adt/leases/<serial>/`. Creating it with `mkdir`
  is the claim, and `mkdir` is atomic.
- Its contents are written immediately after the claim, before any emulator is
  started: the project directory, the slug, the creation time, and whether the
  script started the device. The emulator's pid is added when it is known, as a
  hint only.
- A lease belongs to a project directory and a slug together. The project
  directory is `git rev-parse --show-toplevel`, or the current directory
  outside a repository. Two worktrees have different project directories.
- A lease is **live** when its serial is in `adb devices`, or, for an emulator,
  when its console port accepts a connection. A port is tested with bash's
  `/dev/tcp`, which needs no extra tool.
- A lease is **stale** when it is not live and was created more than
  `ADT_BOOT_TIMEOUT_S` ago. Only stale leases are removed automatically. So a
  claim whose emulator is still booting is never taken by another run, and an
  emulator a run still holds is never taken either, however old its lease is.

**`device-acquire`**

1. Remove stale leases.
2. If a live lease for this project and slug exists, print its serial and exit
   0. This makes the command safe to repeat, and lets a re-run of the same
   feature pick up the emulator a dead session left.
3. Find the SDK: `ANDROID_HOME`, then `ANDROID_SDK_ROOT`, then the directory
   that contains the `platform-tools` directory of the `adb` on `PATH`, then
   the platform default. A candidate counts only if it contains
   `emulator/emulator`. `emulator` is often not on `PATH`; on this machine only
   `adb` is.
4. Unless `ADT_DEVICE_MODE=reuse`:
   1. Choose the AVD: `ADT_AVD`, else the first AVD from `emulator -list-avds`
      that is not open in normal mode. An AVD is open in normal mode when a
      running emulator without a lease reports it through
      `adb -s <serial> emu avd name`. Ignore any line of that output that is
      not an AVD name; some emulator versions print log lines there.
   2. Claim a port: walk the even ports 5554 to 5584. Skip a port if
      `emulator-<port>` is in `adb devices`, or if that port or the one above
      it accepts a connection. Claim with `mkdir`, then write the lease.
   3. Start
      `emulator -avd <avd> -read-only -no-window -no-audio -no-boot-anim -port <port>`
      detached from the calling shell, logging into the lease directory. Detach
      with `setsid` where it exists, otherwise
      `perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV'`, otherwise `nohup`.
   4. Wait for `getprop sys.boot_completed` to return `1`, up to the timeout.
   5. If the emulator exits or the timeout passes, stop it and remove the
      lease. Then:
      - if its log says "Another emulator instance is running" and the AVD was
        chosen automatically, go back to step 4.1 with the next AVD;
      - otherwise try once more from step 4.2 on the next free ports, and if
        that also fails, exit 11 with the path of the log.
   6. Set the three animation scales to 0. The instance is disposable, so
      nothing is restored.
5. An attached device is used only if `ADT_DEVICE_MODE=reuse`, or if step 4.1
   found no usable AVD because none exists or every one is open in normal mode.
   Take the first online device that has no lease, claim it the same way, do
   not change its settings, and print which device was taken and why. With no
   such device, exit 10.
6. Print the serial on the last line of output.

**`install`** requires a live lease for this project and slug, runs the given
command with `ANDROID_SERIAL` set to its serial, and exits 12 if the command
fails.

**`device-release`** with `--slug` acts on this project's lease for that slug,
and exits 0 if there is none, so it is safe on any exit path. With `--serial`
it acts on that lease whichever project owns it. It stops the device only if
the script started it: `adb emu kill`, then up to ten seconds for the serial to
leave `adb devices`, then the recorded pid. If the device is still there, it
leaves the lease in place and exits 13 naming the serial, so a device that
would not stop is not forgotten. Otherwise it removes the lease.

**`device-list`** prints one line per lease: serial, project directory, slug,
age, and whether it is live. It is how you find an emulator that a crashed
session left behind.

**How to test**

The script on its own:

1. `/bin/bash tests/adt.test.sh` passes on macOS.
2. `device-acquire --slug a` prints a serial, and `adb devices` lists it after
   the command has returned.
3. Start `device-acquire --slug a` and `device-acquire --slug b` together. They
   print different serials, and both emulators boot.
4. Run `device-acquire --slug a` in two different directories. They print
   different serials. Run it again in the first directory: it prints the same
   serial as before and boots nothing.
5. With two devices attached, `install --slug a -- ./gradlew installDebug`
   installs only on a's serial: `adb -s <other> shell pm path <app id>` prints
   nothing.
6. With the chosen AVD open in normal mode, the script uses another AVD and
   says which. With every AVD open in normal mode, it takes an attached device
   and says why.
7. Occupy port 5557 with another program and acquire. The script does not
   claim 5556.
8. `device-release --slug a` stops that emulator and leaves any other running.
   Run it again: it exits 0. `device-list` no longer shows it.

In the pipeline:

9. With no emulator open, run `/build-auto` with its defaults. An emulator is
   booted and used, and it is gone from `adb devices` before the final summary.
10. With your usual emulator open, run a feature. The run uses a different
    emulator, and yours is untouched.
11. Run two features at once in two worktrees, using the same slug. Each
    reports a different device, and neither install lands on the other's.
12. Break the build on purpose. The install fails, the run STOPs, and no
    emulator is left.
13. Force a `NEEDS FIXES`. The re-test uses the same serial; the transcript has
    one `device-acquire` and one boot.
14. In `/build-guided`, at the gate after testing, the emulator is still
    running. `revise:` re-tests on it. `approve` releases it, and so does
    `stop`.
15. Stop a session in the middle of testing, then run the same command for the
    same feature in the same checkout. It reuses the emulator the dead session
    left.
16. Do the one-time AVD setup and set `ADT_AVD`, then time the Tester's first
    `getAndroid` on a fresh instance. It should not be reinstalling the helper
    service.
17. With `ADT_DEVICE_MODE=reuse` and a USB phone as the only device, run a
    feature. The Tester binds to the phone and tests the build installed there.

**To undo:** revert the PR. PR 1's plain install instruction comes back.

## 14. PR 3 — Maestro as a second driver

**What it does.** Moves everything that names auto-mobile's tools out of the
Tester's prompt into an adapter, adds a Maestro adapter beside it, and lets a
project choose. Projects that declare nothing stay on auto-mobile and behave
exactly as after PR 2.

| File | Change |
|---|---|
| `plugins/agentic-dev-team/drivers/auto-mobile.md` | New, with headings 1 to 4 from section 7. It carries, unchanged, what the Tester's prompt says about auto-mobile after PR 2: the registration, binding, the device-state table and offline rule, and the settled, full `observe`. It adds: pass `screenshot: "none"` to `observe` unless the image itself is needed. |
| `plugins/agentic-dev-team/drivers/maestro.md` | New, with the same headings. Requirements: the Maestro CLI at 2.11.0 or later, which needs Java 17, registered as an MCP server named `maestro` (`claude mcp add maestro -- maestro mcp`). Binding: every call passes `device_id: DEVICE`; there is no bind call. Device state: the Maestro column of the table in section 7, run as inline commands through `run`, and `INCONCLUSIVE` for font scale. Driving: `run` with inline YAML, one short command list per step. Looking: `inspect_screen`. Selectors: `id:` matches a resource id, so a Compose app needs `testTagsAsResourceId`. |
| `agents/adt-android-tester.md` | The `tools` line becomes `Read, Write, mcp__auto-mobile__*, mcp__maestro__*`; a pattern for a server that is not registered grants nothing. New input `DRIVER_DOC`: read that adapter before the first device call and follow it; STOP if it is missing or unreadable. The device-state section and every auto-mobile tool name move to the adapter. The binding principle from PR 2 becomes "bind as the adapter says", and the stop condition becomes "`DEVICE` is missing, or the driver does not list it". The description says it drives the app through the project's test driver. |
| `agents/adt-android-architect.md` | Operating Principle 8: when the app's selectors are Compose test tags, Grep for `testTagsAsResourceId`, and add the one-line change to Section 2 if it is absent. Apps built with Views need nothing. |
| `agents/adt-android-architect-reviewer.md` | Item 6 gains one blocker: a Compose app with no `testTagsAsResourceId` and no change adding it. |
| `commands/build-auto.md`, `build-auto-reviewed.md`, `build-guided.md` | At the start of the command, before any agent runs: read the `Test driver:` line from the project's `AGENTS.md` or `CLAUDE.md`; with none it is `auto-mobile`; any value other than `auto-mobile` or `maestro` is a STOP naming the two. Resolve the adapter the way the script is resolved: `.claude/adt/drivers/<driver>.md`, else `${CLAUDE_PLUGIN_ROOT}/drivers/<driver>.md`. Pass it to the Tester as `DRIVER_DOC`. The final summary names the driver. |
| `.claude/adt/drivers`, `install.sh` | A symlink to the new directory, and one more glob in `build_desired_pairs`: `"$REPO_DIR"/.claude/adt/drivers/*.md`. |
| `.opencode/agents/adt-android-tester.md` | "via the `auto-mobile` MCP server" becomes "via the project's test driver's MCP server". |
| `AGENTIC_DEV_TEAM_PIPELINE.md` | Part A: the test driver is resolved as above, and "Manual verification" names the project's test driver instead of auto-mobile. Part B: the Tester Phase bullet passes `DRIVER_DOC`. The Antigravity mapping is unchanged; `enable_mcp_tools = true` already covers both servers. |
| `README.md`, `HOW_IT_WORKS.md` | Requirements offer two drivers, how to choose one, and the Maestro registration. Troubleshooting gains "the driver's MCP server is not registered". |

**How to test**

auto-mobile projects are unchanged:

1. Run the same auto-mobile feature before and after. The cases, the tools
   called and the results are the same.
2. `grep -c 'getAndroid\|setDeviceState\|getDeviceState\|displayConfig' plugins/agentic-dev-team/agents/adt-android-tester.md`
   prints 0.
3. With no `Test driver:` line, the final summary says auto-mobile.

Maestro:

4. Register Maestro. In a project that declares `Test driver: maestro`, run a
   feature. The Tester's device calls are all Maestro tools, and each carries
   the leased serial as `device_id`.
5. The plan added `testTagsAsResourceId`, and a Compose test tag is found by
   `id:`.
6. The rotate, dark-mode and permission cases use Maestro's commands. A
   font-scale case is `INCONCLUSIVE`, with the reason.
7. An offline case takes the app offline. If it does not on your emulator,
   change the Maestro adapter to make offline cases `INCONCLUSIVE`, and merge.
8. Run two Maestro features at once in two worktrees. Each one's calls go only
   to its own emulator.
9. Declare `Test driver: espresso`. The run STOPs before any agent runs, and
   names the two valid values.

The plan:

10. Plan a feature for a Compose app without `testTagsAsResourceId`: Section 2
    adds it. Plan one for an app built with Views: nothing is added and the
    reviewer raises nothing.

**To undo:** revert the PR, and remove the declaration from any project that
added it.

## 15. PR 4 — The Test Writer, and flows run by a script

**What it does.** Adds the Test Writer, which turns each test case into a flow
after the Coder, on the run's emulator. Adds `adt.sh run`, which runs the flows
with no model. The Tester reads the results and investigates only the failures
and the cases with no flow. The Architect does not change.

| File | Change |
|---|---|
| `agents/adt-android-test-writer.md` | New. Specified below. |
| `.opencode/agents/adt-android-test-writer.md` | New stub in the same form as the others: read `.claude/agents/adt-android-test-writer.md` and follow it, end with `✅ TEST WRITER DONE`. |
| `drivers/auto-mobile.md`, `drivers/maestro.md` | Headings 5 and 6. The flow format of section 8 with the header lines, the reset steps, and the assertion form: `observe` with `waitFor` (`elementId` or `text`) under auto-mobile, which fails when it times out; `assertVisible`, `assertNotVisible` and `extendedWaitUntil` under Maestro. How to run one flow from the agent: `executePlan` with the file's content as `planContent` and `platform: "android"`, or `run` with the file in `files`. How the script runs them, as in section 8. The auto-mobile adapter notes that a plan step's `expectations` field is not evaluated in 0.0.84, so assertions must be `observe` steps. |
| `agents/adt-android-tester.md` | New input `RUN_RESULTS`, the path of `run-results.md`. Process step 3 becomes the four cases in section 8: a `PASS` row passes; a `FAIL` row is driven by hand from the failing step, and decided as app or flow; a `FLAKY` row is an observation; a case with no flow, per `flows/INDEX.md`, is driven by hand. `test-results.md` gains a "Flow defects" list, one line per case with the step, which the orchestrator passes to the Test Writer before a re-test. On a re-test the Tester drives by hand only the cases without a flow that failed before or that the fix plausibly affects. The record-and-replay paragraph is removed. Operating Principle 3, "you drive the app, you don't write tests", is unchanged, and gains: never edit a flow. |
| `plugins/agentic-dev-team/scripts/adt.sh` | New subcommand `run`, specified below. |
| `tests/adt.test.sh`, `tests/shims/` | A fake `bunx` that answers `--cli executePlan` with a JSON result, and a fake `maestro` that writes a JUnit report. Cases: all pass, a failure with its step, a flaky flow, no flows, the driver command missing, and no live lease. |
| `commands/build-auto.md`, `build-auto-reviewed.md`, `build-guided.md` | The test phase becomes the steps below. The fix loop's re-test instruction, "re-run the failed cases and the happy path", is replaced: the script re-runs every flow, and the Tester drives by hand only as the Tester row above says. The final summary replaces "Tester phase" with three times: Test Writer, flow run, and Tester. |
| `README.md` | `executePlan` is added to `AUTOMOBILE_ENABLED_TOOLS`. The agent table gains the Test Writer. |
| `HOW_IT_WORKS.md` | The agent table gains the Test Writer and its marker. The install file maps gain its two files. Troubleshooting gains "a flow fails but the case passes by hand": the Test Writer rewrites it at the next re-test, and it is not kept. |
| `AGENTIC_DEV_TEAM_PIPELINE.md` | Part A: the Artifact Layout gains `flows/`, `flows/INDEX.md`, `run-results.md` and `run-logs/`; the Test Writer's role, its rule that it edits nothing outside `flows/`, and its marker `✅ TEST WRITER DONE`; `sonnet` is listed as its model. Part B: the test phase below, and the Test Writer's Antigravity mapping: `enable_write_tools = true` (for writing flows; the no-shell rule is enforced by the prompt, as for the Tester), `enable_subagent_tools = false`, `enable_mcp_tools = true`. |
| `.agents/AGENTIC_DEV_TEAM.md` | A Test Writer persona. The Tester persona reads results and never edits a flow. |

The test phase then reads:

| Step | Action | On failure |
|---|---|---|
| **1** | First test only: `device-acquire`. Before every test: `install` | Release, then STOP |
| **2** | First test only: the Test Writer, with `PLAN_PATH`, `PIPELINE_DOC`, `DRIVER_DOC`, `DEVICE` and `BUILD_INSTALLED`. Before a re-test: only if the last `test-results.md` lists flow defects, with those cases as `CASES` | A STOP from it: release, then STOP |
| **3** | `adt.sh run --slug S --driver D` | Exit 1 means a flow failed, which the Tester handles. Any other non-zero exit: release, then STOP |
| **4** | The Tester, with `PLAN_PATH`, `PIPELINE_DOC`, `DRIVER_DOC`, `DEVICE`, `BUILD_INSTALLED` and `RUN_RESULTS` | — |
| **5** | Handle the verdict as today. On `NEEDS FIXES`, the fix loop returns to step 1. | Budget exhausted: release, then STOP |
| **On exit** | Release, as in PR 2 | |

### The Test Writer

- **Frontmatter.** `name: adt-android-test-writer`; `tools: Read, Glob, Grep, Write, mcp__auto-mobile__*, mcp__maestro__*`; `model: sonnet`. The description says when to use it: after the Coder, with the build installed on a leased device, and the plan present.
- **Mission.** Turn each test case in the plan into a flow that passes when the
  app does what the case expects, and fails when it does not.
- **Inputs.** `PLAN_PATH`, `PIPELINE_DOC`, `DRIVER_DOC`, `DEVICE`,
  `BUILD_INSTALLED`, and on a re-test `CASES` with the Tester's note on each.
- **Process.** Section 8's five steps. Flows go to
  `pipeline_artifacts/{slug}/flows/<NN>-<short-name>.yaml`, where `NN` is the
  case's number in the plan. Each flow is checked with at most three runs.
- **Rules.** Section 8's five rules. Bind to `DEVICE` as the adapter says, and
  never start, stop or switch devices. Write nothing outside
  `pipeline_artifacts/{slug}/flows/`.
- **Output.** `flows/INDEX.md`, with one row per case: the case, the flow file
  or `none — <reason>`, and the check: `passes`, `fails at Expected: <what the
  screen showed>`, or `not checked: <why>`.
- **Definition of Done.** Every case in Section 4 has a row in `INDEX.md`. The
  final line is `✅ TEST WRITER DONE — <n> flows, <m> cases without a flow`.
- **Stop conditions.** `PLAN_PATH`, `DEVICE`, `BUILD_INSTALLED` or `DRIVER_DOC`
  is missing; the app is not installed on `DEVICE`.

### `adt.sh run`

```
adt.sh run --slug <slug> --driver auto-mobile|maestro
```

1. Require a live lease for this project and slug, and take its serial.
2. Collect every `*.yaml` under `pipeline_artifacts/<slug>/flows/`.
3. Run them on the serial:
   - **auto-mobile:** one call per flow,
     `$ADT_AUTOMOBILE --cli executePlan --platform android --deviceId <serial> --planContent "<the file's content>"`.
     `ADT_AUTOMOBILE` defaults to `bunx @kaeawc/auto-mobile@0.0.84`, and the
     call's environment carries the README's `AUTOMOBILE_ENABLED_TOOLS`. The
     output goes to `run-logs/<flow>.log`. The script reads `success` and
     `failedStep` from the JSON result with `bun -e`; `bun` is already present
     wherever `bunx` is.
   - **Maestro:** one call for all flows,
     `maestro --device <serial> test --format junit --output <dir>/junit.xml --test-output-dir <dir>/artifacts <files…>`,
     where `<dir>` is `run-logs/`. Each flow's result and failure message come
     from its entry in the report.
4. Run each failed flow once more, the same way. A pass on the second run is
   `FLAKY`.
5. Write `pipeline_artifacts/<slug>/run-results.md`, replacing the previous
   run's: one row per flow, with the flow, `PASS`, `FAIL` or `FLAKY`, the
   failing step and its error, the seconds, and the log path; then the totals.
   Durations are measured by the script for auto-mobile and taken from the
   report for Maestro.

Exit codes: 0 no flow failed, including when there are no flows; 1 a flow
failed; 2 usage; 14 the driver's command, or `bun` for auto-mobile, was not
found; 15 no live lease for this project and slug.

**How to test**

1. Plan a feature with `/plan-design`. The plan is the same as before this PR.
   The Architect writes no flows.
2. Run the baseline feature. After the Coder, the Test Writer writes one flow
   per case into `flows/`, and `INDEX.md` has one row per case. Each flow
   starts with the reset steps and launches the installed app id.
3. The flow run is one Bash call in the transcript, with no model call per
   step. `run-results.md` has one row per flow, with its duration.
4. With every flow passing, the Tester drives by hand only the cases without a
   flow, and the verdict is `READY TO MERGE`.
5. Break the feature on purpose. The flow fails, the Tester drives the case by
   hand from the failing step, and reports the finding.
6. Give one flow a wrong selector by hand while the feature is correct. The
   Tester reports a flow defect, and the verdict is unaffected. Force a
   `NEEDS FIXES` with another case: before the re-test the Test Writer runs
   only for the defective flow, and the re-test runs every flow again.
7. A case that starts signed in has no flow, `INDEX.md` says why, and the
   Tester drives it.
8. Make the app wrong before the Test Writer runs, so that a case's Expected
   element never appears. The flow keeps that assertion, `INDEX.md` says
   "fails at Expected", and the Tester reports the finding.
9. Repeat steps 2 to 6 in a Maestro project. The flow run is one
   `maestro test` call.
10. Run two features at once in two worktrees. Each one's flows run only on its
    own emulator.
11. Compare the final summary with the baseline. The re-test after a fix is
    faster than the baseline's.

**Do not merge** if step 3 fails under auto-mobile: that means its command line
cannot run a plan on a given device. The end of section 17 says what to do
then.

**To undo:** revert the PR.

## 16. PR 5 — A regression suite with P0, P1 and P2

**What it does.** The Architect gives each case an id and a tier, and the plan
says which tiers each area replays. Every test runs the selected suite flows in
the same script call as the feature's flows. Flows that pass are copied into
`e2e/flows/` after a green run.

| File | Change |
|---|---|
| `agents/adt-android-architect.md` | Each Section 4 case gets an id, `<area>/<name>`, in its heading, and a `**Priority**` line: `p0`, `p1`, `p2` or `none`, with a one-clause reason. Section 4 gains the Regression Scope table from section 9 and a Flows Retired table. Before writing them, the Architect searches `e2e/flows/` for the tags and screens the plan changes or removes; a flow whose behaviour changes is re-specified as a case with the same id, or listed as retired. The Definition of Done lists all of this. |
| `agents/adt-android-architect-reviewer.md` | Item 6 gains these blockers: a case with no id or no priority; a P0 with no reason, or one that is not on the app's critical path; a Regression Scope missing an area the plan modifies; an existing flow whose tags the plan removes that is neither re-specified nor retired. |
| `agents/adt-android-test-writer.md` | Flows are named after the case id, `flows/<area>/<name>.yaml`, and the header gains `# adt:priority: <tier>`. |
| `agents/adt-android-tester.md` | `RUN_RESULTS` now also has regression rows. A regression `FAIL` is driven by hand and classified as one of: a regression (blocking); `OUTDATED`, when the plan intentionally changed that behaviour, citing the plan's line (not blocking); or a flow defect (not blocking). `test-results.md` gains a "Suite flows to remove" list, one line per `OUTDATED` or defective suite flow, with the reason. Suite flow defects go only on that list, never on PR 4's "Flow defects" list, because the Test Writer only rewrites this plan's cases. When there are regression rows, the Tester skips its manual sanity check of an adjacent screen. |
| `agents/adt-android-coder.md` | Operating Principle 10 gains one sentence: if a regression finding is in an area your change cannot have caused, STOP and report it rather than editing unrelated code. |
| `agents/adt-android-code-reviewer.md` | Item 1 gains one sentence: files under `e2e/` are out of review scope. |
| `plugins/agentic-dev-team/scripts/adt.sh` | `select` and `promote`, below, and `run` gains `--list`. |
| `tests/adt.test.sh` | Cases for selection (P0 only; an area with tiers; an excluded flow; a flow for the other driver; an empty suite), for `run --list`, and for promotion (add, replace, remove an updated flow that did not pass, remove a retired flow, skip `none` and `FLAKY`). |
| `commands/build-auto.md`, `build-auto-reviewed.md`, `build-guided.md` | The test phase becomes the steps below. The final summary gives the replay counts (passed, failed, flaky), the replay's duration, a warning when the P0 rows' durations add up to more than three minutes, and the flows added, replaced and removed. |
| `AGENTIC_DEV_TEAM_PIPELINE.md` | Part A: a new "The regression suite" section with the tiers, the selection rule, that `e2e/flows/` is committed project content changed only by promotion after a final `READY TO MERGE`, and that only flows whose last result was `PASS` are kept. Review Currency gains the exemption that files under `e2e/` are test assets, not code changes. Part B: the test phase below. |
| `README.md`, `HOW_IT_WORKS.md` | A short "Regression suite" section: what a flow is, where flows live, how tiers are chosen, that cases needing credentials are not kept, that you commit flows with the feature, and how to run the suite by hand. Troubleshooting gains "a flow fails on every run": it is broken independently of the feature, so fix it or delete it. |

A case in Section 4 then reads:

````
### Case checkout/pay-with-saved-card — Happy path
**Priority**: p1 — the main path of checkout
**Setup**: Fresh install
**Steps**:
1. Launch app
2. Tap [testTag=checkout_pay_button]
**Expected**: [testTag=order_confirmation_title] is visible
````

and after the Risk Category Coverage table come the Regression Scope table
from section 9 and:

````
### Flows Retired
| Flow                  | Why                                    |
|-----------------------|----------------------------------------|
| checkout/legacy-promo | promo codes are removed by this change |

("None" is a valid answer. A case above whose id matches a flow in
e2e/flows/ replaces that flow.)
````

### The script

```
adt.sh select  --driver <name> [--area <area>:<tiers>]… [--exclude <id>]…
adt.sh run     --slug <slug> --driver <name> [--list <file>]
adt.sh promote --slug <slug> [--remove <id>]…
```

**`select`** prints one path per line from `e2e/flows/`, P0 first. A flow is
selected when its tier is `p0`, or when its area is given with its tier. The
area is the first directory under `e2e/flows/`, and the tier comes from the
`# adt:priority:` header. A flow named by `--exclude` is never selected. A flow
whose `# adt:driver:` header names the other driver is not selected, and is
printed to standard error as skipped. With no suite, it prints nothing and
exits 0.

**`run --list <file>`** also runs every path in the file, after this run's own
flows and in the same driver call. Their rows are marked `regression` and carry
the tier.

**`promote`** reads `run-results.md`. It copies each of this run's flows whose
row is `PASS` and whose tier is `p0`, `p1` or `p2` to `e2e/flows/<id>.yaml`,
creating directories and replacing any flow with the same id. Then it removes
each `--remove` flow that it did not just replace. It prints what it added,
replaced and removed.

The test phase then reads:

| Step | Action | On failure |
|---|---|---|
| **1** | First test only: acquire. Before every test: install | Release, then STOP |
| **2** | The Test Writer, as in PR 4 | A STOP from it: release, then STOP |
| **3** | `adt.sh select --driver D`, with one `--area` per Regression Scope row, and one `--exclude` per Flows Retired row and per case whose id is already in `e2e/flows/` | — |
| **4** | `adt.sh run --slug S --driver D --list <the selected paths>` | As in PR 4 |
| **5** | The Tester, as in PR 4 | — |
| **6** | Handle the verdict. On `NEEDS FIXES`, the fix loop returns to step 1. | Budget exhausted: release, then STOP |
| **7** | On a final `READY TO MERGE` (in `/build-guided`, on `approve`): `adt.sh promote --slug S` with one `--remove` per Flows Retired row, per case whose id was already in `e2e/flows/`, and per line of the Tester's "Suite flows to remove" | Report; the verdict stands |
| **On exit** | Release, as in PR 2 | |

**How to test**

The plan:

1. Run `/plan-design` on a feature. Every case has an id and a priority, and
   both tables are present.
2. Delete a case's priority by hand and run the plan reviewer. It requests the
   change.

Keeping flows:

3. After a green run, the flows with a tier whose last result was `PASS` are
   under `e2e/flows/` as uncommitted files.
4. A flow with tier `none`, a `FLAKY` flow, a flow the Tester found defective,
   and the flow of a case that failed are not kept.
5. A run that ends `NEEDS FIXES`, or stops, adds nothing to `e2e/`.
6. Re-plan a feature whose case changed, with the same id. The flow is
   replaced, and the summary says so. A plan that retires a flow, or an update
   whose new flow did not pass, leaves the old flow removed.
7. Two features in two worktrees each keep flows. Their branches merge with no
   conflict in `e2e/`.
8. In `/build-auto-reviewed`, with uncommitted flows from an earlier run in the
   tree, the code reviewer raises nothing about them.

Replaying:

9. With a suite in place, run any feature. Every P0 flow runs in the same
   `adt.sh run` call as the feature's flows.
10. List an area with `p1` in the plan's Regression Scope. Its P1 flows run and
    its P2 flows do not.
11. Put an offline flow that fails first in the list, followed by a P0 flow.
    The P0 flow still passes, because it starts by turning Airplane mode off.
12. Break an existing feature. Its flow fails, the run is `NEEDS FIXES`, and
    the Coder receives the finding.
13. Break a flow in an area the feature does not touch. The Coder STOPs and
    reports it, without editing unrelated code.
14. Change a behaviour that an existing flow asserts, without telling the plan.
    The Tester marks it `OUTDATED`, the verdict is unaffected, and the flow is
    removed at the end with the summary naming it.
15. Give a suite flow a wrong selector by hand. It fails twice, the Tester
    finds its case passes by hand, the verdict is unaffected, and the flow is
    removed at the end with the summary naming it.
16. With no suite, the replay is skipped, the Tester does its manual sanity
    check, and the summary says so.
17. Each regression row has a duration, and the summary's P0 warning appears
    when those durations add up to more than three minutes.
18. In a Maestro project, put one auto-mobile flow into `e2e/flows/`. It is not
    run, and the summary names it as skipped.

**To undo:** revert the PR. Flows already in `e2e/` are plain files; keep or
delete them.

## 17. Deferred

| Cut | What would bring it back |
|---|---|
| A slash command for the suite | Not wanted. The suite runs inside the build commands. |
| Booting the emulator while the Coder works, to hide the boot | The 21-second boot mattering |
| Skipping the Tester when every flow passes and every case has a flow | The Tester's quick pass on a green run mattering |
| Passing credentials to flows at run time, so signed-in cases can have flows | The suite missing too much of an app that requires sign-in |
| Shared start states (one sign-in flow used by many) | The above, plus sign-in steps duplicated across many flows |
| Picking regression flows from the files a feature changes | Plans often missing an area they affect |
| Rewriting outdated flows instead of removing them | Useful coverage being lost to `OUTDATED` |
| A healer that repairs a broken flow in a later run | Flow defects being common |
| Automatic demotion of slow flows | The three-minute P0 warning being ignored |
| A quarantine marker for flaky flows | Flaky flows starting to block runs |
| Splitting a replay across several emulators | One emulator becoming the bottleneck |
| Converting a suite from one driver to the other | A project wanting to switch drivers |
| ARTEMIS as an explorer | A wish for exploratory testing beyond the Tester's edge cases |
| Crash detection from logcat, and failure evidence bundles | Coders struggling to act on findings |
| CI for this repository, and a workflow that runs a project's suite on pull requests | The script growing past what its test file covers |

If PR 4's test step 3 shows that auto-mobile's command line cannot run a plan,
there are two ways forward. The Tester can run each auto-mobile flow with one
`executePlan` call, which is slower but needs no shell. Or auto-mobile's
Gradle runner, `auto-mobile-junit-runner`, can run them, which adds a test
dependency to the app.

---

# Part 3 — Verification

## 18. What was verified, and how

**Run on this machine** (macOS, Android emulator 37.2.12, system bash 3.2.57):

- Two headless `-read-only` instances of one AVD ran at the same time on ports
  5580 and 5582, with independent state, and both shut down with
  `adb emu kill`. Your running emulator was not touched.
- A `-read-only` instance of an AVD that was already running in normal mode was
  refused.
- A cold boot took about 21 seconds. One measurement, on this hardware.
- A process started with `nohup`, in a subshell, or under `perl` `setsid` was
  still alive in the next tool call in Claude Code.
- bash 3.2's `/dev/tcp` reports a port correctly: 5554 and 5555, held by the
  running emulator, as listening, and 5580 and 5581 as free.
- `git rev-parse --show-toplevel` returns a different directory in a worktree
  than in the main checkout.
- A prototype of the flow selection logic passed eight scenarios under bash
  3.2.

**Read from the auto-mobile 0.0.84 package, or from the tool schemas its
running server advertised. Not executed:**

- `AUTOMOBILE_ENABLED_TOOLS` and `--enable-tool` exist.
- `getAndroid` accepts `deviceId`, a booted emulator's serial or an AVD name.
  `setActiveDevice` accepts `deviceId`.
- `executePlan` takes `planContent`, `platform` and `deviceId`, and rejects any
  option it does not know; it has no `holdSessionOnFailure`. Its result has
  `success`, `failedStep` with the step's index, tool and error, and
  `debug.executionTimeMs`.
- A plan step is `tool` plus that tool's arguments. A step's `expectations` are
  not evaluated; the package's own warning says so.
- The package has a command-line mode, `--cli <tool>`; its own error text says
  "Use --cli <tool> instead of --cli=<tool>".
- Plan execution is locked per session by default (`planExecutionLockScope`
  defaults to `session`), so plans run by two different runs do not wait for
  each other.
- `observe` accepts `screenshot: "none"`, `project: "full"` and
  `waitFor: {for: "stable"}`. Its `waitFor` finds elements by resource id,
  text, content description or class name, not by test tag.
- `tapOn` accepts a `testTag` selector.
- `setDeviceState` accepts `connectivity` with `airplaneMode` and
  `wifiEnabled`; `getDeviceState` reads back airplane mode and Wi-Fi.
- `rotate` takes `orientation: portrait | landscape`; `displayConfig` takes
  `theme` and `fontScale`, where `fontScale` accepts `"default"`.

**Read only from auto-mobile's online docs, which describe its main branch:**

- Every tool can be called from the command line as
  `bunx @kaeawc/auto-mobile --cli <tool>`, with object arguments as JSON, for
  example `--selector '{"text":"Submit"}'`.
- An unknown name in `AUTOMOBILE_ENABLED_TOOLS` stops the server from starting.
- `executePlan` stops at the first failed step, and an `observe` step fails
  when its `waitFor` times out.
- The network-condition setting is best-effort on emulators.
- The daemon restart command.
- The Gradle runner, `auto-mobile-junit-runner`, runs plans as JVM tests.
- Session ownership and the two-minute idle release. The codes those docs name
  are not in 0.0.84, so the design does not rely on them.

**Read from Maestro's source at `cli-2.11.0` and its docs. Maestro is not
installed here, so nothing was run:**

- `maestro test` accepts several flow files and `--device`, writes a JUnit
  report with one `testcase` per flow carrying `file`, `time` and `status`, and
  exits 1 when a flow fails.
- Its MCP tool `run` requires `device_id` and takes exactly one of inline
  `yaml`, a list of `files`, or a `dir`. `inspect_screen` and `take_screenshot`
  also require `device_id`.
- The commands `setOrientation`, `setDarkMode`, `setAirplaneMode`,
  `setPermissions`, `killApp`, `assertVisible` and `assertNotVisible` exist.

**Read from other docs:** Claude Code (a subagent's `tools` list accepts
`mcp__<server>__*`; `disallowedTools` accepts exact tool names; plugin
subagents ignore `hooks`, `mcpServers` and `permissionMode`); the emulator's
own help (an instance needs its console port and the port above it); Android's
docs (`testTagsAsResourceId` exposes Compose test tags as resource ids).

**Not verified. Each one is a test step in the PR that depends on it:**

| Assumption | PR | Test step |
|---|---|---|
| `AUTOMOBILE_ENABLED_TOOLS` on the server makes the hidden tools available to a Claude Code *subagent*, not only the main session | 1 | Steps 2 and 3 |
| The same holds in OpenCode and Antigravity | 1 | Step 4 |
| Switching Airplane mode on through `setDeviceState` takes the emulator offline, and `getDeviceState` confirms it | 1 | Step 6 |
| A detached emulator survives the call that started it in Antigravity and OpenCode | 2 | Step 2, in each tool |
| `ANDROID_SERIAL` restricts the project's install task to one device | 2 | Step 5 |
| A read-only instance starts with auto-mobile's helper service present once the AVD has been bound normally | 2 | Step 16 |
| `setActiveDevice` binds the Tester to a physical device | 2 | Step 17 |
| Maestro's `run` with inline commands drives the app step by step on the given device, and `id:` matches a bare Compose tag | 3 | Steps 4 and 5 |
| Maestro's `setAirplaneMode` takes an emulator offline | 3 | Step 7 |
| `executePlan` runs a flow on the bound device, and a timed-out `waitFor` with `elementId` set to a bare Compose tag fails the flow | 4 | Steps 2 and 5 |
| `--cli executePlan` with `--planContent`, `--platform` and `--deviceId` runs a flow on that device and prints a result with `success`, with the enabled-tools variable set in its own environment | 4 | Step 3 |
| A command-line plan run is not refused on a device that the Test Writer's MCP session bound earlier | 4 | Step 3 |
| Maestro's JUnit report looks as its source says | 4 | Step 9 |
| Maestro's reset commands in section 8's example (`setAirplaneMode`, `setOrientation`, `setDarkMode`) are valid at 2.11.0 as written | 4 | Step 9 |
| The reset steps put the device back to its baseline after a flow that failed | 5 | Step 11 |

One side effect to know about: on 2026-10-09 I ran one auto-mobile CLI command
(`--cli executePlan --help`) and its output began with "Restarting daemon…".
The shared daemon was already mid-restart when that session started, so I
cannot tell whether my command caused one. If another session was driving a
device through auto-mobile at that moment, it may have lost its device session.

## 19. Sources

- [auto-mobile repository](https://github.com/kaeawc/auto-mobile): `docs/tools.md`,
  `docs/using/dynamic-tools.md`, `docs/using/device-ownership.md`,
  `docs/using/ui-tests.md`, `docs/faq.md`, and the published
  `@kaeawc/auto-mobile@0.0.84` package
- [Maestro repository](https://github.com/mobile-dev-inc/Maestro):
  `maestro-cli/src/main/java/maestro/cli/command/TestCommand.kt`,
  `maestro-cli/src/main/java/maestro/cli/report/JUnitTestSuiteReporter.kt`,
  `maestro-cli/src/main/java/maestro/cli/mcp/tools/`
- [Maestro MCP](https://docs.maestro.dev/getting-started/maestro-mcp) and
  [commands](https://docs.maestro.dev/api-reference/commands)
- [Compose testing interoperability](https://developer.android.com/develop/ui/compose/testing/interoperability)
- [Claude Code subagents](https://code.claude.com/docs/en/sub-agents)
- [Playwright Test Agents](https://playwright.dev/docs/test-agents)
- [Arbigent README](https://raw.githubusercontent.com/takahirom/arbigent/main/README.md)
- [BMAD Test Architect](https://github.com/bmad-code-org/bmad-method-test-architecture-enterprise)
