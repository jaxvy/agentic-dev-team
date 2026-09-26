# Multi-Agent Pipeline & Orchestration Rules

This file is the shared source of truth for the PM → Architect → Coder → Tester
pipeline. Every agent and command file references this document. Project-specific
architecture, libraries, and verification rules live in the consuming project's
`AGENTS.md` (or `CLAUDE.md`).

The document has two halves:

- **Part A — Agent Protocol**: everything an `adt-*` agent must obey. Agents read
  Part A and stop there.
- **Part B — Orchestration & Tool Registration**: everything only the
  orchestrator (the parent agent or slash command driving a run) needs —
  subagent mappings, approval gates, the reviewer loop, and per-tool
  registration. Agents do not need it.

Commands and orchestrators read both halves.

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
  - `adt-android-tester` writes `pipeline_artifacts/{slug}/test-results.md`.
  - `adt-android-coder` produces no markdown — only uncommitted code changes in the working tree.
  - `pipeline_artifacts/` must be git-ignored in the consuming project. Two mechanisms cover this, and they are deliberately redundant:
    - `install.sh` adds `/pipeline_artifacts/` to the managed `.gitignore` block. This covers the per-project install path only.
    - Whichever agent first creates the directory (`adt-android-pm`, or `adt-android-architect` in the auto flows) also writes `pipeline_artifacts/.gitignore` containing a single `*` line, which ignores the directory's contents and itself. This is the only thing covering a **plugin-only install**, where no `install.sh` run ever happened and the project's `.gitignore` is untouched.
    - Why it matters: artifacts left visible to git land in the changed-file manifest below as untracked files, and the Coder's no-commit rule means a developer running `git add -A` would commit the run's scratch files into their repository.

## Handoff Protocol

- **Read-before-write**: Every agent must read the prior phase artifact in full before starting. A missing required artifact is a STOP condition — report to the user, do not proceed by guessing.
- **No-commit rule for adt-android-coder**: The Coder must never run `git add`, `git commit`, or any staging command. Changes stay uncommitted for human review.
- **Manual verification**: `adt-android-tester` must perform manual verification through the `auto-mobile` MCP server when that server is available and the consuming project's `AGENTS.md` / `CLAUDE.md` requires it.

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

## The Three Named Commands

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

