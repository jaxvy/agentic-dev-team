"""The pipeline as a LangGraph state machine.

Same shape as the markdown flows — PM → Architect → Coder → Tester with two
reviewer gates — but the parts that are prose instructions today are code here:

  * the "at most 2 re-runs" cap is a counter the graph checks, not a rule an
    orchestrating LLM is asked to remember 60k tokens into a run
  * the parallel-safety decision is parsed and fanned out with `Send`
  * `/build-guided` approval gates are `interrupt()` + checkpointer, so a run
    survives the process exiting
  * every node emits structured usage, so cost per role is measured, not narrated
"""

from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Send, interrupt

from .executors import AgentRequest, ExecutorRouter, ModelSpec
from .plan_parser import PlanFormatError, parse_execution_plan
from .platforms import PlatformPack, get as get_platform
from .prompts import load_agent, system_prompt
from .review import PanelMember, format_feedback, run_panel
from .state import (
    MAX_RERUNS_PER_GATE,
    ExecutionPlan,
    PipelineState,
    Section,
    Usage,
    Verdict,
)


@dataclass
class GraphConfig:
    """Everything swappable about a run."""

    router: ExecutorRouter
    platform: PlatformPack = field(default_factory=lambda: get_platform("android"))
    plan_panel: list[PanelMember] = field(default_factory=list)
    code_panel: list[PanelMember] = field(default_factory=list)
    plan_adjudicator: PanelMember | None = None
    code_adjudicator: PanelMember | None = None
    agents_dir: str | None = None
    agent_prefix: str = "adt-android"
    run_verify: Callable[[str], tuple[bool, str]] | None = None
    write_artifacts: bool = True

    def agent_name(self, role: str) -> str:
        return f"{self.agent_prefix}-{role}"


def _event(kind: str, **fields: Any) -> dict[str, Any]:
    return {"kind": kind, "ts": round(time.time(), 3), **fields}


def _artifact_path(state: PipelineState, filename: str) -> Path:
    return Path(state["repo_root"]) / state["artifacts_dir"] / filename


def _run_agent(
    cfg: GraphConfig,
    state: PipelineState,
    role: str,
    task: str,
) -> tuple[str, Usage, bool, str]:
    """Invoke one role through its routed executor. Returns (text, usage, ok, error)."""
    agent = load_agent(cfg.agent_name(role), cfg.agents_dir)
    executor = cfg.router.for_role(role)
    result = executor.run(
        AgentRequest(
            role=role,
            system_prompt=system_prompt(agent, cfg.platform.as_prompt()),
            task=task,
            cwd=state["repo_root"],
            allowed_tools=agent.tools,
            model=ModelSpec("anthropic", agent.model_hint),
        )
    )
    return result.text, result.usage, result.ok, result.error


def _persist(state: PipelineState, filename: str, text: str, cfg: GraphConfig) -> str:
    """Write an artifact if the agent did not write it itself."""
    rel = f"{state['artifacts_dir']}/{filename}"
    if not cfg.write_artifacts:
        return rel
    path = _artifact_path(state, filename)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() and text.strip():
        path.write_text(text, encoding="utf-8")
    return rel


def _read_artifact(state: PipelineState, filename: str) -> str:
    path = _artifact_path(state, filename)
    return path.read_text(encoding="utf-8") if path.exists() else ""


def _stop(reason: str, **extra: Any) -> dict[str, Any]:
    return {"status": "stopped", "stop_reason": reason,
            "events": [_event("stop", reason=reason, **extra)]}


# --------------------------------------------------------------------------
# nodes
# --------------------------------------------------------------------------

