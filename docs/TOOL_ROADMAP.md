# Tool Roadmap: Novel Capabilities for the Pipeline Itself

Candidate next-generation capabilities for the tool, sequenced after PR #3
(codebase review + efficiency plan) lands. Everything here changes what the
pipeline *can do*, not how it is presented.

Two organizing themes:

- **Theme 1 — Push more phases onto the device.** The pipeline's unique
  asset is the auto-mobile device loop, and today only one of four phases
  (Tester) uses it. Specs are written blind, bugs are fixed unproven, and
  UI is verified only functionally. Every phase that gains device access
  gains a capability no text-only pipeline can copy.
- **Theme 2 — Scale out from "one feature per run".** The current tool runs
  one feature at a time from a slash command. Real team workloads are
  backlogs, bug queues, review feedback, and large migrations.

## Theme 1: Device-native phases

### 1.1 `/fix` — reproduction-first bug pipeline

A new command and a new agent, `adt-android-reproducer`, implementing
red/green TDD *on the device*:

1. **Reproduce (red).** Input is a bug report, stack trace, or "the app
   does X when it should do Y". The Reproducer drives the installed app via
   auto-mobile until it observes the failure, then compiles the
   reproduction into a failing artifact: an auto-mobile YAML plan with an
   assertion that currently fails (or an instrumented test where the bug is
   below the UI). If it cannot reproduce, the pipeline **stops and reports**
  — no speculative fixes, ever.
2. **Fix.** Architect (lite variant: diagnosis + fix plan, not a full
   feature plan) → Coder, as today.
3. **Verify (green).** Tester re-runs the reproduction plan (must now
   pass) plus the standard verification, then commits the repro plan into
   the project's regression library (`test-plans/`, already specified in
   ADDITIONAL-IMPROVEMENTS.md) so the bug can never silently return.

Artifacts: `pipeline_artifacts/<slug>/repro-plan.yaml`, before/after
screenshots of the failing and passing states.

Why it's novel: every coding agent "fixes bugs"; none are required to
**prove the bug exists on a real device before touching code, and prove
its absence after**. This single command is arguably a stronger reason to
install the tool than the feature pipeline itself — bug queues are bigger
than feature backlogs.

### 1.2 Device-grounded PM

Today the PM writes `feature.md` from the idea plus static code reading —
it specs an app it has never seen running. Give the PM (in `/build-guided`
and `/plan-research`) auto-mobile access with an explicit exploration
budget:

