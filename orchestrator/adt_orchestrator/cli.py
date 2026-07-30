"""Run the pipeline for real.

    python -m adt_orchestrator.cli "add a save-draft hook" --flow auto-reviewed
    python -m adt_orchestrator.cli "..." --platform ios --panel anthropic,openai

Executor routing by default follows the harness each role actually needs:
Coder/Tester/Architect get a full coding harness (Claude Agent SDK, falling back
to a headless CLI); reviewers get provider-agnostic chat calls so a panel can
span vendors.
"""

from __future__ import annotations

import argparse
import json
import sys

from .executors import (
    ClaudeAgentSDKExecutor,
    ExecutorRouter,
    LangChainExecutor,
    ModelSpec,
    SubprocessExecutor,
)
from .graph import GraphConfig, default_verify, make_graph
from .platforms import REGISTRY, get as get_platform
from .review import PanelMember
from .state import cost_by_role, initial_state, total_cost

PANEL_DEFAULTS = {
    "anthropic": "claude-opus-5",
    "openai": "gpt-5",
    "google": "gemini-2.5-pro",
}

HEAVY_ROLES = ("architect", "coder", "tester")


def build_router(args: argparse.Namespace) -> ExecutorRouter:
    heavy = (
        SubprocessExecutor(cli=args.cli)
        if args.harness == "cli"
        else ClaudeAgentSDKExecutor()
    )
    light = LangChainExecutor(ModelSpec("anthropic", PANEL_DEFAULTS["anthropic"]))
    return ExecutorRouter(
        default=light,
        by_role={role: heavy for role in HEAVY_ROLES},
    )


def build_panel(spec: str | None) -> list[PanelMember]:
    if not spec:
        return []
    members = []
    for entry in spec.split(","):
        entry = entry.strip()
        if not entry:
            continue
        provider, _, model = entry.partition(":")
        model = model or PANEL_DEFAULTS.get(provider, "")
        if not model:
            raise SystemExit(f"no default model for provider {provider!r}; use provider:model")
        ms = ModelSpec(provider, model)
        members.append(PanelMember(provider, LangChainExecutor(ms), ms))
    return members


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="adt-orchestrator")
    p.add_argument("request", help="the feature request")
    p.add_argument("--flow", default="auto-reviewed",
                   choices=["auto", "auto-reviewed", "guided"])
    p.add_argument("--platform", default="android", choices=sorted(REGISTRY))
    p.add_argument("--repo-root", default=".")
    p.add_argument("--slug", default="")
    p.add_argument("--harness", default="sdk", choices=["sdk", "cli"],
                   help="how heavy roles run: Agent SDK in-process, or a headless CLI")
    p.add_argument("--cli", default="claude", help="CLI binary when --harness=cli")
    p.add_argument("--panel", default="",
                   help="comma-separated reviewer providers, e.g. anthropic,openai")
    p.add_argument("--adjudicator", default="",
                   help="provider that merges panel findings (defaults to first panel member)")
    p.add_argument("--no-verify", action="store_true",
                   help="skip the between-group build/lint gate")
    p.add_argument("--trace", default="", help="write the event trace to this JSON file")
    args = p.parse_args(argv)

    platform = get_platform(args.platform)
    panel = build_panel(args.panel)
    adjudicator = None
    if panel and len(panel) > 1:
        key = args.adjudicator or panel[0].name
        ms = ModelSpec(key, PANEL_DEFAULTS.get(key, key))
        adjudicator = PanelMember("adjudicator", LangChainExecutor(ms), ms)

    cfg = GraphConfig(
        router=build_router(args),
        platform=platform,
        plan_panel=panel,
        code_panel=panel,
        plan_adjudicator=adjudicator,
        code_adjudicator=adjudicator,
        run_verify=None if args.no_verify else default_verify(platform),
    )
    graph = make_graph(cfg)
    flow = args.flow.replace("-", "_")
    state = initial_state(
        args.request, flow=flow, slug=args.slug,
        platform=args.platform, repo_root=args.repo_root,
    )
    run_cfg = {"configurable": {"thread_id": state["slug"]}, "recursion_limit": 100}

    result = graph.invoke(state, config=run_cfg)

    # /build-guided pauses at each gate; resume from stdin.
    while "__interrupt__" in result:
        from langgraph.types import Command

        payload = result["__interrupt__"][0].value
        print(f"\n=== gate: {payload['gate']} ===")
        if payload.get("artifact"):
            print(f"artifact: {payload['artifact']}")
        if payload.get("preview"):
            print(payload["preview"][:1500])
        print(f"\naccepts: {', '.join(payload['accepts'])}")
        result = graph.invoke(Command(resume=input("> ").strip()), config=run_cfg)

    print(f"\nstatus   : {result['status']}")
    if result.get("stop_reason"):
        print(f"stopped  : {result['stop_reason']}")
    if result.get("verdict_summary"):
        print(f"verdict  : {result['verdict_summary']}")
    print(f"re-runs  : plan={result.get('plan_reruns', 0)} code={result.get('code_reruns', 0)}")
    print(f"coders   : {len(result.get('coder_results', []))}")
    print(f"cost     : ${total_cost(result)}  {cost_by_role(result)}")

    if args.trace:
        with open(args.trace, "w", encoding="utf-8") as fh:
            json.dump({"events": result.get("events", []),
                       "verdicts": result.get("verdicts", [])}, fh, indent=2)
        print(f"trace    : {args.trace}")

    return 0 if result["status"] == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
