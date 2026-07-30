"""Typed pipeline state.

Every invariant that `AGENTIC_DEV_TEAM_PIPELINE.md` states in prose lives here as
a field the graph can actually enforce: re-run counters, gate verdicts, the
execution-group cursor, and a structured event log for observability.
"""

from __future__ import annotations

import operator
from dataclasses import dataclass, field
from typing import Annotated, Any, Literal, TypedDict

Flow = Literal["auto", "auto_reviewed", "guided"]
Phase = Literal["pm", "architect", "coder", "tester"]
Gate = Literal["plan", "code"]

# `AGENTIC_DEV_TEAM_PIPELINE.md`: "Each gate allows at most 2 re-runs
# (3 production attempts total)." In markdown that is a hope; here it is a bound.
MAX_RERUNS_PER_GATE = 2


@dataclass(frozen=True)
class Section:
    """One unit of Coder work, parsed from plan Section 3."""

    name: str
    files: tuple[str, ...] = ()
    complexity: str = "unknown"
    contract: str = ""


@dataclass(frozen=True)
class ExecutionPlan:
    """The Architect's parallel-safety decision, as data rather than prose."""

    parallel_safe: bool
    groups: tuple[tuple[Section, ...], ...]
    rationale: str = ""

    @property
    def total_sections(self) -> int:
        return sum(len(g) for g in self.groups)


@dataclass
class Finding:
    """One reviewer finding. Structured so a panel can dedupe and merge."""

    reviewer: str
    severity: Literal["blocking", "major", "minor"]
    summary: str
    file: str | None = None
    line: int | None = None


@dataclass
class Verdict:
    """A reviewer's decision. Replaces marker-string sniffing."""

    approved: bool
    reviewer: str
    provider: str
    findings: list[Finding] = field(default_factory=list)
    raw: str = ""

    @property
    def blocking(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "blocking"]


@dataclass
class Usage:
    """Per-node cost/latency. The thing the markdown orchestrator can only guess at."""

    provider: str = ""
    model: str = ""
    tokens_in: int = 0
    tokens_out: int = 0
    cost_usd: float = 0.0
    duration_s: float = 0.0


class PipelineState(TypedDict, total=False):
    # --- inputs ---
    request: str
    flow: Flow
    platform: str
    slug: str
    artifacts_dir: str
    repo_root: str

    # --- artifacts (the handoff contract) ---
    feature_path: str
    plan_path: str
    test_results_path: str

    # --- execution strategy ---
    execution_plan: ExecutionPlan
    group_cursor: int

    # --- reviewer loops: counters the graph enforces ---
    plan_reruns: int
    code_reruns: int
    plan_feedback: list[str]
    code_feedback: list[str]

    # --- accumulating channels (parallel-safe reducers) ---
    coder_results: Annotated[list[dict[str, Any]], operator.add]
    verdicts: Annotated[list[dict[str, Any]], operator.add]
    events: Annotated[list[dict[str, Any]], operator.add]
    usage: Annotated[list[Usage], operator.add]

    # --- terminal ---
    status: Literal["running", "done", "stopped"]
    stop_reason: str
    verdict_summary: str


def initial_state(
    request: str,
    *,
    flow: Flow = "auto_reviewed",
    slug: str = "",
    platform: str = "android",
    repo_root: str = ".",
) -> PipelineState:
    slug = slug or _slugify(request)
    return PipelineState(
        request=request,
        flow=flow,
        platform=platform,
        slug=slug,
        repo_root=repo_root,
        artifacts_dir=f"pipeline_artifacts/{slug}",
        group_cursor=0,
        plan_reruns=0,
        code_reruns=0,
        plan_feedback=[],
        code_feedback=[],
        coder_results=[],
        verdicts=[],
        events=[],
        usage=[],
        status="running",
    )


def _slugify(text: str, max_words: int = 5) -> str:
    words = [w for w in "".join(c if c.isalnum() or c.isspace() else " " for c in text.lower()).split()]
    skip = {"a", "an", "the", "add", "to", "for", "and", "of", "on", "in", "that"}
    keep = [w for w in words if w not in skip][:max_words] or words[:max_words]
    return "-".join(keep) or "feature"


def total_cost(state: PipelineState) -> float:
    return round(sum(u.cost_usd for u in state.get("usage", [])), 4)


def cost_by_role(state: PipelineState) -> dict[str, float]:
    out: dict[str, float] = {}
    for event, usage in zip(
        [e for e in state.get("events", []) if e.get("kind") == "agent"],
        state.get("usage", []),
    ):
        role = event.get("role", "unknown")
        out[role] = round(out.get(role, 0.0) + usage.cost_usd, 4)
    return out