- Launch the app, navigate to the screens the feature touches, screenshot
  them, and embed the screenshots plus observed UX facts into `feature.md`
  ("the home screen currently has no horizontal container; the toolbar
  already hosts an overflow menu").
- Clarifying questions to the human become concrete: "should the carousel
  replace this section (screenshot) or sit above it?"

Specs stop hallucinating UI that doesn't exist, and downstream Architect
bounces from spec/reality mismatch disappear. Cheap to build — the Tester's
device-setup protocol already exists to be reused — and it makes the tool's
PM meaningfully different from every text-only PM agent.

### 1.3 Visual verification loop (Designer gate for UI)

For UI-touching features, add an optional visual closed loop:

- The Architect's plan gains a **UI spec section**: screen states,
  layout intent, and which existing theme tokens/components to reuse
  (pulled from the project's actual theme files). An optional reference
  image (mock, sketch, competitor screenshot) can be attached to the
  command.
- The Tester captures per-state screenshots via auto-mobile and does a
  **vision comparison** against the UI spec / reference: layout structure,
  states present, obvious defects (clipped text, wrong theme in dark
  mode). Mismatch = NEEDS FIXES with the annotated screenshot attached,
  feeding the bounded Tester → Coder loop PR #3 defines.

Functional testing says "the button works"; this says "the screen is
right". No agent pipeline closes the visual loop on a real device today.

### 1.4 Device-matrix Tester

Once the Tester compiles test cases to auto-mobile YAML plans
(ADDITIONAL-IMPROVEMENTS.md), executing a plan against one emulator or
five is the same work. Add a per-project matrix config:

```yaml
# .adt/matrix.yaml (optional; default = single current device)
configs:
  - { api: 35 }
  - { api: 28 }                      # minSdk reality check
  - { api: 35, night: true }         # dark mode
  - { api: 35, fontScale: 2.0 }      # accessibility
  - { api: 35, locale: ar }          # RTL
```

The Tester fans the compiled plan out across configs (parallel emulators
where available, serial otherwise) and reports a pass/fail matrix in
`run-report.md`. Dark-mode, RTL, and font-scale regressions — the classic
"works on my emulator" class — become something the pipeline catches by
default. This is where "agent team" beats "one agent" most visibly: the
marginal cost of the extra configs is near zero because the plan is
compiled once.

## Theme 2: Team-scale workloads

### 2.1 `/migrate` — sharded large-scale refactors

The workload where multi-agent genuinely beats single-agent, and no
current command covers it: mechanical, codebase-wide migrations
(LiveData → Flow, XML → Compose screen-by-screen, Groovy → Kotlin DSL,
dependency major-version bumps).

- A **Migration Planner** (Architect variant) inventories all occurrences,
  derives the transformation recipe from 2–3 hand-verified exemplar
  conversions, and shards the remainder into independent units (by module
  / package / screen) with an explicit "does not shard cleanly" list for
  human triage.
- **Parallel Coders** each take a shard in an isolated git worktree; the
  per-shard gate is the single Gradle invocation PR #3 pins, scoped to the
  shard's module.
- An **Integrator** merges shards in dependency order, resolves mechanical
  conflicts, runs the full build gate, and hands the merged result to the
  Tester for a smoke pass of the affected screens.

Progress is checkpointed per shard, so a 200-file migration survives
session death and resumes where it stopped. This reuses PR #3's
parallel-safety machinery but inverts the shape: instead of one feature
split into sections, one recipe applied across N shards.

### 2.2 Steward mode — issue-to-PR autonomy

Turn the tool from a slash command a developer runs into a teammate the
team assigns work to:

- Label a GitHub issue `adt:build` (or `adt:fix`) → a trigger runs the
  matching pipeline headless against a fresh branch and opens a PR whose
  body embeds the run artifacts (spec, plan, test evidence).
- **`/address-review`** — the missing half of PR-based work: given a PR
  with human review comments, map each review thread to the plan section
  and diff hunks it concerns, re-run the Coder with that scoped context
  (not the whole plan), push, and reply on resolved threads. Bounded like
  the reviewer gates: unresolvable feedback stops and reports rather than
  thrashing.

The pipeline already produces the artifacts that make an agent PR
reviewable; steward mode is what makes them *arrive* the way a teammate's
work arrives. `/address-review` is also independently useful for PRs a
human wrote.

### 2.3 Per-role model routing

An optional `.adt/models.yaml` mapping roles to models with an escalation
rule: reviewers and the PM run on a fast/cheap model; Architect and Coder
on the strongest; any gate bounce escalates the producing agent's model
one tier for the re-run. In Claude Code this is per-agent `model:`
frontmatter driven by config; Antigravity and opencode fall back to the
selected model (documented, not hacked around). Reviewed-mode runs are the
tool's most expensive path; this is the lever that makes
`/build-auto-reviewed` the default instead of the splurge.

## Sequencing

| Order | Capability | Depends on | Notes |
|---|---|---|---|
| 0 | Land PR #3 | — | gates, resume, run-report, tester-plan substrate |
| 1 | 1.1 `/fix` | Tester YAML plans (deferred work) | biggest new user-facing verb |
| 2 | 1.2 device-grounded PM | Tester's device-setup protocol | small, high leverage |
| 3 | 1.4 device matrix | Tester YAML plans | near-free once plans compile |
| 4 | 2.2 `/address-review` | — | independently useful; steward trigger after |
| 5 | 1.3 visual loop | 1.2 patterns | needs vision-comparison prompt design |
| 6 | 2.1 `/migrate` | PR #3 parallel-safety | largest build; ship after the above |
| 7 | 2.3 model routing | — | anytime; config + docs |

`/fix` first: it shares its hard dependency (compiled auto-mobile plans)
with the matrix Tester, it exercises the regression library, and it gives
the tool a second headline verb — *build* features and *prove* fixes —
that no comparable pipeline has.
