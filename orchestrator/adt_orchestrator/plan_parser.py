"""Parse the Architect's Section 3 into an ExecutionPlan.

`adt-android-architect.md` already specifies an exact output format for the
parallel-safety decision and execution groups. Today the orchestrating LLM reads
that prose and decides how many Coders to spawn. Here it becomes a parser, so a
malformed plan is a loud failure instead of a silent mis-fan-out.
"""

from __future__ import annotations

import re

from .state import ExecutionPlan, Section

_PARALLEL_SAFE = re.compile(r"\*\*Parallel-safe\*\*\s*:\s*(YES|NO)", re.IGNORECASE)
_RATIONALE = re.compile(r"\*\*Rationale\*\*\s*:\s*(.+)")
_GROUP_HEADER = re.compile(r"^\s*Group\s+(\d+)\b", re.IGNORECASE)
_SEQUENTIAL_HEADER = re.compile(r"^\s*Sequential\s*:", re.IGNORECASE)
_SECTION_LINE = re.compile(r"^\s*-\s*Section\s+([A-Za-z0-9]+)\s*:\s*(.+?)\s*$")
_INLINE_FILES = re.compile(r"[—-]\s*files?\s*:\s*(.+)$", re.IGNORECASE)
_FILES_LINE = re.compile(r"^\s*-\s*Files?\s*:\s*(.+)$", re.IGNORECASE)
_COMPLEXITY_LINE = re.compile(r"^\s*-\s*(?:Estimated\s+)?complexity\s*:\s*(.+)$", re.IGNORECASE)


class PlanFormatError(ValueError):
    """The plan does not carry a machine-readable execution strategy."""


def _split_files(blob: str) -> tuple[str, ...]:
    parts = [p.strip().strip("`") for p in re.split(r"[,\s]+(?=\S)", blob) if p.strip()]
    return tuple(p for p in parts if p and p not in {"and", "&"})


def parse_execution_plan(markdown: str) -> ExecutionPlan:
    """Extract the parallel-safety decision and execution groups from a plan."""
    m = _PARALLEL_SAFE.search(markdown)
    if not m:
        raise PlanFormatError(
            "plan is missing the required `**Parallel-safe**: YES|NO` field in "
            "Section 3 — the Architect must state it explicitly"
        )
    parallel_safe = m.group(1).upper() == "YES"
    rationale_match = _RATIONALE.search(markdown)
    rationale = rationale_match.group(1).strip() if rationale_match else ""

    groups: list[list[Section]] = []
    current: list[Section] | None = None
    pending: dict | None = None

    def flush_section() -> None:
        nonlocal pending
        if pending is not None and current is not None:
            current.append(
                Section(
                    name=pending["name"],
                    files=tuple(pending["files"]),
                    complexity=pending["complexity"],
                    contract=pending["contract"].strip(),
                )
            )
        pending = None

    for raw in markdown.splitlines():
        if _GROUP_HEADER.match(raw) or _SEQUENTIAL_HEADER.match(raw):
            flush_section()
            current = []
            groups.append(current)
            continue

        sec = _SECTION_LINE.match(raw)
        if sec and current is not None:
            flush_section()
            label, rest = sec.group(1), sec.group(2)
            files: tuple[str, ...] = ()
            inline = _INLINE_FILES.search(rest)
            title = rest
            if inline:
                files = _split_files(inline.group(1))
                title = rest[: inline.start()].strip(" —-")
            pending = {
                "name": f"Section {label}: {title}".strip(),
                "files": list(files),
                "complexity": "unknown",
                "contract": "",
            }
            continue

        if pending is None:
            continue

        f = _FILES_LINE.match(raw)
        if f:
            pending["files"].extend(_split_files(f.group(1)))
            continue
        c = _COMPLEXITY_LINE.match(raw)
        if c:
            pending["complexity"] = c.group(1).strip()
            continue
        if raw.strip() and not raw.lstrip().startswith("-"):
            pending["contract"] += raw.strip() + "\n"

    flush_section()
    groups = [g for g in groups if g]

    if not groups:
        raise PlanFormatError(
            "plan declares a parallel-safety decision but lists no execution "
            "groups — expected `Sequential:` or `Group N (run in parallel):`"
        )

    # A sequential plan is one group the Coder walks in order.
    if not parallel_safe:
        flat = [s for g in groups for s in g]
        groups = [flat]

    overlap = _file_overlap(groups) if parallel_safe else {}
    if overlap:
        raise PlanFormatError(
            "plan is marked Parallel-safe: YES but sections within a group share "
            f"files, which would cause write conflicts: {overlap}"
        )

    return ExecutionPlan(
        parallel_safe=parallel_safe,
        groups=tuple(tuple(g) for g in groups),
        rationale=rationale,
    )


def _file_overlap(groups: list[list[Section]]) -> dict[str, list[str]]:
    """Sections inside one group must not touch the same file."""
    clashes: dict[str, list[str]] = {}
    for group in groups:
        seen: dict[str, str] = {}
        for section in group:
            for path in section.files:
                if path in seen and seen[path] != section.name:
                    clashes.setdefault(path, [seen[path]]).append(section.name)
                else:
                    seen[path] = section.name
    return clashes