- **The install command** — how `adt-android-tester` puts the build on the
  device before driving it. A failure here is a STOP, not something to work
  around.

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
   ```

The defaults are a starting point, not a contract: `detekt` does not exist in a
project that has not applied the plugin, and a multi-module project may need
module-qualified tasks (`:app:assembleDebug`, `:app:lintDebug`). Running a task
the project does not define fails the whole invocation, so a resolved command
that names a non-existent task is a defect — never "the project's build is
broken".

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

## Verdict and DONE Markers

Each producing agent ends its turn with its own DONE marker; the orchestrator
waits on that marker before advancing.

- `adt-android-pm` → `✅ PM DONE`
- `adt-android-architect` → `✅ ARCHITECT DONE`
- `adt-android-coder` → `✅ CODER DONE`
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

## Raw adb Fallbacks

`adb` is not banned. `adt-android-tester` drives the device through auto-mobile
by default, because those tools know which app is under test and the shell does
not — but where auto-mobile has no equivalent, or its call fails, the shell is
a legitimate fallback rather than a dead end.

What makes it safe is that it is **declared**, not that it is forbidden. A raw
`adb` command can silently move the ground under the run: `keyevent 26` (POWER)
locks the screen and `keyevent 3` (HOME) backgrounds the app, after which every
tap lands on the launcher and reads exactly like a feature that does not
respond. That is how a real run reported a pass on a feature it never saw — not
because the command was used, but because nobody knew it had been.

So each fallback carries three obligations, defined in the Tester's Operating
Principle 9: re-establish that the app is foregrounded before trusting the next
observation, record the command and its justification under **Raw adb
Fallbacks** in `test-results.md`, and never treat shell-only interaction as
evidence the feature works.

**The orchestrator surfaces the count.** The Tester's DONE line carries it, so
the orchestrator reports it in the run summary without opening the file. A run
that needed fallbacks is not a failed run and the count never changes the
verdict — it is a signal about the harness, for the human who maintains it.

**Invariant**: no raw `adb` interaction happens silently. Using one is a normal
working step; hiding one is the defect.

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
- **Every flow can answer.** The blocked gate is the one point where the auto
  flows pause for a human too (Part B, "The Blocked Path"), so a locked device
  costs one reply rather than a discarded run, whichever command started it.
- **They are run-scoped and never persisted.** They do not go into
  `pipeline_artifacts/`, into `test-results.md`, into a screenshot, into a
  recorded auto-mobile plan, into the code, or into the orchestrator's final
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

---

# Part B — Orchestration & Tool Registration

Orchestrator-facing. The agents spawned by the pipeline do not need this half.

## Subagent Tool & Environment Mappings

When defining subagents via the `define_subagent` tool, parse the configuration
from `.claude/agents/adt-*.md` and configure tools as follows:

- `adt-android-pm`: system prompt from `.claude/agents/adt-android-pm.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-architect`: system prompt from `.claude/agents/adt-android-architect.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-coder`: system prompt from `.claude/agents/adt-android-coder.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-tester`: system prompt from `.claude/agents/adt-android-tester.md`; `enable_write_tools = true`; `enable_subagent_tools = false`; `enable_mcp_tools = true`.
- `adt-android-architect-reviewer`: system prompt from `.claude/agents/adt-android-architect-reviewer.md`; `enable_write_tools = true` (for read-only Bash inspection — the reviewer never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-code-reviewer`: system prompt from `.claude/agents/adt-android-code-reviewer.md`; `enable_write_tools = true` (for `git diff` and the build gate — the reviewer never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.
- `adt-android-review-judge` (configured review panels only): system prompt from `.claude/agents/adt-android-review-judge.md`; `enable_write_tools = true` (for read-only Bash inspection; the judge never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`.

Antigravity does not support per-subagent model selection. The recommended models
in each agent file (`opus` for adt-android-pm/adt-android-architect and both
reviewers, `sonnet` for adt-android-coder and adt-android-tester) are documented
for reference; in Antigravity, all subagents inherit the user's globally selected
model — select the strongest available model for full pipeline runs.
The `agents:` model settings in .agentic-dev-team/config.yaml cannot change this; see "Agent Configuration".

## Agent Configuration

Every command reads this section, through its "Agent configuration" paragraph.
It defines the optional config file `.agentic-dev-team/config.yaml`. **With no
active setting in that file, nothing in this section changes a run**: a
missing file, an empty file, and the file as created (every setting commented
out) give `MODELS` off and `RUNS` off, and the command runs exactly as it
would without the file.

### The files

```
<project root>/.agentic-dev-team/
  .gitignore     one line: *
  config.yaml    copy of config.example.yaml, every setting commented out
```

The `*` line ignores the whole directory, the `.gitignore` included, so
`git status` and the changed-file manifest never list these files.

The command's "Agent configuration" paragraph creates both files once, with
`bash "ADT_ROOT/scripts/adt-run-agent.sh" --init-config "PROJECT_ROOT"`, when
`config.yaml` does not exist. `install.sh` runs the same step at install. The
step never edits or overwrites an existing `config.yaml`, and it never creates
`.gitignore` while `config.yaml` exists. It prints one status line first:
`ADT_INIT status=created`, `status=exists`, `status=unreadable` (the path
exists but is not a readable file: a config error) or `status=failed`.

**Un-ignore.** To share the config with a team, the developer deletes
`.agentic-dev-team/.gitignore` and commits `config.yaml`. Later `install.sh`
runs and commands never re-create the `.gitignore` while `config.yaml` exists,
and `install.sh --uninstall` never touches `.agentic-dev-team/`.

### Schema (version 1)

```yaml
version: 1

agents:                      # all commands; native agents only
  <role>:
    model: <alias>

build_auto_reviewed:         # /build-auto-reviewed only
  architect: <slot>
  coder:     <slot>
  tester:    <slot>
  architect_reviewer:
    reviewers: [<slot>, ...]   # 1 to 5 entries
  code_reviewer:
    reviewers: [<slot>, ...]   # 1 to 5 entries
```

Roles and agents:

| Role | Agent | Frontmatter model |
|---|---|---|
| `pm` | `adt-android-pm` | `opus` |
| `architect` | `adt-android-architect` | `opus` |
| `architect_reviewer` | `adt-android-architect-reviewer` | `opus` |
| `coder` | `adt-android-coder` | `sonnet` |
| `code_reviewer` | `adt-android-code-reviewer` | `opus` |
| `tester` | `adt-android-tester` | `sonnet` |
| `review_judge` | `adt-android-review-judge` | `inherit` (the main model) |

A slot:

| Key | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `runner` | string | no | `native` | `native`, `claude`, `codex`, `agy`, `opencode`, `command` |
| `model` | string | no | see "Model values" | For `native`: an alias. For external runners: any value that CLI's `--model` flag accepts. |
| `timeout_minutes` | integer ≥ 1 | no | `30` for a reviewer, `120` for `architect`, `coder` and `tester` | External runners only. Ignored for `native` (a native agent has no time limit). |
| `required` | boolean | no | `true` | Reviewer slots only, and only in a list with 2 or more entries. |
| `command` | string | only for `runner: command` | none | Command template, see "Command templates" below. |
| `check` | string | required for `runner: command`, not allowed for other runners | none | The program that preflight looks for, and the program word of the template (they must be the same). |

`review_judge` and `pm` are valid only under `agents:`. The judge always runs
native, on the main model unless `agents.review_judge.model` sets another.

### Switches

A **native model value** is any `agents.<role>.model`, or the `model` of a
`build_auto_reviewed` slot or reviewer entry whose `runner` is `native` or
that has no `runner` key.

- **`MODELS` is on** when at least one native model value is set for a role
  that the current command starts: an `agents.<role>.model` for a role in the
  table below, or (in `/build-auto-reviewed` only) a native model value under
  `build_auto_reviewed`.

  | Command | Roles it starts |
  |---|---|
  | `/plan-research` | `pm` |
  | `/plan-design` | `architect` |
  | `/build-auto` | `architect`, `coder`, `tester` |
  | `/build-guided` | `pm`, `architect`, `coder`, `tester` |
  | `/build-auto-reviewed` | `architect`, `architect_reviewer`, `coder`, `code_reviewer`, `tester`; and `review_judge` only when a **configured** `reviewers` list has 2 or more entries |

- **`RUNS` is on** (only in `/build-auto-reviewed`) when at least one slot or
  reviewer entry under `build_auto_reviewed:` has a `runner` other than
  `native`, or a `reviewers` list has 2 or more entries. A native slot or a
  single native reviewer entry with a `model` is a native model value
  (`MODELS`), not `RUNS`. So `architect: { runner: native }` or
  `coder: { runner: native, model: opus }` never turns on `RUNS`.

`version` alone does not turn on a switch.

### Validation

Validate the whole file at the start of every command, before the first agent
runs (every command validates the whole file, also the part it does not use).
Any of these stops the command with a message that names the key and the
problem:

1. The file is not valid YAML, or its top level is neither empty (YAML
   `null`: an empty or comments-only file, which counts as no config) nor a
   mapping.
2. `version` is present and is not `1`.
3. An unknown top-level key, role, or slot key.
4. A `runner` that is not in the list.
5. A `reviewers` list that is empty or has more than 5 entries.
6. A problem with a `command` runner, any of:
   - `runner: command` without `command`, or without `check`;
   - `command` or `check` with another runner;
   - a `command` whose **parsed string value** (after YAML parsing, so YAML's
     own quotes around the value do not count) fails any item of the
     "Template check" list below;
   - a `command` with neither `{instruction}` nor `{prompt_file}`;
   - a `command` that uses `{model}` in a slot without `model`;
   - a `check` value whose basename is one of the shells and command runners
     listed in the "Template check";
   - a `check` value that does not match
     `^([A-Za-z0-9_+][A-Za-z0-9._+-]*|/[A-Za-z0-9._/+-]+)$`: a bare program
     name (no `/`, does not start with `-` or `.`) or an absolute path. No
     spaces, `$`, `~` or quotes, and no relative path such as `bin/gemini`.
7. `required` outside a reviewer slot; `required: false` in a `reviewers`
   list that has only one entry; or `timeout_minutes` that is not a whole
   number ≥ 1.
8. In Claude Code only, and only when the Agent (Task) tool has a `model`
   parameter in its schema: **any** native model value in the file, also one
   that the current command does not use, that is not one of the values that
   parameter accepts: the values of its `enum` when the schema has one; when
   the parameter is a plain string without an `enum`, the aliases `sonnet`,
   `opus`, `haiku` and `fable` only. This rule only compares the file with the
   schema; it runs no command.
9. A value of the wrong type. The only allowed shapes are:
   - `version`: the integer `1`.
   - `agents`: `null` or a mapping; each role under it: a mapping with exactly
     one key, `model`, whose value is a non-empty string (an empty mapping,
     `model:` with no value, and `model: ""` are errors).
   - `build_auto_reviewed`: `null` or a mapping. `architect`, `coder`,
     `tester`: a slot. `architect_reviewer`, `code_reviewer`: a mapping whose
     only key is `reviewers`, a **list** (not `null`) of slots.
   - A slot: a mapping. `runner`, `model`, `command`, `check`: non-empty
     strings. `timeout_minutes`: an integer. `required`: exactly `true` or
     `false`, lowercase and without quotes. Every other value (`yes`, `no`,
     `True`, `"false"`, ...) is an error.
   A role key whose value is `null` (for example `coder:` with nothing after
   it) is an error: remove the key or comment it out.

### Command templates

A `runner: command` slot runs a program from a template. **No shell runs the
template.** The script turns it into an argument list:

1. **Words.** Split on spaces and tabs that are **outside** double quotes. A
   double-quoted part groups text (spaces included) into the word, and the
   quote characters are removed. There is no other quoting or escaping.
2. **Assignments.** Leading words of the form `NAME=value` (`NAME` matches
   `[A-Za-z_][A-Za-z0-9_]*`) become environment variables for the program.
   The first other word is the **program word**; the rest are its arguments.
3. Placeholders `{instruction}`, `{prompt_file}`, `{output_file}` and
   `{model}` are replaced inside each word, after the split, so a value never
   creates or splits words.

**Template check.** The template is rejected when:

- it contains `'`, `\`, a backtick, `$`, a newline or carriage return, or any
  of `|`, `;`, `&`, `<`, `>`;
- its double quotes are not balanced (an odd number of `"`);
- it has neither `{instruction}` nor `{prompt_file}`;
- it uses `{model}` and the slot has no `model`;
- it assigns `PATH`, `BASH_ENV`, `ENV`, `IFS`, or a name that starts with
  `LD_` or `DYLD_`;
- the program word is not exactly the slot's `check` value (so no wrapper such
  as `env`, `timeout`, `nohup` or `sudo` can run in front of the program; set
  a variable with `NAME=value` in front of the program word instead, and use
  `timeout_minutes` for a time limit);
- the basename of the program word is one of `sh`, `bash`, `rbash`, `zsh`,
  `dash`, `ksh`, `mksh`, `ash`, `fish`, `csh`, `tcsh`, `pwsh`, `powershell`,
  `busybox`, `env`, `sudo`, `su`, `ssh`.

The script applies the same check before it runs anything. It cannot know
what the checked program does with its arguments: never pass a placeholder to
a program that runs an argument as code (`python3 -c`, `node -e`).

### Model values

**Native agents in Claude Code.** Pass the value in the `model` parameter of
the Agent tool. That parameter accepts **aliases only** (today `sonnet`,
`opus`, `haiku`, `fable`; the exact list is the enum in the tool's own
schema). Full model IDs, `inherit`, `best`, `default`, `opusplan` and `[1m]`
variants are rejected by validation rule 8.

What a native alias runs (Claude Code resolves it when it starts the
subagent):

1. If the main conversation's model is in the same family (for example the
   main session runs an Opus model and the config says `opus`), the subagent
   runs on the main conversation's **exact** model, including any `[1m]`
   suffix.
