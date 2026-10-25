# Multi-Agent Pipeline: Orchestration

The orchestrator's half of the pipeline rules. The slash commands read this
file and `AGENTIC_DEV_TEAM_PIPELINE.md` (Part A, the agent protocol); agents
read only Part A. The optional config file and configured runs are in
`AGENTIC_DEV_TEAM_CONFIG.md`, which you read only when "Command Start" says so.

---

# Part B — Orchestration & Tool Registration

Orchestrator-facing. The agents spawned by the pipeline do not need this half.

## Command Start

Every command does these steps first, in this order, before any agent runs.
The command file says which steps it does.

1. **The docs.** The command file found PIPELINE_DOC
   (`AGENTIC_DEV_TEAM_PIPELINE.md`) and ORCHESTRATION_DOC (this file): each at
   `.claude/<file>` in the project if it exists there, else at
   `${CLAUDE_PLUGIN_ROOT}/<file>` (a plugin-only install). Pass PIPELINE_DOC
   to every subagent you spawn, beside the artifact paths you already pass.
   Never pass ORCHESTRATION_DOC or CONFIG_DOC to an agent: they are yours.

2. **The test driver** (build commands). Read the `Test driver:` line in the
   project's `AGENTS.md` (or `CLAUDE.md`): `auto-mobile` or `maestro`, and
   `auto-mobile` when there is no such line. Any other value is a STOP: report
   it and name the two valid values. Then find the driver's adapter the way
   PIPELINE_DOC was found (`.claude/adt/drivers/<driver>.md` if it exists,
   otherwise `${CLAUDE_PLUGIN_ROOT}/drivers/<driver>.md`) and store that path as
   DRIVER_DOC. The test phase passes it on (Part A, "The Test Driver").

3. **The device script** (build commands). Resolve it the same way and store
   it as ADT_SH: the relative path `.claude/adt/scripts/adt.sh`, written
   exactly like that, if it exists, otherwise
   `${CLAUDE_PLUGIN_ROOT}/scripts/adt.sh`. Run it only as one plain command,
   `bash <ADT_SH> …`, from the project root: no `cd`, no `&&`, no variables in
   front, and no absolute form of the relative path. That is what the
   pre-approved permission rule matches, so the run is not stopped to ask.

4. **Preflight** (build commands; "Before the Run" below).
   1. Run `bash <ADT_SH> preflight --driver <driver>`. It checks the Android
      SDK, the AVDs, and the driver's command line and background service. On
      exit 16, STOP and report its FAIL lines; each says how to fix it. Keep
      its warn lines for the final summary.
   2. Check your own tool list for the driver's MCP tools
      (`mcp__auto-mobile__…` or `mcp__maestro__…`). None at all: STOP, the
      driver's MCP server is not registered (HOW_IT_WORKS, "Setting up device
      testing"). For auto-mobile, if `mcp__auto-mobile__rotate`,
      `mcp__auto-mobile__setDeviceState` or `mcp__auto-mobile__executePlan` is
      missing, its hidden tools are not switched on: say so now and in the
      final summary, because rotation, offline and permission cases will come
      back INCONCLUSIVE and the Test Writer cannot check its flows.