def make_graph(cfg: GraphConfig, checkpointer: Any | None = None):
    """Build and compile the pipeline graph."""

    def pm(state: PipelineState) -> dict[str, Any]:
        text, usage, ok, err = _run_agent(
            cfg, state, "pm",
            f"Refine this idea into a concrete feature spec and write it to "
            f"{state['artifacts_dir']}/feature.md:\n\n{state['request']}",
        )
        if not ok:
            return _stop(f"PM failed: {err}")
        rel = _persist(state, "feature.md", text, cfg)
        return {
            "feature_path": rel,
            "usage": [usage],
            "events": [_event("agent", role="pm", ok=True, artifact=rel)],
        }

    def pm_gate(state: PipelineState) -> dict[str, Any]:
        decision = interrupt({
            "gate": "pm",
            "artifact": state.get("feature_path", ""),
            "preview": _read_artifact(state, "feature.md")[:2000],
            "accepts": ["approve", "revise: <feedback>", "stop"],
        })
        return _handle_gate(decision, "pm")

    def architect(state: PipelineState) -> dict[str, Any]:
        feedback = state.get("plan_feedback") or []
        attempt = state.get("plan_reruns", 0) + 1
        if feedback:
            task = (
                f"Revise the plan at {state['artifacts_dir']}/implementation-plan.md "
                f"IN PLACE to address this reviewer feedback:\n\n{feedback[-1]}"
            )
        elif state.get("feature_path"):
            task = (
                f"Read {state['feature_path']} in full, then write the implementation "
                f"plan to {state['artifacts_dir']}/implementation-plan.md"
            )
        else:
            task = (
                f"Write an implementation plan to "
                f"{state['artifacts_dir']}/implementation-plan.md for:\n\n{state['request']}"
            )

        text, usage, ok, err = _run_agent(cfg, state, "architect", task)
        if not ok:
            return _stop(f"Architect failed: {err}")
        rel = _persist(state, "implementation-plan.md", text, cfg)

        plan_md = _read_artifact(state, "implementation-plan.md") or text
        try:
            execution_plan = parse_execution_plan(plan_md)
        except PlanFormatError as exc:
            # In the markdown pipeline this is where a malformed plan silently
            # produces the wrong number of Coders. Here it is a hard stop.
            return _stop(f"plan is not machine-readable: {exc}", artifact=rel)

        return {
            "plan_path": rel,
            "execution_plan": execution_plan,
            "group_cursor": 0,
            "usage": [usage],
            "events": [_event("agent", role="architect", ok=True, artifact=rel,
                              attempt=attempt, parallel_safe=execution_plan.parallel_safe,
                              sections=execution_plan.total_sections)],
        }

    def architect_review(state: PipelineState) -> dict[str, Any]:
        return _review_gate(state, gate="plan")

    def code_review(state: PipelineState) -> dict[str, Any]:
        return _review_gate(state, gate="code")

    def _review_gate(state: PipelineState, gate: str) -> dict[str, Any]:
        role = "architect-reviewer" if gate == "plan" else "code-reviewer"
        panel = cfg.plan_panel if gate == "plan" else cfg.code_panel
        adjudicator = cfg.plan_adjudicator if gate == "plan" else cfg.code_adjudicator
        agent = load_agent(cfg.agent_name(role), cfg.agents_dir)

        if gate == "plan":
            task = f"Review the implementation plan at {state['plan_path']}."
        else:
            task = (
                f"Review the uncommitted diff in this working tree against the plan "
                f"at {state['plan_path']} and the project's conventions."
            )

        if not panel:  # single-reviewer parity with the markdown pipeline
            text, usage, ok, err = _run_agent(cfg, state, role, task)
            from .review import _parse_verdict

            verdict = (
                _parse_verdict(text, role, "anthropic")
                if ok
                else Verdict(False, role, "anthropic", raw=err)
            )
            usages = [usage]
        else:
            verdict, members, usages = run_panel(
                panel,
                system_prompt=system_prompt(agent, cfg.platform.as_prompt()),
                task=task,
                cwd=state["repo_root"],
                adjudicator=adjudicator,
            )

        key = f"{gate}_feedback"
        out: dict[str, Any] = {
            "usage": usages,
            "verdicts": [{
                "gate": gate,
                "approved": verdict.approved,
                "reviewer": verdict.reviewer,
                "provider": verdict.provider,
                "attempt": state.get(f"{gate}_reruns", 0) + 1,
                "blocking": len(verdict.blocking),
                "panel_size": len(panel) or 1,
            }],
            "events": [_event("review", gate=gate, approved=verdict.approved,
                              panel_size=len(panel) or 1,
                              findings=len(verdict.findings))],
        }
        if not verdict.approved:
            out[key] = list(state.get(key, [])) + [format_feedback(verdict)]
        return out

    def coder_join(state: PipelineState) -> dict[str, Any]:
        """Barrier after each execution group; runs the cross-section verify gate."""
        plan: ExecutionPlan = state["execution_plan"]
        cursor = state.get("group_cursor", 0)
        events = [_event("group_complete", group=cursor + 1, of=len(plan.groups))]

        failures = [r for r in state.get("coder_results", []) if not r.get("ok")]
        if failures:
            return _stop(
                f"coder reported a problem: {failures[0].get('error', 'unknown')}",
                group=cursor + 1,
            )

        # Between groups the orchestrator runs the verify gate to catch
        # cross-section breakage before the next group starts.
        more_groups = cursor + 1 < len(plan.groups)
        if more_groups and cfg.run_verify:
            ok, output = cfg.run_verify(state["repo_root"])
            events.append(_event("verify", group=cursor + 1, ok=ok))
            if not ok:
                return _stop(f"verify gate failed after group {cursor + 1}: {output[:500]}")

        return {"group_cursor": cursor + 1, "events": events}

    def coder(payload: dict[str, Any]) -> dict[str, Any]:
        """One Coder working one section. Reached only via `Send`."""
        state: PipelineState = payload["_state"]
        section: Section | None = payload.get("section")
        plan: ExecutionPlan = state["execution_plan"]

        if payload.get("fix_mode"):
            task = (
                f"Read {state['plan_path']} in full. Address exactly this reviewer "
                f"feedback, changing nothing else:\n\n{payload['feedback']}"
            )
            label = "fix"
        elif section is None:  # sequential: one Coder walks every section in order
            listing = "\n".join(f"- {s.name}" for g in plan.groups for s in g)
            task = (
                f"Read {state['plan_path']} in full and implement all sections "
                f"sequentially in this order:\n\n{listing}"
            )
            label = "sequential"
        else:
            task = (
                f"Read {state['plan_path']} in full. Implement ONLY {section.name}. "
                f"Do not touch files outside this list: {', '.join(section.files) or 'see plan'}. "
                f"Other coders are working on other sections concurrently."
            )
            label = section.name

        text, usage, ok, err = _run_agent(cfg, state, "coder", task)
        return {
            "coder_results": [{
                "section": label, "ok": ok, "error": err,
                "done_marker": "coder done" in text.lower(),
            }],
            "usage": [usage],
            "events": [_event("agent", role="coder", section=label, ok=ok)],
        }

    def coder_fix(state: PipelineState) -> dict[str, Any]:
        """Re-run after CODE CHANGES REQUESTED — always a single Coder."""
        feedback = (state.get("code_feedback") or ["(no feedback captured)"])[-1]
        result = coder({"_state": state, "fix_mode": True, "feedback": feedback})
        result["code_reruns"] = state.get("code_reruns", 0) + 1
        return result

    def tester(state: PipelineState) -> dict[str, Any]:
        text, usage, ok, err = _run_agent(
            cfg, state, "tester",
            f"Read the Manual Testing Plan in {state['plan_path']} and execute it. "
            f"Write results to {state['artifacts_dir']}/test-results.md",
        )
        if not ok:
            return _stop(f"Tester failed: {err}")
        rel = _persist(state, "test-results.md", text, cfg)
        results = _read_artifact(state, "test-results.md") or text
        needs_fixes = "needs fixes" in results.lower()
        return {
            "test_results_path": rel,
            "status": "done",
            "verdict_summary": "NEEDS FIXES" if needs_fixes else "READY TO MERGE",
            "usage": [usage],
            "events": [_event("agent", role="tester", ok=True, artifact=rel)],
        }

    def plan_gate(state: PipelineState) -> dict[str, Any]:
        decision = interrupt({
            "gate": "architect",
            "artifact": state.get("plan_path", ""),
            "preview": _read_artifact(state, "implementation-plan.md")[:2000],
            "accepts": ["approve", "revise: <feedback>", "stop"],
        })
        return _handle_gate(decision, "plan")

    def code_gate(state: PipelineState) -> dict[str, Any]:
        decision = interrupt({
            "gate": "coder",
            "sections": [r["section"] for r in state.get("coder_results", [])],
            "accepts": ["approve", "revise: <feedback>", "stop"],
        })
        return _handle_gate(decision, "code")

    def _handle_gate(decision: Any, gate: str) -> dict[str, Any]:
        text = (decision if isinstance(decision, str) else str(decision or "")).strip()
        lowered = text.lower()
        if lowered.startswith("stop"):
            return _stop(f"user stopped at the {gate} gate")
        if lowered.startswith("revise"):
            feedback = text.partition(":")[2].strip() or "(no detail given)"
            key = "plan_feedback" if gate in {"plan", "pm"} else "code_feedback"
            return {key: [feedback],
                    "events": [_event("gate", gate=gate, decision="revise")]}
        return {"events": [_event("gate", gate=gate, decision="approve")]}

    def stopped(state: PipelineState) -> dict[str, Any]:
        return {"status": "stopped"}

    # ----------------------------------------------------------------------
    # routing
    # ----------------------------------------------------------------------

    def entry(state: PipelineState) -> str:
        return "pm" if state["flow"] == "guided" else "architect"

    def after_pm(state: PipelineState) -> str:
        if state.get("status") == "stopped":
            return "stopped"
        return "pm_gate" if state["flow"] == "guided" else "architect"

    def after_pm_gate(state: PipelineState) -> str:
        if state.get("status") == "stopped":
            return "stopped"
        return "pm" if state.get("plan_feedback") else "architect"

    def after_architect(state: PipelineState) -> str:
        if state.get("status") == "stopped":
            return "stopped"
        if state["flow"] == "auto_reviewed":
            return "architect_review"
        if state["flow"] == "guided":
            return "plan_gate"
        return "coder_dispatch"

    def after_plan_review(state: PipelineState) -> str:
        latest = _latest_verdict(state, "plan")
        if latest and latest["approved"]:
            return "coder_dispatch"
        if state.get("plan_reruns", 0) >= MAX_RERUNS_PER_GATE:
            return "gate_exhausted_plan"
        return "architect_rerun"

    def after_plan_gate(state: PipelineState) -> str:
        if state.get("status") == "stopped":
            return "stopped"
        return "architect" if state.get("plan_feedback") else "coder_dispatch"

    def fan_out(state: PipelineState) -> list[Send] | str:
        """The Architect's parallel-safety decision, executed."""
        if state.get("status") == "stopped":
            return "stopped"
        plan: ExecutionPlan = state["execution_plan"]
        cursor = state.get("group_cursor", 0)
        if cursor >= len(plan.groups):
            return "coder_join"
        group = plan.groups[cursor]
        if not plan.parallel_safe:
            return [Send("coder", {"_state": state, "section": None})]
        return [Send("coder", {"_state": state, "section": s}) for s in group]

    def after_join(state: PipelineState) -> str:
        if state.get("status") == "stopped":
            return "stopped"
        plan: ExecutionPlan = state["execution_plan"]
        if state.get("group_cursor", 0) < len(plan.groups):
            return "coder_dispatch"
        if state["flow"] == "auto_reviewed":
            return "code_review"
        if state["flow"] == "guided":
            return "code_gate"
        return "tester"

    def after_code_review(state: PipelineState) -> str:
        latest = _latest_verdict(state, "code")
        if latest and latest["approved"]:
            return "tester"
        if state.get("code_reruns", 0) >= MAX_RERUNS_PER_GATE:
            return "gate_exhausted_code"
        return "coder_fix"

    def after_code_gate(state: PipelineState) -> str:
        if state.get("status") == "stopped":
            return "stopped"
        return "coder_fix" if state.get("code_feedback") else "tester"

    def _latest_verdict(state: PipelineState, gate: str) -> dict[str, Any] | None:
        matching = [v for v in state.get("verdicts", []) if v["gate"] == gate]
        return matching[-1] if matching else None

    def architect_rerun(state: PipelineState) -> dict[str, Any]:
        """Increment the counter, then hand back to the Architect."""
        return {"plan_reruns": state.get("plan_reruns", 0) + 1,
                "events": [_event("rerun", gate="plan",
                                  attempt=state.get("plan_reruns", 0) + 1)]}

    def gate_exhausted_plan(state: PipelineState) -> dict[str, Any]:
        return _stop(
            f"plan gate exhausted after {MAX_RERUNS_PER_GATE} re-runs "
            f"({MAX_RERUNS_PER_GATE + 1} attempts); unresolved feedback: "
            f"{(state.get('plan_feedback') or ['n/a'])[-1][:300]}"
        )

    def gate_exhausted_code(state: PipelineState) -> dict[str, Any]:
        return _stop(
            f"code gate exhausted after {MAX_RERUNS_PER_GATE} re-runs "
            f"({MAX_RERUNS_PER_GATE + 1} attempts); unresolved feedback: "
            f"{(state.get('code_feedback') or ['n/a'])[-1][:300]}"
        )

    # ----------------------------------------------------------------------
    # wiring
    # ----------------------------------------------------------------------

    g = StateGraph(PipelineState)
    for name, fn in [
        ("pm", pm), ("pm_gate", pm_gate),
        ("architect", architect), ("architect_review", architect_review),
        ("architect_rerun", architect_rerun), ("plan_gate", plan_gate),
        ("coder_dispatch", lambda s: {}), ("coder", coder), ("coder_join", coder_join),
        ("coder_fix", coder_fix), ("code_review", code_review), ("code_gate", code_gate),
        ("tester", tester), ("stopped", stopped),
        ("gate_exhausted_plan", gate_exhausted_plan),
        ("gate_exhausted_code", gate_exhausted_code),
    ]:
        g.add_node(name, fn)

    g.add_conditional_edges(START, entry, ["pm", "architect"])
    g.add_conditional_edges("pm", after_pm, ["pm_gate", "architect", "stopped"])
    g.add_conditional_edges("pm_gate", after_pm_gate, ["pm", "architect", "stopped"])
    g.add_conditional_edges(
        "architect", after_architect,
        ["architect_review", "plan_gate", "coder_dispatch", "stopped"],
    )
    g.add_conditional_edges(
        "architect_review", after_plan_review,
        ["coder_dispatch", "architect_rerun", "gate_exhausted_plan"],
    )
    g.add_edge("architect_rerun", "architect")
    g.add_conditional_edges("plan_gate", after_plan_gate,
                            ["architect", "coder_dispatch", "stopped"])
    g.add_conditional_edges("coder_dispatch", fan_out, ["coder", "coder_join", "stopped"])
    g.add_edge("coder", "coder_join")
    g.add_conditional_edges(
        "coder_join", after_join,
        ["coder_dispatch", "code_review", "code_gate", "tester", "stopped"],
    )
    g.add_conditional_edges("code_review", after_code_review,
                            ["tester", "coder_fix", "gate_exhausted_code"])
    g.add_edge("coder_fix", "code_review")
    g.add_conditional_edges("code_gate", after_code_gate,
                            ["coder_fix", "tester", "stopped"])
    g.add_edge("tester", END)
    g.add_edge("stopped", END)
    g.add_edge("gate_exhausted_plan", END)
    g.add_edge("gate_exhausted_code", END)

    return g.compile(checkpointer=checkpointer or MemorySaver())


def default_verify(platform: PlatformPack) -> Callable[[str], tuple[bool, str]]:
    """Between-group verify gate for the platform (`./gradlew lint detekt ...`)."""

    def _verify(cwd: str) -> tuple[bool, str]:
        proc = subprocess.run(
            platform.verify_cmd, shell=True, cwd=cwd,
            capture_output=True, text=True, timeout=3600,
        )
        return proc.returncode == 0, (proc.stdout + proc.stderr)[-4000:]

    return _verify
