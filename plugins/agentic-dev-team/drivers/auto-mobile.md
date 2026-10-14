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
  `rotate,displayConfig,setAppPermissions,setDeviceState,getDeviceState,openLink`.
  The README's Requirements give the exact registration command.
- Its tools appear as `mcp__auto-mobile__<name>`. auto-mobile hides most of its
  tools until they are enabled. If a tool named below is missing from your
  tool list, the server was started without it: any case that needs it is
  `INCONCLUSIVE`, with "auto-mobile tool `<name>` is not enabled" as the reason.
  Never work around a missing tool.

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
| Rotation | `rotate` with `orientation: portrait` or `landscape` |
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

## 4. Driving the app and looking at the screen

| To | Use |
|---|---|
| Launch the app | `launchApp` with `appId` (add `clearAppData: true` for a clean start) |
| Tap | `tapOn` with `selector: {testTag: …}`, `{elementId: …}` or `{text: …}` |
| Type | `sendKeys` with `selector` naming the field and `commands: [{action: type, text: "…"}]` |
| Scroll, swipe | `swipeOn` with `direction`, and `lookFor` to scroll until an element appears |
| Press Back or Home | `pressButton` |
| Look at the screen | `observe`, as below |

`tapOn` and `sendKeys` accept a Compose test tag directly as
`selector: {testTag: …}`.

**Looking at the screen.** When you need to read the screen, use one `observe`
that waits for it to stop changing and returns the whole hierarchy:
`waitFor: {for: "stable"}`, `project: "full"`, `screenshot: "none"`. The
default `observe` returns only tappable elements and does not wait, so it would
miss a plain label and could read the screen before a save finished. Ask for a
screenshot (`screenshot: "settled"`) only when the image itself is the evidence:
a failure, or the final happy-path state.

**Waiting for something.** `observe` with `waitFor` fails when its `timeout`
passes: `waitFor: {elementId: …, timeout: 10000}` waits for an element to
appear, `waitFor: {text: …}` for a text, and `waitFor: {absent: {elementId: …}}`
for one to go away. `waitFor` matches resource ids, not test tags, so a
Compose test tag is found by `elementId` only when the app exposes test tags as
resource ids (`testTagsAsResourceId`).
