# LangGraph Orchestrator

The same PM → Architect → Coder → Tester pipeline as the markdown commands, with
the control flow enforced in code instead of described in prose.

It reads the **same agent prompts** — `plugins/agentic-dev-team/agents/adt-*.md`
and `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` stay the single source of truth, so a
persona edit still reaches Claude Code, Antigravity, opencode, and this graph at
once. No forked prompts.

```bash
python -m venv .venv && .venv/bin/pip install -e ".[dev,anthropic,openai]"
.venv/bin/pytest                     # 19 tests, no API keys needed
.venv/bin/python demo.py happy       # runnable trace with stubbed agents
.venv/bin/python demo.py exhausted   # the re-run cap actually stopping a run
.venv/bin/python demo.py panel       # Claude + GPT reviewer panel
```

## What moves from prose to code

| `AGENTIC_DEV_TEAM_PIPELINE.md` says | Here it is |
|---|---|
| "at most 2 re-runs (3 attempts total)" | a counter checked on a conditional edge |
| "STOP the entire pipeline and report" | a terminal node with a structured reason |
| "`Parallel-safe: YES` → spawn one Coder per section" | a parser + `Send` fan-out |
| "wait for ALL coders before the next group" | a barrier node |
| "run lint/detekt between groups" | `run_verify` at the barrier |
| "pause for explicit user approval" | `interrupt()` + checkpointer (survives restart) |
| "report re-run counts so the user can gauge cost" | measured per node, not narrated |
| reviewer verdict as a `✅`/`🔧` marker string | typed `Verdict` with structured findings |

The re-run cap is the clearest case. Today it is an instruction an orchestrating
LLM is asked to honor tens of thousands of tokens into a run. `test_plan_gate_stops_after_max_reruns`
hands the reviewer an endless stream of rejections and asserts the Architect is
invoked exactly 3 times and the Coder never runs.

## Executor routing: the part that matters

Roles have very different harness needs, so they get different backends.

| Role | Needs | Default executor |
|---|---|---|
| Coder | multi-file edits, build/fix loop, context mgmt | `ClaudeAgentSDKExecutor` |
| Tester | device driving via MCP | `ClaudeAgentSDKExecutor` |
| Architect | repo exploration, writes one file | `ClaudeAgentSDKExecutor` |
| PM | conversation, writes one file | `LangChainExecutor` |
| **Reviewers** | **read a diff, emit a verdict** | **`LangChainExecutor` (any provider)** |

This is why the graph does not require rebuilding a coding harness: the Agent SDK
exposes Claude Code's editing/bash/context machinery as a library, so the Coder
keeps that quality while the graph owns control flow. `SubprocessExecutor`
(`claude -p`, `opencode run`) is the fallback when the SDK isn't installed.

Reviewers are the exception, and deliberately so — they need almost no harness,
which is exactly what makes a cross-vendor panel practical.

## The reviewer panel

```bash
python -m adt_orchestrator.cli "add offline caching" --panel anthropic,openai
```

N reviewers run concurrently on different providers; an adjudicator merges their
findings — dedupe, resolve contradictions, drop style preferences. **This flow
has no representation as Claude Code subagents at all**: the `model:` field in an
agent file takes `opus`/`sonnet`/`haiku`, so a Claude+GPT panel cannot be
expressed there regardless of how the prompts are written.

Merge rules, in `review.py`:

- any `blocking` finding blocks, even if the reviewer's JSON claims `approved`
- an unparseable verdict is a **rejection** — failing open would ship code on a
  malformed response
- a panel member erroring out (rate limit, timeout) becomes a blocking finding,
  not a crash
- adjudicator unavailable → conservative union, never silent approval

With one member and no adjudicator this degrades to exactly the current
single-reviewer gate.

## Platform packs

`platforms.py` carries build/verify/install commands, the UI-selector idiom, and
the device MCP per platform. The graph is unchanged across all of them —
`test_same_graph_runs_for_a_non_android_platform` runs the whole pipeline on the
iOS pack and asserts `xcodebuild` and `accessibilityIdentifier` reached the
agents.

Android, iOS, KMP, Flutter, and React Native packs ship here. Note the real gap:
auto-mobile is Android-only, so iOS needs an idb/XCUITest-backed MCP. That is a
tooling gap, not an orchestration one — it exists no matter which orchestrator
you use.

The agent prompts themselves are still Android-flavored (the Architect carries 54
platform-specific references). Splitting role prompts from platform specifics is
the remaining work, and it is orchestrator-agnostic — the markdown pipeline needs
exactly the same refactor.

## What this does not replace

Honest scope, so the trade is visible:

- **Distribution.** The markdown pipeline installs with `install.sh` and runs
  inside the editor the developer already has open. This is a separate process
  they run in a terminal. For interactive work that is a real downgrade — keep
  both; they share prompts.
- **The coding harness.** The graph orchestrates; it does not edit files. That
  quality still comes from the Agent SDK or a headless CLI.
- **Interactive `/build-guided`.** `interrupt()` works and survives restarts, but
  the chat-native gate is a nicer experience than a terminal prompt.

The strongest case for running this one is a flow the markdown cannot express —
a cross-vendor reviewer panel — or a run where you need the gate caps enforced
and the cost attributed rather than narrated.

## Observability

Every node emits a structured event and a `Usage` record (provider, model,
tokens, cost, duration). `cost_by_role()` and `total_cost()` read straight off
final state; `--trace out.json` dumps the event log and every gate verdict with
its attempt number and panel size.

For full traces, `pip install -e ".[trace]"` and set `LANGCHAIN_TRACING_V2=true`
— LangGraph reports node-level spans to LangSmith with no code change here.

## Layout

```
adt_orchestrator/
  state.py        typed state; re-run counters, verdicts, usage
  graph.py        nodes, conditional edges, Send fan-out, interrupt gates
  executors.py    StubExecutor | ClaudeAgentSDK | Subprocess | LangChain
  review.py       multi-provider panel + adjudicator + merge rules
  plan_parser.py  Architect Section 3 -> ExecutionPlan (fails loudly)
  platforms.py    android | ios | kmp | flutter | react-native
  prompts.py      loads the existing adt-*.md — no forked prompts
  cli.py          real runs
tests/            19 tests, fully stubbed
demo.py           runnable traces
```
