# Implementation Plan: Pipeline Improvements & the `/on-call` Entry Point

**Date**: 2026-07-22 (consolidates the 2026-07-12 codebase review)
**Structure**: one document, five parts.
- **Part I — Codebase review & decided changes**: implementation-ready;
  every either/or resolved into a single pinned decision.
- **Part II — `/on-call`**: design spec for the production-driven entry
  point (two new agents, one new command); decisions pinned, external
  dependencies marked **VERIFY**.
- **Part III — `/design-doc`**: design spec for the human-facing design
  artifact (one new agent, one new command); no external dependencies.
- **Part IV — Deferred & optional integrations**: §1–§2 need
  design/verification before an agent can implement them unambiguously; §3
  is the optional AdbHarbor device-lease protocol.
- **Part V — Documentation & packaging updates**: pinned edits to
  `README.md`, `HOW_IT_WORKS.md`, persona stubs, and the plugin manifest so
  the repo's user-facing docs explain each capability as it ships.

Cross-references between parts are written "Part N §x"; a bare §x refers to
the part it appears in.

## Unified implementation order

| Step | What ships | Defined in | Docs to ship with it |
|---|---|---|---|
| 1 | PR 1 — Correctness & packaging | Part I §5 | Part V §1 |
| 2 | PR 2 — Efficiency & safeguards | Part I §5 | — |
| 3 | PR 3 — Flow enhancements (incl. Architect `Alternatives Considered`) | Part I §5, Part III §2 | Part V §2 |
| 4 | `/design-doc` agent + standalone command, then build-command integration | Part III §9 | Part V §3 |
| 5 | Device lease protocol (AdbHarbor, optional dependency) | Part IV §3 | Part V §5 |
| 6 | auto-mobile plan-schema verification | Part IV §1 prerequisite (unblocks Parts II & IV §1) | — |
| 7 | `/on-call` steps 2–6: Triager → Reproducer → full loop → rollout advice (incl. fix-brief variant) | Part II §8, Part III §7 | Part V §4 |
| 8 | Tester speed redesign; cross-run codebase map | Part IV §1–§2 | Part V §6 |

Step 5 is a prerequisite for *recommending* step 7's scheduled mode on a
machine a human also uses (Part II §1); it is independently useful before
that for anyone running pipeline commands concurrently.

Step 4 is the cheapest capability to ship (no external dependencies, one
lightweight agent) and the one that most changes how humans experience the
pipeline — it can be pulled ahead of anything except Part I PR 3, whose
Architect template edit it depends on.

---

# Part I — Codebase Review & Decided Changes

**Status**: **Implementation-ready.** Every either/or in the original review
has been resolved into a single decision; templates and added wording are
pinned. Topics that still need design or external verification (the Tester
speed redesign, the cross-run codebase map) are deferred to **Part IV** and
are **not** part of this part.
**Scope**: All agent prompts (`plugins/agentic-dev-team/agents/`), commands
(`plugins/agentic-dev-team/commands/`), orchestration rules
(`.claude/AGENTIC_DEV_TEAM_PIPELINE.md`), cross-tool stubs (`.opencode/`,
`.agents/`), `install.sh`, and the plugin packaging.

Implementation phasing (which changes ship together, in what order) and the
cross-tool sync checklist an implementer must follow are in **§5**. Empirical
evidence for the verified findings is in the **§6 appendix**.

---

## 1. Correctness & Consistency Defects

### 1.1 Tool manifests are inconsistent with the agents' write paths (MEDIUM)

