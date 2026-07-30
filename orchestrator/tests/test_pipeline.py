"""Tests for the invariants the markdown pipeline can only state as prose."""

from __future__ import annotations

import pytest

from adt_orchestrator import (
    MAX_RERUNS_PER_GATE,
    ExecutorRouter,
    GraphConfig,
    ModelSpec,
    PanelMember,
    PlanFormatError,
    StubExecutor,
    initial_state,
    make_graph,
    parse_execution_plan,
    run_panel,
)
from adt_orchestrator.platforms import get as get_platform

# A plan in exactly the format `adt-android-architect.md` Section 3 specifies.
PARALLEL_PLAN = """
# Implementation Plan: Recently Played Carousel

## 3. Work Breakdown & Execution Strategy

### Parallelization Decision
**Parallel-safe**: YES
**Rationale**: Data and UI layers touch disjoint files with a stable contract.

### Execution Groups

Group 1 (run in parallel):
- Section A: Data Layer
  - Files: RecentlyPlayedRepository.kt, RecentlyPlayedDao.kt
  - Estimated complexity: medium
  - Public interface (contract for downstream groups):
    interface RecentlyPlayedRepository {
        suspend fun fetch(): Result<List<Track>>
    }
- Section B: Analytics
  - Files: RecentlyPlayedAnalytics.kt
  - Estimated complexity: low

Group 2 (run in parallel):
- Section C: UI
  - Files: RecentlyPlayedCarousel.kt, HomeScreen.kt
  - Estimated complexity: medium

## 4. Manual Testing Plan
### TC1: Happy path
"""

SEQUENTIAL_PLAN = """
## 3. Work Breakdown & Execution Strategy

### Parallelization Decision
**Parallel-safe**: NO
**Rationale**: Single-screen feature under 200 lines; coordination cost exceeds benefit.

### Execution Groups

Sequential:
- Section A: ViewModel — files: ComposeViewModel.kt
- Section B: Persistence — files: DraftDao.kt, DraftEntity.kt
"""

APPROVED = '✅ CODE APPROVED\n```json\n{"approved": true, "findings": []}\n```'
REJECTED = (
    '🔧 CODE CHANGES REQUESTED\n```json\n{"approved": false, "findings": '
    '[{"severity": "blocking", "summary": "missing null guard", '
    '"file": "Repo.kt", "line": 42}]}\n```'
)
PLAN_APPROVED = '✅ PLAN APPROVED\n```json\n{"approved": true, "findings": []}\n```'
PLAN_REJECTED = (
    '🔧 PLAN CHANGES REQUESTED\n```json\n{"approved": false, "findings": '
    '[{"severity": "blocking", "summary": "no offline case"}]}\n```'
)


def build(script, flow="auto_reviewed", **cfg_kwargs):
    stub = StubExecutor(script)
    cfg = GraphConfig(
        router=ExecutorRouter(default=stub),
        platform=get_platform("android"),
        write_artifacts=False,
        **cfg_kwargs,
    )
    graph = make_graph(cfg)
    state = initial_state("add a carousel", flow=flow, slug="carousel", repo_root="/tmp")
    return stub, graph, state


def run(graph, state, thread="t1"):
    return graph.invoke(
        state,
        config={"configurable": {"thread_id": thread}, "recursion_limit": 100},
    )


# ---------------------------------------------------------------- parser ----

def test_parses_parallel_groups():
    plan = parse_execution_plan(PARALLEL_PLAN)
    assert plan.parallel_safe is True
    assert len(plan.groups) == 2
    assert [len(g) for g in plan.groups] == [2, 1]
    assert plan.total_sections == 3
    assert "RecentlyPlayedRepository.kt" in plan.groups[0][0].files
    assert plan.groups[0][0].complexity == "medium"


def test_parses_sequential_as_one_group():
    plan = parse_execution_plan(SEQUENTIAL_PLAN)
    assert plan.parallel_safe is False
    assert len(plan.groups) == 1
    assert plan.total_sections == 2


def test_missing_parallel_safe_field_is_an_error():
    with pytest.raises(PlanFormatError, match="Parallel-safe"):
        parse_execution_plan("## 3. Work Breakdown\n\nJust do it however.")


def test_file_overlap_inside_a_group_is_rejected():
    bad = PARALLEL_PLAN.replace("RecentlyPlayedAnalytics.kt", "RecentlyPlayedDao.kt")
    with pytest.raises(PlanFormatError, match="share"):
        parse_execution_plan(bad)


# ------------------------------------------------------- reviewer gates ----