5. **The config file** (every command).
   1. Set PROJECT_ROOT to the absolute path of the directory this command
      started in (your working directory at the start; your tool shows it, no
      shell command is needed). All paths below are relative to PROJECT_ROOT,
      whatever the shell's current directory is later.
   2. If PROJECT_ROOT/.claude/adt/scripts/adt-run-agent.sh exists, set
      ADT_ROOT to PROJECT_ROOT/.claude and ADT_RUN to that script path;
      otherwise, if `${CLAUDE_PLUGIN_ROOT}/scripts/adt-run-agent.sh` exists,
      set ADT_ROOT to `${CLAUDE_PLUGIN_ROOT}` and ADT_RUN to that script path;
      otherwise leave both empty. CONFIG_DOC is
      ADT_ROOT/AGENTIC_DEV_TEAM_CONFIG.md.
   3. For every "exists" check in this step, read that exact path with your
      file-read tool, only its first line (for example a line limit of 1).
      Never use a file-search tool: search tools skip git-ignored files, and
      both the script link in an `install.sh` project and the config file are
      git-ignored. Never use a shell command for these checks.
   4. Read PROJECT_ROOT/.agentic-dev-team/config.yaml the same way. There are
      exactly three outcomes:
      (a) The read succeeds (an empty file counts as success): the file
          exists. Skip the init step.
      (b) The read reports that the file does not exist, in any wording (for
          example "File does not exist.", "file not found", "no such file"):
          treat the file as missing. If ADT_ROOT is set, run
          `bash "ADT_RUN" --init-config "PROJECT_ROOT"` (with the real paths in
          place of the names, each in double quotes); if ADT_ROOT is empty,
          skip it. (A broken link is also reported as "not found"; the script
          then prints `ADT_INIT status=unreadable`, see below.)
      (c) The read fails for a reason other than "the file does not exist"
          (the path is a directory, or no permission): a config error. Do not
          run the init step. STOP the command before the first agent and say:
          "agentic-dev-team: .agentic-dev-team/config.yaml exists but cannot
          be read; fix or delete it."
   5. The init step creates the optional, git-ignored config once. After it:
      - `ADT_INIT status=created` or `status=exists`: continue.
      - `ADT_INIT status=unreadable`: a config error; STOP the command before
        the first agent and show the script's message.
      - The permission was declined, the tool reported an error, or
        `ADT_INIT status=failed`: print this line once and continue. (When
        the init step was skipped, print nothing.)
        "The optional config file .agentic-dev-team/config.yaml was not
        created. To stop this question, allow the command, or create two files
        yourself: .agentic-dev-team/.gitignore with the single line *, and
        .agentic-dev-team/config.yaml copied from <TEMPLATE>."
        where <TEMPLATE> is only the one that applies: in a plugin install
        (ADT_ROOT is not PROJECT_ROOT/.claude), the real path of
        ADT_ROOT/config.example.yaml; in an install.sh install (ADT_ROOT is
        PROJECT_ROOT/.claude), the text
        "plugins/agentic-dev-team/config.example.yaml in your agentic-dev-team
        clone".
   6. **Active or not.** When the config file exists, read it in full. It has
      an **active setting** when any line is something other than a blank
      line, a comment (a `#` after optional spaces), `version: 1`, or one of
      the top-level keys `agents:` and `build_auto_reviewed:` with nothing
      after the colon but an optional comment. The file as created has no
      active setting.
      - **No active setting**, or no file: MODELS and RUNS are off. Do not
        read CONFIG_DOC, and ignore every rule that names MODELS or RUNS. The
        run is exactly as it would be without the config file.
      - **An active setting**: read CONFIG_DOC in full and follow its "Agent
        Configuration" section: validate the whole file, and set MODELS (and,
        in `/build-auto-reviewed`, RUNS). When MODELS is on, follow that
        section every time you start an `adt-*` subagent: it says which model
        to pass, and when to pass none. When RUNS is on, follow CONFIG_DOC,
        "Configured Runs", for every phase of `/build-auto-reviewed`.
      - If ADT_ROOT is empty or CONFIG_DOC does not exist (an older install),
        do not use the config file, and, only when it has an active setting,
        print one line: "agentic-dev-team: the installed pipeline is older
        than the config file support, so .agentic-dev-team/config.yaml was not
        used."

## The Run Ledger

A build command keeps the state of its run in a ledger, not in your memory:
`bash <ADT_SH> state --slug S …`. A long run can outlive your context (it gets
compacted) or your session (it dies), and a count that exists only in the
conversation is then lost. The ledger survives both, and the script refuses a
re-run that the budget does not allow.

**What to record.** As soon as you know the slug S (from the Architect's DONE
marker, or from an existing plan the command was given):

```
bash <ADT_SH> state --slug S set command <build-auto | build-auto-reviewed | build-guided>
bash <ADT_SH> state --slug S set plan <PLAN_PATH>
bash <ADT_SH> state --slug S set design_doc <DOC_PATH, or none>
bash <ADT_SH> state --slug S set driver <the test driver>
```

Then `set phase <name>` at the start of every phase, with the command's own
phase names (`2R` for Phase 2R). In a parallel Coder phase, also
`set group <n>` at the start of each Execution Group. After every Tester
verdict, `set verdict <READY TO MERGE | NEEDS FIXES | BLOCKED>`.

**Budgets.** Before each re-run that a budget limits, bump its counter:

| Before | Counter | `--max` |
|---|---|---|
| an Architect re-run at the plan review gate | `plan_review_reruns` | 2 |
| a Coder re-run at the code review gate | `code_review_reruns` | 2 |
| a cross-section fix round after group `<n>` | `cross_section_rounds_g<n>` | 2 |
| a Tester fix-loop iteration | `fix_iterations` | 2 |
| a Coder re-run in the targeted re-review of fix iteration `<n>` | `targeted_reruns_<n>` | 1 |
| a Tester resume after `⛔ TESTER BLOCKED` | `resumes` | 2 |