The handoff protocol makes markdown artifacts the contract between phases.
In Claude Code, the frontmatter `tools` field is a restriction ("inherits all
tools if omitted" — specifying it denies everything else), and the manifests
of the three artifact-producing agents don't grant `Write`:

| Agent | Declared tools | Required output | Actual write path today |
|---|---|---|---|
| `adt-android-pm` | `Read, Glob, Grep` | `feature.md` | **None of its own** in Claude Code — no Write, no Bash. Works in practice because Antigravity maps it with `enable_write_tools = true`, the opencode stub sets no tool restriction, and in Claude Code's `/build-guided` the orchestrator (full tools) can land the file on the PM's behalf. |
| `adt-android-architect` | `Read, Glob, Grep, Bash, Skill` | `implementation-plan.md` | Bash (quoted heredoc). Works, including for markdown with nested code fences. |
| `adt-android-tester` | `Read, Bash, mcp__auto-mobile__*` | `test-results.md` | Bash (quoted heredoc). Works. |

This does **not** break pipeline runs (see §6, Tests 1–2), but it makes
behavior tool-dependent in the one place the repo promises identical
personas, and the PM's Claude Code path relies on unstated orchestrator
goodwill rather than its own toolset.

**DECIDED CHANGE**:
- `adt-android-pm.md` frontmatter: `tools: Read, Glob, Grep, Write, Bash`
- `adt-android-architect.md` frontmatter: `tools: Read, Write, Glob, Grep, Bash, Skill`
- `adt-android-tester.md` frontmatter: `tools: Read, Write, Bash, mcp__auto-mobile__*`
- Reviewers and Coder: unchanged.
- No prompt-body changes required (the PM's existing `mkdir -p` step is now
  executable as written).

### 1.2 Plugin installs are missing the pipeline doc (HIGH)

Every agent's "Required Reading" section and every command says:

> Read `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` in full. It is the source of truth…

That file is materialized by `install.sh` — but the **Claude Code plugin**
does not ship it: the plugin's `git-subdir` source packages only `agents/`,
`commands/`, and `.claude-plugin/` (verified — see §6). Plugin-only runs
still succeed, but pay a recovery tax: in the live test the orchestrator's
`Read` failed, then it Globbed, then ran a **filesystem-wide
`find / -iname`** before locating a copy outside the project — and the
Architect subagent simply skipped the read entirely.

Scope note: the cross-tool layout (canonical files under
`plugins/agentic-dev-team/`, symlinked into `.claude/`, stubbed for
Antigravity and opencode) is intentional and untouched. The gap is only that
the pipeline doc sits *outside* the one subdirectory the plugin packages.

**DECIDED CHANGE** (the symlink move; the "inline the protocol into every
agent" alternative from the original review is **rejected** — it would
duplicate the protocol six times and drift):
1. `git mv .claude/AGENTIC_DEV_TEAM_PIPELINE.md plugins/agentic-dev-team/AGENTIC_DEV_TEAM_PIPELINE.md`
2. Create a relative symlink in its old place:
   `.claude/AGENTIC_DEV_TEAM_PIPELINE.md -> ../plugins/agentic-dev-team/AGENTIC_DEV_TEAM_PIPELINE.md`
   — the same pattern `.claude/agents` and `.claude/commands` already use.
   `install.sh` needs **no change**: its `[ -f ]` check and symlink source
   both resolve through the new symlink.
3. In every file that says "Read `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`"
   (6 agents, 5 commands), append this exact sentence:
   > If that file does not exist in the project (plugin-only install), read
   > `${CLAUDE_PLUGIN_ROOT}/AGENTIC_DEV_TEAM_PIPELINE.md` instead; if neither
   > exists, proceed using the rules in this prompt.

### 1.3 Coder prompt contradicts its own no-staging rule (MEDIUM)

`adt-android-coder.md` step 6 says "confirm changes are uncommitted but
**staged for review**", while Operating Principle 1 and the Definition of
Done forbid staging.

**DECIDED CHANGE**: replace step 6's wording with:
> Run `git status` to confirm all changes are uncommitted and unstaged,
> present in the working tree for human review. Do not commit or stage.

### 1.4 Build gate is specified in three slightly different ways (MEDIUM)

The gate command differs between the pipeline doc, the Coder prompt, and the
code-reviewer prompt (assembleDebug sometimes included, sometimes not,
sometimes "if quick enough").

**DECIDED CHANGE**: define once, in the pipeline doc's agent-facing Part A
(see §2.1), under the name **"the build gate"**:
```
./gradlew assembleDebug lint detekt testDebugUnitTest
```
Then replace every restated command in `adt-android-coder.md`,
`adt-android-code-reviewer.md`, and the three build commands with the phrase
"run the build gate (defined in the pipeline doc)". One invocation also pays
Gradle configuration once instead of twice.

### 1.5 Stale path in Architect description (LOW)

**DECIDED CHANGE**: in `plugins/agentic-dev-team/agents/adt-android-architect.md`
and `.opencode/agents/adt-android-architect.md`, change
"Requires either pipeline_artifacts/feature.md to exist" to
"Requires either pipeline_artifacts/{slug}/feature.md to exist".

### 1.6 `/build-guided` loose ends (LOW)

**DECIDED CHANGE**, three edits to `build-guided.md` Phase 4:
1. After "Delegate to the `adt-android-tester` subagent. Pass: PLAN_PATH",
   add: "Wait for ✅ TESTER DONE."
2. Add NEEDS FIXES handling: the fix loop defined in §4.3 (guided variant —
   the user chooses at the gate).
3. Add a closing gate after the summary: "Ask the user: `approve` to finish,
   `revise: <feedback>` to send the failures back to the Coder, or `stop`."

### 1.7 Hardcoded Android skill list will go stale (LOW)

The identical 16-entry skill list is duplicated in the Architect and Coder
prompts; it's environment-dependent, and in the live plugin test invoking
`styles` from it produced `Unknown skill: styles` (see §6).

**DECIDED CHANGE**:
1. Move the list once into the pipeline doc's Part A under "Android skills
   (examples — availability varies by environment)".
2. In both prompts, replace the inline list with a reference to it plus this
   exact guard sentence:
   > Before invoking any skill, confirm it appears in your available-skills
   > listing; if it is not available, proceed without it — do not retry or
   > treat the absence as an error.

---

## 2. Efficiency Improvements

### 2.1 Restructure the pipeline doc into Part A (agents) / Part B (orchestrators)

Each of the six agents reads the project's `AGENTS.md`/`CLAUDE.md`, the full
pipeline doc, and the prior artifact on every invocation. Most of the
pipeline doc is orchestrator-facing (subagent mappings, Antigravity/opencode
registration) — content no subagent needs, re-read ~8–10× per reviewed run.

**DECIDED CHANGE** (single file — a physical split into two files is
**rejected**: it would double the symlink/install surface and Antigravity's
orchestrator needs both halves from one auto-discovered path):

Reorganize `AGENTIC_DEV_TEAM_PIPELINE.md` into two clearly headed halves:
- **`# Part A — Agent Protocol`** (first, short): artifact directory layout
  and slug rules, read-before-write rule, no-commit rule, **the build gate**
  (§1.4), verdict/DONE markers, the Android skills list (§1.7).
- **`# Part B — Orchestration & Tool Registration`**: subagent tool
  mappings, reviewer-loop protocol, approval gates, Antigravity and opencode
  workflow sections.

Change every *agent* prompt's Required Reading from "read
`.claude/AGENTIC_DEV_TEAM_PIPELINE.md` in full" to "read **Part A (Agent
Protocol)** of `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`; Part B is
orchestrator-facing and may be skipped". Commands keep reading the whole
file.

### 2.2 Stop re-discovering the codebase in every phase

Four agents independently re-survey the codebase per feature. The Architect's
plan Section 1 ("Current State of Codebase") already contains the survey.

**DECIDED CHANGE**: add this exact sentence to `adt-android-coder.md` and
`adt-android-code-reviewer.md` (the architect-reviewer already has equivalent
"spot-check the riskiest claims" scoping):
> Treat the plan's Section 1 as your codebase orientation; verify only the
> specific claims your own work depends on, rather than re-surveying the
> repository.

(The cross-run `codebase-map.md` idea is deferred — see Part IV §2.)

### 2.3 Run Gradle less

On a clean `/build-auto-reviewed` run the same checks execute up to 4×.

**DECIDED CHANGES**:
1. Single-invocation gate everywhere (done by §1.4).
2. In `build-auto-reviewed.md` Phase 2R, when delegating to the code
   reviewer, pass the Coder's reported gate status and `git diff --stat`
   output, and add to `adt-android-code-reviewer.md`:
   > If the orchestrator provides a build-gate result for the current
   > working tree and the tree has not changed since, do not re-run the
   > gate; re-run it only if no result was provided, the tree changed, or
   > the Coder reported "passing-within-scope" from a parallel run.
3. In both build commands' parallel branch, qualify the between-groups gate:
   > Run the build gate between groups only when a later group depends on
   > this group's code compiling; otherwise defer to the single gate after
   > the final group.

### 2.4 Delta re-review on reviewer bounces

**DECIDED CHANGE**: add this exact sentence to both reviewer prompts:
> If this is a re-review after your own CHANGES REQUESTED verdict, first
> verify each item of your previous numbered feedback was addressed, then
> spot-check only code changed since that review; do a full review only on
> the first pass.

### 2.5 Converge the PM interrogation loop

Each Q&A round in `/build-guided` / `/plan-research` re-invokes the PM, which
re-scans the codebase.

**DECIDED CHANGES**:
1. In `build-guided.md` and `plan-research.md`, where user responses are
   passed back to the PM, add: "Include the full accumulated Q&A transcript
   with each re-invocation."
2. In `adt-android-pm.md` Process step 2, add: "If the prompt includes a
   prior Q&A transcript, skip the codebase scan — it was done in round 1."
3. In `adt-android-pm.md` Operating Principle 5, add: "Budget the
   interrogation: aim to resolve everything in at most 2 question rounds;
   capture what remains under Open Questions for Architect."

### 2.6 Section-scoped plan reading for parallel Coders

**DECIDED CHANGE**: in both build commands' parallel branch, extend the
per-coder instruction to:
> Read the plan's Section 1, your assigned section, and the Public Interface
> blocks of any sections yours depends on. Skip other sections' code
> samples.

---

## 3. Missing Safeguards

### 3.1 Tester failure-loop

Covered as a flow change — see §4.3 (this was the single biggest
effectiveness gap: an unattended run could finish "complete" with a broken
feature).

### 3.2 Test adequacy in code review

**DECIDED CHANGE**: add to `adt-android-code-reviewer.md`'s "What You
Review" list:
> 6. **Test adequacy.** The tests the plan required exist, exercise the edge
>    cases the plan names, and would fail if the feature regressed.

### 3.3 Revision notes across reviewer bounces

**DECIDED CHANGE**: add to the reviewer-loop protocol in the pipeline doc
(Part B):
> On each re-run, the producing agent appends a short
> `## Revision Notes (attempt N)` section to its artifact listing what
> changed, so downstream agents can see how the artifact drifted.

### 3.4 Accumulate reviewer feedback across attempts

**DECIDED CHANGE**: add to the reviewer-loop protocol in the pipeline doc
(Part B):
> On the 2nd re-run, pass the producing agent all prior numbered feedback
> (both rounds), marking items the reviewer previously accepted as resolved.

### 3.5 PM guard for non-interactive contexts

The interrogation is the PM's whole value — it must not degrade into
guessing. **DECIDED CHANGE**: add to `adt-android-pm.md` Stop Conditions:
> - You are running in a context where no user answers arrive → STOP and
>   report that this flow requires an interactive session; never write a
>   spec from your own assumptions.

### 3.6 install.sh robustness (LOW)

**DECIDED CHANGES**:
1. In `abs_readlink`, when the manual resolution's `cd` fails (target's
   parent missing), fall back to echoing the raw `readlink` value instead of
   an empty string, so broken foreign symlinks are still classified
   correctly during the refuse phase.
2. Add one comment line inside the managed `.gitignore` block, immediately
   after the start marker:
   `# This block is also install-state used for stale-cleanup — hand-edits break sync.`

---

## 4. Flow Enhancements (existing commands, deeper behavior)

No new commands, no new agents. Each item pins the exact behavior to
implement.

### 4.1 Resume instead of restarting

**Today**: `/build-auto` always runs the Architect — even when handed a plan
`/plan-design` just produced; slug collisions are undefined; a STOP is a
dead end.

**DECIDED CHANGES**:
1. **Plan-path arguments skip planning.** In `build-auto.md` and
   `build-auto-reviewed.md`, before Phase 1: if `$ARGUMENTS` is a path to an
   existing `implementation-plan.md`, set PLAN_PATH to it and skip Phase 1
   (`/build-auto-reviewed` still runs the Phase 1R review gate on the
   provided plan). If it is a path to a `feature.md`, pass that to the
   Architect as `/build-guided` does.
2. **Artifact-driven entry.** In all three build commands, after deriving
   the slug: if `pipeline_artifacts/{slug}/implementation-plan.md` exists,
   announce "resuming existing run" and enter at Phase 2 (Phase 1R first in
   the reviewed flow); if `test-results.md` exists with a NEEDS FIXES
   verdict, enter at the §4.3 fix loop. In `/build-guided`, ask the user
   first: "`resume` the existing run at {phase}, or `fresh` to start over
   under `{slug}-2`?"
3. **Slug-collision rule** in the pipeline doc (Part A):
   > If `pipeline_artifacts/{slug}/` already exists, the run resumes it;
   > never silently create a duplicate directory for the same feature.
4. **Structured STOP report.** Add to the pipeline doc (Part B) and use in
   every STOP path of the three build commands:
   ```
   ⛔ PIPELINE STOPPED — <phase>
   Reason: <one line>
   Artifacts so far: <paths + git status summary>
   Resume: re-run /<command> <original argument> — it will resume at <phase>.
   ```

### 4.2 Baseline build-gate check at kickoff

**DECIDED CHANGE**: in all three build commands, as the first step after
slug derivation:
> Run the build gate once and write the result to
> `pipeline_artifacts/{slug}/baseline.md` (PASS, or FAIL plus the failing
> task names). On FAIL in /build-auto and /build-auto-reviewed: STOP with
> the standard report — the pipeline must start from a green baseline. In
> /build-guided: show the failures and ask the user whether to continue
> anyway.

Later gate failures are then classified against `baseline.md` (*new* vs
*pre-existing*); pre-existing failures never count against the Coder's or
reviewer's bounded re-runs.

### 4.3 Act on the Tester's verdict

**DECIDED CHANGE**: in `build-auto.md` and `build-auto-reviewed.md`, replace
the "suggest re-running the Coder" ending with:
> Phase 3F — Tester fix loop (max 2 iterations): on NEEDS FIXES, spawn ONE
> `adt-android-coder` with PLAN_PATH plus the test report's
> "Recommendations for Coder" section, wait for ✅ CODER DONE, then re-run
> `adt-android-tester` with PLAN_PATH and the previous `test-results.md`,
> instructing it to re-run the failed cases and the happy path (other
> previously-passing cases only if the fix plausibly affects them). After
> the 2nd failed iteration, STOP with the standard report.

