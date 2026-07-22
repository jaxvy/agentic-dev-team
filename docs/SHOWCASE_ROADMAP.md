# Showcase Roadmap: From Useful Pipeline to Field-Leading Proof

This document answers one question: **what should this repo do differently —
and novelly — to become an exemplar showcase of agentic AI development
leadership?** It assumes PR #3 (codebase review + efficiency plan) lands
first; everything here builds on top of it.

## 1. The honest diagnosis

What this repo already does well is rarer than it looks:

- **Cross-harness portability.** The same agent team runs identically in
  Claude Code, Antigravity, and opencode. Almost every "agent team" repo is
  welded to one framework.
- **Real-device verification.** The Tester drives an actual Android
  device/emulator through the auto-mobile MCP. Most pipelines stop at "the
  code compiles."
- **Empirical rigor.** PR #3's findings were validated with live headless
  runs against a mock project, not armchair prompt review.

What it lacks is what every agent repo lacks — and that gap is exactly the
opportunity:

- **No proof of work.** There is no artifact a stranger can inspect in five
  minutes and conclude "this pipeline actually ships features."
- **No numbers.** No success rate, no cost per feature, no comparison
  against a plain single-agent baseline. Every claim is prose.
- **No compounding.** Run #50 is no smarter or cheaper than run #1. Nothing
  learned in one run survives into the next.

The thesis of this roadmap: **a showcase is made of receipts, not
features.** The field is drowning in orchestration frameworks; it is
starving for evidence. The person who publishes hard, reproducible numbers
for their own agent pipeline — including where it loses — reads as a leader.
Everyone else reads as a demo.

Three pillars, in priority order: **Proof of Work**, **Measurement**,
**Self-Improvement**. Each is a workstream below, with two supporting
workstreams after.

## 2. Workstream A — The receipts app (Proof of Work)

**The single highest-leverage move.** Create a companion repo (e.g.
`adt-showcase-app`): a small but real Android app in which **every feature
was built by this pipeline, with the PR as the receipt.**

Each feature lands as a PR that embeds:

- the `feature.md` and `implementation-plan.md` from `pipeline_artifacts/`
- the Tester's **device screenshots / screen recording** captured via
  auto-mobile during verification
- the `run-report.md` (PR #3 introduces it): phase timings, token cost in
  dollars, reviewer bounce count, which command variant ran
- a one-line honesty ledger: what the pipeline did unaided vs. where a
  human intervened

The app's README is a table: *feature → PR → cost → wall time → verified
on device*. A recruiter, peer, or conference reviewer clicks any row and
sees the entire agentic lifecycle of that feature — spec, plan, diff,
review bounces, on-device evidence, price tag.

Why this is novel: "built with AI" claims are everywhere;
**per-feature audit trails with device-level evidence and cost accounting
are essentially nonexistent.** This is the artifact nobody else has.

Implementation notes:

- Add a final "publish" step to the build commands: after Tester passes,
  assemble the PR body from the run's artifacts (a `run-report.md` →
  PR-body template; mostly string assembly, cheap to build).
- Have auto-mobile save screenshots at each test-case assertion; commit
  them under `pipeline_artifacts/<slug>/evidence/`.
- Seed the app with 5–8 features of increasing difficulty (a settings
  screen → a Room-backed offline cache → a WorkManager sync job) so the
  table shows the pipeline's ceiling, not just its floor.

## 3. Workstream B — Eval harness + public scorecard (Measurement)

Treat the pipeline the way serious teams treat models: **it has an eval
suite, and the README shows the current scores.**

- **Task suite.** 10–15 pinned feature tasks against the mock Android
  project already used in PR #3's validation. Each task has a machine-
  checkable pass condition (build green + named tests pass + a scripted
  auto-mobile assertion).
