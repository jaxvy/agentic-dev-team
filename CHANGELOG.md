# Changelog

Every release has a tag, `v<version>`. The version is in
`plugins/agentic-dev-team/.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json`, and `tests/release.test.sh` checks that
both agree with the newest entry below. [RELEASING.md](RELEASING.md) has the
steps.

## 0.6.0

Production hardening.

- **Docs split.** The pipeline rules are three files: Part A for agents
  (`AGENTIC_DEV_TEAM_PIPELINE.md`), Part B for the orchestrator
  (`AGENTIC_DEV_TEAM_ORCHESTRATION.md`), and the config rules
  (`AGENTIC_DEV_TEAM_CONFIG.md`, read only when the config file has an active
  setting). Agents load a third of what they did. Re-run `install.sh` once.
- **Run ledger and resume.** `adt.sh state` records the phase, paths and
  budgets; the script refuses a re-run past its budget, and
  `/<build command> resume <slug>` continues a run whose session died.
- **Promote guard.** `adt.sh promote` keeps flows only when the Tester's
  verdict is `READY TO MERGE`.
- **No silent fallback to your device.** An attached device is used only with
  `ADT_DEVICE_MODE=reuse`. Runs boot an AVD on the app's `targetSdk`.
- **Release check and device tests.** Two optional Section 0 commands: R8 on
  the release build, and the plan's instrumented tests on the run's device.
  Room schema changes need a migration test.
- **Test secrets and test hooks.** Flows sign in with secrets named in
  `AGENTS.md` and kept in `.agentic-dev-team/secrets.env`; the script fills
  them in and scrubs them from logs. Debug-only test hooks seed data.
- **Plan handoff.** The build commands start from an existing plan, design
  doc or spec.
- **CI.** `adt.sh suite` replays `e2e/flows/` with no model and writes a JUnit
  report; `examples/ci/android-e2e.yml` runs it on pull requests. The
  repository has its own CI.
- **Tool limits outside Claude Code.** OpenCode agents get `permission`
  blocks; an external Tester runs with no shell.
- **Run summary and evaluations.** `adt.sh summary` writes
  `run-summary.json`; `evals/` has the procedure to compare releases.

## 0.5.0

- Configurable agent models and review panels for `/build-auto-reviewed`
  (`.agentic-dev-team/config.yaml`), with the review judge.
- Test cases written so a flow can run them, checked in one review round.

## Earlier

See the git history.