def test_plan_gate_stops_after_max_reruns():
    """The headline invariant: an endlessly unhappy reviewer cannot loop forever."""
    stub, graph, state = build({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": [PLAN_REJECTED],  # always rejects
    })
    final = run(graph, state)

    assert final["status"] == "stopped"
    assert "plan gate exhausted" in final["stop_reason"]
    # 1 initial + MAX_RERUNS_PER_GATE re-runs = 3 attempts, never more.
    assert len(stub.calls_for("architect")) == MAX_RERUNS_PER_GATE + 1
    assert final["plan_reruns"] == MAX_RERUNS_PER_GATE
    # It must not have advanced to later phases.
    assert stub.calls_for("coder") == []
    assert stub.calls_for("tester") == []


def test_code_gate_stops_after_max_reruns():
    stub, graph, state = build({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": [PLAN_APPROVED],
        "code-reviewer": [REJECTED],  # always rejects
        "coder": ["✅ CODER DONE"],
    })
    final = run(graph, state)

    assert final["status"] == "stopped"
    assert "code gate exhausted" in final["stop_reason"]
    assert final["code_reruns"] == MAX_RERUNS_PER_GATE
    assert stub.calls_for("tester") == []


def test_gate_recovers_when_reviewer_approves_on_retry():
    stub, graph, state = build({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": [PLAN_REJECTED, PLAN_APPROVED],
        "code-reviewer": [APPROVED],
        "coder": ["✅ CODER DONE"],
        "tester": ["## Verdict\nREADY TO MERGE\n✅ TESTER DONE"],
    })
    final = run(graph, state)

    assert final["status"] == "done"
    assert final["verdict_summary"] == "READY TO MERGE"
    assert len(stub.calls_for("architect")) == 2  # one re-run, then approved
    assert final["plan_reruns"] == 1


def test_unparseable_reviewer_response_blocks_rather_than_ships():
    stub, graph, state = build({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": ["I have thoughts but no verdict."],
    })
    final = run(graph, state)
    assert final["status"] == "stopped"
    assert stub.calls_for("coder") == []


# ------------------------------------------------------------- fan-out ----

def test_parallel_plan_spawns_one_coder_per_section():
    stub, graph, state = build({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": [PLAN_APPROVED],
        "code-reviewer": [APPROVED],
        "coder": ["✅ CODER DONE"],
        "tester": ["READY TO MERGE"],
    })
    final = run(graph, state)

    assert final["status"] == "done"
    # 3 sections across 2 groups -> 3 coder invocations, group-ordered.
    assert len(stub.calls_for("coder")) == 3
    sections = [r["section"] for r in final["coder_results"]]
    assert sorted(sections) == ["Section A: Data Layer", "Section B: Analytics", "Section C: UI"]


def test_sequential_plan_spawns_exactly_one_coder():
    stub, graph, state = build({
        "architect": [SEQUENTIAL_PLAN],
        "architect-reviewer": [PLAN_APPROVED],
        "code-reviewer": [APPROVED],
        "coder": ["✅ CODER DONE"],
        "tester": ["READY TO MERGE"],
    })
    final = run(graph, state)
    assert len(stub.calls_for("coder")) == 1
    assert "sequentially" in stub.calls_for("coder")[0].task


def test_verify_gate_runs_between_groups_and_can_halt():
    calls = []

    def failing_verify(cwd):
        calls.append(cwd)
        return False, "detekt: 3 issues"

    stub, graph, state = build(
        {
            "architect": [PARALLEL_PLAN],
            "architect-reviewer": [PLAN_APPROVED],
            "coder": ["✅ CODER DONE"],
        },
        run_verify=failing_verify,
    )
    final = run(graph, state)

    assert len(calls) == 1  # ran after group 1, before group 2
    assert final["status"] == "stopped"
    assert "verify gate failed" in final["stop_reason"]
    assert len(stub.calls_for("coder")) == 2  # group 2 never started


def test_malformed_plan_halts_instead_of_guessing_fanout():
    stub, graph, state = build({"architect": ["A plan with no execution strategy."]})
    final = run(graph, state)
    assert final["status"] == "stopped"
    assert "not machine-readable" in final["stop_reason"]
    assert stub.calls_for("coder") == []


# --------------------------------------------------------- human gates ----

def test_guided_flow_interrupts_at_the_pm_gate():
    stub, graph, state = build(
        {"pm": ["# Feature spec\n✅ PM DONE"], "architect": [PARALLEL_PLAN]},
        flow="guided",
    )
    cfg = {"configurable": {"thread_id": "guided-1"}, "recursion_limit": 100}
    result = graph.invoke(state, config=cfg)

    assert "__interrupt__" in result
    payload = result["__interrupt__"][0].value
    assert payload["gate"] == "pm"
    assert "approve" in payload["accepts"]
    # Architect must not have run before the human approved.
    assert stub.calls_for("architect") == []