- **Runner.** Headless Claude Code (`claude -p`) executes each task per
  pipeline variant; a small script scores the results. Metrics per task:
  pass/fail, tokens, dollars, wall time, reviewer bounces, human
  interventions (always 0 in headless mode — that's the point).
- **Baselines.** Run the same tasks with plain single-agent Claude Code
  (no pipeline) and with `/build-auto` vs `/build-auto-reviewed`. Publish
  the comparison. If the reviewed variant costs 2.3× and lifts pass rate
  from 60% → 85%, *that number* is the most quotable sentence you will
  ever produce about this project. If plain Claude Code wins on some
  tasks, publish that too — selective reporting is what everyone else
  does, and it's why nobody trusts agent-repo claims.
- **Scorecard surface.** A GitHub Actions workflow (manual dispatch +
  weekly cron; it costs real tokens) writes `evals/results/*.json` and
  regenerates a scorecard: a README badge/table plus a GitHub Pages
  dashboard with trends over time. Every prompt change in this repo
  becomes measurable: **"CI for agents" — a regression suite for prompt
  edits.** No public repo in this niche has that.

This also solves your kangentic.com itch without a domain: the GitHub
Pages dashboard *is* the site, and it's better than a landing page because
it's live evidence.

## 4. Workstream C — The pipeline that improves itself (Self-Improvement)

The most conceptually novel piece, and it becomes cheap once A and B
exist: a `/retro` command with an `adt-retro-analyst` agent.

- **Input:** the run-reports and transcripts of the last N runs (from the
  showcase app and/or eval runs).
- **Output:** a diagnosis of recurring failure modes ("Coder repeatedly
  re-reads the full plan"; "Tester wastes a phase rediscovering the
  emulator") and **a concrete diff against this repo's own agent prompts**,
  opened as a PR with the evidence linked.
- **Gate:** a human (you) merges. The loop is
  *evidence → prompt diff → eval re-run → measured delta*, and the eval
  scorecard from Workstream B proves whether the retro's change helped.

That closed loop — an agent team whose prompts are maintained by
evidence-backed PRs from its own retrospective agent, validated by its own
eval suite — is a genuinely publishable idea. PR #3 is itself a manual
prototype of this; `/retro` productizes it.

## 5. Workstream D — Cross-tool conformance suite

The README's boldest claim is "works identically in Claude Code,
Antigravity, and opencode." Prove it mechanically:

- A conformance script that runs one pinned small task in each harness
  (headless where the harness allows) and diffs the artifact *shapes*:
  same files produced, same sections present, same gates fired.
- Publish the conformance matrix in the README (✅/⚠️ per tool per
  command).

This is modest effort but unique positioning: it makes this repo the
reference example for **harness-portable agent definitions**, which is a
real emerging problem (every team is quietly locked into one tool's
subagent format). A short write-up of the portability patterns you already
invented — canonical prompt + per-tool stubs + symlink sync — would stand
alone as a leadership artifact.

## 6. Workstream E — Memory that compounds

Extends `docs/ADDITIONAL-IMPROVEMENTS.md`'s `codebase-map.md` idea from
"cache" to "institutional memory":

- **`pipeline_artifacts/memory/lessons.md`** — reviewers and the Tester
  append one-line lessons on every bounce/failure ("this project's
  ViewModels must expose StateFlow, not LiveData"). Producers read it at
  phase start. Bounded (max N entries, retro agent prunes).
- **`codebase-map.md`** — as already specified in ADDITIONAL-IMPROVEMENTS.
- **Measurable claim:** with Workstream B in place you can show bounce
  rate declining across sequential runs on the same project. "My agent
  team gets cheaper the longer it works on your codebase" — with a chart
  — is another quotable, novel result.

## 7. Sequencing and effort

| Order | Workstream | Depends on | Effort | Payoff |
|---|---|---|---|---|
| 0 | Land PR #3 | — | (planned) | run-report.md, resume, gates — the substrate |
| 1 | **A: receipts app** | PR #3's run-report | ~2–3 focused days | The five-minute "wow" artifact |
| 2 | **B: evals + scorecard** | mock project (exists) | ~3–4 days | The numbers everyone else lacks |
| 3 | **C: /retro** | A or B transcripts | ~1–2 days | The publishable idea |
| 4 | D: conformance | — | ~1 day | Defends the core claim |
| 5 | E: memory | B (to measure it) | ~1–2 days | The compounding chart |

Do A before B: a working receipts app makes the eval suite's task design
obvious, and A is demoable immediately.

## 8. Positioning notes

- **Don't broaden past Android yet.** "The definitive agentic pipeline for
  Android, with receipts" beats "another general agent framework" — the
  general space is saturated; the vertical with device-level evidence is
  empty. Portability across *harnesses* (already done) is the
  generality story; portability across *platforms* can wait until the
  Android numbers are strong.
- **No domain needed.** The kangentic.com instinct was right that a
  surface is needed, wrong about the form: the GitHub Pages eval
  dashboard + the receipts-app README are stronger than any landing page,
  because they're evidence rather than marketing.
- **Write as you ship.** Each workstream yields one natural essay: "I put
  my agent team on a benchmark and here's where it lost", "My pipeline
  opens PRs against its own prompts", "Making one agent team run in three
  harnesses". The repo produces the receipts; the writing spends them.
  Leadership perception = artifacts × explanation.
- **Honesty is the differentiator.** Publish failures, costs, and human
  interventions. In a field of cherry-picked demos, calibrated claims are
  the scarcest signal and the one senior audiences actually screen for.
