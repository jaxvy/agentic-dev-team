# Multi-Agent Pipeline: Agent Configuration and Configured Runs

The orchestrator reads this file only when `.agentic-dev-team/config.yaml` has
an active setting (ORCHESTRATION_DOC, "Command Start"). With no active
setting, nothing in it applies, and a command runs exactly as it would without
the file. Agents never read it.

---


## Agent Configuration

An orchestrator reads this section when ORCHESTRATION_DOC, "Command Start",
step 5, finds an active setting in the config file. It defines the optional config file `.agentic-dev-team/config.yaml`. **With no
active setting in that file, nothing in this section changes a run**: a
missing file, an empty file, and the file as created (every setting commented
out) give `MODELS` off and `RUNS` off, and the command runs exactly as it
would without the file.

### The files

```
<project root>/.agentic-dev-team/
  .gitignore     one line: *
  config.yaml    copy of config.example.yaml, every setting commented out
```

The `*` line ignores the whole directory, the `.gitignore` included, so
`git status` and the changed-file manifest never list these files.

ORCHESTRATION_DOC, "Command Start", step 5, creates both files once, with
`bash "ADT_RUN" --init-config "PROJECT_ROOT"`, when
`config.yaml` does not exist. `install.sh` runs the same step at install. The
step never edits or overwrites an existing `config.yaml`, and it never creates
`.gitignore` while `config.yaml` exists. It prints one status line first:
`ADT_INIT status=created`, `status=exists`, `status=unreadable` (the path
exists but is not a readable file: a config error) or `status=failed`.

**Un-ignore.** To share the config with a team, the developer deletes
`.agentic-dev-team/.gitignore` and commits `config.yaml`. Later `install.sh`
runs and commands never re-create the `.gitignore` while `config.yaml` exists,
and `install.sh --uninstall` never touches `.agentic-dev-team/`.

### Schema (version 1)

```yaml
version: 1

agents:                      # all commands; native agents only
  <role>:
    model: <alias>

build_auto_reviewed:         # /build-auto-reviewed only
  architect: <slot>
  coder:     <slot>
  tester:    <slot>
  architect_reviewer:
    reviewers: [<slot>, ...]   # 1 to 5 entries
  code_reviewer:
    reviewers: [<slot>, ...]   # 1 to 5 entries
```

Roles and agents:

| Role | Agent | Frontmatter model |
|---|---|---|
| `pm` | `adt-android-pm` | `opus` |
| `architect` | `adt-android-architect` | `opus` |
| `architect_reviewer` | `adt-android-architect-reviewer` | `opus` |
| `coder` | `adt-android-coder` | `sonnet` |
| `code_reviewer` | `adt-android-code-reviewer` | `opus` |
| `test_writer` | `adt-android-test-writer` | `sonnet` |
| `tester` | `adt-android-tester` | `sonnet` |
| `review_judge` | `adt-android-review-judge` | `inherit` (the main model) |

A slot:

| Key | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `runner` | string | no | `native` | `native`, `claude`, `codex`, `agy`, `opencode`, `command` |
| `model` | string | no | see "Model values" | For `native`: an alias. For external runners: any value that CLI's `--model` flag accepts. |
| `timeout_minutes` | integer ≥ 1 | no | `30` for a reviewer, `120` for `architect`, `coder` and `tester` | External runners only. Ignored for `native` (a native agent has no time limit). |
| `required` | boolean | no | `true` | Reviewer slots only, and only in a list with 2 or more entries. |
| `command` | string | only for `runner: command` | none | Command template, see "Command templates" below. |
| `check` | string | required for `runner: command`, not allowed for other runners | none | The program that preflight looks for, and the program word of the template (they must be the same). |

`review_judge`, `pm` and `test_writer` are valid only under `agents:` (the
Test Writer always runs native). The judge always runs
native, on the main model unless `agents.review_judge.model` sets another.

### Switches

A **native model value** is any `agents.<role>.model`, or the `model` of a
`build_auto_reviewed` slot or reviewer entry whose `runner` is `native` or
that has no `runner` key.

- **`MODELS` is on** when at least one native model value is set for a role
  that the current command starts: an `agents.<role>.model` for a role in the
  table below, or (in `/build-auto-reviewed` only) a native model value under
  `build_auto_reviewed`.

  | Command | Roles it starts |
  |---|---|
  | `/plan-research` | `pm` |
  | `/plan-design` | `architect` |
  | `/build-auto` | `architect`, `coder`, `test_writer`, `tester` |
  | `/build-guided` | `pm`, `architect`, `coder`, `test_writer`, `tester` |
  | `/build-auto-reviewed` | `architect`, `architect_reviewer`, `coder`, `code_reviewer`, `test_writer`, `tester`; and `review_judge` only when a **configured** `reviewers` list has 2 or more entries |

- **`RUNS` is on** (only in `/build-auto-reviewed`) when at least one slot or
  reviewer entry under `build_auto_reviewed:` has a `runner` other than
  `native`, or a `reviewers` list has 2 or more entries. A native slot or a
  single native reviewer entry with a `model` is a native model value
  (`MODELS`), not `RUNS`. So `architect: { runner: native }` or
  `coder: { runner: native, model: opus }` never turns on `RUNS`.

`version` alone does not turn on a switch.

### Validation