def test_guided_flow_stop_decision_halts_the_run():
    from langgraph.types import Command

    stub, graph, state = build(
        {"pm": ["# Feature spec"], "architect": [PARALLEL_PLAN]}, flow="guided"
    )
    cfg = {"configurable": {"thread_id": "guided-2"}, "recursion_limit": 100}
    graph.invoke(state, config=cfg)
    final = graph.invoke(Command(resume="stop"), config=cfg)

    assert final["status"] == "stopped"
    assert "user stopped" in final["stop_reason"]
    assert stub.calls_for("architect") == []


# ------------------------------------------------------- reviewer panel ----

def test_panel_fans_out_across_providers_and_blocks_on_any_blocking_finding():
    claude = StubExecutor({"reviewer:claude": [APPROVED]})
    gpt = StubExecutor({"reviewer:gpt": [REJECTED]})
    members = [
        PanelMember("claude", claude, ModelSpec("anthropic", "claude-opus-5")),
        PanelMember("gpt", gpt, ModelSpec("openai", "gpt-5")),
    ]
    final, individual, usage = run_panel(members, system_prompt="review", task="the diff")

    assert len(individual) == 2
    assert {v.provider for v in individual} == {"anthropic", "openai"}
    assert final.approved is False  # one blocking finding blocks the union
    assert len(usage) == 2


def test_panel_adjudicator_can_overrule_the_union():
    claude = StubExecutor({"reviewer:claude": [APPROVED]})
    gpt = StubExecutor({"reviewer:gpt": [REJECTED]})
    judge = StubExecutor({"reviewer:adjudicator": [
        '```json\n{"approved": true, "findings": '
        '[{"severity": "minor", "summary": "style nit, not blocking"}]}\n```'
    ]})
    members = [
        PanelMember("claude", claude, ModelSpec("anthropic", "claude-opus-5")),
        PanelMember("gpt", gpt, ModelSpec("openai", "gpt-5")),
    ]
    final, _, usage = run_panel(
        members, system_prompt="review", task="the diff",
        adjudicator=PanelMember("judge", judge, ModelSpec("anthropic", "claude-opus-5")),
    )

    assert final.approved is True
    assert final.reviewer == "adjudicator"
    assert len(usage) == 3  # 2 panel + 1 adjudicator


def test_panel_member_failure_is_a_blocking_finding_not_a_crash():
    class Boom:
        name = "boom"

        def run(self, req):
            from adt_orchestrator.executors import AgentResult

            return AgentResult(text="", ok=False, error="429 rate limited")

    members = [
        PanelMember("claude", StubExecutor({"reviewer:claude": [APPROVED]}),
                    ModelSpec("anthropic", "claude-opus-5")),
        PanelMember("gpt", Boom(), ModelSpec("openai", "gpt-5")),
    ]
    final, individual, _ = run_panel(members, system_prompt="review", task="diff")
    assert final.approved is False
    assert any("rate limited" in f.summary for f in final.findings)


# ------------------------------------------------------- observability ----

def test_run_records_per_role_cost_and_events():
    from adt_orchestrator.state import cost_by_role, total_cost

    stub, graph, state = build({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": [PLAN_APPROVED],
        "code-reviewer": [APPROVED],
        "coder": ["✅ CODER DONE"],
        "tester": ["READY TO MERGE"],
    })
    final = run(graph, state)

    assert total_cost(final) > 0
    roles = cost_by_role(final)
    assert {"architect", "coder", "tester"} <= set(roles)
    kinds = {e["kind"] for e in final["events"]}
    assert {"agent", "review", "group_complete"} <= kinds
    # Both gates recorded a verdict with its panel size and attempt number.
    assert {v["gate"] for v in final["verdicts"]} == {"plan", "code"}


# ---------------------------------------------------------- portability ----

def test_same_graph_runs_for_a_non_android_platform():
    stub = StubExecutor({
        "architect": [SEQUENTIAL_PLAN],
        "architect-reviewer": [PLAN_APPROVED],
        "code-reviewer": [APPROVED],
        "coder": ["✅ CODER DONE"],
        "tester": ["READY TO MERGE"],
    })
    cfg = GraphConfig(
        router=ExecutorRouter(default=stub),
        platform=get_platform("ios"),
        write_artifacts=False,
    )
    graph = make_graph(cfg)
    final = run(graph, initial_state("add a carousel", flow="auto_reviewed", repo_root="/tmp"))

    assert final["status"] == "done"
    # The iOS pack reached the agents; the graph itself did not change.
    assert "xcodebuild" in stub.calls_for("coder")[0].system_prompt
    assert "accessibilityIdentifier" in stub.calls_for("architect")[0].system_prompt
