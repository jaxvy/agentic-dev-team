"""Pluggable execution backends.

Each graph node says *what* to run; an Executor decides *how*. That split is what
makes the multi-provider reviewer panel possible without rewriting the Coder:

  ClaudeAgentSDKExecutor  heavy harness in-process (file edits, bash, context mgmt)
  SubprocessExecutor      heavy harness out-of-process (`claude -p`, `opencode run`)
  LangChainExecutor       any provider via init_chat_model — light harness
  StubExecutor            scripted, for tests

Roles have different harness needs, so they get different executors. The Coder
wants real multi-file editing; a reviewer only needs a diff and a verdict, which
is exactly why a reviewer can run on a provider the coding CLI cannot host.
"""

from __future__ import annotations

import shutil
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

from .state import Usage

# Rough $/Mtok, used for the cost column in traces. Override via ModelSpec.
_PRICING: dict[str, tuple[float, float]] = {
    "anthropic": (3.0, 15.0),
    "openai": (2.5, 10.0),
    "google": (1.25, 5.0),
}


@dataclass(frozen=True)
class ModelSpec:
    provider: str
    model: str
    price_in: float | None = None
    price_out: float | None = None

    def cost(self, tokens_in: int, tokens_out: int) -> float:
        pin, pout = _PRICING.get(self.provider, (0.0, 0.0))
        pin = self.price_in if self.price_in is not None else pin
        pout = self.price_out if self.price_out is not None else pout
        return round((tokens_in * pin + tokens_out * pout) / 1_000_000, 6)

    def __str__(self) -> str:
        return f"{self.provider}:{self.model}"


@dataclass
class AgentRequest:
    role: str
    system_prompt: str
    task: str
    cwd: str = "."
    allowed_tools: tuple[str, ...] = ()
    model: ModelSpec | None = None
    max_turns: int = 60


@dataclass
class AgentResult:
    text: str
    usage: Usage = field(default_factory=Usage)
    ok: bool = True
    error: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)

    def has_marker(self, marker: str) -> bool:
        return marker.lower() in self.text.lower()


@runtime_checkable
class Executor(Protocol):
    name: str

    def run(self, req: AgentRequest) -> AgentResult: ...


class StubExecutor:
    """Scripted executor for tests — lets us assert graph invariants with no API calls.

    `script` maps a role to a list of responses consumed in order; the last one
    repeats. This is how the re-run cap gets tested: hand the reviewer an endless
    stream of rejections and assert the graph stops at 3 attempts anyway.
    """

    name = "stub"

    def __init__(self, script: dict[str, list[str]] | None = None, default: str = "done"):
        self.script = {k: list(v) for k, v in (script or {}).items()}
        self.default = default
        self.calls: list[AgentRequest] = []

    def run(self, req: AgentRequest) -> AgentResult:
        self.calls.append(req)
        queue = self.script.get(req.role)
        if not queue:
            text = self.default
        elif len(queue) == 1:
            text = queue[0]
        else:
            text = queue.pop(0)
        spec = req.model or ModelSpec("stub", "stub")
        return AgentResult(
            text=text,
            usage=Usage(provider=spec.provider, model=spec.model, tokens_in=1000, tokens_out=200,
                        cost_usd=spec.cost(1000, 200), duration_s=0.0),
        )

    def calls_for(self, role: str) -> list[AgentRequest]:
        return [c for c in self.calls if c.role == role]


class ClaudeAgentSDKExecutor:
    """Runs a node inside Claude Code's own harness, in-process.

    This is the executor that makes the "you'd have to rebuild the file-editing
    harness" objection false: the Agent SDK exposes the same edit/bash/context
    machinery as a library, so a Coder node keeps that quality while the graph
    owns the control flow.
    """

    name = "claude-agent-sdk"

    def __init__(self, default_model: str = "claude-opus-5"):
        self.default_model = default_model

    def run(self, req: AgentRequest) -> AgentResult:
        try:
            from claude_agent_sdk import ClaudeAgentOptions, query  # type: ignore
        except ImportError:
            return AgentResult(
                text="", ok=False,
                error="claude-agent-sdk not installed. `pip install claude-agent-sdk` "
                      "or use SubprocessExecutor / LangChainExecutor for this role.",
            )
        import asyncio

        model = req.model.model if req.model else self.default_model
        options = ClaudeAgentOptions(
            system_prompt=req.system_prompt,
            cwd=req.cwd,
            model=model,
            allowed_tools=list(req.allowed_tools) or None,
            max_turns=req.max_turns,
        )

        async def _drive() -> tuple[str, Usage]:
            chunks: list[str] = []
            usage = Usage(provider="anthropic", model=model)
            started = time.monotonic()
            async for message in query(prompt=req.task, options=options):
                for block in getattr(message, "content", []) or []:
                    if getattr(block, "type", None) == "text":
                        chunks.append(block.text)
                meta = getattr(message, "usage", None)
                if meta:
                    usage.tokens_in += getattr(meta, "input_tokens", 0)
                    usage.tokens_out += getattr(meta, "output_tokens", 0)
            usage.duration_s = round(time.monotonic() - started, 2)
            spec = req.model or ModelSpec("anthropic", model)
            usage.cost_usd = spec.cost(usage.tokens_in, usage.tokens_out)
            return "\n".join(chunks), usage

        try:
            text, usage = asyncio.run(_drive())
        except Exception as exc:  # surfaced as a graph-visible failure, not a crash
            return AgentResult(text="", ok=False, error=f"{type(exc).__name__}: {exc}")
        return AgentResult(text=text, usage=usage)