In `build-guided.md`, the same loop runs only when the user chooses
`revise:`/"send back to Coder" at the post-test gate (§1.6).

(Making the re-test leg cheap via recorded plan replay is deferred —
Part IV §1.3.)

### 4.4 Decision-grade approval gates in `/build-guided`

**DECIDED CHANGES**:
1. Replace the plan gate's "show the section headings" with:
   > Show a decision digest of the plan: new dependencies added; database/
   > schema or migration changes; public API changes; files modified outside
   > the feature's own area; the Parallel-safe decision, its rationale, and
   > the number of Coder subagents it implies; any deviation from
   > feature.md. Then ask for approve / revise / stop.

   **Superseded once Part III ships** (see Part III §5.1): the gate then
   presents `design-doc.md`'s Summary, Alternatives Considered, and Blast
   Radius sections instead of this inline digest, plus the parallel-safety
   decision and Coder count. Implement the digest as written in PR 3;
   replace it when the design writer lands.
2. At the post-coder gate, show `git diff --stat` grouped by plan section
   plus the build-gate result compared against `baseline.md`.
3. **Gate policy**: at kickoff, if `$ARGUMENTS` contains a directive of the
   form `gates: <list>` (comma-separated subset of `pm, plan, code, test`),
   pause only at the listed gates and auto-approve the rest; otherwise pause
   at all gates as today. Example:
   `/build-guided gates: code,test add a recently-played carousel`.

### 4.5 Cheaper review gates in `/build-auto-reviewed`

1. Delta re-review — done by §2.4.
2. Gate-skip on unchanged tree — done by §2.3.2.
3. **Mechanical parallel-safety pre-check** — add to both build commands'
   parallel branch, before spawning:
   > Extract each section's file list from the plan and verify no file
   > appears in two sections of the same group (mechanical comparison, not
   > judgment). On overlap, STOP with the standard report naming the files —
   > do not spawn coders against a plan with a parallelization bug.

### 4.6 Write down the "why", not just the "what"

**DECIDED CHANGES**:
1. `adt-android-pm.md` feature.md template gains, after "Success Criteria":
   ```
   ## Decision Log
   - Q: <question asked> → Decision: <chosen option> — Why: <one line>
   ```
2. `adt-android-architect.md` plan template gains, after Section 4:
   ```
   ## Confidence & Risk
   - Verified against codebase: <files/types/APIs checked and confirmed>
   - Assumed (not verified): <APIs, versions, behaviors taken on faith>
   - Riskiest parts: <sections/files and why>
   ```
3. Add to `adt-android-architect-reviewer.md`:
   > Prioritize spot-checks using the plan's "Assumed (not verified)" and
   > "Riskiest parts" lists when present.

### 4.7 Use checks that already exist

**DECIDED CHANGES**:
1. Add to `adt-android-code-reviewer.md`'s "What You Review" list:
   > 7. **Android security basics.** Newly exported components; PendingIntent
   >    mutability/flags; WebView settings (JS bridges, file access);
   >    cleartext traffic; SQL/content-provider injection; secrets or tokens
   >    in code; permission escalation. Block only on real vulnerabilities.
2. Add to `adt-android-architect.md`'s Manual Testing Plan requirements:
   > If the feature ships or modifies UI, include one accessibility test
   > case: TalkBack announces every interactive element (contentDescription
   > present), text contrast is acceptable, and touch targets are ≥48dp —
   > all checkable via auto-mobile's accessibility tools.

### 4.8 Record what each run cost

**DECIDED CHANGE**: in all three build commands, replace the scattered
final-summary cost notes with:
> Write `pipeline_artifacts/{slug}/run-report.md`:
> ```
> # Run Report: <feature>
> - Command: </build-auto|...> | Started / finished: <ISO timestamps>
> - Baseline gate: <PASS|FAIL (pre-existing: …)>
> - Architect attempts: <n> | Plan-review verdicts: <list, reviewed flow only>
> - Coders spawned: <n> (parallel: yes/no, groups: n)
> - Code-review verdicts: <list, reviewed flow only>
> - Build-gate runs: <n>
> - Tester iterations: <n> | Final verdict: <READY TO MERGE|NEEDS FIXES>
> ```
> Then show it to the user as the run summary.

---

## 5. Implementation Phasing & Cross-Tool Sync Checklist

### Phasing — three independently shippable PRs, in this order

**PR 1 — Correctness & packaging** (do first; everything else builds on the
restructured pipeline doc):
§1.1, §1.2, §1.3, §1.5, §1.6, §2.1 (Part A/B restructure), §1.4 and §1.7
(both land inside Part A during the restructure).

**PR 2 — Efficiency & safeguards** (prompt-only edits):
§2.2–§2.6, §3.2–§3.6.

**PR 3 — Flow enhancements** (command behavior):
§4.1–§4.8.

Acceptance check for every PR: the §6 appendix's smoke test — a headless
`claude -p "/plan-design <small feature>"` run in a mock Android project
(both install paths) completes, writes a well-formed plan, and the transcript
shows no failed file reads, no unknown-skill errors, and no
filesystem-wide searches.

### Cross-tool sync checklist (apply to every edit above)

1. **Edit only canonical files** under `plugins/agentic-dev-team/` (the
   repo-root `.claude/agents` and `.claude/commands` are symlinks into it;
   Antigravity workflows and opencode commands symlink to
   `.claude/commands/`, so they follow automatically).
2. If an agent's frontmatter **`description:` changes**, mirror the same text
   in the matching `.opencode/agents/adt-*.md` stub (descriptions are
   duplicated there; bodies are not).
3. If an agent's **role, traits, or constraints change** (e.g. §3.5, §4.6),
   update its persona stub in `.agents/AGENTIC_DEV_TEAM.md` to match, and
   note in the changelog that consuming projects must re-run `install.sh` to
   refresh the inlined `agents.md` block.
4. The pipeline-doc move (§1.2) requires updating the path table in
   `HOW_IT_WORKS.md` only if the *project-side* path changes — it does not
   (still `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`); add a one-line note that
   the canonical file now lives in the plugin directory.
5. **Bump the plugin version** in `.claude-plugin/marketplace.json`
   (`0.1.0` → `0.2.0`) in PR 1 so marketplace users pick up the packaged
   pipeline doc.
6. Do not edit anything under consuming projects — all changes propagate via
   the clone symlinks or a plugin update.

---

## 6. Appendix: Empirical Validation

The findings marked "verified" were tested against a mock Android project
(minimal Compose app: `settings.gradle.kts`, `app/build.gradle.kts`,
`MainActivity.kt`, `HomeScreen.kt`, `CLAUDE.md`) using headless Claude Code
v2.1.207 (`claude -p`, `--permission-mode acceptEdits`), with both install
paths, and the session transcripts (including subagent sidechains) inspected
for every tool call and error.

### Setup A — `install.sh` into the mock project

Install succeeded cleanly: 28 symlinks, `.gitignore` and `.agents/agents.md`
marker blocks synced, zero refusals.

**Test 1 — PM must write its own artifact; orchestrator forbidden to write.**
The `adt-android-pm` subagent produced a complete spec as *message text* and
reported it has "only Read, Glob, and Grep available — no Write, Edit, or
Bash tool". **No file was created.** Its `✅ PM DONE` marker even said
"file not yet written — no write tool available in this session".

**Test 2 — same run, orchestrator free to act (normal usage).**
`pipeline_artifacts/dark-mode-settings/feature.md` landed on disk — written
by the **main agent** from the PM's returned text, not by the PM. This is why
the pipeline *appears* to work in day-to-day Claude Code use: the
orchestrating model silently absorbs the write the PM's prompt assigns to the
PM. Conclusion: §1.1 is a real inconsistency but not a breakage — the fix
(grant `Write`) makes the contract explicit instead of relying on
orchestrator recovery.

### Setup B — Claude Code plugin only (no `install.sh`)

Marketplace add + `plugin install agentic-dev-team@adt-pipeline` succeeded;
`/plan-design` ran end-to-end in a project with **no `.claude/` directory at
all** and produced a complete, well-formed 626-line
`implementation-plan.md` (all four sections, UI Selectors table, 32 testTag
references, intact nested code fences).

Transcript observations:

| Observation | Finding it validates |
|---|---|
| Plugin cache contains only `agents/`, `commands/`, `.claude-plugin/` — no pipeline doc | §1.2 |
| Orchestrator: `Read .claude/AGENTIC_DEV_TEAM_PIPELINE.md` → "File does not exist" → `Glob` → **`find / -iname …`** across the filesystem before locating a copy outside the project | §1.2 (per-run recovery cost; recovery not guaranteed on machines without a full clone) |
| Architect subagent never read the pipeline doc at all | §1.2 / §2.1 (the "Required Reading" contract is aspirational under the plugin install) |
| Architect: `Skill: styles` → `Unknown skill: styles` error | §1.7 |
| Architect wrote the plan itself via `Bash` (`mkdir -p` + `cat >` heredoc), content intact | §1.1 (Bash is a workable write path for Architect/Tester; only the PM has none) |