2. Otherwise it runs the version the alias points to: the value of
   `ANTHROPIC_DEFAULT_<FAMILY>_MODEL` when that variable is set, else Claude
   Code's current mapping (for example `opus` is Opus 5.5 on the Anthropic API
   today; other providers can map it to another version).
3. On a provider other than the Anthropic API, when Claude Code cannot tell
   the main model's family, `opus` also resolves to the main model, unless
   `ANTHROPIC_DEFAULT_OPUS_MODEL` is set.

A native agent cannot be pinned to an exact version through this config. To
pin one: in `/build-auto-reviewed` use `runner: claude` with a full model ID;
for another family than the main model, set `ANTHROPIC_DEFAULT_<FAMILY>_MODEL`
in the `env` of `.claude/settings.json`; otherwise select that version as the
main session's model.

**Precedence in Claude Code:** the per-invocation `model` parameter wins over
the agent frontmatter, which wins over `CLAUDE_CODE_SUBAGENT_MODEL`, which wins
over the main model. `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` overrides all of them.

**Model resolution for a native agent** (first match wins):

1. In `/build-auto-reviewed` only: the `model` of the slot that starts this
   agent (for a reviewer: its own entry in the `reviewers` list), when that
   slot is native.
2. `agents.<role>.model`.
3. No value: pass no `model` parameter, so the agent file's frontmatter
   applies (today's behavior).

**Native agents in Antigravity and opencode.** These tools cannot select a
model per subagent. Pass nothing, do not fail, and report once in the final
summary: `Model settings were not applied: <tool> runs every subagent on its
selected model.` Validation rule 8 does not apply there.

**External runners** (`/build-auto-reviewed`): `model` goes to the CLI's
`--model` flag unchanged (`claude`: an alias or a full ID such as
`claude-opus-5-5`; `codex`: a Codex model name; `agy`: an Antigravity model
slug; `opencode`: `provider/model`; `command`: put into `{model}`). Without
`model`, the CLI uses its own default.

### Steps at the start of every command

1. The config file check and `--init-config` were done by the command's
   "Agent configuration" paragraph. Do not run `--init-config` again here.
2. Read `.agentic-dev-team/config.yaml` if it exists. Validate it (rules 1 to
   7 and 9, and in Claude Code rule 8). On an error: stop, report, start no
   agent.
3. Set `MODELS` (and in `/build-auto-reviewed`, `RUNS`).
4. If `MODELS` is off: skip the rest of this section and continue with the
   command's first phase as usual. No `printenv`, no model passing, no summary
   line about models.
5. If `MODELS` is on and the tool is Claude Code: do the start check below.

### When `MODELS` is on

1. **Claude Code, every native start:** each time you start an `adt-*`
   subagent natively (in `/build-auto-reviewed` this includes native slots and
   native panel reviewers), resolve the model and, while model passing is on,
   pass it in the Agent tool's `model` parameter. With no resolved value, pass
   nothing.
2. **Claude Code, start check (once).** Model passing starts **on**, and is
   turned **off** for the whole run when:
   1. `printenv CLAUDE_CODE_SUBAGENT_MODEL_FORCE` prints a non-empty value
      other than `0` or `false` (any casing). REASON:
      `CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set to <value>`. Do not narrow
      this to `1` or `true`: Claude Code applies the variable silently, so
      treating an unusual value as on can only skip model passing, while
      treating it as off could report a model that never ran.
   2. The Agent (Task) tool has no `model` parameter in its schema. REASON:
      `the Agent tool has no model parameter`.
3. **Claude Code, during the run:** if a subagent start that included `model`
   fails with an error that names the `model` parameter or says a model
   cannot be passed, start that same subagent again once without `model`, and
   turn model passing off for the rest of the run. REASON:
   `Claude Code rejected the model parameter: <error message>`. Any other
   start error is handled as usual; it never turns model passing off.
4. **While model passing is off:** pass no `model` to any subagent, and put
   `Model settings were not applied: <REASON>.` in the final summary. The run
   continues normally.
5. **Antigravity, opencode:** pass nothing, and report as in "Model values".
6. **Summary line:** `Models requested: <role>=<value> ...` for each role
   whose configured model was passed. Say "requested", never "ran": an
   organization `availableModels` allowlist or alias case 1 above can still
   change the model that runs.
7. **`CLAUDE_CODE_SUBAGENT_MODEL` note (Claude Code).** In the start check,
   also run `printenv CLAUDE_CODE_SUBAGENT_MODEL`. If it prints a value, add
   to the summary: `Note: CLAUDE_CODE_SUBAGENT_MODEL is set to <value>.
   Claude Code older than v2.1.251 lets it override the requested models
   (sub-agents docs).` Model passing stays on.

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

## Configured Runs (/build-auto-reviewed only)

Only /build-auto-reviewed uses this section, and only when RUNS is on. Every other command, and a run with RUNS off, ignores it.

Configured runs let a role run as an external CLI (Claude Code, Codex,
Antigravity, opencode, or any command) instead of as a native subagent, and
let a review gate run as a **review panel**: 2 to 5 reviewers whose findings
the `adt-android-review-judge` agent verifies and merges. Each CLI uses the
developer's own login; no API key is involved.

### The runner script

`RUNNER` is `ADT_ROOT/scripts/adt-run-agent.sh`. Always call it as
`bash "RUNNER" ...`, and put every path in double quotes.

```
bash RUNNER --check <claude|codex|agy|opencode>
bash RUNNER --check command --check-program <program> --command-file <path> [--model <model>]
bash RUNNER --runner <runner> --access <read-only|write> --project-root <path>
            --prompt-file <path> --output-file <path>
            [--model <model>] [--timeout-minutes <n>]
            [--command-file <path> --check-program <program>]
            [--allow-read <path>]... --detach
bash RUNNER --wait <output-file>... [--max-seconds <n>]
bash RUNNER --hash <file>
bash RUNNER --snapshot --project-root <path> [--guard-path <path>]...
bash RUNNER --cancel <run dir>
```

**Paths.** Every path you pass is absolute (built from PROJECT_ROOT). The
script exits 2 for a relative `--wait`, `--output-file`, `--prompt-file`,
`--command-file`, `--allow-read`, `--project-root` or `--cancel` path.
`--guard-path` is the one exception: it may be relative to `--project-root`.

Files of one run, next to the output file `O`: `O` (the agent's final
answer), `O.log` (CLI progress and errors), `O.status` (the result, written
last), and the script's own `O.pid`, `O.clipid`, `O.cancel`, `O.elapsed` and
`O.timedout`. You read only `O`, `O.log` and `O.status`.

A result is five lines (stdout, and the content of `O.status`):

```
ADT_RUN status=<status> runner=<runner> exit=<CLI exit status>
ADT_RUN marker=<last marker line, or empty>
ADT_RUN output=<O> log=<O.log> seconds=<run time>
ADT_RUN code=<this script's exit code>
ADT_RUN sha=<output of `--hash O` when the run ended, or empty>
```

| Code | Status | Meaning |
|---|---|---|
| 0 | `ok` | Finished, marker found |
| 2 | `usage` | Bad arguments; a relative path; not a git repo; `O` or `O.log` not git-ignored; a missing guard path |
| 3 | `missing-runner` | CLI not on `PATH` |
| 4 | `timeout` | Stopped at the timeout |
| 5 | `failed` | CLI exit status not 0 |
| 6 | `no-marker` | Finished without a marker line |
| 13 | `conflicting-markers` | Finished with marker lines of different known markers |
| 14 | `cancelled` | Stopped by `--cancel` |
| 10 | `running` | `--wait` only: not finished yet |
| 11 | `lost` | `--wait` only: the detached job ended without a result, or is stuck |
| 12 | `not-started` | The CLI never started |

**`--wait O...`** takes one or more output files and prints one block per
file, in the order given: the five `ADT_RUN` lines of a finished run, or
`ADT_RUN status=running output=<O>`. It exits 10 while any file is still
running, else 0 (with a single file, it exits with that run's code). **The
result of each run is the `code` line of its block**, never the exit code of
a multi-file call. Repeat the call until it does not exit 10; the script's
own stuck-job rules guarantee that this ends.

### Marker rule

Used for every answer in a configured run, native and external alike. Only
these **known markers** count: `✅ ARCHITECT DONE`, `✅ CODER DONE`,
`✅ TESTER DONE`, `⛔ TESTER BLOCKED`, `✅ PLAN APPROVED`,
`🔧 PLAN CHANGES REQUESTED`, `✅ CODE APPROVED`, `🔧 CODE CHANGES REQUESTED`.

- Remove every U+FE0F character (the invisible emoji variation selector, as in
  `⛔️`) from a line before matching.
- A **marker line** starts in the first column (a line that begins with a
  space or tab is never one). After these are removed from its start, in this
  order, it **starts with** a known marker: (1) if present, `#` characters and
  spaces; (2) if present, one `**` or `__`; (3) if present, the label
  `Verdict:` (any casing), then, if present, one `**` or `__`, then spaces,
  then, if present, one `**` or `__`. So `✅ CODE APPROVED — summary`,
  `## ✅ CODE APPROVED`, `**✅ CODE APPROVED**`, `Verdict: ✅ CODE APPROVED`,
  `**Verdict:** ✅ CODE APPROVED` and `Verdict: **✅ CODE APPROVED**` are
  marker lines.
- A line that starts with a bullet (`*`, `-` or `+` and a space), `>`, a
  backtick, or any other character is never a marker line. A line that starts
  with an emoji but not with a known marker (`✅ Item 1 is fixed`) is ignored.
- If every marker line starts with the **same** known marker, that is the
  answer's marker (the last such line is reported). Marker lines with
  **different** known markers make the answer invalid (`conflicting-markers`,
  code 13). Never guess.

In this section, "the marker is X" means this rule found a line that starts
with X.

### Start

0. If ADT_ROOT is empty, STOP: the configured run needs the scripts. Report
   that the agentic-dev-team install is incomplete.
1. **Run directory:** `PROJECT_ROOT/pipeline_artifacts/.runs/<run id>/`, always
   used as an absolute path. `<run id>` is the UTC timestamp from
   `date -u +%Y%m%dT%H%M%SZ`, a `-`, and 6 random lowercase letters or digits;
   if the directory already exists, choose new random characters. Before you
   create it: create `PROJECT_ROOT/pipeline_artifacts/` with `mkdir -p`, then
   create `PROJECT_ROOT/pipeline_artifacts/.gitignore` with the single line
   `*` if it does not exist. Only then create the run directory.
2. **Paths:**
   - RUNNER: `ADT_ROOT/scripts/adt-run-agent.sh`.
   - Persona of each agent: `ADT_ROOT/agents/<agent file>`.
   - PIPELINE_DOC_ABS: PIPELINE_DOC as an absolute path (prefix it with
     `PROJECT_ROOT/` when it does not start with `/`). Use it in every script
     call and prompt file; native subagents keep getting PIPELINE_DOC.
3. **Preflight.**
   1. For each `runner: command` slot, write its command file
      `<run dir>/command-<slot>.txt`, where `<slot>` is `architect`, `coder`,
      `tester`, `architect_reviewer-<i>` or `code_reviewer-<i>` (`<i>` is the
      1-based position in that `reviewers` list). It holds the **parsed string
      value** of `command` followed by one newline.
   2. Run `bash "RUNNER" --check <runner>` once for each distinct runner among
      `claude`, `codex`, `agy` and `opencode` in the config.
   3. For each `runner: command` slot, run
      `bash "RUNNER" --check command --check-program <check> --command-file "<its command file>" [--model M]`
      (with `--model` when the slot has `model`).
   4. Exit 3 means the CLI is missing (below). Exit 2 from a `command` check
      means the template is invalid: STOP before Phase 1 and show the
      script's message. Any other non-zero exit: STOP and report the command
      and its output.
   5. A missing CLI in a producer slot (`architect`, `coder`, `tester`) or in
      a required reviewer: STOP before Phase 1 and name the CLI. A missing CLI
      in an optional reviewer: remove that reviewer, and report it in the
      summary.
4. **Effective reviewer lists.** Fix each gate's reviewer list for the whole
   run: the configured list minus the removed reviewers, or one native
   reviewer when the gate is not configured. If a configured gate's list is
   now empty: STOP before Phase 1 and report `<gate> has no available
   reviewer`. Choose each gate's case (A, B or C, below) from its effective
   list here, one time. If the removals leave a single reviewer, that
   reviewer is required from now on, and the summary says so.
5. If the `coder` or `tester` slot uses `runner: codex`, print one warning:
   Codex's `workspace-write` sandbox blocks network access and writes outside
   the project by default, so Gradle downloads, the Gradle daemon and `adb`
   can fail; use another runner for that role, or allow network and the
   needed paths in your own Codex configuration (`sandbox_workspace_write`).

### Starting an external agent

1. **File names are unique for each start:**
   `<run dir>/jobs/<phase>-<role>[-s<section>]-a<attempt>.prompt.md` and
   `...-a<attempt>.out.md`. `<phase>` is `1`, `1R`, `2`, `2R`, `3`, `3B` or
   `3F<iteration>`; `-s<section>` is for parallel coders; `<attempt>` starts at
   1 and goes up each time the same phase starts the same role again. An
   external reviewer uses `O = <run dir>/jobs/<gate>-r<N>-<letter>.out.md` and
   `<run dir>/jobs/<gate>-r<N>-<letter>.prompt.md`. **All runner files live in
   `<run dir>/jobs/`.** When a reviewer's run is complete, copy its answer to
   the round directory with `cp "O" "<run dir>/<gate>-r<N>/reviewer-<letter>.md"`
   (a byte copy in the shell, never a read-and-write of the text).
2. Create `<run dir>/jobs/` with `mkdir -p`, then write the prompt file (see
   "Prompt file").
3. Start it detached:
   `bash "RUNNER" --runner R --access A --project-root "PROJECT_ROOT" --prompt-file "P" --output-file "O" [--model M] --timeout-minutes N [--command-file "<run dir>/command-<slot>.txt" --check-program <check>] --allow-read "<persona path>" --allow-read "PIPELINE_DOC_ABS" --detach`
   **Check the result before any `--wait`.** `--detach` prints
   `ADT_RUN status=started` and exits 0 when the job started. Any other exit is
   a STOP of the run for a producer or a required reviewer (for an optional
   reviewer: drop it, as a failed reviewer), and the report shows the script's
   output. Never call `--wait` for a job whose `--detach` did not exit 0.
   Always pass `--timeout-minutes`: the slot's `timeout_minutes`, else 30 for a
   reviewer and 120 for `architect`, `coder` and `tester`.
4. **Wait** with `bash "RUNNER" --wait "O" --max-seconds <W>`. In Claude Code
   use `--max-seconds 240` and set the Bash tool's timeout to 330000 ms; in a
   tool whose shell timeout is unknown or short, use 60. Repeat the call until
   its exit code is not 10. For several jobs started together, pass all their
   output files to **one** `--wait` call and read each run's `code` from its
   block.
5. **Access:** `read-only` for reviewers, `write` for architect, coder and
   tester.
6. **Result of a producer** (architect, coder, tester):

   | Script result | Marker | Action |
   |---|---|---|
   | code 0 | `✅ ARCHITECT DONE` / `✅ CODER DONE` / `✅ TESTER DONE` | Continue as the command file says for that marker. |
   | code 0 | `⛔ TESTER BLOCKED` (tester only) | The Blocked Path, exactly as for a native Tester. Not a failure. |
   | code 0 | any other marker | STOP: report role, runner, marker, output path. |
   | code 6 (`no-marker`) | none | The agent stopped without a marker, as a native agent does for its own STOP conditions: relay the output file's text to the user as that agent's STOP report, and STOP the run. |
   | code 13 (`conflicting-markers`) | several | STOP: report role, runner, the conflicting lines from `O.log`, and the output path. |
   | code 2, 3, 4, 5, 11, 12 | any | STOP: report role, runner, status, and the log path. |
   | code 14 (`cancelled`) | any | STOP: report the role and that its change may be incomplete. Never continue with its result. |

   Never retry, and never fall back to native.

**Parallel runs** (several coders in one group, several reviewers in a
panel): start all detached jobs first, then wait for all of them with one
repeated `--wait` call that lists every output file.

### Prompt file

Write exactly this, with the placeholders filled in:

```
# Task for <agent name> (agentic-dev-team pipeline)

Another agent (the pipeline orchestrator) started you. No human will answer
questions during this run.

1. Read <absolute persona path> in full and follow it. It is your complete
   role prompt. Ignore its YAML frontmatter: those settings are for Claude
   Code subagents.
2. Read Part A of <PIPELINE_DOC_ABS>.
3. Read the project's AGENTS.md (or CLAUDE.md) as your role prompt says.

## Your task

<exactly the text the orchestrator gives the native subagent for this step,
including PLAN_PATH, DOC_PATH, DESIGN_DOC, the section to implement, and
the numbered feedback, as the command file specifies>

## Access

<read-only>
You are read-only. Do not create, edit, move, or delete any file. Do not run
git commands that change the repository. The orchestrator checks the working
tree after your run, and a change stops the pipeline.
</read-only>
<write>
You may edit files in the project as your role prompt allows. Never run git
add, git commit, git stash, or any command that changes git history.
</write>

<optional blocks from 7.4>

## End

End your answer with the marker line that your role prompt defines. After
it, write only what your role prompt puts after it (for a CHANGES REQUESTED
verdict: the numbered list). Do not write a second marker line.
```

In this template, "7.4" means the section "Blocks given to reviewers" below.
Use only the access block that applies (without its `<read-only>` or
`<write>` tag lines). **Never put `TEST CREDENTIALS`, or any credential value,
in a prompt file.** Two mechanical rules make sure of it:

1. Text that comes from a Tester (findings, recommendations) is copied into a
   prompt file **only from `test-results.md`**, never from the Tester's chat
   answer. Part A already forbids credential values in `test-results.md`.
2. **No text from a human reply** (a `resume` reply included) is ever copied
   into a prompt file.

### Blocks given to reviewers

**`BUILD GATE OUTPUT`**: given to every code reviewer in a Case B or Case C
code gate, after the build gate ran (passed or failed):

```
## BUILD GATE OUTPUT
The orchestrator ran the build gate from the plan's Section 0:
Command: <command>
Exit status: <n>
<last 200 lines of output>
```

**`EARLIER CONFIRMED FINDINGS`**: given to every reviewer in a Case B or Case
C gate (plan or code) whenever the list below is not empty: from round 2 of
the gate, and in every Phase 3F targeted gate.

The list holds every numbered item that the producing agent was told to fix
earlier in this run for this artifact, in order, with where it came from:

1. each earlier round's feedback in this gate: when the build gate failed in
   that round, its item as one line only, `Build gate failed: <command>
   exited <n>` (never the Gradle output); then the judge's Confirmed list
   (Case C) or the single reviewer's numbered **blocking** items (Case B;
   never its "Nits / optional" items);
2. for a code gate in Phase 3F: also every item from Phase 2R and from the
   earlier Phase 3F iterations that came from a **reviewer, the judge, or a
   build gate**.

The Tester's findings are **never** in this block. A targeted re-review
already gets them as "the fix instructions the Coder worked from", and the
code reviewer must stay free to flag a Tester-driven fix as plan drift.

```
## EARLIER CONFIRMED FINDINGS
Earlier in this run, the producing agent was told to fix these items, and
changed the plan or code to fix them. Those changes are review-driven and in
scope, even where the plan does not specify them. Do not report them as
scope creep. You may report a fix that is wrong or incomplete.
<source heading per group, for example "Code review, round 1 (panel)",
"Code review, round 2 (build gate)", "Code review, Phase 3F iteration 1,
round 1", then the items numbered as they were given>
```

The judge gets the same block and uses it for its REJECTED rule. For a native
reviewer, add the same blocks to the subagent prompt.

### Review gates with RUNS on

A gate uses its effective reviewer list and the case chosen at the start.

**Build gate first (Case B and Case C, code gates only).** Before the
reviewers start, run the build gate from the plan's Section 0 one time (in
Phase 3F targeted re-reviews too), and keep the command, exit status and
output. The reviewers run in either case. **If the exit status is not 0**,
the round result is always `🔧 CODE CHANGES REQUESTED`, whatever the reviewers
and the judge say, and this item comes **first** in the numbered feedback:
`Build gate failed: <command> exited <n>. Fix the failures in this output:
<last 200 lines>.` The other items follow (the judge's Confirmed list, or the
single reviewer's list); when every reviewer approved, the build item is the
only one. The round counts once against the gate's budget. A failed build can
never pass a gate.

**Tree guard for the whole round (Case B and Case C).** Order within a round:
(1) the build gate (code gates), (2) the first snapshot, (3) the reviewers,
(4) the judge when it runs, (5) the second snapshot. Command:
`bash "RUNNER" --snapshot --project-root "PROJECT_ROOT" --guard-path pipeline_artifacts/<slug>`.
If the two hashes differ, or either call exits non-zero: **STOP the run**,
whether the reviewer was required or optional. Report the gate, the round, the
reviewers that ran in that round, and the output of `git status --short`. Do
not revert anything; the developer decides.

**Every STOP stops the external jobs.** On every exit path of a configured run
(a STOP of any kind, the end of the run, or a failed gate), first run
`bash "RUNNER" --cancel "<run dir>"`. The STOP report and the final summary
always include this line: `To stop any external agent that is still running:
bash "<RUNNER>" --cancel "<run dir>"`.

**Case A: the effective list is exactly one native reviewer.** This is
**today's gate**, unchanged: the native reviewer runs the build gate itself,
there is no orchestrator build gate, no tree guard, no extra blocks, and no
judge. The only differences are the model resolution of "Agent
Configuration" and that you write the reviewer's final answer to
`<run dir>/<gate>-r<N>/reviewer-A.md` (create the directory first). A gate the
developer did not configure is always Case A.

**Case B: the effective list is exactly one external reviewer.** For a code
gate, build gate first, then that reviewer gets `BUILD GATE OUTPUT`. Its own
marker is the verdict. No judge. A failure of this reviewer (script code not
0) stops the run, whether it is marked required or not. A code 0 result whose
marker is not this gate's APPROVED or CHANGES REQUESTED marker also stops the
run (report the marker and the output path).

**Case C: 2 to 5 reviewers (a panel).** One round:

1. Code gates only: build gate first. The rest runs whether it passed or
   failed.
2. Create the round directory `<run dir>/<gate>-r<N>/` with `mkdir -p`. It
   holds **only** the reviewer answers, `judge.md` and `panel-map.md`.
   Assign the letters A, B, C, ... to the reviewers in a **random order, new
   for every round**. Start all external reviewers detached, run the native
   reviewer(s) as subagents, then wait for all. The same task text goes to
   every reviewer, plus the blocks above.
3. **Files in the round directory** (all written by you): for a native
   reviewer, its final message; for an external reviewer, the `cp` copy of
   its `O`; both as `<run dir>/<gate>-r<N>/reviewer-<letter>.md`. `<gate>` is
   `plan-review`, `code-review`, or `targeted-review-<k>` (`<k>` is a run-wide
   counter that starts at 1 and goes up each time a Phase 3F targeted gate
   starts; it never repeats). `N` is the round of that gate, from 1. The same
   names apply in Case B (letter `A`). Write the judge's final message to
   `<run dir>/<gate>-r<N>/judge.md`. Right after you write a native reviewer's
   file, take its hash with `bash "RUNNER" --hash <file>`.
4. A reviewer **fails** when its script code is not 0, or its marker is not
   this gate's APPROVED or CHANGES REQUESTED marker (a native reviewer with no
   marker fails too). A required reviewer's failure stops the run; an
   optional reviewer is dropped from this round and reported in the summary.
   If no reviewer output is left: STOP. One remaining output still goes
   through steps 5 to 8.