`bash <ADT_SH> state --slug S bump <counter> --max <n>` prints the new count.
Exit 17 means the budget is spent: do not start the re-run, and STOP exactly as
the command says for that budget. Bump first, then re-run; never the other way
round. When you are not sure of a count, run `bash <ADT_SH> state --slug S
show`: the ledger is the record, not your memory.

**Resume.** When a build command's `$ARGUMENTS` is exactly `resume <slug>`:

1. Do "Command Start" as usual.
2. Run `bash <ADT_SH> state --slug <slug> show`. Exit 2: STOP, there is no run
   to resume. A `command` that is not this command: STOP and tell the user to
   run `/<that command> resume <slug>`. A `driver` that is not the one Command
   Start found: STOP and say so.
3. Restore PLAN_PATH from `plan`, and DOC_PATH from `design_doc` (`none` means
   DESIGN_DOC is off). Keep every counter as recorded.
4. Tell the user which phase the run continues at, then start that phase from
   its beginning:
   - No `phase` yet, or Phase 1: nothing is worth keeping. STOP, and tell the
     user to start the command again with the feature request.
   - From Phase 2 on, first start the early boot again
     (`device-acquire --background`; it returns at once, and reuses the run's
     device when it still runs).
   - A Coder phase: the tree may hold part of the work. Tell every Coder that
     this is a resumed run: an earlier Coder may have done part of its
     section, so it reads the files first, finishes what the plan asks, and
     does nothing twice. In a parallel phase, start at the recorded `group`.
   - A review gate: run the review again. A review is not a re-run, so bump
     nothing for it.
   - A test phase, or a fix-loop iteration: run the test phase again from its
     first step, install included.
   - A blocked Tester (Phase 3B or 4B): show the ask from `test-results.md`
     again and wait for `resume` or `stop`.
   - In `/build-guided`: show the gate of the recorded phase again and wait
     for the user.

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
- `adt-android-review-judge` (configured review panels only): system prompt from `.claude/agents/adt-android-review-judge.md`; `enable_write_tools = true` (for read-only Bash inspection; the judge never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.

Antigravity does not support per-subagent model selection. The recommended models
in each agent file (`opus` for adt-android-pm/adt-android-architect and both
reviewers, `sonnet` for adt-android-coder, adt-android-test-writer and adt-android-tester) are documented
for reference; in Antigravity, all subagents inherit the user's globally selected
model — select the strongest available model for full pipeline runs.
The `agents:` model settings in .agentic-dev-team/config.yaml cannot change this; see CONFIG_DOC, "Agent Configuration".

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

Testing should never be the first place a broken setup shows up. So every
build command resolves the script and runs the preflight before any agent runs
("Command Start", steps 3 and 4). The preflight checks `adb`, the emulator and
the AVDs it would boot, and the driver: for auto-mobile, that its background
service is on the pinned version or can be started, which it then does; for
Maestro, the CLI's version and Java. Each problem is a `FAIL` line that says
how to fix it, and exit 16 means STOP before planning or coding anything.
`warn` lines go into the final summary. The script is always run as one plain
command, so the pre-approved permission rule matches it (see "Permissions"
below).

Then, as soon as the plan names the slug `S` and before the Coder starts, the
command **boots the run's device early**:
`bash <adt.sh> device-acquire --slug S --api <A> --background`, where `A` is
the `device API` line of the plan's Section 0 (leave `--api` out when the plan
has no such line). It returns at once, and the emulator boots while the Coder
works, on an AVD of that API when one is free. The test phase's own
`device-acquire` waits for it, so the boot costs no extra time. From this
point on, every exit releases the device.

**Permissions.** `install.sh` adds the pipeline's own rules to the project's
`.claude/settings.local.json`: `Bash(bash .claude/adt/scripts/adt.sh *)`,
`mcp__auto-mobile__*` and `mcp__maestro__*`. The build commands also list them
under `allowed-tools`. So Claude Code does not stop a run to ask about the
script or the driver's tools. An agent never adds permission rules itself;
only a person runs `install.sh` or `adt.sh allow`.

**Long-running calls.** `device-acquire`, `install` and `run` can each take
several minutes — a cold boot, a Gradle install, a long suite — and so can
`device-release` while an early boot is still in progress, since it waits for
that boot to finish. Give them a long timeout (in Claude Code, the Bash tool's
maximum, ten minutes), or run them in the background and wait for them to
finish. Each is safe to repeat: if one is cut off by the tool's timeout, run it
again in the background and wait for it.

## The Test Phase