class SubprocessExecutor:
    """Runs a node via a headless coding CLI (`claude -p`, `opencode run`).

    Keeps the full harness without a Python dependency on it. Slower per call
    than the SDK (process spawn) but works with whichever CLI is installed.
    """

    name = "subprocess"

    def __init__(self, cli: str = "claude", extra_args: tuple[str, ...] = (), timeout_s: int = 1800):
        self.cli = cli
        self.extra_args = extra_args
        self.timeout_s = timeout_s

    def run(self, req: AgentRequest) -> AgentResult:
        binary = shutil.which(self.cli)
        if not binary:
            return AgentResult(text="", ok=False, error=f"CLI not on PATH: {self.cli}")
        if self.cli == "claude":
            argv = [binary, "-p", req.task, "--append-system-prompt", req.system_prompt]
        else:  # opencode run
            argv = [binary, "run", f"{req.system_prompt}\n\n---\n\n{req.task}"]
        argv.extend(self.extra_args)

        started = time.monotonic()
        try:
            proc = subprocess.run(
                argv, cwd=req.cwd, capture_output=True, text=True, timeout=self.timeout_s
            )
        except subprocess.TimeoutExpired:
            return AgentResult(text="", ok=False, error=f"{self.cli} timed out after {self.timeout_s}s")
        duration = round(time.monotonic() - started, 2)
        if proc.returncode != 0:
            return AgentResult(text=proc.stdout, ok=False, error=proc.stderr.strip()[:2000])
        return AgentResult(
            text=proc.stdout,
            usage=Usage(provider="cli", model=self.cli, duration_s=duration),
        )


class LangChainExecutor:
    """Single provider-agnostic LLM call via LangChain's model abstraction.

    This is the piece that makes a Claude+OpenAI reviewer panel trivial: one
    interface, N providers. Deliberately *not* used for the Coder — a bare chat
    call has no file-editing harness behind it.
    """

    name = "langchain"

    def __init__(self, spec: ModelSpec, temperature: float = 0.0, **kwargs: Any):
        self.spec = spec
        self.temperature = temperature
        self.kwargs = kwargs
        self._model: Any = None

    def _load(self) -> Any:
        if self._model is None:
            from langchain.chat_models import init_chat_model  # type: ignore

            self._model = init_chat_model(
                self.spec.model,
                model_provider=self.spec.provider,
                temperature=self.temperature,
                **self.kwargs,
            )
        return self._model

    def run(self, req: AgentRequest) -> AgentResult:
        try:
            model = self._load()
        except Exception as exc:
            return AgentResult(text="", ok=False, error=f"model init failed: {exc}")

        started = time.monotonic()
        try:
            resp = model.invoke(
                [("system", req.system_prompt), ("human", req.task)]
            )
        except Exception as exc:
            return AgentResult(text="", ok=False, error=f"{type(exc).__name__}: {exc}")

        meta = getattr(resp, "usage_metadata", None) or {}
        tin, tout = meta.get("input_tokens", 0), meta.get("output_tokens", 0)
        return AgentResult(
            text=resp.content if isinstance(resp.content, str) else str(resp.content),
            usage=Usage(
                provider=self.spec.provider, model=self.spec.model,
                tokens_in=tin, tokens_out=tout,
                cost_usd=self.spec.cost(tin, tout),
                duration_s=round(time.monotonic() - started, 2),
            ),
        )


@dataclass
class ExecutorRouter:
    """Per-role executor selection — the model-routing the markdown prompts ask
    for but Antigravity and opencode cannot honor (they run one global model)."""

    default: Executor
    by_role: dict[str, Executor] = field(default_factory=dict)

    def for_role(self, role: str) -> Executor:
        return self.by_role.get(role, self.default)