5. If every remaining reviewer's marker is the gate's APPROVED marker: the
   judge does not run, and the gate passes **unless the build gate failed**
   (then the result is CHANGES REQUESTED with the build item only). Their
   "Nits / optional" items go to the summary.
6. **Reviewer files are checked first.** For each reviewer file that goes to
   the judge, compute `bash "RUNNER" --hash <file>` now and compare it with
   the hash taken when it was complete: the `sha` line of `O.status` for an
   external reviewer, your own `--hash` result for a native one. A difference:
   STOP the run and report the file.
   Then start the judge (native, `adt-android-review-judge`) with: gate type
   (`PLAN` or `CODE`), round number, targeted or full, PLAN_PATH, DOC_PATH when
   present, the `BUILD GATE OUTPUT` block (code gates), the `EARLIER CONFIRMED
   FINDINGS` block when it is not empty; for a targeted re-review, the fix
   instructions the Coder worked from; from round 2, an `EARLIER PANEL
   DECISIONS` block (the "Rejected" and "Disputed" sections of this gate's
   earlier `judge.md` files, with their round numbers; for the judge only);
   and the file paths of **only the reviewers that did not fail in this
   round** (their original letters; gaps are allowed). Never tell the judge
   which tool wrote which file, and never pass whole `judge.md` files to a
   later judge or reviewer.