Validate the whole file at the start of every command, before the first agent
runs (every command validates the whole file, also the part it does not use).
Any of these stops the command with a message that names the key and the
problem:

1. The file is not valid YAML, or its top level is neither empty (YAML
   `null`: an empty or comments-only file, which counts as no config) nor a
   mapping.
2. `version` is present and is not `1`.
3. An unknown top-level key, role, or slot key.
4. A `runner` that is not in the list.
5. A `reviewers` list that is empty or has more than 5 entries.
6. A problem with a `command` runner, any of:
   - `runner: command` without `command`, or without `check`;
   - `command` or `check` with another runner;
   - a `command` whose **parsed string value** (after YAML parsing, so YAML's
     own quotes around the value do not count) fails any item of the
     "Template check" list below;
   - a `command` with neither `{instruction}` nor `{prompt_file}`;
   - a `command` that uses `{model}` in a slot without `model`;
   - a `check` value whose basename is one of the shells and command runners
     listed in the "Template check";
   - a `check` value that does not match
     `^([A-Za-z0-9_+][A-Za-z0-9._+-]*|/[A-Za-z0-9._/+-]+)$`: a bare program
     name (no `/`, does not start with `-` or `.`) or an absolute path. No
     spaces, `$`, `~` or quotes, and no relative path such as `bin/gemini`.
7. `required` outside a reviewer slot; `required: false` in a `reviewers`
   list that has only one entry; or `timeout_minutes` that is not a whole
   number ≥ 1.
8. In Claude Code only, and only when the Agent (Task) tool has a `model`
   parameter in its schema: **any** native model value in the file, also one
   that the current command does not use, that is not one of the values that
   parameter accepts: the values of its `enum` when the schema has one; when
   the parameter is a plain string without an `enum`, the aliases `sonnet`,
   `opus`, `haiku` and `fable` only. This rule only compares the file with the
   schema; it runs no command.
9. A value of the wrong type. The only allowed shapes are:
   - `version`: the integer `1`.
   - `agents`: `null` or a mapping; each role under it: a mapping with exactly
     one key, `model`, whose value is a non-empty string (an empty mapping,
     `model:` with no value, and `model: ""` are errors).
   - `build_auto_reviewed`: `null` or a mapping. `architect`, `coder`,
     `tester`: a slot. `architect_reviewer`, `code_reviewer`: a mapping whose
     only key is `reviewers`, a **list** (not `null`) of slots.
   - A slot: a mapping. `runner`, `model`, `command`, `check`: non-empty
     strings. `timeout_minutes`: an integer. `required`: exactly `true` or
     `false`, lowercase and without quotes. Every other value (`yes`, `no`,
     `True`, `"false"`, ...) is an error.
   A role key whose value is `null` (for example `coder:` with nothing after
   it) is an error: remove the key or comment it out.

### Command templates

A `runner: command` slot runs a program from a template. **No shell runs the
template.** The script turns it into an argument list:

1. **Words.** Split on spaces and tabs that are **outside** double quotes. A
   double-quoted part groups text (spaces included) into the word, and the
   quote characters are removed. There is no other quoting or escaping.
2. **Assignments.** Leading words of the form `NAME=value` (`NAME` matches
   `[A-Za-z_][A-Za-z0-9_]*`) become environment variables for the program.
   The first other word is the **program word**; the rest are its arguments.
3. Placeholders `{instruction}`, `{prompt_file}`, `{output_file}` and
   `{model}` are replaced inside each word, after the split, so a value never
   creates or splits words.

**Template check.** The template is rejected when:

- it contains `'`, `\`, a backtick, `$`, a newline or carriage return, or any
  of `|`, `;`, `&`, `<`, `>`;
- its double quotes are not balanced (an odd number of `"`);
- it has neither `{instruction}` nor `{prompt_file}`;
- it uses `{model}` and the slot has no `model`;
- it assigns `PATH`, `BASH_ENV`, `ENV`, `IFS`, or a name that starts with
  `LD_` or `DYLD_`;
- the program word is not exactly the slot's `check` value (so no wrapper such
  as `env`, `timeout`, `nohup` or `sudo` can run in front of the program; set
  a variable with `NAME=value` in front of the program word instead, and use
  `timeout_minutes` for a time limit);
- the basename of the program word is one of `sh`, `bash`, `rbash`, `zsh`,
  `dash`, `ksh`, `mksh`, `ash`, `fish`, `csh`, `tcsh`, `pwsh`, `powershell`,
  `busybox`, `env`, `sudo`, `su`, `ssh`.

The script applies the same check before it runs anything. It cannot know
what the checked program does with its arguments: never pass a placeholder to
a program that runs an argument as code (`python3 -c`, `node -e`).

### Model values

**Native agents in Claude Code.** Pass the value in the `model` parameter of
the Agent tool. That parameter accepts **aliases only** (today `sonnet`,
`opus`, `haiku`, `fable`; the exact list is the enum in the tool's own
schema). Full model IDs, `inherit`, `best`, `default`, `opusplan` and `[1m]`
variants are rejected by validation rule 8.

What a native alias runs (Claude Code resolves it when it starts the
subagent):

1. If the main conversation's model is in the same family (for example the
   main session runs an Opus model and the config says `opus`), the subagent
   runs on the main conversation's **exact** model, including any `[1m]`
   suffix.
