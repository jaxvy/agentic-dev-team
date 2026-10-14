# Test driver: Maestro

The adapter for projects that declare `Test driver: maestro` in their
`AGENTS.md` or `CLAUDE.md`. Agents that drive the device read it from the
`DRIVER_DOC` path their caller passes. Their own prompts say *how to test*;
this file says *which Maestro tools and commands do it*. Nothing here
overrides an agent's rules.

## 1. Requirements and registration

- The [Maestro](https://maestro.dev) CLI, version 2.11.0 or later, which needs
  Java 17 or later. Its MCP server ships inside the CLI.
- Registered as an MCP server named `maestro`. In Claude Code:
  `claude mcp add maestro -- maestro mcp`.
- Its tools appear as `mcp__maestro__<name>`. You use three of them:
  `run`, `inspect_screen` and `take_screenshot`. If they are missing from your
  tool list, the server is not registered: STOP and say so.

## 2. Binding to the leased device

There is no bind call. Pass `device_id: DEVICE` on **every** Maestro call, and
never call one without it — Maestro would otherwise pick a device itself, and
another run may be testing on it.

## 3. Device state

Maestro changes device state through flow commands. Send them with `run` as
inline YAML (`yaml:`), one short list at a time.

| Case needs | Maestro command |
|---|---|
| Rotation | `- setOrientation: PORTRAIT` or `LANDSCAPE_LEFT` |
| Dark mode | `- setDarkMode: enabled` or `disabled` |
| Font scale | No Maestro command: the case is `INCONCLUSIVE`, "Maestro cannot change font scale" |
| Grant or revoke a permission | `- setPermissions: {permissions: {<name>: allow \| deny}}` |
| Offline | `- setAirplaneMode: enabled` (below) |
| Background, then process death | `- pressKey: Home`, then `- killApp` (a system-initiated process death) |
| Force stop | `- stopApp` |
| Clean app state | `- launchApp: {clearState: true}` |
| Deep link | `- openLink: <url>` |

Every inline flow must start with the app's id, so Maestro knows which app the
commands act on:

```yaml
appId: com.example.app.debug
---
- setOrientation: LANDSCAPE_LEFT
```

**Offline.** Maestro cannot read Airplane mode back, so look at the app after
`setAirplaneMode: enabled` instead: if it still behaves as if it were online —
it loads fresh data, or shows no offline state anywhere — the switch did not
take, and the case is `INCONCLUSIVE`, not `FAIL`. Afterwards send
`- setAirplaneMode: disabled` before the next case.

## 4. Driving the app and looking at the screen

| To | Inline commands for `run` |
|---|---|
| Launch the app | `- launchApp` (add `clearState: true` for a clean start) |
| Tap | `- tapOn: {id: <test tag or resource id>}` or `- tapOn: <visible text>` |
| Type | `- tapOn: {id: <field>}` then `- inputText: "…"` |
| Scroll | `- scrollUntilVisible: {element: {id: …}}`, or `- swipe: {direction: UP}` |
| Press Back or Home | `- back`, `- pressKey: Home` |

Send each step, or a short run of steps, as its own `run` call, so a failure
points at one step.

**Looking at the screen.** `inspect_screen` returns the current view hierarchy.
Use it when a step gives no selector, when you must confirm an element is
absent, and after a failure. `take_screenshot` only when the image itself is
the evidence: a failure, or the final happy-path state.

**Waiting for something.** `- assertVisible: {id: …}` waits up to 7 seconds and
fails otherwise; for longer waits use
`- extendedWaitUntil: {visible: {id: …}, timeout: 15000}`. `assertNotVisible`
and `extendedWaitUntil: {notVisible: …}` check that something went away.

**Selectors.** `id:` matches a resource id. A Compose app's test tags are
resource ids only when the app sets `testTagsAsResourceId = true` at its root
composable; without it, a step that names a test tag cannot find it, and the
case is `INCONCLUSIVE` with that reason. Apps built with Views already have
resource ids.