The three build commands test the same way. A run leases one device for its
whole life (Part A, "Devices"), and each test — the first one and every
re-test in the fix loop — goes through the same steps. Below, `S` is the
feature's slug, the `{slug}` in PLAN_PATH, and `<adt.sh>` is the script
resolved in "Before the Run".

Each test:

1. **Lease the device — the run's first test only.**
   `bash <adt.sh> device-acquire --slug S --api <A>`. It returns the device the early
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
   that is `BUILD_INSTALLED`. A device that runs out of space is handled
   inside the script: on an emulator it started, it clears app caches before
   each install and, if the install still runs out of space, restarts that
   emulator as a fresh copy on the same serial and installs again, so `DEVICE`
   stays valid. Do not release and re-acquire the device yourself to work
   around an install failure. If `install` fails, release the device (below),
   then STOP and report its message. Never test a stale build. When the install
   command is more than one plain command — it has `&&`, `;` or a pipe, or
   starts with `cd` — pass it whole to a shell, so all of it runs inside the
   script and reaches `DEVICE` only:
   `bash <adt.sh> install --slug S -- bash -c '<the install command>'`.
3. **Write the flows — the run's first test only.** Delegate to
   `adt-android-test-writer` with PLAN_PATH, PIPELINE_DOC and DRIVER_DOC, and
   wait for ✅ TEST WRITER DONE. It writes every flow from the plan and the code
   without a device, so you may start it before step 2 and run the install
   while it writes. Before a re-test, run it only if the previous
   `test-results.md` lists Flow Defects: pass those flows and the Tester's
   notes as `FIX`, with `DEVICE` and `BUILD_INSTALLED`. Otherwise skip this
   step — the flows are already written. If it STOPs, release the device, then
   STOP and report.
4. **Run the flows.**
   `bash <adt.sh> run --slug S --driver <the test driver> --area <area>:<tiers> … --exclude <id> …`,
   with one `--area` per row of the plan's Regression Scope (its tiers joined
   by commas, `--area checkout:p1,p2`) and one `--exclude` per row of Flows
   Retired. A Regression Scope of `None — only P0`, or Flows Retired of
   `None`, adds no argument. It runs this run's own flows plus the regression suite flows it
   selects — every P0, the named tiers per area, never a flow this run
   re-specifies — on `DEVICE` with no model in the loop, and writes
   `pipeline_artifacts/S/run-results.md`. After each flow it reads Android's
   crash log, so a crash or ANR of the app fails that flow even when every
   check in it passed. Exit 0 means every flow passed and exit 1 that at least
   one failed — both continue, because judging failures is the Tester's job.
   Any other exit: release the device, then STOP and report its message. Each
   flow may run for up to `ADT_FLOW_TIMEOUT_S` (300 s by default), so this is
   one of the long-running calls in "Before the Run". When the run has a
   second emulator, the script splits the flows between the two; nothing else
   changes, and agents only ever use `DEVICE`.
5. **Fix the flows that failed — the run's first test only.** If any of this
   run's own flows (kind `feature`) is `FAIL` for a reason other than a crash
   or an ANR, delegate to `adt-android-test-writer` with PLAN_PATH,
   PIPELINE_DOC, DRIVER_DOC, `DEVICE`, `BUILD_INSTALLED`,
   `RUN_RESULTS: pipeline_artifacts/S/run-results.md` and `FIX`: those flows'
   ids, each with its failing step. When it names flows as fixed, re-run just
   those: `bash <adt.sh> run --slug S --driver <the test driver> --only <id> …`,
   one `--only` per fixed flow. That updates their rows in `run-results.md`;
   every other row stands. Do this once, and skip it when no flow of this run
   failed, or none was fixed. Flows it could not fix keep their `FAIL` rows for
   the Tester. A regression-suite failure, a crash and an ANR always go
   straight to the Tester.
6. **Test.** Delegate to `adt-android-tester` with PLAN_PATH, PIPELINE_DOC,
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
`bash <adt.sh> device-release --slug S`. If the early boot is still in
progress, it waits for that boot and then stops the device, so a run that
stops early never leaves an emulator behind. If it exits non-zero, report the
serial it names and carry on. This is deliberately its own step, not part of
"Close the run", which is skipped whenever a run has no design doc.

