# Test driver: auto-mobile

The adapter for projects whose test driver is auto-mobile, which is the default
when a project declares none. Agents that drive the device read it from the
`DRIVER_DOC` path their caller passes. Their own prompts say *how to test*;
this file says *which auto-mobile tools do it*. Nothing here overrides an
agent's rules.

## 1. Requirements and registration

- The [auto-mobile](https://github.com/kaeawc/auto-mobile) MCP server,
  registered under the name `auto-mobile` at version `0.0.84`, with
  `AUTOMOBILE_ENABLED_TOOLS` set to
  `rotate,displayConfig,setAppPermissions,setDeviceState,getDeviceState,openLink,executePlan`.
  HOW_IT_WORKS, "Setting up device testing", gives the exact registration for each tool.
- Its tools appear as `mcp__auto-mobile__<name>`. auto-mobile hides most of its
  tools until they are enabled. The list is fixed by whichever process starts
  auto-mobile's background service — the MCP registration, or `adt.sh`, which
  passes the same list — and every client then sees it. If a tool named below
  is missing from your tool list, the service was started without it: any case
  that needs it is `INCONCLUSIVE`, with "auto-mobile tool `<name>` is not
  enabled" as the reason. Never work around a missing tool.

## 2. Binding to the leased device

Your first device call binds this session to `DEVICE`:

- an emulator serial (`emulator-<port>`): `getAndroid` with `deviceId: DEVICE`;
- any other device: `setActiveDevice` with `deviceId: DEVICE`.

Every later call then goes to that device without naming it. Never call
`getAndroid` without `deviceId`, and never with an AVD name — that boots or
picks a device, which is not yours to do. If a later call is refused because
the device session is gone, bind to the same serial again and carry on.

## 3. Device state

| Case needs | auto-mobile tool |
|---|---|
| Rotation | `rotate` with `orientation: portrait` or `landscape`, and `lockOrientation: true` (below) |
| Dark mode | `displayConfig` with `theme: dark` or `light` |
| Font scale | `displayConfig` with `fontScale` (a number, or `"default"`) |
| Grant, revoke or reset a permission | `setAppPermissions` |
| Offline | `setDeviceState` with `connectivity: {airplaneMode: true}`, confirmed with `getDeviceState` (below) |
| Background, then process death | `appLifecycle` with `action: background`, then `action: killBackgrounded` |
| Force stop | `terminateApp` |
| Clean app state | `launchApp` with `clearAppData: true` |
| Deep link | `openLink` |

**Offline is confirmed, not assumed.** After switching Airplane mode on, call
`getDeviceState` and judge an offline case only once Airplane mode reads as on.
If it does not, the case is `INCONCLUSIVE` — never `FAIL`, because the app was
never actually offline. Afterwards switch it off again with
`connectivity: {airplaneMode: false, wifiEnabled: true}` before the next case.
Use the Airplane mode switch rather than the network-condition setting, which
auto-mobile documents as best-effort on emulators.

**Rotation is locked.** Without `lockOrientation: true`, the emulator's
auto-rotate can turn the screen straight back, and the `rotate` step fails. The
reset steps' turn to portrait needs no lock, since an emulator stands in
portrait.

## 4. Driving the app and looking at the screen

| To | Use |
|---|---|
| Launch the app | `launchApp` with `appId` (add `clearAppData: true` for a clean start) |
| Tap | `tapOn` with `selector: {testTag: …}`, `{elementId: …}` or `{text: …}`; add `searchUntil: {duration: …}` (milliseconds, at most 12000) to wait for an element that appears after the previous step, such as a list row after a save |
| Type | `sendKeys` with `selector` naming the field and `commands: [{action: type, operation: replace, mode: a11y, text: "…"}]` (below) |
| Scroll, swipe | `swipeOn` with `direction`, and `lookFor` to scroll until an element appears |
| Press Back or Home | `pressButton` |
| Look at the screen | `observe`, as below |

`tapOn` and `sendKeys` accept a Compose test tag directly as
`selector: {testTag: …}`. `searchUntil` only waits: to reach an element further
down a list, scroll to it with `swipeOn` and `lookFor` first.

**Typing sets the whole text at once.** `operation: replace` with `mode: a11y`
puts the text into the field in one accessibility call, so the field ends up
holding exactly that text even when the app changes it as keys arrive — adding
`https://` to a URL, say, or formatting a phone number. `replace` alone is not
enough: its default mode types through auto-mobile's own keyboard, and the app
can see part of the text first. Type key by key (leave out `operation` and
`mode`) only when the case is about what the field does as you type.

**Looking at the screen.** Call `observe` with `screenshot: "none"` and
nothing else. It returns a compact list of what is on screen: every tappable
element with its `label` and `sublabel` (a row's title and summary text), and
non-tappable text such as status lines under `context`. To check whether one
particular text or element is there — including a plain label the compact list
leaves out — use `observe` with `waitFor` (below): it searches the whole screen
and waits for the screen to catch up. Do not use `project: "full"` or
`waitFor: {for: "stable"}` in 0.0.84: the first can fail with an output-schema
error or come back as a large file instead of a result, and the second times
out within about a second and a half on a screen that is still animating. Ask
for a screenshot (`screenshot: "settled"`) only when the image itself is the
evidence: a failure, or the final happy-path state.

**Waiting for something.** `observe` with `waitFor` fails when its `timeout`
passes: `waitFor: {elementId: …, timeout: 10000}` waits for an element to
appear, `waitFor: {text: …}` for a text, and `waitFor: {absent: {elementId: …}}`
for one to go away. `waitFor` matches resource ids, not test tags, so a
Compose test tag is found by `elementId` only when the app exposes test tags as
resource ids (`testTagsAsResourceId`).

## 5. Flows

A flow is one test case as an auto-mobile **plan**: a YAML file with a `name`
and a list of `steps`, each step being a tool name plus that tool's arguments.
The adt header lines go first, as YAML comments.

```yaml
# adt:driver: auto-mobile
# adt:priority: p1
# adt:case: 03 — Pay with a saved card
name: 03-pay-with-saved-card
steps:
  # Reset: put back every setting a flow may change.
  - tool: setDeviceState
    connectivity:
      airplaneMode: false
      wifiEnabled: true
  - tool: rotate
    orientation: portrait
  - tool: displayConfig
    theme: light
    fontScale: default
  # Launch the installed app with clean data.
  - tool: launchApp
    appId: com.example.app.debug
    clearAppData: true
  # The case's steps.
  - tool: tapOn
    selector:
      testTag: checkout_pay_button
  # The case's Expected.
  - tool: observe
    waitFor:
      elementId: order_confirmation_title
      timeout: 10000
```

**Reset steps.** Every flow starts with the three steps above, exactly: Airplane
mode off and Wi-Fi on, portrait, light theme at the default font scale. Then
the case's Setup, when it is device state — `setDeviceState` with
`airplaneMode: true` for an offline case, say — so the app starts in it. Then
`launchApp` with the installed app id and `clearAppData: true`. Clearing the
data also resets the app's runtime permissions, so a permission prompt the app
shows at start appears again. Then the plan's "First launch" Shared setup: its
onboarding screens, and a tap on the prompt's button with the selector the
plan names (for example `[text="Allow"]`) unless the case tests a denial.

**Test secrets.** A step that types a test secret uses its name,
`text: "${TEST_PASSWORD}"`, exactly as the plan writes it. The script fills in
the value when it runs the flow.

**Steps.** Use the tools from section 4, with the same arguments a direct call
would take. `tapOn` and `sendKeys` take `selector: {testTag: …}`.

**Assertions.** Write each Expected clause as an `observe` step with `waitFor`,
which fails the flow when its `timeout` (milliseconds) passes:
`waitFor: {elementId: …}` for an element that must appear, `{text: …}` for a
text, `{absent: {elementId: …}}` for one that must go away. A step's
`expectations` field is **not evaluated** in auto-mobile 0.0.84, so never use it
as an assertion. `waitFor` does not match test tags directly: a Compose tag is
found by `elementId` only when the app sets `testTagsAsResourceId`.

**Checking a flow.** Run it with one `executePlan` call: the file's content as
`planContent`, `platform: "android"`, and `deviceId: DEVICE` — without it,
auto-mobile refuses the call whenever more than one device is attached. The
result's `success` says whether it passed; on a failure, `failedStep` gives the
step's index, tool and error. `executePlan` ends your device session when it
finishes, so bind to `DEVICE` again before your next call.

## 6. How the script runs flows

`adt.sh run --driver auto-mobile` runs each flow with one call to auto-mobile's
command line, on the run's device, with no model involved:

```
bunx @kaeawc/auto-mobile@0.0.84 --cli executePlan --platform android \
  --deviceId <DEVICE> --planContent "<the flow file>"
```

It exits 0 when the flow passed. On a failure it prints the failed step and its
error, which the script copies into `run-results.md`. Before the call, the
script replaces each `${NAME}` of a test secret in the flow's content with its
value from `.agentic-dev-team/secrets.env`; afterwards it scrubs the values
from the flow's logs. The flow file keeps the names. Before the first flow it
binds auto-mobile to the device once (`getAndroid` with `deviceId`): a fresh
emulator on a serial auto-mobile has driven before lacks its helper app, and
auto-mobile installs it again only when it binds. The command line reaches
every auto-mobile tool, including the ones hidden from agents, so flows need no
extra setup. It talks to the same background service as the MCP server, so that
service must be on the pinned version (HOW_IT_WORKS, "Setting up device testing").
`ADT_AUTOMOBILE` overrides the command.