Net: both install paths work in practice — this plan's changes remove the
recovery turns, silent skips, and orchestrator improvisation that make them
work, which cost tokens on every run and are one uncooperative
model-response away from failing.

---

# Part II — `/on-call`: Production-Driven Pipeline Entry Point

**Status**: Design spec — decisions pinned where possible; items requiring
external verification are marked **VERIFY** and listed in §6. Implementation
should follow the phasing in §8 (after Part I lands, and sharing a
prerequisite with Part IV §1).
**Scope**: two new agents (`adt-android-triager`, `adt-android-reproducer`),
one new command (`/on-call`), one config file (`.adt/on-call.yaml`), and the
cross-tool stubs/packaging the extension recipe in `HOW_IT_WORKS.md` requires.
User-facing documentation changes are pinned in Part V §4.

## 0. Positioning — why this capability

Every pipeline command today starts from a **human prompt**. `/on-call`
starts from the **live app**: a crash cluster, ANR spike, or vitals
regression becomes the pipeline's input, and a verified fix PR is its
output, with no human in between (unless the config says so).

The surrounding ecosystem makes this the right bet now:

- [Firebase Crashlytics MCP tools](https://firebase.google.com/docs/crashlytics/ai-assistance-mcp)
  (official) expose prioritized issues, stack traces, and event metadata to
  agents — but as a *conversational assist* ("ask about this crash").
- [gplay CLI](https://github.com/tamtom/play-console-cli) exposes Play
  Console (vitals, staged rollouts) to agents — but as a *toolbox*.
- auto-mobile (already a pipeline dependency) drives real devices.

Nobody composes these into an unattended loop with a **reproduction gate**
(no fix without a locally observed failure) and **rollout guardrails**. The
loop is structurally Android — staged rollouts, Play vitals thresholds,
R8 mapping deobfuscation, device-population diversity — which is why no
general-purpose agent framework will drift into it. That composition is the
tool's distinguishing capability; the point tools are commodities.

## 1. Trigger model

The command is identical in all modes; only the invoker changes. Guardrails
(§5) live in the command, not the trigger, so every mode is equally safe.

| Mode | Invoker | Ships in |
|---|---|---|
| **Manual** | Developer runs `/on-call` in Claude Code / Antigravity / opencode | v1 |
| **Scheduled** | Cron (GitHub Actions or any scheduler) runs headless Claude Code: `claude -p "/on-call"` | v1 (workflow template in `docs/examples/`) |
| **Event-driven** | Crashlytics velocity alert → Cloud Function → repository-dispatch of the same workflow | v2, optional; **VERIFY** alert webhook path |

One cycle per invocation: triage → reproduce → fix → verify → deliver →
stop. The scheduled mode gets autonomy from repetition, not from looping
inside the command. Manual mode behaves like `/build-guided` (gates pause
for the human); scheduled mode behaves like `/build-auto-reviewed`
(reviewer gates only, bounded, stop-and-report on failure).

**Shared-machine caveat.** Scheduled and event-driven runs drive the device
while a human may be using it — a velocity-alert firing at 2pm will
reinstall over whatever the developer is debugging. Until the device-lease
protocol of Part IV §3 is in place, document scheduled mode as requiring a
dedicated device or an off-hours window; with it, background runs queue
behind the human instead of interrupting them.

## 2. New agent: `adt-android-triager`

**Persona**: the on-call engineer who decides *what deserves attention*,
not how to fix it.

**Tools**: `Read, Glob, Grep, Write, Bash, mcp__firebase__*` (Crashlytics
MCP; exact server/tool names **VERIFY** §6.1). gplay CLI is invoked via
Bash when configured.

**Input**: `.adt/on-call.yaml` (§5), plus the delivery-dedupe check result
passed by the orchestrator.

**Behavior**:
1. Pull the current issue list (Crashlytics prioritized issues; vitals
   deltas via gplay when configured).
2. Filter by the config's severity floor; drop issues that already have an
   open delivery (dedupe is the orchestrator's job — §4 phase 0 — the
   Triager just respects the exclusion list it's given).
3. Select **exactly one** issue (highest user impact; ANRs outrank crashes
   at equal volume because they gate Play visibility).
4. Write `pipeline_artifacts/on-call/{issue-slug}/bug.md` with pinned
   sections: **Issue** (Crashlytics ID + link), **Impact** (users affected,
   event velocity, first/last seen, affected versions), **Device profile**
   (modal API level, device class, locale, orientation from event
   metadata), **Stack trace** (deobfuscated — §6.2), **Repro hypothesis**
   (numbered steps the Reproducer will attempt first), **Acceptance
   criteria** (observable condition that defines "fixed").
5. If nothing clears the severity floor: write a one-paragraph
   `healthy.md` report and signal ✅ TRIAGE CLEAN — the command ends. A
   quiet night is a successful run, not a failure.

`bug.md` is to `/on-call` what `feature.md` is to `/build-guided`: the
contract artifact the rest of the pipeline consumes.

## 3. New agent: `adt-android-reproducer`

**Persona**: the skeptic. Its job is to make the bug happen on hardware it
controls, and to refuse to let the pipeline continue if it can't.

**Tools**: `Read, Write, Bash, mcp__auto-mobile__*`.

**Behavior**:
1. **Device match**: select or create an emulator approximating `bug.md`'s
   device profile — API level exactly; locale and font scale via `adb`;
   device class (screen size/density) via the closest AVD definition. OEM
   skins are explicitly out of scope — document "closest-profile rule" in
   the prompt. (**VERIFY** §6.3: AVD creation from the command line in the
   consuming project's environment.)
2. **Reproduce**: drive the app via auto-mobile following the repro
   hypothesis; where the hypothesis fails, form a new one from the stack
   trace and app state — **at most 3 hypothesis rounds** (config §5), then
   stop.
3. **On success**: capture the failure evidence (screenshot/screen
   recording + logcat excerpt showing the crash/ANR), and persist the
   reproduction as a replayable failing test plan at
   `pipeline_artifacts/on-call/{issue-slug}/repro-plan.yaml` — this reuses
   the recording → export mechanism of Part IV §1.3
   and inherits its schema-verification prerequisite. Signal
   ✅ REPRODUCED.
4. **On failure after the bounded attempts**: write
   `no-repro.md` (what was attempted, what was observed, best current
   hypothesis) and signal ⛔ NOT REPRODUCED. **The pipeline never proceeds
   to a fix without a reproduction.** In `delivery.mode: pr` runs, the
   orchestrator downgrades delivery to a triage issue (§4 phase 6) so the
   investigation isn't lost.

The reproduction gate is the spec's central invariant. It is what
separates this from "LLM reads a stack trace and guesses": the fix phase
starts from a failing, replayable test, and the verify phase has an
unambiguous green condition.

## 4. New command: `/on-call` — orchestration

Phases (existing agents reused unchanged wherever possible):

- **Phase 0 — Preflight**: config file exists (else print setup
  instructions and stop); Crashlytics MCP reachable; budget check
  (`issues_per_run`, `max_runs_per_day` — the latter enforced by counting
  today's `adt-on-call`-labeled deliveries); build dedupe exclusion list
  by searching open PRs/issues labeled `adt-on-call` whose body contains a
  Crashlytics issue ID (stateless dedupe — no local state file to drift).
- **Phase 1 — Triage**: delegate to `adt-android-triager`. On ✅ TRIAGE
  CLEAN, end the run.
- **Phase 2 — Reproduce**: delegate to `adt-android-reproducer`. On
  ⛔ NOT REPRODUCED, skip to Phase 6 in triage-issue mode.
- **Phase 3 — Plan**: delegate to `adt-android-architect` in **fix mode**:
  input is `bug.md` + `repro-plan.yaml`; output is a lite plan (root-cause
  analysis, fix design, test additions) — same artifact path and grammar
  as a feature plan so every downstream consumer works unchanged. The
  architect-reviewer gate applies as in `/build-auto-reviewed`.
- **Phase 4 — Implement**: delegate to `adt-android-coder`; code-reviewer
  gate applies; build gate as defined in the pipeline doc.
- **Phase 5 — Verify**: delegate to `adt-android-tester`. Green condition
  is pinned: `repro-plan.yaml` **must now pass** (the previously failing
  assertion holds), plus the standard regression sanity per the pipeline
  doc. The bounded NEEDS FIXES → Coder loop from Part I §4.3
  applies. On success, the repro plan is promoted into the committed
  `test-plans/` regression library (Part IV §1.4) —
  a fixed bug becomes a permanent regression test.
- **Phase 6 — Deliver**: per `delivery.mode`:
  - `pr` (default): branch `on-call/{issue-slug}`, commit, push, open a PR
    labeled `adt-on-call` whose body embeds: impact summary from `bug.md`,
    before-evidence (failing state), the fix summary, after-evidence
    (passing replay), and the run-report. In manual mode, pause for
    confirmation before pushing; in scheduled mode, proceed.
  - `issue`: open a GitHub issue carrying the triage/repro artifacts
    (also the automatic downgrade path for ⛔ NOT REPRODUCED).
- **Phase 7 — Rollout advice**: if the affected version is in a staged
  rollout (gplay), append to the PR body a **Rollout recommendation**
  section (halt / hold / continue, with the numbers). Only if
  `rollout.action: halt` is explicitly configured does the pipeline
  execute the halt via gplay — and it reports having done so in the PR
  body. Default is recommend-only.

## 5. Config: `.adt/on-call.yaml` (pinned schema)

```yaml
severity:
  min_users_affected: 50        # ignore clusters below this
  vitals:                        # optional; requires gplay
    crash_rate_pct: 1.1          # Play bad-behavior thresholds
    anr_rate_pct: 0.47
budget:
  issues_per_run: 1              # fixed at 1 in v1; key reserved
  max_runs_per_day: 4
  max_repro_attempts: 3
rollout:
  action: recommend              # recommend | halt
delivery:
  mode: pr                       # pr | issue
  label: adt-on-call
```

Config lives in the **consuming project** (committed — it's team policy,
not per-developer state). Absence of the file is the off switch: `/on-call`
without config prints setup instructions and exits. The `.adt/` directory
is new; nothing else claims it.

## 6. External verification prerequisites (before implementation)

1. **Crashlytics MCP surface**: exact server registration, tool names, and
   whether issue lists include the per-event device metadata (API level,
   locale, device class) the Triager's device-profile section needs.
   Verified against a live Firebase project.
2. **Deobfuscation path**: Crashlytics serves deobfuscated traces when the
   R8 mapping was uploaded. Confirm via MCP output; specify local
   `retrace` from the project's mapping file as the documented fallback,
   and pin which the prompt prefers.
3. **Emulator provisioning**: `avdmanager`/`sdkmanager` availability in
   consuming projects for API-matched AVD creation, and auto-mobile's
   behavior against a freshly created AVD. Fallback rule if provisioning
   is unavailable: run on the currently connected device and record the
   profile mismatch in `bug.md`.
4. **gplay CLI**: auth model (service account) and the minimal read scopes
   for vitals + rollout status; the halt call used by `rollout.action:
   halt`.
5. **auto-mobile plan schema**: shared prerequisite with
   Part IV §1 — the Reproducer's failing-plan
   artifact and the Tester's green condition both depend on it. Verify
   once, unblock both.

## 7. Cross-tool story

Follows `HOW_IT_WORKS.md`'s extension recipe: canonical prompts at
`.claude/agents/adt-android-{triager,reproducer}.md` and
`.claude/commands/on-call.md`; `.opencode/` stubs, `.agents/workflows/`
symlink, persona stubs in `.agents/AGENTIC_DEV_TEAM.md`; plugin version
bump. Manual mode works in all three tools (the new agents use the same
Read/Write/Bash/MCP surface as existing ones). **Scheduled and
event-driven modes are documented as Claude Code headless only** in v1 —
Antigravity and opencode have no equivalent headless entry point; the docs
say so plainly rather than pretending parity.

## 8. Phasing

| Step | What ships | Depends on |
|---|---|---|
| 0 | Part I main plan | — |
| 1 | auto-mobile plan-schema verification (§6.5) | — (unblocks this part **and** Part IV §1) |
| 2 | Triager + `bug.md` + `/on-call` phases 0–1 + config | §6.1 |
| 3 | Reproducer + phases 2, 6-as-issue (triage+repro only, delivery as issue) | steps 1–2, §6.2–6.3 |
| 4 | Full loop: phases 3–6, PR delivery, regression promotion | step 3 |
| 5 | Rollout advice (phase 7) + scheduled-mode workflow template | §6.4 |
| 6 | Event-driven trigger | step 5 |

Step 3 is independently shippable and already valuable: "every morning
there's a triaged, locally-reproduced bug report with a replayable failing
test attached" is a real product before any auto-fixing exists — and it
builds trust in the reproduction gate before the pipeline is allowed to
write code from it.

## 9. Explicit non-goals (v1)

- Multiple issues per run (backlog-draining loops) — one cycle per
  invocation keeps cost and blast radius inspectable.
- Auto-merge of on-call PRs — a human merges, always.
- OEM-exact device reproduction — closest-profile rule, stated in
  `bug.md`.
- Non-crash signals (bad reviews, uninstall spikes) — the Triager's input
  set can grow later; the loop doesn't change.

---

# Part III — `/design-doc`: The Human-Facing Design Artifact

**Status**: Design spec — decisions pinned. No external dependencies; this
part can ship immediately after Part I.
**Scope**: one new agent (`adt-android-design-writer`), one new command
(`/design-doc`), one new artifact (`design-doc.md`), one addition to the
Architect's plan template, and integration points in the three build
commands. User-facing documentation changes are pinned in Part V §3.

## 1. The gap this closes

Every artifact the pipeline produces today is written **for the next
agent**. `implementation-plan.md` is the clearest case: the live validation
run in Part I §6 produced a **626-line** plan with a UI-selector table and
32 testTag references — exactly right as a Coder contract, and exactly wrong
as something a senior engineer reads to decide whether the approach is
sound.

That mismatch has two costs:

1. **The `/build-guided` plan gate asks for a decision on a document
   written for a different reader.** Part I §4.4 already concedes this by
   replacing the gate's section-heading dump with a hand-assembled "decision
   digest" — a design doc in embryo, generated inline by the orchestrator
   and thrown away.
2. **Unattended runs produce nothing a team can review at design
   altitude.** `/build-auto-reviewed` reviews the plan with another *agent*
   and hands a human a diff. Engineering organizations do not adopt work
   they can only evaluate as a diff — they adopt work that arrived through
   the review ritual they already run: a design doc, read before the code
   exists, when changing course is still cheap.

The pipeline is already generating the raw material for that document
(PM Decision Log, Architect Confidence & Risk, file lists, test plan). It
just never assembles it for a human.

## 2. What makes this more than a summary

A summarizer adds nothing — a human can skim the plan's headings. The
design doc earns its place only if it carries **information the plan does
not have**: the alternatives that were considered and rejected, and why.

The Architect necessarily weighs alternatives while planning (Room vs
DataStore, new screen vs bottom sheet, Flow vs callback) and currently
discards that reasoning — it writes the winner. Recovering it is nearly
free (the reasoning happened) and is precisely what a reviewer needs to
either agree or say "you dismissed option B too fast."

**DECIDED CHANGE — Architect plan template addition** (a sibling of the
`## Confidence & Risk` section added in Part I §4.6, and a prerequisite for
this part):

```
## Alternatives Considered
- <approach>: <one line on what it would look like> — Rejected: <why>
- <approach>: <one line> — Rejected: <why>
(If a decision was close, say so and name what would flip it.)
```

Minimum two entries when the plan makes any structural choice; "none — the
codebase's existing pattern determined the approach" is an acceptable
single entry when true, and is itself useful signal to a reviewer.

## 3. New agent: `adt-android-design-writer`

**Persona**: the staff engineer who writes the RFC. Explains, does not
instruct.

**Tools**: `Read, Write, Glob, Grep`. No Bash, no device access — it reads
artifacts and code, and writes one file. Cheap phase; a fast model is
appropriate (documented as a recommendation, since Antigravity and opencode
cannot set per-agent models).

**Inputs**: `implementation-plan.md` (required), `feature.md` (when the run
had a PM phase), and the codebase for verifying its claims about current
behavior.

**Output**: `pipeline_artifacts/{slug}/design-doc.md`.

**Pinned template**:

```markdown
# Design: <feature name>

## Summary
<3–5 sentences: what changes, for whom, and the shape of the approach.>

## Problem & Context
<The user-visible need or defect; how the app behaves today, with file
references for any claim about current behavior.>

## Goals / Non-Goals
- Goal: <…>
- Non-goal: <explicitly out of scope, so review does not relitigate it>

## Proposed Design
<Prose explanation of the approach, plus one diagram (mermaid or ASCII)
showing data flow or component interaction. No file-by-file steps.>

## Alternatives Considered
<From the plan's Alternatives Considered section, expanded to one short
paragraph each.>

## Blast Radius
- Modules / layers touched: <…>
- Public API or interface changes: <…>
- Schema / migration changes: <…>
- New dependencies: <name, why, and what it costs>
- Permissions, minSdk, or build-config implications: <…>

## Risks & Mitigations
<From the plan's Confidence & Risk section, in reviewer-facing terms.>

## Testing Strategy
<What will prove this works — the *shape* of verification, not the steps.>

## Rollout & Reversibility
<Feature-flagged? Staged? How is this reverted if it misbehaves in
production?>

## Open Questions
<From the PM's Open Questions and the plan's "Assumed (not verified)" list.
Empty is a valid answer; say so explicitly.>
```

**Pinned constraints** (these are the difference between a document people
read and one they skip):

> - Target 800–1200 words. A design doc nobody finishes is worse than none.
> - Write for an engineer who knows Android well and this codebase not at
>   all.
> - Explain and justify; never instruct. No testTags, no selector tables,
>   no file-by-file implementation steps.
> - Include at most one code block, at most 10 lines, and only when a
>   type signature or data shape is the clearest way to say it.
> - Every claim about how the app behaves today must cite a file path.
> - Do not invent rationale. If the plan does not say why, write "the plan
>   does not state why" — an honest gap is more useful to a reviewer than
>   plausible-sounding reconstruction.

## 4. New command: `/design-doc <plan path | slug>`

Runs only the design writer, then stops — the same shape as `/plan-research`
and `/plan-design`. Resolves its argument to an `implementation-plan.md`
(directly, or via `pipeline_artifacts/{slug}/`), delegates to
`adt-android-design-writer`, and reports the artifact path.

Naming note: the planning family is `plan-*`, but `/plan-doc` reads as a
near-synonym of `/plan-design` and would be mistyped for it constantly.
`/design-doc` names the output, matches industry vocabulary, and is worth
the small break in prefix symmetry.

## 5. Integration with the build commands

**DECIDED CHANGES**:

1. **`/build-guided`** — generate the design doc immediately after the
   Architect phase, before the plan gate. The gate then presents the design
   doc as the primary artifact. This **supersedes** Part I §4.4.1: instead
   of the orchestrator assembling a decision digest inline, the gate shows
   the design doc's **Summary**, **Alternatives Considered**, and **Blast
   Radius** sections, plus the parallel-safety decision and Coder count
   (which stay orchestrator-level facts, not design-doc content). The plan
   remains linked for anyone who wants the full detail.
2. **`/build-auto-reviewed`** — generate **after** the architect-reviewer
   gate passes, so the doc describes the approved design rather than a
   draft that was about to be bounced. Include the path in the final
   summary and in `run-report.md`.
3. **`/build-auto`** — generate after the Architect phase. On by default;
   `doc: off` in `$ARGUMENTS` skips the phase for speed-critical runs.
4. **Regeneration on drift** — if the plan gained `## Revision Notes`
   (reviewer bounces, Part I §3.3) or the Tester fix loop changed the
   implementation after the doc was written, regenerate the design doc at
   the end of the run so the committed artifact matches what was actually
   built. Cheap: one agent invocation over an existing artifact.

## 6. Anti-drift rule (v1)

Three artifacts describing one feature is two chances to disagree. The rule
is pinned in the pipeline doc's Part A:

> `design-doc.md` is a **derived** artifact. `implementation-plan.md`
> remains the sole contract for implementation; where the two disagree, the
> plan wins and the design doc is regenerated. Never hand-edit
> `design-doc.md` expecting the change to reach the Coder.

Human feedback flows through the approval gate (`revise: <feedback>`), not
through edits to the doc.

**Explicit v2 (not in scope now)**: *design-doc-driven revision* — a human
edits the design doc ("use approach B from Alternatives"), and the
Architect is re-run with the edited doc as authoritative input,
regenerating the plan. That inverts the derivation and is the natural
end-state of this feature, but it needs a conflict-resolution design
(what happens to plan sections the edit invalidates) before it is safe to
specify.

## 7. `/on-call` variant

For fix runs (Part II), the same agent emits a **fix brief** — the same
mechanism, a template variant: Summary, Impact (from `bug.md`), Root
Cause, Fix, Why This Fix And Not Others, Regression Risk, Verification.
This becomes the PR body for on-call deliveries (Part II §4 phase 6),
which currently assembles its narrative ad hoc. Ships with Part II step 4.

## 8. Why this is a differentiating capability

The agent-pipeline ecosystem is saturated with tools that make agents
produce *code* faster, and with agent-facing planning artifacts. What no
comparable tool produces is the artifact an engineering organization
actually gates work on: a design doc, written for humans, generated before
implementation, carrying the alternatives that were rejected.

It also changes where human attention is spent: from reviewing a diff
after the fact — the most expensive place to discover a wrong approach — to
reviewing a design before code exists. That is the argument for adopting
agentic development in a team setting, and it is made by an artifact rather
than a claim.

## 9. Phasing

| Step | What ships | Depends on |
|---|---|---|
| 1 | Architect `## Alternatives Considered` template addition (§2) | Part I PR 3 (same template touched by §4.6) |
| 2 | `adt-android-design-writer` + `/design-doc` standalone command | step 1 |
| 3 | `/build-guided` integration, superseding the §4.4.1 digest | step 2 |
| 4 | `/build-auto` + `/build-auto-reviewed` integration, regeneration on drift | step 2 |
| 5 | `/on-call` fix-brief variant | step 2 + Part II step 4 |

Steps 1–2 are independently useful: `/design-doc` run against any existing
plan produces a reviewable document with no other pipeline changes.

---

# Part IV — Deferred & Optional Integrations

Items kept out of Part I. §1 and §2 need design or verification work before
an agent can implement them unambiguously; §3 is fully specified but depends
on an **optional** external tool, so it ships as a graceful-degradation
protocol rather than a requirement. Nothing here blocks the changes in
Part I; each topic can be picked up independently later.

---

## 1. Making the Tester Fast: Reusable, Replayable Test Plans

**Why deferred**: the core mechanism depends on auto-mobile's plan file
schema and the exact semantics of `executePlan` / `startTestRecording` /
`exportPlan`, which must be verified against the
[kaeawc/auto-mobile](https://github.com/kaeawc/auto-mobile) documentation
(and ideally a live device session) before the Architect post-step and the
step-grammar → YAML mapping can be specified. Implementing this from
assumptions would bake in a wrong schema.

**Prerequisite task**: read auto-mobile's docs/source for the plan format;
confirm (a) the YAML step vocabulary (tap/type/assert by testTag), (b)
whether assertions can be embedded in plans and reported in the
`executePlan` result, (c) how plan files are addressed (path? name?), and
(d) what `exportPlan` emits. Then pin the mapping from the Architect's step
grammar (`Tap [testTag=x]`, `Type "…" into [testTag=y]`, assert
visible/absent) to that schema.

### 1.1 Where the time actually goes

The selector-driven redesign (testTags + "no observe when you have a
selector") already removed the worst cost — live screen discovery. What
remains, in order:

1. **One LLM round-trip per device action.** A 6-case plan × ~8 steps ≈ 50
   sequential model turns, each gated on MCP latency. Selectors made each
   turn cheaper; they didn't reduce the *number* of turns.
2. **Re-tests repeat almost everything.** The NEEDS FIXES → fix → re-test
   cycle re-drives the full suite interactively; the `executePlan` replay is
   currently best-effort and covers only the happy path.
3. **The regression sanity check is always interactive.**
4. `installDebug` (necessary; already incremental).

### 1.2 The core change: make the executable test plan a first-class artifact

Today the machine-readable plan exists only if the Tester happens to record
one, and it's never persisted contractually. Invert this:

- **The Architect's Manual Testing Plan steps already use a strict grammar**
  (`Tap [testTag=x]`, `Type "…" into [testTag=y]`, assert visible/absent).
  That grammar is mechanically translatable to auto-mobile's YAML plan
  format. Add an Architect post-step that emits
  `pipeline_artifacts/{slug}/test-plans/tc1-happy-path.yaml` … `tcN.yaml`
  alongside the prose plan (mechanical translation — it doesn't need design
  judgment, just the grammar).
- **The Tester executes each case with a single `executePlan` call** instead
  of driving step-by-step. Fifty model turns collapse to ~6 (one per case),
  plus reasoning turns only where a plan step fails or an edge case needs
  judgment. This is the biggest possible speedup — an order of magnitude on
  the happy paths.
- **The Tester's LLM budget is re-aimed at what actually needs a brain**:
  interpreting failures, choosing feature-relevant edge cases, and the
  verdict. Deterministic execution is delegated to the tool, where it
  belongs.
- Steps that genuinely need judgment (e.g. "verify the animation feels
  smooth", absence assertions without a selector) stay interactive — mark
  them `manual: true` in the prose plan so the compiler skips them and the
  Tester handles only those interactively.

### 1.3 Reuse across the re-test loop

Replace the current best-effort recording paragraph in the Tester prompt with
a contract:

- **First run**: execute the compiled YAML plans; for any case that needed
  interactive driving (selector gaps, judgment steps), record it
  (`startTestRecording` → `exportPlan`) and save the export into
  `pipeline_artifacts/{slug}/test-plans/`. After the first run, *every* case
  has a replayable artifact — not just the happy path.
- **Re-test after a fix**: replay **only** (a) previously-failed cases and
  (b) the happy path, via `executePlan`. Previously-passing cases are
  re-verified by replay only if the Coder's fix touched files in their
  feature area (the orchestrator can pass `git diff --stat` to the Tester).
  Do not re-derive edge cases on re-test — they're already in the plan
  directory.
- **Fail fast**: run the happy path first; if it fails, STOP and report
  immediately instead of burning the remaining cases on a build that's
  fundamentally broken.

(Note: the bounded Tester fix-loop itself — NEEDS FIXES → Coder → re-test,
max 2 rounds — is **not** deferred; it's Part I §4.3 and works
today with ordinary interactive re-testing. This section only makes the
re-test leg cheap.)

### 1.4 Reuse across features: a committed regression library

`pipeline_artifacts/` is gitignored (correctly — it's per-run scratch). Add a
promotion step: when a feature reaches READY TO MERGE, the Tester copies its
stable plans into a **committed** `test-plans/<surface>/` directory in the
consuming project. Then:

- The Tester's "light regression sanity check of one adjacent surface"
  becomes: `executePlan test-plans/<adjacent-surface>/happy-path.yaml` — one
  tool call, deterministic, seconds instead of minutes.
- Later features' Testers inherit an ever-growing replayable library at zero
  authoring cost, and a user can ask any flow's Tester to replay all of it —
  it's just `executePlan` calls over committed files.
- Plans self-heal cheaply: testTag selectors are stable by construction (the
  Architect mandates them), so plans survive refactors that don't change the
  UX contract; when one breaks, the Tester falls back to interactive driving
  for that case and re-records it.

This is the direct answer to "reuse test plans": persist them per-case,
replay them per-call, promote them per-surface.

### 1.5 Smaller levers

- **Device state setup via Bash, not UI.** Prefer `adb shell pm clear`,
  `cmd connectivity airplane-mode enable`, `am force-stop`, demo-mode for
  status bar — one Bash call replaces multi-step Settings-app navigation.
  Add a "Setup via adb, not via UI navigation" principle to the Tester.
  (This one has no schema dependency — it can be pulled into a main-plan
  phase early if desired.)
- **Model**: once execution is `executePlan`-driven, re-test runs are almost
  pure tool dispatch — they can run on haiku-class models. First runs keep
  sonnet for edge-case judgment. (Document as recommendation, since
  Antigravity/opencode can't set per-agent models anyway.)
- **Batch assertions into the plan**: if auto-mobile plan steps support
  assertions, put "assert [testTag=item_list] contains 'Test item'" *in the
  YAML* so pass/fail comes back in the `executePlan` result instead of a
  separate observe turn. (Depends on the schema verification above.)

### 1.6 What a fast run looks like after these changes

| Phase | Before | After |
|---|---|---|
| First full run (6 cases) | ~50 interactive turns | ~6 `executePlan` calls + edge-case turns |
| Re-test after fix | full suite, interactive | failed cases + happy path, replayed |
| Regression sanity | interactive smoke | 1 `executePlan` of saved plan |
| Failure handling | continue through suite | fail-fast on happy path |

---

## 2. Per-project `codebase-map.md` (shared discovery cache)

**Why deferred**: needs a decision on staleness handling (when is the map
refreshed, who owns it, what happens when it's wrong) before it's safe to
tell agents to trust it.

The idea: four agents independently re-survey the same codebase per feature
(PM scans entry points, Architect does a full survey, both reviewers
re-verify). A committed, per-project `codebase-map.md` (module list, nav
graph location, DI style, pattern exemplars) generated once and refreshed on
demand would let the PM and Architect start from it instead of cold
Glob/Grep sweeps. Part I §2.2 (trust the Architect's Section 1 as
the within-run cache) captures most of the win without the staleness
problem; this item is the cross-run extension.

---

## 3. Device contention: AdbHarbor integration (optional dependency)

[AdbHarbor](https://github.com/msomu/AdbHarbor) is a **lock broker for
shared Android devices** — not an MCP server. Its daemon takes over ADB's
default port 5037 (relocating the real server to 5038), inspects the
smart-socket protocol to see which device a connection targets, and gates
device-*mutating* operations behind per-session leases with a FIFO queue.
Read-only commands (`getprop`, `dumpsys`, `pm list`) are exempt. A PATH
shim adds progress messages ("waiting for device (held by X)") and exit
code **75** on lease timeout. Leases linger (default 5 min) across agent
think-time, and heartbeats reclaim leases from crashed sessions.

The architecturally important consequence: because it intercepts the port
rather than wrapping a tool, **auto-mobile, Gradle's `installDebug`, and
raw `adb` are all covered without modification**.

### 3.1 Why this pipeline specifically needs it

The pipeline has exactly one device and a growing number of things that
want to drive it:

1. **Scheduled `/on-call` versus the human at the keyboard** (Part II §1).
   This is the sharp one. Without a broker, the honest documentation for
   scheduled mode would have to read "do not run this on a machine you also
   develop on" — a 3am cron is fine, but a velocity-alert-triggered run at
   2pm will `force-stop` and reinstall over whatever the developer is
   debugging. With AdbHarbor the background run simply queues behind the
   human. **This is what makes unattended `/on-call` safe to enable on a
   developer's daily driver instead of requiring a dedicated device.**
2. **Reproducer versus Tester** (Part II §3 and the existing Tester). An
   on-call run and a feature build run overlap the moment both are in
   flight, and both phases are long — install, drive, assert.
3. **Concurrent feature runs.** The build commands already spawn parallel
   Coders; nothing stops a developer from running two features at once, and
   the Tester phases will collide.

Note what this is *not*: it does not make one Tester faster (that is §1),
and a solo developer running one command at a time needs nothing here. Its
value is entirely in concurrency and unattended operation.

### 3.2 Design principles

- **Optional and auto-detected — never a hard dependency.** If `adbharbor`
  is not on `PATH`, every agent behaves exactly as it does today. This
  matches the repo's install philosophy (non-destructive, additive) and
  keeps the auto-mobile prerequisite the only device-side requirement.
- **Define the protocol once**, in the pipeline doc's agent-facing Part A,
  under the name **"the device lease"** — the same consolidation decision
  made for the build gate (Part I §1.4) and the skills list (Part I §1.7).
  Both the Tester and the Reproducer reference it; neither restates it.
- **Lease per phase, not per command.** This is the subtle part. The port
  layer gates *individual* commands, so a phase without an explicit lease
  can be interleaved by another session *between* test steps — the Tester
  would tap through a screen another agent just reinstalled underneath it.
  Acquiring once for the whole device phase is what makes a multi-step test
  case atomic with respect to other sessions.

### 3.3 Pinned protocol — "the device lease"

Added to the pipeline doc's Part A, referenced by `adt-android-tester` and
`adt-android-reproducer`:

> **The device lease.** Before the first device-mutating action of a phase:
>
> 1. Run `command -v adbharbor`. If it is absent, proceed without leasing —
>    the broker is optional and its absence is not an error. Do not install
>    it.
> 2. Otherwise run `adbharbor acquire --any --ttl 45m` and record the
>    returned serial as `DEVICE_SERIAL`. Export `ANDROID_SERIAL` to that
>    value for every subsequent adb, Gradle, and auto-mobile action in the
>    phase, so no later command can drift onto a device you do not hold.
>    - **Exit code 75** (timeout): every device is leased by another
>      session. Run `adbharbor who` and STOP with the standard report,
>      naming the holder — do not proceed unleased.
>    - **No devices connected**: STOP with the standard report using a
>      distinct message; this is an environment problem, not contention.
> 3. Release at the end of the phase, on **both** the pass and fail paths:
>    `adbharbor release -s $DEVICE_SERIAL`.
> 4. If a device action fails mid-phase with a lease error, run
>    `adbharbor who -s $DEVICE_SERIAL` once. If the lease was reclaimed
>    (crash/heartbeat loss), re-acquire and re-run the failed test case
>    only. If another session now holds it, STOP with the standard report.
>
> Inspection commands are exempt from locking, so leasing concerns device
> mutation only — never wrap a read-only check in a lease.

The 45-minute TTL is chosen to cover a full multi-case Tester phase
including `installDebug` and re-tests; the broker's own lingering handles
per-turn think-time, so the agent never re-acquires between steps.

### 3.4 Session cleanup

`adbharbor cleanup on` auto-uninstalls packages installed during a session
before the device passes to the next waiter. **DECIDED RECOMMENDATION**
(documentation, not enforced by the pipeline): **on** for CI and scheduled
`/on-call` runs, so each unattended run starts from a clean device and does
not leave debug builds on a shared phone; **off** for local interactive
runs, where the developer usually wants the app left installed to poke at
after the Tester reports.

### 3.5 VERIFY before implementing

1. **auto-mobile's ADB path.** Confirm auto-mobile connects to the default
   server port and honors `ANDROID_SERIAL` (or exposes a device-selection
   parameter). AdbHarbor documents that clients hard-coding a non-default
   `ANDROID_ADB_SERVER_PORT` bypass the proxy — if auto-mobile does that,
   the lease becomes advisory for the auto-mobile leg and the protocol must
   say so plainly rather than implying protection it does not have.
2. **`acquire --any` output format**, so the serial can be parsed
   deterministically rather than by regex guesswork.
3. **Exit-code propagation.** Per the README, exit code 75 comes from the
   PATH shim layer; confirm an agent invoking `adbharbor acquire` directly
   via Bash observes it (the protocol above depends on that distinction).
4. **Non-macOS install path.** Homebrew is the documented install; confirm
   the `go install` path for Linux CI runners, since scheduled `/on-call`
   is the primary beneficiary.

### 3.6 Phasing

Ships after Part I PR 3 (it depends on the structured STOP report from
Part I §4.1) and before scheduled `/on-call` is recommended for shared
machines (Part II §1). Two steps: (a) the Part A protocol plus the Tester
reference, which is useful on its own for developers running concurrent
feature builds; (b) the Reproducer reference, with Part II.

---

# Part V — Documentation & Packaging Updates

User-facing docs must explain the repo's capabilities as they ship. Each
subsection below ships **in the same PR as the code it describes** (mapping
in the Unified implementation order table at the top). install.sh needs
**no changes** for any of this: it discovers files by globbing
`.claude/commands/*.md`, `.claude/agents/*.md`, `.agents/workflows/*.md`,
`.opencode/agents/*.md`, and `.opencode/commands/*.md` (verified —
install.sh lines 65–69), so creating the canonical files and stubs is
sufficient for the installer to sync them.

## 1. With Part I, PR 1 (correctness & packaging)

- `HOW_IT_WORKS.md`: add the one-line note from Part I §5 checklist item 4
  — the canonical pipeline doc now lives in `plugins/agentic-dev-team/`;
  the project-side path (`.claude/AGENTIC_DEV_TEAM_PIPELINE.md`) is
  unchanged.
- `.claude-plugin/marketplace.json`: bump `version` `0.1.0` → `0.2.0`
  (Part I §5 checklist item 5).
- `README.md`: no changes required.

## 2. With Part I, PR 3 (flow enhancements)

- `README.md`, `/build-auto` and `/build-auto-reviewed` sections — append:
  > You can also pass a path instead of a description: an existing
  > `implementation-plan.md` skips the Architect and goes straight to
  > implementation (the reviewed variant still reviews the plan first);
  > a `feature.md` is handed to the Architect. If a run for the same
  > feature already has artifacts under `pipeline_artifacts/<slug>/`, the
  > command resumes it at the right phase instead of starting over.
- `README.md`, `/build-guided` section — append:
  > By default every phase pauses for your approval. To pause only at
  > specific gates, pass a `gates:` directive:
  > `/build-guided gates: code,test add a recently-played carousel`.
- `HOW_IT_WORKS.md`: no change (behavioral, not structural).

## 3. With Part III (`/design-doc`)

### 3.1 `README.md`

1. New section, placed with the planning-only commands (it is one of them):

   > #### `/design-doc <plan path | slug>`
   >
   > Runs only the design writer. Turns an implementation plan into an
   > engineering design doc written for **humans**, at
   > `pipeline_artifacts/<slug>/design-doc.md` — summary, problem, the
   > approach and the alternatives that were rejected, blast radius, risks,
   > testing strategy, and rollout — then stops.
   >
   > ```
   > /design-doc pipeline_artifacts/recently-played-carousel/implementation-plan.md
   > ```
   >
   > The implementation plan is written for the Coder: hundreds of lines of
   > file-by-file steps and selectors. The design doc is written for the
   > engineer who has to agree with the approach before it gets built — and
   > it is generated automatically inside the build commands too, so
   > `/build-guided`'s approval gate asks you to review a design rather than
   > a specification.

2. `/build-guided` section — add after the existing description:
   > Before the plan gate, the pipeline generates a human-readable design
   > doc and shows you its summary, alternatives, and blast radius, so the
   > approval decision is made at design altitude.
3. `/build-auto` and `/build-auto-reviewed` sections — add:
   > Each run also produces `design-doc.md`, a human-readable write-up of
   > the approach for reviewing unattended work. Pass `doc: off` to skip
   > it.

### 3.2 `HOW_IT_WORKS.md`

1. Symlink table — add rows: `.claude/commands/design-doc.md`,
   `.claude/agents/adt-android-design-writer.md`,
   `.agents/workflows/design-doc.md`,
   `.opencode/commands/design-doc.md`,
   `.opencode/agents/adt-android-design-writer.md`.
2. "Claude Code discovery" list — add `/design-doc` and
   `@adt-android-design-writer`.
3. New subsection after "Project Context", titled **"Artifacts and their
   audiences"** — this is the conceptual point the repo currently never
   states:
   > Each phase writes one markdown artifact, and each artifact has exactly
   > one intended reader:
   >
   > | Artifact | Written by | Read by |
   > |---|---|---|
   > | `feature.md` | PM | Architect (and the human at the spec gate) |
   > | `implementation-plan.md` | Architect | Coder, reviewers, Tester |
   > | `design-doc.md` | Design writer | **Humans** — reviewers and future maintainers |
   > | `test-results.md` | Tester | Coder (on failures) and the human |
   > | `run-report.md` | Orchestrator | The human |
   >
   > `design-doc.md` is derived from the plan, never the other way around:
   > the plan stays the contract for implementation, and the design doc is
   > regenerated if they disagree.

### 3.3 Stubs & packaging

- `.agents/AGENTIC_DEV_TEAM.md`: persona stub for
  `@adt-android-design-writer`.
- `.opencode/agents/adt-android-design-writer.md`: `mode: subagent` stub
  reading the canonical prompt, description mirrored verbatim (Part I §5
  checklist item 2).
- `.claude-plugin/marketplace.json`: bump `0.2.0` → `0.3.0`.

## 4. With Part II (`/on-call`)

### 4.1 `README.md`

1. Intro paragraph: after the first sentence, add:
   > It also includes a production-driven entry point, `/on-call`, that
   > turns live crash reports into verified fix PRs.
2. New command section, after the planning-only commands (wording pinned;
   matches the README's existing voice):

   > ### `/on-call`
   >
   > Production-driven variant. Instead of a human prompt, the pipeline
   > starts from your app's live health signals — Crashlytics crash
   > clusters, ANR spikes, Play vitals regressions — and ends with a
   > verified fix PR.
   >
   > ```
   > /on-call
   > ```
   >
   > The Triager picks the single most impactful production issue and
   > writes a bug spec; the Reproducer makes the failure happen on an
   > emulator matched to the crash's device profile and saves it as a
   > replayable failing test — **no reproduction, no fix**: an
   > unreproduced issue is delivered as a triage report instead. The
   > Architect, Coder, and Tester then fix and verify it (the saved test
   > must pass), and a PR opens with the impact numbers, before/after
   > evidence, and run report attached. One issue per run. Configure via a
   > committed `.adt/on-call.yaml`; without it, the command prints setup
   > instructions and exits. Runs manually from the chat prompt, or
   > unattended on a schedule via headless Claude Code (workflow template
   > in `docs/examples/`).

3. Prerequisites section — add two bullets:
   > - **Firebase Crashlytics MCP tools** — required only for `/on-call`
   >   (crash/ANR triage). Register per the Firebase docs.
   > - **gplay CLI** *(optional)* — enables `/on-call`'s Play vitals triage
   >   and staged-rollout recommendations.
4. Plugin bullet in Installation: extend the command list with
   `/on-call`.

### 4.2 `HOW_IT_WORKS.md`

1. Symlink table — add rows (same pattern as existing entries):
   `.claude/commands/on-call.md`,
   `.claude/agents/adt-android-triager.md`,
   `.claude/agents/adt-android-reproducer.md`,
   `.agents/workflows/on-call.md`,
   `.opencode/commands/on-call.md`,
   `.opencode/agents/adt-android-triager.md`,
   `.opencode/agents/adt-android-reproducer.md`.
2. "Claude Code discovery" list — add `/on-call`, `@adt-android-triager`,
   `@adt-android-reproducer`.
3. New subsection after "Project Context", titled **"Production context
   (`/on-call`)"**:
   > `/on-call` reads a committed `.adt/on-call.yaml` in the consuming
   > project (severity floor, run budget, rollout policy — see the schema
   > in this repo's docs). The file is team policy, so it is **not** in
   > the managed `.gitignore` block; run artifacts under
   > `pipeline_artifacts/on-call/` are gitignored like every other run.
   > Promoted regression plans live in the committed `test-plans/`
   > directory.

### 4.3 Stubs & packaging

- `.agents/AGENTIC_DEV_TEAM.md`: add persona stub blocks for
  `@adt-android-triager` and `@adt-android-reproducer` (the install
  refreshes consuming projects' `agents.md` on next run).
- `.opencode/agents/`: `mode: subagent` stubs for both new agents, bodies
  reading the canonical `.claude/agents/` prompts, descriptions mirrored
  verbatim (Part I §5 checklist item 2).
- `.claude-plugin/marketplace.json`: bump `0.3.0` → `0.4.0`; the new
  agents/commands live under `plugins/agentic-dev-team/` so the
  `git-subdir` plugin packages them with no manifest shape change.
- `docs/examples/on-call-schedule.yml`: the GitHub Actions workflow
  template for scheduled headless runs (referenced from the README
  section above).

## 5. With Part IV §3 (AdbHarbor device lease)

- `README.md` Prerequisites — add one bullet, phrased so its optionality is
  unmistakable:
  > - **[AdbHarbor](https://github.com/msomu/AdbHarbor)** *(optional)* — a
  >   lock broker for shared Android devices. Not required for a single
  >   developer running one command at a time. Install it if you run
  >   pipeline commands concurrently, or if you enable scheduled
  >   `/on-call` on a machine you also develop on: the Tester and
  >   Reproducer will lease the device for the duration of their phase, so
  >   a background run queues behind you instead of reinstalling over your
  >   session. When it is not installed, the pipeline behaves exactly as
  >   before.
- `README.md` `/on-call` section — replace any "dedicated device" caveat
  with a pointer to the AdbHarbor bullet once the lease protocol ships.
- `HOW_IT_WORKS.md` — new short subsection under the production/device
  material:
  > **Device leasing.** When `adbharbor` is on `PATH`, device-driving
  > phases acquire a lease for the whole phase and release it at the end,
  > so multi-step test cases cannot be interleaved by another session. The
  > broker intercepts ADB's port, so auto-mobile, Gradle installs, and raw
  > `adb` are all covered without configuration. When it is absent, agents
  > skip leasing entirely — it is never installed automatically.
- No `install.sh` change: AdbHarbor is a per-developer machine tool
  (Homebrew / `go install`), like auto-mobile — not a per-project file.

## 6. With Part IV §1–§2 (when picked up)

- `README.md`: in the Tester-related prose, mention that verification
  replays committed plans from `test-plans/` when they exist.
- `HOW_IT_WORKS.md`: document the `test-plans/<surface>/` promotion
  convention (committed, per-surface, replayable) alongside the
  Production-context subsection.
