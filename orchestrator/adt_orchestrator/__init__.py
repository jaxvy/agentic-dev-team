"""LangGraph orchestrator for the agentic dev team pipeline.

Runs the same PM → Architect → Coder → Tester flows as the markdown commands,
against the same agent prompts, with the control flow enforced in code.
"""

from .executors import (
    AgentRequest,
    AgentResult,
    ClaudeAgentSDKExecutor,
    Executor,
    ExecutorRouter,
    LangChainExecutor,
    ModelSpec,
    StubExecutor,
    SubprocessExecutor,
)
from .graph import GraphConfig, default_verify, make_graph
from .plan_parser import PlanFormatError, parse_execution_plan
from .platforms import REGISTRY as PLATFORMS, PlatformPack
from .review import PanelMember, run_panel
from .state import MAX_RERUNS_PER_GATE, ExecutionPlan, PipelineState, Section, initial_state

__all__ = [
    "AgentRequest", "AgentResult", "ClaudeAgentSDKExecutor", "Executor",
    "ExecutorRouter", "LangChainExecutor", "ModelSpec", "StubExecutor",
    "SubprocessExecutor", "GraphConfig", "default_verify", "make_graph",
    "PlanFormatError", "parse_execution_plan", "PLATFORMS", "PlatformPack",
    "PanelMember", "run_panel", "MAX_RERUNS_PER_GATE", "ExecutionPlan",
    "PipelineState", "Section", "initial_state",
]