2. Otherwise it runs the version the alias points to: the value of
   `ANTHROPIC_DEFAULT_<FAMILY>_MODEL` when that variable is set, else Claude
   Code's current mapping (for example `opus` is Opus 5.5 on the Anthropic API
   today; other providers can map it to another version).
3. On a provider other than the Anthropic API, when Claude Code cannot tell
   the main model's family, `opus` also resolves to the main model, unless
   `ANTHROPIC_DEFAULT_OPUS_MODEL` is set.

A native agent cannot be pinned to an exact version through this config. To
pin one: in `/build-auto-reviewed` use `runner: claude` with a full model ID;
for another family than the main model, set `ANTHROPIC_DEFAULT_<FAMILY>_MODEL`
in the `env` of `.claude/settings.json`; otherwise select that version as the
main session's model.

**Precedence in Claude Code:** the per-invocation `model` parameter wins over
the agent frontmatter, which wins over `CLAUDE_CODE_SUBAGENT_MODEL`, which wins
over the main model. `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` overrides all of them.

**Model resolution for a native agent** (first match wins):

1. In `/build-auto-reviewed` only: the `model` of the slot that starts this
   agent (for a reviewer: its own entry in the `reviewers` list), when that
   slot is native.
2. `agents.<role>.model`.
3. No value: pass no `model` parameter, so the agent file's frontmatter
   applies (today's behavior).

**Native agents in Antigravity and opencode.** These tools cannot select a
model per subagent. Pass nothing, do not fail, and report once in the final
summary: `Model settings were not applied: <tool> runs every subagent on its
selected model.` Validation rule 8 does not apply there.

**External runners** (`/build-auto-reviewed`): `model` goes to the CLI's
`--model` flag unchanged (`claude`: an alias or a full ID such as
`claude-opus-5-5`; `codex`: a Codex model name; `agy`: an Antigravity model
slug; `opencode`: `provider/model`; `command`: put into `{model}`). Without
`model`, the CLI uses its own default.

### Steps at the start of every command

1. The config file check and `--init-config` were done by ORCHESTRATION_DOC,
   "Command Start", step 5, which also found an active setting (else you
   would not be reading this). Do not run `--init-config` again here.
2. Read `.agentic-dev-team/config.yaml` if it exists. Validate it (rules 1 to
   7 and 9, and in Claude Code rule 8). On an error: stop, report, start no
   agent.
3. Set `MODELS` (and in `/build-auto-reviewed`, `RUNS`).
4. If `MODELS` is off: skip the rest of this section and continue with the
   command's first phase as usual. No `printenv`, no model passing, no summary
   line about models.
5. If `MODELS` is on and the tool is Claude Code: do the start check below.

### When `MODELS` is on

1. **Claude Code, every native start:** each time you start an `adt-*`
   subagent natively (in `/build-auto-reviewed` this includes native slots and
   native panel reviewers), resolve the model and, while model passing is on,
   pass it in the Agent tool's `model` parameter. With no resolved value, pass
   nothing.
2. **Claude Code, start check (once).** Model passing starts **on**, and is
   turned **off** for the whole run when:
   1. `printenv CLAUDE_CODE_SUBAGENT_MODEL_FORCE` prints a non-empty value
      other than `0` or `false` (any casing). REASON:
      `CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set to <value>`. Do not narrow
      this to `1` or `true`: Claude Code applies the variable silently, so
      treating an unusual value as on can only skip model passing, while
      treating it as off could report a model that never ran.
   2. The Agent (Task) tool has no `model` parameter in its schema. REASON:
      `the Agent tool has no model parameter`.
3. **Claude Code, during the run:** if a subagent start that included `model`
   fails with an error that names the `model` parameter or says a model
   cannot be passed, start that same subagent again once without `model`, and
   turn model passing off for the rest of the run. REASON:
   `Claude Code rejected the model parameter: <error message>`. Any other
   start error is handled as usual; it never turns model passing off.
4. **While model passing is off:** pass no `model` to any subagent, and put
   `Model settings were not applied: <REASON>.` in the final summary. The run
   continues normally.
5. **Antigravity, opencode:** pass nothing, and report as in "Model values".
6. **Summary line:** `Models requested: <role>=<value> ...` for each role
   whose configured model was passed. Say "requested", never "ran": an
   organization `availableModels` allowlist or alias case 1 above can still
   change the model that runs.
7. **`CLAUDE_CODE_SUBAGENT_MODEL` note (Claude Code).** In the start check,
   also run `printenv CLAUDE_CODE_SUBAGENT_MODEL`. If it prints a value, add
   to the summary: `Note: CLAUDE_CODE_SUBAGENT_MODEL is set to <value>.
   Claude Code older than v2.1.251 lets it override the requested models
   (sub-agents docs).` Model passing stays on.

## Configured Runs (/build-auto-reviewed only)

Only /build-auto-reviewed uses this section, and only when RUNS is on. Every other command, and a run with RUNS off, ignores it.

Configured runs let a role run as an external CLI (Claude Code, Codex,
Antigravity, opencode, or any command) instead of as a native subagent, and
let a review gate run as a **review panel**: 2 to 5 reviewers whose findings
the `adt-android-review-judge` agent verifies and merges. Each CLI uses the
developer's own login; no API key is involved.

### The runner script

`RUNNER` is ADT_RUN, the script path that ORCHESTRATION_DOC, "Command Start",
step 5, resolved (`.claude/adt/scripts/adt-run-agent.sh` in an `install.sh`
project, `scripts/adt-run-agent.sh` in the plugin). Always call it as
`bash "RUNNER" ...`, and put every path in double quotes.

```
bash RUNNER --check <claude|codex|agy|opencode>
bash RUNNER --check command --check-program <program> --command-file <path> [--model <model>]
bash RUNNER --runner <runner> --access <read-only|write> --project-root <path>
            --prompt-file <path> --output-file <path>
            [--model <model>] [--timeout-minutes <n>]
            [--command-file <path> --check-program <program>]
            [--allow-read <path>]... --detach
bash RUNNER --wait <output-file>... [--max-seconds <n>]
bash RUNNER --hash <file>
bash RUNNER --snapshot --project-root <path> [--guard-path <path>]...
bash RUNNER --cancel <run dir>
```

**Paths.** Every path you pass is absolute (built from PROJECT_ROOT). The
script exits 2 for a relative `--wait`, `--output-file`, `--prompt-file`,
`--command-file`, `--allow-read`, `--project-root` or `--cancel` path.
`--guard-path` is the one exception: it may be relative to `--project-root`.

Files of one run, next to the output file `O`: `O` (the agent's final
answer), `O.log` (CLI progress and errors), `O.status` (the result, written
last), and the script's own `O.pid`, `O.clipid`, `O.cancel`, `O.elapsed` and
`O.timedout`. You read only `O`, `O.log` and `O.status`.

A result is five lines (stdout, and the content of `O.status`):

```
ADT_RUN status=<status> runner=<runner> exit=<CLI exit status>
ADT_RUN marker=<last marker line, or empty>
ADT_RUN output=<O> log=<O.log> seconds=<run time>
ADT_RUN code=<this script's exit code>
ADT_RUN sha=<output of `--hash O` when the run ended, or empty>
```

| Code | Status | Meaning |
|---|---|---|
| 0 | `ok` | Finished, marker found |
| 2 | `usage` | Bad arguments; a relative path; not a git repo; `O` or `O.log` not git-ignored; a missing guard path |
| 3 | `missing-runner` | CLI not on `PATH` |
| 4 | `timeout` | Stopped at the timeout |
| 5 | `failed` | CLI exit status not 0 |
| 6 | `no-marker` | Finished without a marker line |
| 13 | `conflicting-markers` | Finished with marker lines of different known markers |
| 14 | `cancelled` | Stopped by `--cancel` |
| 10 | `running` | `--wait` only: not finished yet |
| 11 | `lost` | `--wait` only: the detached job ended without a result, or is stuck |
| 12 | `not-started` | The CLI never started |

**`--wait O...`** takes one or more output files and prints one block per
file, in the order given: the five `ADT_RUN` lines of a finished run, or
`ADT_RUN status=running output=<O>`. It exits 10 while any file is still
running, else 0 (with a single file, it exits with that run's code). **The
result of each run is the `code` line of its block**, never the exit code of
a multi-file call. Repeat the call until it does not exit 10; the script's
own stuck-job rules guarantee that this ends.

### Marker rule

Used for every answer in a configured run, native and external alike. Only
these **known markers** count: `✅ ARCHITECT DONE`, `✅ CODER DONE`,
`✅ TESTER DONE`, `⛔ TESTER BLOCKED`, `✅ PLAN APPROVED`,
`🔧 PLAN CHANGES REQUESTED`, `✅ CODE APPROVED`, `🔧 CODE CHANGES REQUESTED`.

- Remove every U+FE0F character (the invisible emoji variation selector, as in
  `⛔️`) from a line before matching.
- A **marker line** starts in the first column (a line that begins with a
  space or tab is never one). After these are removed from its start, in this
  order, it **starts with** a known marker: (1) if present, `#` characters and
  spaces; (2) if present, one `**` or `__`; (3) if present, the label
  `Verdict:` (any casing), then, if present, one `**` or `__`, then spaces,
  then, if present, one `**` or `__`. So `✅ CODE APPROVED — summary`,
  `## ✅ CODE APPROVED`, `**✅ CODE APPROVED**`, `Verdict: ✅ CODE APPROVED`,
  `**Verdict:** ✅ CODE APPROVED` and `Verdict: **✅ CODE APPROVED**` are
  marker lines.
- A line that starts with a bullet (`*`, `-` or `+` and a space), `>`, a
  backtick, or any other character is never a marker line. A line that starts
  with an emoji but not with a known marker (`✅ Item 1 is fixed`) is ignored.
- If every marker line starts with the **same** known marker, that is the
  answer's marker (the last such line is reported). Marker lines with
  **different** known markers make the answer invalid (`conflicting-markers`,
  code 13). Never guess.

In this section, "the marker is X" means this rule found a line that starts
with X.

### Start

0. If ADT_ROOT is empty, STOP: the configured run needs the scripts. Report
   that the agentic-dev-team install is incomplete.
1. **Run directory:** `PROJECT_ROOT/pipeline_artifacts/.runs/<run id>/`, always
   used as an absolute path. `<run id>` is the UTC timestamp from
   `date -u +%Y%m%dT%H%M%SZ`, a `-`, and 6 random lowercase letters or digits;
   if the directory already exists, choose new random characters. Before you
   create it: create `PROJECT_ROOT/pipeline_artifacts/` with `mkdir -p`, then
   create `PROJECT_ROOT/pipeline_artifacts/.gitignore` with the single line
   `*` if it does not exist. Only then create the run directory.
2. **Paths:**
   - RUNNER: ADT_RUN.
   - Persona of each agent: `ADT_ROOT/agents/<agent file>`.
   - PIPELINE_DOC_ABS: PIPELINE_DOC as an absolute path (prefix it with
     `PROJECT_ROOT/` when it does not start with `/`). Use it in every script
     call and prompt file; native subagents keep getting PIPELINE_DOC.
3. **Preflight.**
   1. For each `runner: command` slot, write its command file
      `<run dir>/command-<slot>.txt`, where `<slot>` is `architect`, `coder`,
      `tester`, `architect_reviewer-<i>` or `code_reviewer-<i>` (`<i>` is the
      1-based position in that `reviewers` list). It holds the **parsed string
      value** of `command` followed by one newline.
   2. Run `bash "RUNNER" --check <runner>` once for each distinct runner among
      `claude`, `codex`, `agy` and `opencode` in the config.
   3. For each `runner: command` slot, run
      `bash "RUNNER" --check command --check-program <check> --command-file "<its command file>" [--model M]`
      (with `--model` when the slot has `model`).
   4. Exit 3 means the CLI is missing (below). Exit 2 from a `command` check
      means the template is invalid: STOP before Phase 1 and show the
      script's message. Any other non-zero exit: STOP and report the command
      and its output.
   5. A missing CLI in a producer slot (`architect`, `coder`, `tester`) or in
      a required reviewer: STOP before Phase 1 and name the CLI. A missing CLI
      in an optional reviewer: remove that reviewer, and report it in the
      summary.
4. **Effective reviewer lists.** Fix each gate's reviewer list for the whole
   run: the configured list minus the removed reviewers, or one native
   reviewer when the gate is not configured. If a configured gate's list is
   now empty: STOP before Phase 1 and report `<gate> has no available
   reviewer`. Choose each gate's case (A, B or C, below) from its effective
   list here, one time. If the removals leave a single reviewer, that
   reviewer is required from now on, and the summary says so.
5. If the `coder` or `tester` slot uses `runner: codex`, print one warning:
   Codex's `workspace-write` sandbox blocks network access and writes outside
   the project by default, so Gradle downloads, the Gradle daemon and `adb`
   can fail; use another runner for that role, or allow network and the
   needed paths in your own Codex configuration (`sandbox_workspace_write`).

### Starting an external agent

1. **File names are unique for each start:**
   `<run dir>/jobs/<phase>-<role>[-s<section>]-a<attempt>.prompt.md` and
   `...-a<attempt>.out.md`. `<phase>` is `1`, `1R`, `2`, `2R`, `3`, `3B` or
   `3F<iteration>`; `-s<section>` is for parallel coders; `<attempt>` starts at
   1 and goes up each time the same phase starts the same role again. An
   external reviewer uses `O = <run dir>/jobs/<gate>-r<N>-<letter>.out.md` and
   `<run dir>/jobs/<gate>-r<N>-<letter>.prompt.md`. **All runner files live in
   `<run dir>/jobs/`.** When a reviewer's run is complete, copy its answer to
   the round directory with `cp "O" "<run dir>/<gate>-r<N>/reviewer-<letter>.md"`
   (a byte copy in the shell, never a read-and-write of the text).
2. Create `<run dir>/jobs/` with `mkdir -p`, then write the prompt file (see
   "Prompt file").
3. Start it detached:
   `bash "RUNNER" --runner R --access A --project-root "PROJECT_ROOT" --prompt-file "P" --output-file "O" [--model M] --timeout-minutes N [--command-file "<run dir>/command-<slot>.txt" --check-program <check>] --allow-read "<persona path>" --allow-read "PIPELINE_DOC_ABS" --detach`
   **Check the result before any `--wait`.** `--detach` prints
   `ADT_RUN status=started` and exits 0 when the job started. Any other exit is
   a STOP of the run for a producer or a required reviewer (for an optional
   reviewer: drop it, as a failed reviewer), and the report shows the script's
   output. Never call `--wait` for a job whose `--detach` did not exit 0.
   Always pass `--timeout-minutes`: the slot's `timeout_minutes`, else 30 for a
   reviewer and 120 for `architect`, `coder` and `tester`.
4. **Wait** with `bash "RUNNER" --wait "O" --max-seconds <W>`. In Claude Code
   use `--max-seconds 240` and set the Bash tool's timeout to 330000 ms; in a
   tool whose shell timeout is unknown or short, use 60. Repeat the call until
   its exit code is not 10. For several jobs started together, pass all their
   output files to **one** `--wait` call and read each run's `code` from its
   block.
5. **Access:** `read-only` for reviewers, `write` for architect, coder and
   tester.
6. **Result of a producer** (architect, coder, tester):

   | Script result | Marker | Action |
   |---|---|---|
   | code 0 | `✅ ARCHITECT DONE` / `✅ CODER DONE` / `✅ TESTER DONE` | Continue as the command file says for that marker. |
   | code 0 | `⛔ TESTER BLOCKED` (tester only) | ORCHESTRATION_DOC, "The Blocked Path", exactly as for a native Tester. Not a failure. |
   | code 0 | any other marker | STOP: report role, runner, marker, output path. |
   | code 6 (`no-marker`) | none | The agent stopped without a marker, as a native agent does for its own STOP conditions: relay the output file's text to the user as that agent's STOP report, and STOP the run. |
   | code 13 (`conflicting-markers`) | several | STOP: report role, runner, the conflicting lines from `O.log`, and the output path. |
   | code 2, 3, 4, 5, 11, 12 | any | STOP: report role, runner, status, and the log path. |
   | code 14 (`cancelled`) | any | STOP: report the role and that its change may be incomplete. Never continue with its result. |

   Never retry, and never fall back to native.

**Parallel runs** (several coders in one group, several reviewers in a
panel): start all detached jobs first, then wait for all of them with one
repeated `--wait` call that lists every output file.

### Prompt file

Write exactly this, with the placeholders filled in:

```
# Task for <agent name> (agentic-dev-team pipeline)

Another agent (the pipeline orchestrator) started you. No human will answer
questions during this run.

1. Read <absolute persona path> in full and follow it. It is your complete
   role prompt. Ignore its YAML frontmatter: those settings are for Claude
   Code subagents.
2. Read Part A of <PIPELINE_DOC_ABS>.
3. Read the project's AGENTS.md (or CLAUDE.md) as your role prompt says.

## Your task

<exactly the text the orchestrator gives the native subagent for this step,
including PLAN_PATH, DOC_PATH, DESIGN_DOC, the section to implement, and
the numbered feedback, as the command file specifies>

## Access

<read-only>
You are read-only. Do not create, edit, move, or delete any file. Do not run
git commands that change the repository. The orchestrator checks the working
tree after your run, and a change stops the pipeline.
</read-only>
<write>
You may edit files in the project as your role prompt allows. Never run git
add, git commit, git stash, or any command that changes git history.
</write>

<optional blocks from 7.4>

## End

End your answer with the marker line that your role prompt defines. After
it, write only what your role prompt puts after it (for a CHANGES REQUESTED
verdict: the numbered list). Do not write a second marker line.
```

In this template, "7.4" means the section "Blocks given to reviewers" below.
Use only the access block that applies (without its `<read-only>` or
`<write>` tag lines). **Never put `TEST CREDENTIALS`, or any credential value,
in a prompt file.** Two mechanical rules make sure of it:

1. Text that comes from a Tester (findings, recommendations) is copied into a
   prompt file **only from `test-results.md`**, never from the Tester's chat
   answer. Part A already forbids credential values in `test-results.md`.
2. **No text from a human reply** (a `resume` reply included) is ever copied
   into a prompt file.

### Blocks given to reviewers

**`BUILD GATE OUTPUT`**: given to every code reviewer in a Case B or Case C
code gate, after the build gate ran (passed or failed):

```
## BUILD GATE OUTPUT
The orchestrator ran the build gate from the plan's Section 0:
Command: <command>
Exit status: <n>
<last 200 lines of output>
```

**`EARLIER CONFIRMED FINDINGS`**: given to every reviewer in a Case B or Case
C gate (plan or code) whenever the list below is not empty: from round 2 of
the gate, and in every Phase 3F targeted gate.

The list holds every numbered item that the producing agent was told to fix
earlier in this run for this artifact, in order, with where it came from:

1. each earlier round's feedback in this gate: when the build gate failed in
   that round, its item as one line only, `Build gate failed: <command>
   exited <n>` (never the Gradle output); then the judge's Confirmed list
   (Case C) or the single reviewer's numbered **blocking** items (Case B;
   never its "Nits / optional" items);
2. for a code gate in Phase 3F: also every item from Phase 2R and from the
   earlier Phase 3F iterations that came from a **reviewer, the judge, or a
   build gate**.

The Tester's findings are **never** in this block. A targeted re-review
already gets them as "the fix instructions the Coder worked from", and the
code reviewer must stay free to flag a Tester-driven fix as plan drift.

```
## EARLIER CONFIRMED FINDINGS
Earlier in this run, the producing agent was told to fix these items, and
changed the plan or code to fix them. Those changes are review-driven and in
scope, even where the plan does not specify them. Do not report them as
scope creep. You may report a fix that is wrong or incomplete.
<source heading per group, for example "Code review, round 1 (panel)",
"Code review, round 2 (build gate)", "Code review, Phase 3F iteration 1,
round 1", then the items numbered as they were given>
```

The judge gets the same block and uses it for its REJECTED rule. For a native
reviewer, add the same blocks to the subagent prompt.

### Review gates with RUNS on

A gate uses its effective reviewer list and the case chosen at the start.

**Build gate first (Case B and Case C, code gates only).** Before the
reviewers start, run the build gate from the plan's Section 0 one time (in
Phase 3F targeted re-reviews too), and keep the command, exit status and
output. The reviewers run in either case. **If the exit status is not 0**,
the round result is always `🔧 CODE CHANGES REQUESTED`, whatever the reviewers
and the judge say, and this item comes **first** in the numbered feedback:
`Build gate failed: <command> exited <n>. Fix the failures in this output:
<last 200 lines>.` The other items follow (the judge's Confirmed list, or the
single reviewer's list); when every reviewer approved, the build item is the
only one. The round counts once against the gate's budget. A failed build can
never pass a gate.

**Tree guard for the whole round (Case B and Case C).** Order within a round:
(1) the build gate (code gates), (2) the first snapshot, (3) the reviewers,
(4) the judge when it runs, (5) the second snapshot. Command:
`bash "RUNNER" --snapshot --project-root "PROJECT_ROOT" --guard-path pipeline_artifacts/<slug>`.
If the two hashes differ, or either call exits non-zero: **STOP the run**,
whether the reviewer was required or optional. Report the gate, the round, the
reviewers that ran in that round, and the output of `git status --short`. Do
not revert anything; the developer decides.

**Every STOP stops the external jobs.** On every exit path of a configured run
(a STOP of any kind, the end of the run, or a failed gate), first run
`bash "RUNNER" --cancel "<run dir>"`. The STOP report and the final summary
always include this line: `To stop any external agent that is still running:
bash "<RUNNER>" --cancel "<run dir>"`.

**Case A: the effective list is exactly one native reviewer.** This is
**today's gate**, unchanged: the native reviewer runs the build gate itself,
there is no orchestrator build gate, no tree guard, no extra blocks, and no
judge. The only differences are the model resolution of "Agent
Configuration" and that you write the reviewer's final answer to
`<run dir>/<gate>-r<N>/reviewer-A.md` (create the directory first). A gate the
developer did not configure is always Case A.

**Case B: the effective list is exactly one external reviewer.** For a code
gate, build gate first, then that reviewer gets `BUILD GATE OUTPUT`. Its own
marker is the verdict. No judge. A failure of this reviewer (script code not
0) stops the run, whether it is marked required or not. A code 0 result whose
marker is not this gate's APPROVED or CHANGES REQUESTED marker also stops the
run (report the marker and the output path).

**Case C: 2 to 5 reviewers (a panel).** One round:

1. Code gates only: build gate first. The rest runs whether it passed or
   failed.
2. Create the round directory `<run dir>/<gate>-r<N>/` with `mkdir -p`. It
   holds **only** the reviewer answers, `judge.md` and `panel-map.md`.
   Assign the letters A, B, C, ... to the reviewers in a **random order, new
   for every round**. Start all external reviewers detached, run the native
   reviewer(s) as subagents, then wait for all. The same task text goes to
   every reviewer, plus the blocks above.
3. **Files in the round directory** (all written by you): for a native
   reviewer, its final message; for an external reviewer, the `cp` copy of
   its `O`; both as `<run dir>/<gate>-r<N>/reviewer-<letter>.md`. `<gate>` is
   `plan-review`, `code-review`, or `targeted-review-<k>` (`<k>` is a run-wide
   counter that starts at 1 and goes up each time a Phase 3F targeted gate
   starts; it never repeats). `N` is the round of that gate, from 1. The same
   names apply in Case B (letter `A`). Write the judge's final message to
   `<run dir>/<gate>-r<N>/judge.md`. Right after you write a native reviewer's
   file, take its hash with `bash "RUNNER" --hash <file>`.
4. A reviewer **fails** when its script code is not 0, or its marker is not
   this gate's APPROVED or CHANGES REQUESTED marker (a native reviewer with no
   marker fails too). A required reviewer's failure stops the run; an
   optional reviewer is dropped from this round and reported in the summary.
   If no reviewer output is left: STOP. One remaining output still goes
   through steps 5 to 8.
