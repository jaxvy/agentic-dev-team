"""Load agent prompts from the existing markdown files.

The graph does NOT fork the prompts. `plugins/agentic-dev-team/agents/adt-*.md`
stays the single source of truth for all four surfaces (Claude Code, Antigravity,
opencode, and this orchestrator), so editing a persona still propagates
everywhere without a redeploy.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
AGENTS_DIR = REPO_ROOT / "plugins" / "agentic-dev-team" / "agents"
PIPELINE_RULES = REPO_ROOT / ".claude" / "AGENTIC_DEV_TEAM_PIPELINE.md"

_FRONTMATTER = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.DOTALL)


@dataclass(frozen=True)
class AgentPrompt:
    name: str
    body: str
    model_hint: str
    tools: tuple[str, ...]
    description: str

    @property
    def role(self) -> str:
        """`adt-android-code-reviewer` -> `code-reviewer`."""
        return re.sub(r"^adt-[a-z]+-", "", self.name)


def _parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    m = _FRONTMATTER.match(text)
    if not m:
        return {}, text
    raw, body = m.group(1), text[m.end() :]
    meta: dict[str, str] = {}
    key: str | None = None
    for line in raw.splitlines():
        if re.match(r"^[a-zA-Z_]+:", line):
            key, _, val = line.partition(":")
            key = key.strip()
            meta[key] = val.strip().lstrip(">").strip()
        elif key and line.strip():
            meta[key] = (meta[key] + " " + line.strip()).strip()
    return meta, body


@lru_cache(maxsize=None)
def load_agent(name: str, agents_dir: str | None = None) -> AgentPrompt:
    """Load one `adt-*` agent prompt by name (with or without the `.md`)."""
    directory = Path(agents_dir) if agents_dir else AGENTS_DIR
    stem = name[:-3] if name.endswith(".md") else name
    path = directory / f"{stem}.md"
    if not path.exists():
        raise FileNotFoundError(
            f"agent prompt not found: {path}. Available: "
            f"{sorted(p.stem for p in directory.glob('adt-*.md'))}"
        )
    meta, body = _parse_frontmatter(path.read_text(encoding="utf-8"))
    tools = tuple(t.strip() for t in meta.get("tools", "").split(",") if t.strip())
    return AgentPrompt(
        name=meta.get("name", stem),
        body=body.strip(),
        model_hint=meta.get("model", "sonnet"),
        tools=tools,
        description=meta.get("description", ""),
    )


@lru_cache(maxsize=1)
def pipeline_rules() -> str:
    """Shared orchestration rules every agent is told to read."""
    return PIPELINE_RULES.read_text(encoding="utf-8") if PIPELINE_RULES.exists() else ""


def system_prompt(agent: AgentPrompt, platform_pack: str = "") -> str:
    """Compose the system prompt: role body + platform pack + shared rules."""
    parts = [agent.body]
    if platform_pack:
        parts.append("\n\n---\n\n## Platform Pack (authoritative for this run)\n\n" + platform_pack)
    rules = pipeline_rules()
    if rules:
        parts.append("\n\n---\n\n## Shared Orchestration Rules\n\n" + rules)
    return "\n".join(parts)


def available_agents(agents_dir: str | None = None) -> list[str]:
    directory = Path(agents_dir) if agents_dir else AGENTS_DIR
    return sorted(p.stem for p in directory.glob("adt-*.md"))
