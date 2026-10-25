#!/usr/bin/env python3
"""Summarize pipeline runs from their run-summary.json files.

Usage:
    python3 evals/report.py <run-summary.json>... [--baseline <run-summary.json>...]

Prints one markdown row per run, then the totals. With --baseline, it also
prints the totals of the baseline runs, so a release candidate can be compared
with the last release on the same features. evals/README.md explains the
procedure. Standard library only.
"""

import json
import sys

BUDGET_KEYS = (
    "plan_review_reruns",
    "code_review_reruns",
    "fix_iterations",
    "resumes",
)


def load(paths):
    runs = []
    for path in paths:
        with open(path) as f:
            runs.append(json.load(f))
    return runs


def num(value):
    return value if isinstance(value, int) else 0


def row(run):
    ledger = run.get("ledger") or {}
    flows = run.get("flows") or {}
    cov = run.get("coverage") or {}
    checks = run.get("checks") or []
    failed_checks = sum(1 for c in checks if c.get("result") == "FAIL")
    return "| %s | %s | %s/%s | %s | %s | %s | %s | %s/%s | %s | %s |" % (
        run.get("slug"),
        run.get("verdict") or "none",
        cov.get("verified", "?"),
        cov.get("cases", "?"),
        num(ledger.get("plan_review_reruns")),
        num(ledger.get("code_review_reruns")),
        num(ledger.get("fix_iterations")),
        num(ledger.get("resumes")),
        num(flows.get("passed")),
        num(flows.get("total")),
        failed_checks,
        num(flows.get("run_seconds")),
    )


def totals(runs):
    n = len(runs)
    ready = sum(1 for r in runs if r.get("verdict") == "READY TO MERGE")
    verified = sum(num((r.get("coverage") or {}).get("verified")) for r in runs)
    cases = sum(num((r.get("coverage") or {}).get("cases")) for r in runs)
    out = {
        "runs": n,
        "ready_to_merge": ready,
        "ready_rate": round(ready / n, 2) if n else 0,
        "coverage": round(verified / cases, 2) if cases else 0,
    }
    for key in BUDGET_KEYS:
        out[key] = sum(num((r.get("ledger") or {}).get(key)) for r in runs)
    out["flow_seconds"] = sum(num((r.get("flows") or {}).get("run_seconds")) for r in runs)
    return out


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 2
    if "--baseline" in argv:
        i = argv.index("--baseline")
        current, baseline = argv[:i], argv[i + 1:]
    else:
        current, baseline = argv, []
    runs = load(current)
    print("| Run | Verdict | Verified | Plan re-runs | Code re-runs | Fix iterations | Resumes | Flows passed | Checks failed | Flow seconds |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for run in runs:
        print(row(run))
    print()
    print("Totals: " + json.dumps(totals(runs), sort_keys=True))
    if baseline:
        print("Baseline: " + json.dumps(totals(load(baseline)), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