5. If every remaining reviewer's marker is the gate's APPROVED marker: the
   judge does not run, and the gate passes **unless the build gate failed**
   (then the result is CHANGES REQUESTED with the build item only). Their
   "Nits / optional" items go to the summary.
6. **Reviewer files are checked first.** For each reviewer file that goes to
   the judge, compute `bash "RUNNER" --hash <file>` now and compare it with
   the hash taken when it was complete: the `sha` line of `O.status` for an
   external reviewer, your own `--hash` result for a native one. A difference:
   STOP the run and report the file.
   Then start the judge (native, `adt-android-review-judge`) with: gate type
   (`PLAN` or `CODE`), round number, targeted or full, PLAN_PATH, DOC_PATH when
   present, the `BUILD GATE OUTPUT` block (code gates), the `EARLIER CONFIRMED
   FINDINGS` block when it is not empty; for a targeted re-review, the fix
   instructions the Coder worked from; from round 2, an `EARLIER PANEL
   DECISIONS` block (the "Rejected" and "Disputed" sections of this gate's
   earlier `judge.md` files, with their round numbers; for the judge only);
   and the file paths of **only the reviewers that did not fail in this
   round** (their original letters; gaps are allowed). Never tell the judge
   which tool wrote which file, and never pass whole `judge.md` files to a
   later judge or reviewer.