7. At the **end of every round** (after the judge, or after the all-approve
   decision; in Case B too), write `<run dir>/<gate>-r<N>/panel-map.md` with
   the letter-to-runner-and-model map.
8. The judge's marker is the gate verdict, **except** when the build gate
   failed in this round: then the verdict is always CHANGES REQUESTED. On
   CHANGES REQUESTED the producing agent gets, as its numbered feedback: the
   build-gate item first when the build gate failed, then the judge's
   **Confirmed** list.
9. **No valid judge verdict:** the judge's verdict is not valid when there is
   no marker, conflicting markers, a marker that is not this gate's APPROVED
   or CHANGES REQUESTED marker, APPROVED with a non-empty Confirmed list, or
   CHANGES REQUESTED with an empty Confirmed list (`None`) while the build gate
   passed. Then STOP the run and report the gate, the round, and the path of
   `judge.md`. Do not retry the judge, do not treat it as approval, and do not
   start another round.

**Budgets do not change.** A panel round counts as one review. Phase 1R and
2R: at most 2 re-runs. Phase 3F targeted re-review: at most 1 re-run. A failed
optional reviewer does not use budget.

### The judge's output

The judge checks each finding against the tree and the plan, and classifies
it: **CONFIRMED** (real and blocking under the reviewer's own rules; a failing
build gate is never listed by the judge, because you add it yourself),
**REJECTED** (wrong, already fixed, a style preference, or it only asks to
undo a fix listed in `EARLIER CONFIRMED FINDINGS` without showing that the fix
is wrong; a finding that repeats one an earlier round rejected is rejected
again unless that place changed), or **DISPUTED** (cannot be verified; not
blocking). It merges duplicates and lists all letters that raised them;
reviewer nits stay nits. In a targeted re-review, findings about code the fix
did not touch go under "Out of scope (for the developer)". Its answer has
these exact headings, `None` under an empty one:

