"""Runnable trace of the graph with stubbed agents — no API keys needed.

    python demo.py            # reviewer-gated happy path, parallel fan-out
    python demo.py exhausted  # reviewer never satisfied -> hard stop at the cap
    python demo.py panel      # Claude + GPT reviewer panel with an adjudicator
"""

from __future__ import annotations

import sys
import threading
import time

from adt_orchestrator import (
    ExecutorRouter,
    GraphConfig,
    ModelSpec,
    PanelMember,
    StubExecutor,
    initial_state,
    make_graph,
    run_panel,
)
from adt_orchestrator.platforms import get as get_platform
from adt_orchestrator.state import cost_by_role, total_cost

sys.path.insert(0, "tests")
from test_pipeline import APPROVED, PARALLEL_PLAN, PLAN_APPROVED, PLAN_REJECTED, REJECTED  # noqa: E402


class TimedStub(StubExecutor):
    """Stub that sleeps, so concurrent fan-out is visible in wall-clock time."""

    def __init__(self, script, delay=0.3):
        super().__init__(script)
        self.delay = delay
        self.timeline: list[tuple[str, float, float, str]] = []
        self._lock = threading.Lock()
        self._t0 = time.monotonic()

    def run(self, req):
        start = time.monotonic() - self._t0
        if req.role == "coder":
            time.sleep(self.delay)
        result = super().run(req)
        with self._lock:
            self.timeline.append(
                (req.role, start, time.monotonic() - self._t0,
                 req.task.split(".")[0][:52])
            )
        return result


def banner(title: str) -> None:
    print(f"\n{'=' * 74}\n  {title}\n{'=' * 74}")


def happy_path() -> None:
    banner("build-auto-reviewed — parallel fan-out, both gates pass")
    stub = TimedStub({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": [PLAN_APPROVED],
        "code-reviewer": [APPROVED],
        "coder": ["✅ CODER DONE"],
        "tester": ["## Verdict\nREADY TO MERGE"],
    })
    graph = make_graph(GraphConfig(
        router=ExecutorRouter(default=stub),
        platform=get_platform("android"),
        write_artifacts=False,
    ))
    final = graph.invoke(
        initial_state("add a recently-played carousel", flow="auto_reviewed", repo_root="/tmp"),
        config={"configurable": {"thread_id": "demo"}, "recursion_limit": 100},
    )

    print("\n  role            start    end   task")
    print("  " + "-" * 70)
    for role, start, end, task in sorted(stub.timeline, key=lambda r: r[1]):
        print(f"  {role:<15} {start:5.2f}s {end:5.2f}s  {task}")

    coder_spans = [(s, e) for r, s, e, _ in stub.timeline if r == "coder"]
    group1 = sorted(coder_spans)[:2]
    overlap = min(group1[0][1], group1[1][1]) - max(group1[0][0], group1[1][0])
    print(f"\n  Group 1's two coders overlapped for {overlap:.2f}s "
          f"-> genuinely concurrent, not sequential")
    print(f"  Group 2 started after Group 1's barrier: "
          f"{sorted(coder_spans)[2][0] > max(e for _, e in group1)}")

    print(f"\n  status          : {final['status']}")
    print(f"  verdict         : {final['verdict_summary']}")
    print(f"  coders spawned  : {len(coder_spans)}")
    print(f"  plan re-runs    : {final['plan_reruns']}   code re-runs: {final['code_reruns']}")
    print(f"  total cost      : ${total_cost(final)}")
    print(f"  cost by role    : {cost_by_role(final)}")


def exhausted() -> None:
    banner("Reviewer never satisfied — the cap is enforced, not hoped for")
    stub = StubExecutor({
        "architect": [PARALLEL_PLAN],
        "architect-reviewer": [PLAN_REJECTED],  # rejects forever
    })
    graph = make_graph(GraphConfig(
        router=ExecutorRouter(default=stub),
        platform=get_platform("android"),
        write_artifacts=False,
    ))
    final = graph.invoke(
        initial_state("add a carousel", flow="auto_reviewed", repo_root="/tmp"),
        config={"configurable": {"thread_id": "demo-x"}, "recursion_limit": 100},
    )
    print(f"\n  architect attempts : {len(stub.calls_for('architect'))}  (1 initial + 2 re-runs)")
    print(f"  coder attempts     : {len(stub.calls_for('coder'))}  (never reached)")
    print(f"  status             : {final['status']}")
    print(f"  stop_reason        : {final['stop_reason'][:96]}")


def panel() -> None:
    banner("Multi-provider reviewer panel — impossible as Claude Code subagents")
    claude = StubExecutor({"reviewer:claude": [APPROVED]})
    gpt = StubExecutor({"reviewer:gpt": [REJECTED]})
    judge = StubExecutor({"reviewer:adjudicator": [
        '```json\n{"approved": false, "findings": [{"severity": "blocking", '
        '"summary": "null guard genuinely missing; claude missed it", '
        '"file": "Repo.kt", "line": 42}]}\n```'
    ]})
    members = [
        PanelMember("claude", claude, ModelSpec("anthropic", "claude-opus-5")),
        PanelMember("gpt", gpt, ModelSpec("openai", "gpt-5")),
    ]
    final, individual, usage = run_panel(
        members, system_prompt="review the diff", task="the uncommitted diff",
        adjudicator=PanelMember("judge", judge, ModelSpec("anthropic", "claude-opus-5")),
    )
    for v in individual:
        print(f"  {v.reviewer:<8} ({v.provider:<9}) -> "
              f"{'APPROVED' if v.approved else 'CHANGES REQUESTED':<18} "
              f"{len(v.findings)} finding(s)")
    print(f"\n  adjudicated      : {'APPROVED' if final.approved else 'CHANGES REQUESTED'}")
    print(f"  surviving        : {[f.summary[:52] for f in final.findings]}")
    print(f"  panel cost       : ${round(sum(u.cost_usd for u in usage), 5)} "
          f"across {len({u.provider for u in usage})} providers")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "happy"
    {"happy": happy_path, "exhausted": exhausted, "panel": panel}[mode]()
    print()
