"""Multi-provider reviewer panel.

N reviewers run concurrently on different providers, then an adjudicator merges
their findings into one verdict. This is the flow that cannot be expressed as
Claude Code subagents at all: the `model:` field in an agent file takes
opus/sonnet/haiku, so a Claude+GPT panel has no representation there.

Merging opinions is also the part prose orchestration handles worst — it needs
dedupe, contradiction resolution, and a deterministic approve/reject rule.
"""

from __future__ import annotations

import json
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

from .executors import AgentRequest, Executor, ModelSpec
from .state import Finding, Usage, Verdict

APPROVED_MARKERS = ("✅ plan approved", "✅ code approved", "plan approved", "code approved")
CHANGES_MARKERS = ("🔧 plan changes requested", "🔧 code changes requested",
                   "plan changes requested", "code changes requested")

_JSON_BLOCK = re.compile(r"```(?:json)?\s*(\{.*?\}|\[.*?\])\s*```", re.DOTALL)

STRUCTURED_SUFFIX = """

---

## Output contract (orchestrator-enforced)

After your prose review, emit a fenced ```json block:

```json
{"approved": true,
 "findings": [{"severity": "blocking|major|minor", "summary": "...",
               "file": "path/or/null", "line": 0}]}
```

`approved` must be false if any finding is `blocking`. Keep prose and JSON consistent.
"""

ADJUDICATOR_PROMPT = """You are the adjudicating reviewer over a panel of independent \
reviewers who each examined the same change.

Your job is NOT to re-review the code. It is to merge their findings:

1. Deduplicate findings that describe the same defect in different words.
2. Resolve contradictions — if one reviewer calls something blocking and another \
does not mention it, judge which reading is correct from the evidence given.
3. Drop findings that are style preferences rather than defects.
4. Downgrade a finding no reviewer could justify with a concrete failure mode.

A reviewer disagreeing with the majority is not automatically wrong; a single \
well-evidenced blocking finding outranks several vague approvals.

Emit the same JSON contract: approved=false if any surviving finding is blocking.
"""


@dataclass
class PanelMember:
    name: str
    executor: Executor
    model: ModelSpec


def _parse_verdict(text: str, reviewer: str, provider: str) -> Verdict:
    """Prefer the JSON contract; fall back to the repo's existing marker strings."""
    findings: list[Finding] = []
    approved: bool | None = None

    for match in _JSON_BLOCK.finditer(text):
        try:
            payload = json.loads(match.group(1))
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            approved = bool(payload.get("approved", False))
            for item in payload.get("findings", []) or []:
                if not isinstance(item, dict):
                    continue
                severity = str(item.get("severity", "minor")).lower()
                findings.append(
                    Finding(
                        reviewer=reviewer,
                        severity=severity if severity in {"blocking", "major", "minor"} else "minor",
                        summary=str(item.get("summary", "")).strip(),
                        file=item.get("file") or None,
                        line=item.get("line") or None,
                    )
                )
            break

    if approved is None:
        lowered = text.lower()
        if any(m in lowered for m in CHANGES_MARKERS):
            approved = False
        elif any(m in lowered for m in APPROVED_MARKERS):
            approved = True
        else:
            # No parseable verdict is a rejection, not an approval. Failing open
            # here would let an unparseable response ship code.
            approved = False
            findings.append(
                Finding(reviewer=reviewer, severity="blocking",
                        summary="reviewer emitted no parseable verdict")
            )

    # The contract says so, but enforce it rather than trusting it.
    if any(f.severity == "blocking" for f in findings):
        approved = False

    return Verdict(approved=approved, reviewer=reviewer, provider=provider,
                   findings=findings, raw=text)


def run_panel(
    members: list[PanelMember],
    *,
    system_prompt: str,
    task: str,
    cwd: str = ".",
    adjudicator: PanelMember | None = None,
    max_workers: int = 4,
) -> tuple[Verdict, list[Verdict], list[Usage]]:
    """Fan out to every panel member concurrently, then adjudicate.

    Returns (final_verdict, member_verdicts, usage). With one member and no
    adjudicator this degrades to exactly the repo's current single-reviewer gate.
    """
    if not members:
        raise ValueError("reviewer panel needs at least one member")

    verdicts: list[Verdict] = []
    usage: list[Usage] = []

    def _run(member: PanelMember) -> tuple[PanelMember, object]:
        req = AgentRequest(
            role=f"reviewer:{member.name}",
            system_prompt=system_prompt + STRUCTURED_SUFFIX,
            task=task,
            cwd=cwd,
            model=member.model,
        )
        return member, member.executor.run(req)

    with ThreadPoolExecutor(max_workers=min(max_workers, len(members))) as pool:
        futures = [pool.submit(_run, m) for m in members]
        for future in as_completed(futures):
            member, result = future.result()
            usage.append(result.usage)
            if not result.ok:
                verdicts.append(
                    Verdict(
                        approved=False, reviewer=member.name, provider=member.model.provider,
                        findings=[Finding(member.name, "blocking",
                                          f"reviewer failed to run: {result.error}")],
                        raw=result.error,
                    )
                )
                continue
            verdicts.append(_parse_verdict(result.text, member.name, member.model.provider))

    verdicts.sort(key=lambda v: [m.name for m in members].index(v.reviewer))

    if len(verdicts) == 1 or adjudicator is None:
        return _merge_without_adjudicator(verdicts), verdicts, usage

    transcript = "\n\n".join(
        f"### Reviewer: {v.reviewer} ({v.provider}) — "
        f"{'APPROVED' if v.approved else 'CHANGES REQUESTED'}\n\n{v.raw}"
        for v in verdicts
    )
    req = AgentRequest(
        role="reviewer:adjudicator",
        system_prompt=ADJUDICATOR_PROMPT,
        task=f"{task}\n\n---\n\n# Panel reviews to adjudicate\n\n{transcript}",
        cwd=cwd,
        model=adjudicator.model,
    )
    result = adjudicator.executor.run(req)
    usage.append(result.usage)
    if not result.ok:
        # Adjudicator down: fall back to the conservative union rule.
        return _merge_without_adjudicator(verdicts), verdicts, usage

    final = _parse_verdict(result.text, "adjudicator", adjudicator.model.provider)
    return final, verdicts, usage


def _merge_without_adjudicator(verdicts: list[Verdict]) -> Verdict:
    """Conservative union: any blocking finding blocks."""
    findings = [f for v in verdicts for f in v.findings]
    approved = all(v.approved for v in verdicts) and not any(
        f.severity == "blocking" for f in findings
    )
    return Verdict(
        approved=approved,
        reviewer="panel-union" if len(verdicts) > 1 else verdicts[0].reviewer,
        provider="+".join(sorted({v.provider for v in verdicts})),
        findings=findings,
        raw="\n\n".join(v.raw for v in verdicts),
    )


def format_feedback(verdict: Verdict) -> str:
    """Numbered feedback for the producing agent, per the Reviewer-Loop Protocol."""
    if not verdict.findings:
        return verdict.raw.strip()
    lines = []
    for i, f in enumerate(sorted(verdict.findings,
                                 key=lambda x: {"blocking": 0, "major": 1, "minor": 2}[x.severity]), 1):
        loc = f" ({f.file}:{f.line})" if f.file and f.line else (f" ({f.file})" if f.file else "")
        lines.append(f"{i}. [{f.severity}]{loc} {f.summary}")
    return "\n".join(lines)