```
## Panel result: <PLAN|CODE> gate, round <N>

### Confirmed (blocking)
1. <file:line or plan section>: <problem>. Fix: <what to do>. Raised by: <letters>.

### Rejected
- <letter>#<item number>: <the finding, in one line, with its file:line or plan section>. Reason: <reason>

### Disputed (not blocking)
- <letter>#<item number>: <claim>. Why not verified: <reason>

### Nits / optional
- <letter>#<item number>: <text>

### Out of scope (for the developer)
- <letter>#<item number>: <text> (targeted re-reviews only; write
  `None` in a full review)
```

Its last line is exactly one marker: `✅ CODE APPROVED` or
`🔧 CODE CHANGES REQUESTED` for a code gate, `✅ PLAN APPROVED` or
`🔧 PLAN CHANGES REQUESTED` for a plan gate. APPROVED if and only if the
Confirmed list is empty. Take the producing agent's feedback from the
"Confirmed (blocking)" section only.

### Special cases

| Case | Rule |
|---|---|
| Parallel coders | Each section's coder uses the `coder` slot. External coders in one group run as parallel detached jobs. They run no Gradle, as usual. The cross-section check after each group is unchanged. |
| Tester | May be external. That CLI must have the `auto-mobile` MCP server in its own config. |
| Tester and credentials | Credentials are never written to a file, and an external run needs a prompt file. So: **from the first reply at the blocked gate that is anything other than exactly `resume` or `stop`** (for example `resume: the PIN is 1234`), **every later Tester start in that run runs native**: that resume itself, every later resume, and every Phase 3F re-test. Only a reply that is exactly the word `resume` (spaces around it do not matter) keeps an external Tester external. Its native model comes from `agents.tester.model`, else the frontmatter (the external slot's `model` is for its CLI only). The summary says so. |
| Architect | May be external (write). Read its `✅ ARCHITECT DONE` line and artifact paths from the output file. |
| External Coder or Tester in Codex | See the warning of "Start" step 5. |

### Summary additions

Add a "Configured run" section to the final summary:

1. Each role: runner and model.
2. Each gate: panel members (letter, runner, model), rounds used, which
   letters raised each confirmed item, disputed items, failed or removed
   optional reviewers.
3. A warning when two reviewers of one gate are in the same model family.
   Family is decided from **what actually runs**:
   - A native reviewer whose model was not applied (Antigravity, opencode, or
     model passing turned off before it started) has the orchestrator tool's
     current model family when known, else unknown.
   - Otherwise use the model value (case-insensitive): for an `opencode`
     value `provider/model`, the provider (`anthropic` is Anthropic, `openai`
     is OpenAI, `google` is Google, any other is unknown); `claude-*`, `opus`,
     `sonnet`, `haiku`, `fable` (also followed by `[`) are Anthropic; `gpt-*`
     or `o` followed by a digit are OpenAI (`opus` and `ollama/...` are not);
     `gemini-*` is Google.
   - When no rule matches, or there is no model value: the `claude` runner is
     Anthropic, `codex` is OpenAI; a `command` runner uses the basename of its
     `check` value (`claude`, `codex`, `gemini` as above); a native reviewer
     with no model value has the orchestrator tool's family when known.
     Anything else is unknown, including `agy` and `opencode` without a model.
   Unknown family: no warning.
4. Every item from the judges' "Out of scope (for the developer)" sections,
   and every DISPUTED item, with gate and round.
5. Nits: the judges' "Nits / optional" items, and, in a round where every
   reviewer approved, the reviewers' own "Nits / optional" items. They take
   the place of "Nits the reviewer declined to block on" for panel gates.
6. The run directory path, and the `--cancel` line above.

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
5. **Ask the human, and wait — in every flow.** Present the ask and take one
   of two replies:
   - `resume` — carrying what the Tester asked for when it named a credential
     (`resume: the device PIN is 1234`), or on its own once the human has
     cleared the gate themselves. Re-invoke the Tester with `PLAN_PATH`, the
     previous `test-results.md`, any `TEST CREDENTIALS` they just supplied, and
     the instruction to resume from the case it stopped at, carrying the
     earlier results forward.
   - `stop` — halt, reporting as in step 4.

   There is no `approve` and no `revise:` here. A run that could not finish its
   cases is not something to approve, and the Coder is not the answer to a
   locked screen.

   **The auto flows pause here too, and that is not a contradiction.** What
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
take, or on the next one. Allow **at most 2 resumes** in every flow; after
that, report and stop, so a device that cannot be made to cooperate does not
turn into an unbounded loop.

Never report a blocked run as a pass, and never let it exit silently. The
failure this path exists to prevent is a green summary on a feature no one ever
saw run.

## Orchestration Workflow (Antigravity)

When the user invokes `/build-guided`, `/build-auto`, or `/build-auto-reviewed`, the parent agent acts as orchestrator:

1. **Define Subagents**: Dynamically register any required subagents using `define_subagent` if they aren't already defined, using the mappings above. For `/build-auto-reviewed`, also register `adt-android-architect-reviewer` and `adt-android-code-reviewer`. When a review panel is configured (Part B, "Configured Runs"), also register adt-android-review-judge.
2. **Execute Phases**:
   - **PM Phase** (`/build-guided` only): Invoke `adt-android-pm` with the user request. Pass messages back and forth between the user and the PM subagent until it outputs `✅ PM DONE`.
   - **Architect Phase**: Invoke `adt-android-architect` with the PM's `feature.md` path (or the feature description for the auto flows) and the `DESIGN_DOC` value this command defaults to (see "Design Doc Defaults Per Command"). Wait until it outputs `✅ ARCHITECT DONE`, and parse the artifact paths out of that marker — the plan path always, and the design doc path when one was requested.
   - **Architect Review Gate** (`/build-auto-reviewed` only): Invoke `adt-android-architect-reviewer` with the plan path (and the design doc path if one was requested), and apply the Reviewer-Loop Protocol above before proceeding. A bounce re-runs the Architect, which re-emits the artifacts, so any document a human ends up reading is always the approved one.
   - **Coder Phase**: Read the execution strategy from the implementation plan. If parallel-safe, verify mechanically that no file appears in two sections of the same group, then invoke multiple `adt-android-coder` subagents in parallel. Otherwise, invoke a single `adt-android-coder`. Parallel coders run no Gradle — you own the verification, via the cross-section check after **every** group (Part A, "Gradle in a Parallel Run"). Take its command from the plan's Section 0 like every other agent — not from Part A's defaults — and on failure follow Part A's "When the cross-section check fails".
   - **Code Review Gate** (`/build-auto-reviewed` only): After all coding is complete, invoke `adt-android-code-reviewer` with the plan path and apply the Reviewer-Loop Protocol above before proceeding.
   - **Tester Phase**: Invoke `adt-android-tester` with the plan path, plus any
     `TEST CREDENTIALS` the human supplied for this run (Part A, "Test
     Credentials"). It runs manual verification via `auto-mobile` and writes
     `test-results.md`. Wait for **either** `✅ TESTER DONE` **or**
     `⛔ TESTER BLOCKED` — both end its turn.
   - **Tester Blocked**: on `⛔ TESTER BLOCKED`, take "The Blocked Path" above
     instead of the fix loop, and do not advance.
   - **Tester Fix Loop**: on a `NEEDS FIXES` verdict, run the bounded
     Coder → targeted re-review → re-test loop the command file defines (max 2
     iterations), then STOP and report if it is still
     failing. In `/build-auto-reviewed` the targeted re-review is mandatory —
     see "The Targeted Re-Review" above; the code that ships must have been
     reviewed after its last mutation. A run never ends by declaring a
     `NEEDS FIXES` feature complete.
3. **Gates**: For `/build-guided`, pause at each phase boundary for explicit user approval — `approve`, `revise: <feedback>`, or `stop`, except at a blocked Tester gate, which takes `resume` or `stop` (see "Approval Gates" and "The Blocked Path"). For `/build-auto-reviewed`, the gates are the automated reviewer loops (no human pause). For `/build-auto`, there are no gates.
4. **Close the run**: when a design doc was produced, append its Implementation Notes before reporting the final summary (see "Design Doc Defaults Per Command"), and report the design doc path alongside the verdict.

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
   The `agents:` model settings in .agentic-dev-team/config.yaml cannot change this; see "Agent Configuration".
4. **Tester MCP**: the `auto-mobile` MCP (an HTTP server) is registered in
   `opencode.json` under the `mcp` key (`type: "remote"`, with auto-mobile's
   `url`); the Tester reaches it like any other tool.
5. **Rules**: agents and commands reference `.claude/AGENTIC_DEV_TEAM_PIPELINE.md`
   and the project's `AGENTS.md`/`CLAUDE.md` by path (both present in the project
   tree), so opencode reads the same sources of truth as the other tools.
