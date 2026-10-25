# Evaluating a release

The scripts have unit tests (`tests/`). The prompts do not, and a prompt change
can make the pipeline better on one feature and worse on the next. So before a
release, run the same features through the pipeline with the release candidate
and with the last release, and compare the records the runs leave.

This folder holds the procedure and `report.py`, which reads the records. It
does not hold a sample app: use an Android app you can change freely.

## 1. The app

Pick one app and keep it for every evaluation, so the results compare:

- a real codebase, with an `AGENTS.md` (architecture, conventions, Section 0
  commands), at least one Room database, a sign-in, and a list screen;
- one AVD on the app's `targetSdk`, prepared as HOW_IT_WORKS, "Setting up
  device testing", says;
- a test account in `.agentic-dev-team/secrets.env`, named in `AGENTS.md`.

Tag the app's commit you start from, and reset to it before each run.

## 2. The features

Write five feature requests into a file, and never change them between
releases. Cover the paths that break most often:

| # | Kind | What it exercises |
|---|---|---|
| 1 | A small UI change on one screen | the happy path, the plan gate, flows |
| 2 | A new list with repeated rows and a bottom sheet | test tags in other windows, predictable tags |
| 3 | A Room schema change | the migration test, the device tests |
| 4 | A feature behind the sign-in | test secrets, the First launch setup |
| 5 | A change that touches an existing area | the regression suite, Flows Retired |

## 3. The runs

For each release (the candidate and the baseline), for each feature:

1. Reset the app to the tagged commit and delete `pipeline_artifacts/` and
   `e2e/flows/` changes.
2. Run `/build-auto-reviewed <the request>` with no edits to the config file.
3. At the end, the command writes `pipeline_artifacts/<slug>/run-summary.json`
   (`adt.sh summary`). Copy it to `evals/runs/<release>/<feature #>.json` in
   your own workspace.
4. Write down the cost your tool reports for the run (Claude Code: `/cost`).

A run that stops is a result too: keep its summary.

## 4. The comparison

```bash
python3 evals/report.py runs/candidate/*.json --baseline runs/v0.5.0/*.json
```

It prints one row per run (verdict, coverage, the budgets each gate used, flows
passed, checks failed, flow time) and the totals of both sets. Ship the
candidate when:

- no feature that reached `READY TO MERGE` on the baseline fails to reach it;
- coverage (verified cases out of plan cases) does not drop;
- the budgets used (re-runs, fix iterations) do not rise, or the reason is
  understood;
- the cost per feature does not rise by more than you accept.

Read the plans and diffs of any feature whose result changed: the numbers say
where to look, not why.