**Keep the passing flows — once, at the end.** After the run's final verdict
is `READY TO MERGE` (in `/build-guided`, when the user answers `approve` and the
last verdict was `READY TO MERGE`), run
`bash <adt.sh> promote --slug S --remove <id> …`, with one `--remove` per row of
Flows Retired and per entry in the last `test-results.md`'s "Suite Flows to
Remove". It copies the flows to keep into `e2e/flows/` and prints what it
added, replaced and removed. Never promote after `NEEDS FIXES`, `BLOCKED` or a
STOP. The script checks this too: it refuses (exit 2) unless the
`test-results.md` beside the plan says `READY TO MERGE` and is newer than the
last flow run. If it fails, report it; the verdict stands.

Note the time around steps 3, 5 and 6. The final summary names the test
driver and the device, and reports, for each test, how long the Test Writer,
the flow run and the Tester took, so the user can see where the run's time
went. Take the flow run's time from the "Run time" line of `run-results.md`,
not from when the command returned to you; a step 5 re-run writes its own. It repeats the preflight's warnings, and the Tester's Coverage: how many
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
problem, 17 a budget is spent (`state bump`, "The Run Ledger"). Its messages
say what to do; report them verbatim.

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

1. **Define Subagents**: Dynamically register any required subagents using `define_subagent` if they aren't already defined, using the mappings above — including `adt-android-test-writer`, which every build command uses. For `/build-auto-reviewed`, also register `adt-android-architect-reviewer` and `adt-android-code-reviewer`. When a review panel is configured (CONFIG_DOC, "Configured Runs"), also register adt-android-review-judge.
2. **Execute Phases**:
   - **PM Phase** (`/build-guided` only): Invoke `adt-android-pm` with the user request. Pass messages back and forth between the user and the PM subagent until it outputs `✅ PM DONE`.
   - **Architect Phase**: Invoke `adt-android-architect` with the PM's `feature.md` path (or the feature description for the auto flows) and the `DESIGN_DOC` value this command defaults to (see "Design Doc Defaults Per Command"). Wait until it outputs `✅ ARCHITECT DONE`, and parse the artifact paths out of that marker — the plan path always, and the design doc path when one was requested.
   - **Architect Review Gate** (`/build-auto-reviewed` only): Invoke `adt-android-architect-reviewer` with the plan path (and the design doc path if one was requested), and apply the Reviewer-Loop Protocol above before proceeding. A bounce re-runs the Architect, which re-emits the artifacts, so any document a human ends up reading is always the approved one.
   - **Coder Phase**: Read the execution strategy from the implementation plan. If parallel-safe, verify mechanically that no file appears in two sections of the same group, then invoke multiple `adt-android-coder` subagents in parallel. Otherwise, invoke a single `adt-android-coder`. Parallel coders run no Gradle — you own the verification, via the cross-section check after **every** group (Part A, "Gradle in a Parallel Run"). Take its command from the plan's Section 0 like every other agent — not from Part A's defaults — and on failure follow Part A's "When the cross-section check fails".
   - **Code Review Gate** (`/build-auto-reviewed` only): After all coding is complete, invoke `adt-android-code-reviewer` with the plan path and apply the Reviewer-Loop Protocol above before proceeding.
   - **Before the run**: resolve the test driver and the script, run the preflight, and check the driver's MCP tools ("Before the Run" above). After the Architect, start the early boot.
   - **Tester Phase**: Run "The Test Phase" above: lease the run's device, install the build on it, invoke `adt-android-test-writer` to write the flows, run them with `adt.sh run`, send any of this run's flows that failed back to the Test Writer to fix and re-run those with `adt.sh run --only`, then invoke `adt-android-tester` with the plan path, `DRIVER_DOC`, `DEVICE`, `BUILD_INSTALLED`, `RUN_RESULTS`, and any `TEST CREDENTIALS` the human supplied for this run (Part A, "Test Credentials"). It judges the flow results, drives what no flow covers, and writes `test-results.md`. Wait for **either** `✅ TESTER DONE` **or** `⛔ TESTER BLOCKED` — both end its turn.
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
   The `agents:` model settings in .agentic-dev-team/config.yaml cannot change this; see CONFIG_DOC, "Agent Configuration".
4. **Tester MCP**: the test driver's MCP server is registered in
   `opencode.json` under the `mcp` key — auto-mobile as an HTTP server
   (`type: "remote"`, with auto-mobile's `url`), Maestro as a local one
   (`type: "local"`, `command: ["maestro", "mcp"]`); the Tester reaches it like
   any other tool.
5. **Rules**: agents and commands reference `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`
   (and commands also `.claude/AGENTIC_DEV_TEAM_ORCHESTRATION.md`) and the
   project's `AGENTS.md`/`CLAUDE.md` by path (all present in the project tree),
   so opencode reads the same sources of truth as the other tools.