7. At the **end of every round** (after the judge, or after the all-approve
   decision; in Case B too), write `<run dir>/<gate>-r<N>/panel-map.md` with
   the letter-to-runner-and-model map.
8. The judge's marker is the gate verdict, **except** when the build gate
   failed in this round: then the verdict is always CHANGES REQUESTED. On
   CHANGES REQUESTED the producing agent gets, as its numbered feedback: the
   build-gate item first when the build gate failed, then the judge's
   **Confirmed** list.
9. **No valid judge verdict:** the judge's verdict is not valid when there is
   no marker, conflicting markers, a marker that is not this gate's APPROVED
   or CHANGES REQUESTED marker, APPROVED with a non-empty Confirmed list, or
   CHANGES REQUESTED with an empty Confirmed list (`None`) while the build gate
   passed. Then STOP the run and report the gate, the round, and the path of
   `judge.md`. Do not retry the judge, do not treat it as approval, and do not
   start another round.

**Budgets do not change.** A panel round counts as one review. Phase 1R and
2R: at most 2 re-runs. Phase 3F targeted re-review: at most 1 re-run. A failed
optional reviewer does not use budget.

### The judge's output

The judge checks each finding against the tree and the plan, and classifies
it: **CONFIRMED** (real and blocking under the reviewer's own rules; a failing
build gate is never listed by the judge, because you add it yourself),
**REJECTED** (wrong, already fixed, a style preference, or it only asks to
undo a fix listed in `EARLIER CONFIRMED FINDINGS` without showing that the fix
is wrong; a finding that repeats one an earlier round rejected is rejected
again unless that place changed), or **DISPUTED** (cannot be verified; not
blocking). It merges duplicates and lists all letters that raised them;
reviewer nits stay nits. In a targeted re-review, findings about code the fix
did not touch go under "Out of scope (for the developer)". Its answer has
these exact headings, `None` under an empty one:

```
## Panel result: <PLAN|CODE> gate, round <N>

### Confirmed (blocking)
1. <file:line or plan section>: <problem>. Fix: <what to do>. Raised by: <letters>.

### Rejected
- <letter>#<item number>: <the finding, in one line, with its file:line or plan section>. Reason: <reason>

### Disputed (not blocking)
- <letter>#<item number>: <claim>. Why not verified: <reason>

### Nits / optional
- <letter>#<item number>: <text>

### Out of scope (for the developer)
- <letter>#<item number>: <text> (targeted re-reviews only; write
  `None` in a full review)
```

Its last line is exactly one marker: `✅ CODE APPROVED` or
`🔧 CODE CHANGES REQUESTED` for a code gate, `✅ PLAN APPROVED` or
`🔧 PLAN CHANGES REQUESTED` for a plan gate. APPROVED if and only if the
Confirmed list is empty. Take the producing agent's feedback from the
"Confirmed (blocking)" section only.

### Special cases

| Case | Rule |
|---|---|
| Parallel coders | Each section's coder uses the `coder` slot. External coders in one group run as parallel detached jobs. They run no Gradle, as usual. The cross-section check after each group is unchanged. |
| Tester | May be external. That CLI must have the test driver's MCP server (auto-mobile or Maestro) in its own config. It gets the same DRIVER_DOC, DEVICE, BUILD_INSTALLED and RUN_RESULTS lines as a native Tester. The Test Writer and the steps of ORCHESTRATION_DOC, "The Test Phase", always run native. |
| Tester and credentials | Credentials are never written to a file, and an external run needs a prompt file. So: **from the first reply at the blocked gate that is anything other than exactly `resume` or `stop`** (for example `resume: the PIN is 1234`), **every later Tester start in that run runs native**: that resume itself, every later resume, and every Phase 3F re-test. Only a reply that is exactly the word `resume` (spaces around it do not matter) keeps an external Tester external. Its native model comes from `agents.tester.model`, else the frontmatter (the external slot's `model` is for its CLI only). The summary says so. |
| Architect | May be external (write). Read its `✅ ARCHITECT DONE` line and artifact paths from the output file. |
| External Coder or Tester in Codex | See the warning of "Start" step 5. |

### Summary additions

Add a "Configured run" section to the final summary:

1. Each role: runner and model.
2. Each gate: panel members (letter, runner, model), rounds used, which
   letters raised each confirmed item, disputed items, failed or removed
   optional reviewers.
3. A warning when two reviewers of one gate are in the same model family.
   Family is decided from **what actually runs**:
   - A native reviewer whose model was not applied (Antigravity, opencode, or
     model passing turned off before it started) has the orchestrator tool's
     current model family when known, else unknown.
   - Otherwise use the model value (case-insensitive): for an `opencode`
     value `provider/model`, the provider (`anthropic` is Anthropic, `openai`
     is OpenAI, `google` is Google, any other is unknown); `claude-*`, `opus`,
     `sonnet`, `haiku`, `fable` (also followed by `[`) are Anthropic; `gpt-*`
     or `o` followed by a digit are OpenAI (`opus` and `ollama/...` are not);
     `gemini-*` is Google.
   - When no rule matches, or there is no model value: the `claude` runner is
     Anthropic, `codex` is OpenAI; a `command` runner uses the basename of its
     `check` value (`claude`, `codex`, `gemini` as above); a native reviewer
     with no model value has the orchestrator tool's family when known.
     Anything else is unknown, including `agy` and `opencode` without a model.
   Unknown family: no warning.
4. Every item from the judges' "Out of scope (for the developer)" sections,
   and every DISPUTED item, with gate and round.
5. Nits: the judges' "Nits / optional" items, and, in a round where every
   reviewer approved, the reviewers' own "Nits / optional" items. They take
   the place of "Nits the reviewer declined to block on" for panel gates.
6. The run directory path, and the `--cancel` line above.
