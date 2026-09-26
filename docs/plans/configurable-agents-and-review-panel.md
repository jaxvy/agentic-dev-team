# Implementation plan: configurable agents and review panel

Status: plan for review. Not implemented yet. Reviewed in many rounds of automated code review; the last round found no defects.
Target version: 0.4.0.
Branch: `claude/multi-agent-review-loop-w2oclk`.

This document is the complete contract for the change. An implementing agent
must be able to build it from this file alone. Where this file gives exact
text, use that text. Where it gives a rule, follow the rule.

---

## 1. Summary

The change adds one optional config file to the consuming repo:
`.agentic-dev-team/config.yaml`. It has two parts:

1. **`agents:`** sets the model of each pipeline agent. It applies in all
   five commands.
2. **`build_auto_reviewed:`** applies only to `/build-auto-reviewed`. It sets
   where each role runs (in the current tool, or in another CLI that the
   developer is logged in to), and it turns a review gate into a **review
   panel**: 1 to 5 reviewers whose findings a new **judge** agent verifies
   and merges.

The file is created automatically, with every setting commented out, and it
is git-ignored. With no active setting, every command works exactly as it
does today.

### 1.1 Flow of `/build-auto-reviewed` with a code review panel

```
 start
   │  run adt-run-agent.sh --init-config (creates the config once, ignored, inert)
   │  read and validate .agentic-dev-team/config.yaml → MODELS, RUNS
   │  RUNS on: make run dir, preflight each external CLI
   ▼
 Phase 1  Architect ─────────── native subagent or external CLI (write)
 Phase 1R Architect review gate  1 native reviewer (as today) or a panel
 Phase 2  Coder(s) ──────────── native subagents or external CLIs (write)
 Phase 2R Code review gate:
   │   orchestrator runs the build gate one time → BUILD GATE OUTPUT
   │   reviewers run in parallel, read-only, anonymous (A, B, C):
   │     A (native)    B (codex)    C (agy)
   │   all approve?
   │     yes → no judge. The gate passes, unless the build gate failed.
   │     no  → judge (native; main model by default):
   │           CONFIRMED / REJECTED / DISPUTED, merged
   │           ✅ CODE APPROVED → Phase 3
   │           🔧 CODE CHANGES REQUESTED → Coder fixes the confirmed list,
   │              then the next round (max 2 re-runs, as today)
 Phase 3  Tester ────────────── native subagent or external CLI (write)
 Phase 3F Fix loop: Coder → targeted re-review (same panel) → re-test
 close   summary with panel members, models, rounds, disputed items
```

### 1.2 Rules for this change

| # | Rule |
|---|---|
| R1 | Without a config that a human edited, every command works exactly as it does today, in Claude Code, Antigravity and opencode. The only visible effects are the git-ignored config file itself (R4) and the one command that creates it: on the first run in a repo with a plugin install, or after the developer deleted the file (4.2). In Claude Code's default permission mode that command asks for permission. If the developer allows it and it succeeds, the file exists and it never asks again (if it fails, for example in a read-only directory, the command says so in one line and asks again next time). If the developer declines, the command continues exactly as today without the file, and the next command run asks again; the command then prints one line saying how to stop the question (allow the command, or create `.agentic-dev-team/.gitignore` with `*` and copy `config.example.yaml` to `.agentic-dev-team/config.yaml` by hand). |
| R2 | External runners and review panels apply only to `/build-auto-reviewed`. |
| R3 | The model of every agent is configurable, including the PM. So `agents:` applies in all five commands. |
| R4 | The config file is created in the consuming repo, and it is git-ignored by default. |
| R5 | The developer can un-ignore the file. Later `install.sh` runs do not change that. |
| R6 | All of this works with the Claude Code plugin install and with `install.sh`. |

---

## 2. Terms

| Term | Meaning |
|---|---|
| Orchestrator | The main agent that runs a command file (Claude Code, Antigravity, or opencode). |
| Native | The agent runs as a subagent of the orchestrator's own tool, as today. |
| External | The agent runs as a separate CLI process through `adt-run-agent.sh`. |
| Role | One of: `pm`, `architect`, `architect_reviewer`, `coder`, `code_reviewer`, `tester`, `review_judge`. |
| Agent file | `adt-android-pm.md`, `adt-android-architect.md`, `adt-android-architect-reviewer.md`, `adt-android-coder.md`, `adt-android-code-reviewer.md`, `adt-android-tester.md`, `adt-android-review-judge.md`. |
| Project root | The directory where the commands run: the one that holds `.claude/` (or where `install.sh` installed) and `pipeline_artifacts/`. Usually also the git top-level, but not always (an Android project can sit in a subdirectory of a larger repo). Every path in this plan that is not absolute is relative to the project root. The orchestrator records it once, as the absolute path PROJECT_ROOT (9.1), and passes it to every script call with `--project-root`. |
| PLUGIN_ROOT | `plugins/agentic-dev-team/` in this repo. In a plugin install, Claude Code puts its absolute path where a command body says `${CLAUDE_PLUGIN_ROOT}`. |
| ADT_ROOT | The absolute directory that holds `scripts/`, `agents/` and `AGENTIC_DEV_TEAM_PIPELINE.md` for this project: `<project root>/.claude` in an `install.sh` project, PLUGIN_ROOT in a plugin install. Both layouts have the same `scripts/`, `agents/` and pipeline doc below this directory. `config.example.yaml` is only in PLUGIN_ROOT: an `install.sh` project does not link it into `.claude/`, so nothing may read `ADT_ROOT/config.example.yaml` there. Each command sets ADT_ROOT (9.1). |

**Important:** Claude Code replaces `${CLAUDE_PLUGIN_ROOT}` only inside the body of a command, skill or agent file when it loads that file. It does **not** replace it in a file that the orchestrator reads with a Read tool (such as the pipeline doc), and the variable is **not** set in the Bash environment. So only command bodies may contain `${CLAUDE_PLUGIN_ROOT}`. The pipeline doc and the scripts use ADT_ROOT, which the command resolves and passes on.

Role to agent file:

| Role | Agent file | Frontmatter model today |
|---|---|---|
| `pm` | `adt-android-pm.md` | `opus` |
| `architect` | `adt-android-architect.md` | `opus` |
| `architect_reviewer` | `adt-android-architect-reviewer.md` | `opus` |
| `coder` | `adt-android-coder.md` | `sonnet` |
| `code_reviewer` | `adt-android-code-reviewer.md` | `opus` |
| `tester` | `adt-android-tester.md` | `sonnet` |
| `review_judge` | `adt-android-review-judge.md` (new) | `inherit` |

---

## 3. The config file

### 3.1 Location and files

```
<project root>/.agentic-dev-team/
  .gitignore     one line: *
  config.yaml    copy of PLUGIN_ROOT/config.example.yaml
```

The `*` line ignores the whole directory, the `.gitignore` included. This is
the same method `pipeline_artifacts/.gitignore` uses today. So `git status`
and the code reviewer's changed-file manifest never list these files.

### 3.2 Schema (version 1)

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

A slot:

| Key | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `runner` | string | no | `native` | `native`, `claude`, `codex`, `agy`, `opencode`, `command` |
| `model` | string | no | see 3.4 | Model for this slot. For `native`: an alias (3.4). For external runners: any value that CLI's `--model` flag accepts. |
| `timeout_minutes` | integer ≥ 1 | no | `30` for a reviewer, `120` for `architect`, `coder` and `tester` | External runners only. Ignored for `native` (a native agent has no time limit, as today). A timeout stops the run, so set it generously for producers. |
| `required` | boolean | no | `true` | Reviewer slots only, and only in a list with 2 or more entries (a single reviewer is always required, so `required: false` there is a config error, rule 7). See 7.5. |
| `command` | string | only for `runner: command` | none | Command template, see 6.4. |
| `check` | string | required for `runner: command`, not allowed for other runners | none | The program that preflight looks for, and the program word of the template (they must be the same), for example `gemini` in `GEMINI_API_KEY=x gemini -p {instruction}`. One word (rule 6). |

`review_judge` and `pm` are valid only under `agents:`. The judge always
runs native (the developer asked that the judge run in the main tool). Its
model is the main model (`model: inherit`) unless
`agents.review_judge.model` sets another one.

### 3.3 Active settings and switches

After YAML parsing (comments are not parsed):

A **native model value** is any `agents.<role>.model`, or the `model` of a
`build_auto_reviewed` slot or reviewer entry whose `runner` is `native` or
that has no `runner` key (such a slot is native). This is the only
definition of the term; everything below uses it.

- **`MODELS` is on** when at least one native model value is set for a
  role that the current command starts: an `agents.<role>.model` for a role
  in the table below, or (in `/build-auto-reviewed` only) a native model
  value under `build_auto_reviewed`.

  | Command | Roles it starts |
  |---|---|
  | `/plan-research` | `pm` |
  | `/plan-design` | `architect` |
  | `/build-auto` | `architect`, `coder`, `tester` |
  | `/build-guided` | `pm`, `architect`, `coder`, `tester` |
  | `/build-auto-reviewed` | `architect`, `architect_reviewer`, `coder`, `code_reviewer`, `tester`; and `review_judge` only when a **configured** `reviewers` list has 2 or more entries (read from the file; the preflight of 7.1 does not change this) |

  Example: a config with only
  `build_auto_reviewed: { coder: { runner: native, model: opus } }` turns on
  `MODELS` (not `RUNS`) in `/build-auto-reviewed`, and neither switch in the
  other commands.
- **`RUNS` is on** when `build_auto_reviewed:` needs the configured-run
  machinery (section 7): at least one slot or reviewer entry has a
  `runner` other than `native`, or a `reviewers` list has 2 or more
  entries. Anything else there changes at most a model: a native slot or a
  single native reviewer entry with a `model` is a native model value
  (`MODELS`), not `RUNS`. `timeout_minutes` has no effect on native
  entries. `required` matters only in a list of 2 or more entries (7.5
  Case C step 4); a single entry is always required, so there only
  `required: true` (or no `required` key) is allowed, and `required:
  false` is a config error (rule 7). So uncommenting a template example such as
  `architect: { runner: native }`, or setting
  `coder: { runner: native, model: opus }`, never turns on `RUNS`.

A missing file, an empty file, and the file as created (everything commented
out) give `MODELS` off and `RUNS` off. `version` alone does not turn on a
switch.

**Validation.** The orchestrator validates the whole file at the start of
every command, before the first agent runs. Any of these stops the command
with a message that names the key and the problem:

1. The file is not valid YAML, or its top level is neither empty (YAML
   `null`: an empty or comments-only file, which counts as no config) nor
   a mapping.
2. `version` is present and is not `1`.
3. An unknown top-level key, role, or slot key.
4. A `runner` that is not in the list.
5. A `reviewers` list that is empty or has more than 5 entries.
6. A problem with a `command` runner, any of:
   - `runner: command` without `command`, or without `check`;
   - `command` or `check` with another runner;
   - a `command` whose **parsed string value** (after YAML parsing, so
     YAML's own quotes around the value do not count) fails any item of
     the "Template check" list in 6.4 (that list is the one definition;
     the script applies the same list);
   - a `command` with neither `{instruction}` nor `{prompt_file}` (the CLI
     would never learn its task);
   - a `command` that uses `{model}` in a slot without `model` (it would
     run with an empty model);
   - a `check` value whose basename is one of the shells and command
     runners listed in 6.4 ("Template check");
   - a `check` value that is not a bare program name or an absolute path.
     It must match `^([A-Za-z0-9_+][A-Za-z0-9._+-]*|/[A-Za-z0-9._/+-]+)$`:
     a name has no `/` and does not start with `-` or `.`; a path starts
     with `/`. No spaces, `$`, `~` or quotes. (A relative path such as
     `bin/gemini` is not allowed, because it would depend on the current
     directory.)
   The template's program word must be exactly the `check` value (6.4),
   so the program that runs is always the one that preflight checked.
7. `required` outside a reviewer slot; `required: false` in a `reviewers`
   list that has only one entry; or `timeout_minutes` that is not a whole
   number ≥ 1.
8. In Claude Code only, and only when the Agent (Task) tool has a `model`
   parameter in its schema (without it, there is no list to check against):
   **any** native model value in the file, also one that the current
   command does not use, that is not one of the values that parameter
   accepts: the values of its `enum` when the schema has one; when the
   parameter is a plain string without an `enum`, the aliases `sonnet`,
   `opus`, `haiku` and `fable` only. So the same file is valid or invalid
   in every command. See 3.4.
9. A value of the wrong type. The only allowed shapes are:
   - `version`: the integer `1`.
   - `agents`: `null` or a mapping; each role under it: a mapping with
     exactly one key, `model`, whose value is a non-empty string (an empty
     mapping, `model:` with no value, and `model: ""` are errors).
   - `build_auto_reviewed`: `null` or a mapping. `architect`, `coder`,
     `tester`: a slot. `architect_reviewer`, `code_reviewer`: a mapping
     whose only key is `reviewers`, a **list** (not `null`) of slots.
   - A slot: a mapping. `runner`, `model`, `command`, `check`: non-empty
     strings. `timeout_minutes`: an integer. `required`: exactly `true` or
     `false`, lowercase and without quotes. Every other value (`yes`, `no`,
     `True`, `"false"`, ...) is an error, so the rule does not depend on
     which YAML version a reader uses, and an orchestrator that reads the
     raw text can apply it without doubt.
   A role key whose value is `null` (for example `coder:` with nothing
   after it) is an error, not "not configured": remove the key or comment
   it out.

`/build-auto`, `/build-guided`, `/plan-design` and `/plan-research` validate
the whole file too (a broken file is an error everywhere), but they use only
`agents:`.

### 3.4 Model values and what they run

**Native agents in Claude Code.** The orchestrator passes the value in the
`model` parameter of its Agent tool. That parameter accepts **aliases only**
(today: `sonnet`, `opus`, `haiku`, `fable`; the exact list is the enum in the
tool's own schema). Full model IDs, `inherit`, `best`, `default`, `opusplan`
and `[1m]` variants are not accepted there, so validation rejects them.

**What a native alias runs.** Claude Code resolves the alias when it starts
the subagent (sub-agents docs, "Choose a model"). The three cases below are
called **alias case 1, 2 and 3** elsewhere in this plan:

1. **If the main conversation's model is in the same family** (for example
   the main session runs an Opus model and the config says `opus`): the
   subagent runs on the main conversation's **exact** model, including any
   `[1m]` suffix. `ANTHROPIC_DEFAULT_OPUS_MODEL` does not change this.
2. **Otherwise:** the subagent runs the version that the alias points to:
   the value of `ANTHROPIC_DEFAULT_<FAMILY>_MODEL` when that variable is set,
   else Claude Code's current mapping (table below).
3. A rare third case (docs): on a provider other than the Anthropic API,
   when Claude Code cannot tell the main model's family (for example an
   unresolved Bedrock inference profile ARN), `opus` also resolves to the
   main conversation's model, unless `ANTHROPIC_DEFAULT_OPUS_MODEL` is set.

Current alias mapping (alias case 2):

| Alias | Anthropic API (today) | Other providers |
|---|---|---|
| `opus` | Opus 5.5 | Can differ, for example Opus 4.6 on Microsoft Foundry |
| `sonnet` | Sonnet 5 | Sonnet 4.6 or 4.5 on some providers |
| `haiku` | latest Haiku | provider-dependent |
| `fable` | Fable 5.1 | provider-dependent |

The mapping changes when Claude Code updates. All of this is the same
behavior as today, because the agent files already use the aliases
`model: opus` and `model: sonnet`, and the same rules apply to them.

**Examples** (Anthropic API, today):

| Main session | Config | The native agent runs |
|---|---|---|
| Opus 5.5 | `opus` | Opus 5.5 (the main model) |
| `opus[1m]` | `opus` | Opus with the 1M context (the main model) |
| Sonnet 5 | `opus` | Opus 5.5, or the model in `ANTHROPIC_DEFAULT_OPUS_MODEL` |
| Opus 5.5 | `sonnet` | Sonnet 5, or the model in `ANTHROPIC_DEFAULT_SONNET_MODEL` |

**Pinning a version for a native agent is not possible through this config.**
The config accepts only aliases (the Agent tool accepts only aliases), and
an alias of the main model's family always gives the main model. To run an
agent on a specific version:
- in `/build-auto-reviewed`: use `runner: claude` with a full model ID, for
  example `{ runner: claude, model: claude-opus-5-5 }` (an external run);
- for a native agent of another family than the main model: set
  `ANTHROPIC_DEFAULT_<FAMILY>_MODEL` in the `env` of `.claude/settings.json`;
- otherwise: select that version as the main session's model.
Document this in the README and in the template.

**Precedence in Claude Code** (sources, checked 2026-09-26:
https://code.claude.com/docs/en/sub-agents, section "Choose a model", and
https://code.claude.com/docs/en/model-config): the
per-invocation `model` parameter wins over the agent frontmatter, which wins
over `CLAUDE_CODE_SUBAGENT_MODEL`, which wins over the main model. Exception:
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE` (set to `1`) overrides all of them. The
orchestrator checks it (section 5.2). `CLAUDE_CODE_SUBAGENT_MODEL` alone does
not override a configured model, because the per-invocation parameter wins.
The sub-agents page says it in these words (quoted on 2026-09-26): "When
Claude invokes a subagent, it resolves the subagent's model in this order:
1. Per-invocation `model` parameter ... 2. Subagent definition's `model`
frontmatter ... 3. `CLAUDE_CODE_SUBAGENT_MODEL` environment variable ...
4. Main conversation's model". Reviewers of this plan have more than once
remembered a different order; the quote above is the source of truth.
Re-check these two pages when you implement; if they changed, follow them and
update this section.

**Model resolution for a native agent** (first match wins):

1. In `/build-auto-reviewed` only: the `model` of the slot that
   starts this agent (for a reviewer: its own entry in the `reviewers`
   list), when that slot is native. Two native entries in one list can
   have different models.
2. `agents.<role>.model`.
3. No value. The orchestrator passes no `model` parameter, so the agent
   file's frontmatter applies (today's behavior).

**Native agents in Antigravity and opencode.** These tools cannot select a
model for each subagent. Every subagent uses the model selected in the tool.
The orchestrator does not fail. It skips the model and reports once in the
final summary: `Model settings were not applied: <tool> runs every subagent
on its selected model.` Validation rule 8 does not apply there.

**External runners.** `model` goes to the CLI's `--model` flag unchanged:

| Runner | Example values | Notes |
|---|---|---|
| `claude` | `opus`, `claude-opus-5-5` | Full IDs pin a version |
| `codex` | a Codex model name | Use a name from the Codex model list |
| `agy` | an Antigravity model slug | Use a slug from the `agy` model list |
| `opencode` | `provider/model` | opencode format |
| `command` | any | Put into `{model}` |

When `model` is absent, the CLI uses its own default model.

---

## 4. Creation, ignore, un-ignore, uninstall

### 4.1 `adt-run-agent.sh --init-config`

The config is created by a mode of the one script of section 6, so the path
logic exists only once (6.5).

```
bash PLUGIN_ROOT/scripts/adt-run-agent.sh --init-config <project-root>
```

1. `<project-root>` is required and must be an absolute path: the
   commands pass PROJECT_ROOT (9.1), `install.sh` passes its `PROJECT_DIR`.
   The config is created in exactly that directory, next to `.claude/` and
   `pipeline_artifacts/`. It is never placed in the shell's current
   directory, and the script never moves it up to the git top-level. (When
   the project root **is** the git top-level, the usual case, that is of
   course where it goes.) A missing or relative argument, or a path that
   is not an existing directory: warning, exit 1 (it never creates the
   project directory itself).
2. Template: let `REAL` be `adt_physical_path "${BASH_SOURCE[0]}"` (6.5).
   `REAL` has no symlinks left, so plain text operations on it are safe: the
   template is `$(dirname "$(dirname "$REAL")")/config.example.yaml`. See
   6.5 for why a physical path is required.
   `--init-config` exits only with 0 or 1 (step 6).
3. If `<project-root>/.agentic-dev-team` exists and is not a directory:
   print a warning to stderr, exit 1.
4. If anything exists at `<project-root>/.agentic-dev-team/config.yaml`
   (test with `[ -e ] || [ -L ]`: a file, a directory, a symlink, broken or
   not), this step decides and step 5 never runs, so the path is **never
   edited or overwritten**:
   - a readable regular file, or a symlink to one: print
     `ADT_INIT status=exists`, exit 0;
   - anything else (a broken symlink, a directory, an unreadable file):
     print `ADT_INIT status=unreadable` and
     `config.yaml exists but is not a readable file; fix or delete it`,
     exit 1.
5. Otherwise:
   1. `mkdir -p <project-root>/.agentic-dev-team`
   2. If `.agentic-dev-team/.gitignore` does not exist, write it with the
      single line `*`, through a temp file with a unique name
      (`.gitignore.tmp.$$`, `$$` being the script's pid) and `mv`. **If
      this fails, delete that temp file and stop here** (warning, exit 1),
      and do not
      create `config.yaml`: a
      config without its `.gitignore` would never be ignored (4.3), and the
      next run tries again.
   3. Copy the template to a temp file with a unique name,
      `.agentic-dev-team/config.yaml.tmp.$$` (so two init runs at the same
      time never share one). **If `cp` fails, delete the temp file,
      warn, and exit 1**: a partial copy is never moved into place. Then
      move it with `mv -n` (never replaces an existing path) and decide
      from the files, not from the exit status of `mv -n` (it differs
      between macOS and GNU versions). There is no retry loop:
      - temp file gone, `config.yaml` exists: it was created; continue
        with item 4 of this inner list (print `ADT_INIT status=created`,
        exit 0);
      - temp file still there, `config.yaml` exists: another run created
        it in the meantime; delete the temp file, print
        `ADT_INIT status=exists`, exit 0;
      - temp file still there, `config.yaml` missing: the move failed;
        delete the temp file, warn, exit 1;
      - both gone: warn, exit 1.
      A stale temp file from a killed run is git-ignored by the `*` rule.
   4. Print `ADT_INIT status=created` and
      `created .agentic-dev-team/config.yaml (git-ignored; see its header to share it)`.
   Every other exit 1 prints `ADT_INIT status=failed` first, then its
   warning. The first stdout line is always one `ADT_INIT status=...`
   line, so a caller can tell the cases apart.
6. **Exit status: 0 or 1 only.** Exit 0 when the config exists at the end
   (created now, or already there, step 4). Exit 1 on every failure
   (template missing, directory not writable, `.agentic-dev-team` is a
   file, `.gitignore` could not be written), with a warning on stderr.
   Exit 1 is a report, never a reason to stop, with **one exception**:
   `ADT_INIT status=unreadable` (step 4: `config.yaml` exists but cannot
   be read) is a config error, and a command stops on it (9.1), the same
   as on invalid YAML. `install.sh` never stops (10.10). The exit status
   and the status line let the caller tell the cases apart.

Compatible with bash 3.2.

### 4.2 Who calls it

| Install path | Caller | When |
|---|---|---|
| `install.sh` | `install.sh` (section 10.10) | At install |
| Claude Code plugin | Each of the five commands, first step (section 9.1) | First command run in that repo. A plugin cannot write into a project at install time. |

A command runs `--init-config` **only when
`.agentic-dev-team/config.yaml` does not exist** (it checks by reading
that exact path with its file-read tool, which runs no shell command; a
file-search tool is not used, because search tools skip git-ignored
files). So in an `install.sh` project, which already has the file, a
command runs it only after the developer deleted the file; in a plugin
install it runs until it succeeds once (normally the first run). If
`--init-config` did not run (the permission was declined, or the tool
reported an error) or exited 1 with `ADT_INIT status=failed`, the command
prints the "not created" message of 9.1 once and continues. With
`ADT_INIT status=unreadable` it stops instead (a config error, 9.1). The exact message text is in the 9.1
command preamble, because only a command body can name the plugin path.
If the script is not found (an older
install), the command continues without it.

### 4.3 Un-ignore (R5)

The developer deletes (or edits) `.agentic-dev-team/.gitignore` and commits
`config.yaml`. This lasts because:

- The ignore rule is not in the `.gitignore` block that `install.sh` rewrites.
- `--init-config` never creates `.gitignore` while `config.yaml` exists.
- `install.sh` never edits files in `.agentic-dev-team/`, also not in
  uninstall (4.4).

If the developer deletes both files, the next init creates both again. That
is intended. After un-ignoring, switching to a branch that does not have
the committed config lets the next command create a local, ignored copy
(and `.gitignore`); switching back replaces that copy with the committed
file (git replaces ignored files on checkout), and the committed file
stays tracked and shared.

**Warning for teams (README and template header):** when a teammate pulls
the newly committed `config.yaml`, git replaces that teammate's local,
ignored `config.yaml` without a warning, because git treats ignored files
as disposable. Before committing a shared config, ask the team to copy any
local settings they want to keep.

### 4.4 Uninstall

`install.sh --uninstall`, after its current steps:

**Uninstall never deletes or edits anything in `.agentic-dev-team/`.** If
the directory exists, it prints
`kept .agentic-dev-team/ (your configuration; delete it yourself if you do not need it)`.
Reason: uninstall cannot know whether the developer edited the config,
committed it for the team, or un-ignored it. Comparing with the current
template gives wrong answers after an upgrade, and deleting a committed
config would leave a deletion in the team's working tree. The kept
`.gitignore` keeps an uncommitted config ignored, so nothing new appears in
`git status`.

The plugin uninstall does not touch the project. That is a Claude Code
limit; document it.

### 4.5 The template: `PLUGIN_ROOT/config.example.yaml`

Exact content. Every setting is commented out. The model comments must
equal the agent frontmatter (a test checks it, section 12.2).

```yaml
# agentic-dev-team configuration
#
# This file has no effect until you remove the "#" from a setting.
# It is git-ignored by .agentic-dev-team/.gitignore. To share it with your
# team: delete .agentic-dev-team/.gitignore, then commit this file.
# install.sh never re-creates that .gitignore while this file exists.
# Warning: when teammates pull the committed file, git silently replaces
# their own local config.yaml. Tell them to copy their settings first.
#
# Full reference: README.md, section "Configuration".

version: 1

# ---------------------------------------------------------------------------
# agents: the model of each agent, in ALL commands.
# Applies when the agent runs in the current tool ("native").
#
# Claude Code: use a model alias: opus, sonnet, haiku, fable.
#   If your main session already runs a model of that family, the agent runs
#   on exactly your main session's model. Otherwise the alias gives the
#   version Claude Code maps it to (for example "opus" is Opus 5.5 on the
#   Anthropic API today), or the model in ANTHROPIC_DEFAULT_OPUS_MODEL
#   (or _SONNET_, _HAIKU_, _FABLE_) when you set it. You cannot pin an exact
#   version here; see README, "Configuration".
# Antigravity and opencode: ignored. These tools run every subagent on the
#   model that you selected in the tool.
#
# The values below are the defaults from the agent files, except
# review_judge, whose default is the main model (no value).
# ---------------------------------------------------------------------------
agents:
  # pm:                 { model: opus }
  # architect:          { model: opus }
  # architect_reviewer: { model: opus }
  # coder:              { model: sonnet }
  # code_reviewer:      { model: opus }
  # tester:             { model: sonnet }
  # review_judge:       { model: <alias> } # default: no value = the main model

# ---------------------------------------------------------------------------
# build_auto_reviewed: only for /build-auto-reviewed.
#
# runner: where the agent runs.
#   native    the current tool (default)
#   claude    Claude Code CLI      (claude -p)
#   codex     OpenAI Codex CLI     (codex exec)
#   agy       Antigravity CLI      (agy -p)
#   opencode  opencode CLI         (opencode run)
#   command   any command; see "command" below
# Each CLI uses your own login. It must be installed and logged in.
#
# model:            the model for that runner (a --model value).
# timeout_minutes:  external runners only. Default 30 for reviewers and
#                   120 for architect, coder and tester. A timeout stops
#                   the run.
# required:         reviewers only. true (default): a failure stops the run.
#                   false: the run continues without that reviewer. Only
#                   in a list of 2 or more reviewers.
# command:          only for runner: command. Placeholders:
#                   {instruction} {prompt_file} {output_file} {model}
#                   The command is not run by a shell: do not use
#                   ' \ ` $ | ; & < > in it. If you use {model}, also
#                   set model. Example: gemini -p {instruction} -m {model}
# check:            required for runner: command. The one program that
#                   must be installed, for example: check: gemini
#
# With 2 or more reviewers, a gate becomes a review panel: a judge agent
# verifies and merges their findings. The judge runs in the current tool,
# on the main model unless agents.review_judge sets a model.
# ---------------------------------------------------------------------------
build_auto_reviewed:
  # architect: { runner: native }
  # coder:     { runner: native }
  # tester:    { runner: native }
  # architect_reviewer:
  #   reviewers:
  #     - { runner: native }
  # code_reviewer:
  #   reviewers:
  #     - { runner: native }
  #     - { runner: codex, required: false }
  #     - { runner: claude, model: claude-opus-5-5 }
  #     - { runner: command, check: gemini, command: "gemini -p {instruction} -m {model}", model: <gemini-model> }
```

Note: `review_judge`'s comment shows a placeholder, because its default
(`inherit` in the frontmatter) is not a valid config value: leaving the key
out keeps the main model. The test in 12.2 treats the judge line as an
exception.

---

## 5. Agent Configuration in every command (`MODELS`)

### 5.1 Steps at the start of every command

After the command resolves PIPELINE_DOC (existing text), and before its
first phase:

1. The config file check and `--init-config` are done **once**, by the
   command preamble (9.1), before this section is read. This section never
   runs `--init-config` again, and never prints the "not created" message
   again.
2. Read `.agentic-dev-team/config.yaml` if it exists. Validate it with rules
   1 to 7 and 9 of 3.3, and, in Claude Code, rule 8. Rule 8 only compares the
   file's values with the Agent tool's schema: it runs no command and adds
   no summary line. An unedited file has no native model value, so rule 8
   checks nothing. On an error: stop, report, start no agent.
3. Set `MODELS` (and in `/build-auto-reviewed`, `RUNS`).
4. If `MODELS` is off: skip step 5 and the rest of section 5, and continue
   with the command's first phase as usual. No `printenv`, no model passing,
   no summary line about models (R1). This is not a STOP.
5. If `MODELS` is on and the tool is Claude Code: do the start check of 5.2
   step 2.

### 5.2 When `MODELS` is on

1. **Claude Code, every native start:** each time the orchestrator starts
   an `adt-*` subagent natively (in `/build-auto-reviewed` this includes
   native slots and native panel reviewers), it resolves the
   model (3.4) and, while model passing is on, passes it in the Agent tool's
   `model` parameter. With no resolved value, it passes nothing.
2. **Claude Code, start check (once, at 5.1 step 5).** Model passing starts
   **on**, and is turned **off** for the whole run when:
   1. `printenv CLAUDE_CODE_SUBAGENT_MODEL_FORCE` prints a non-empty value
      other than `0` or `false` (any casing). REASON:
      `CLAUDE_CODE_SUBAGENT_MODEL_FORCE is set to <value>`.
      FORCE works also when `CLAUDE_CODE_SUBAGENT_MODEL` is not set: the
      model-config docs say subagents then run on "the main conversation's
      model if only the force flag is set". So FORCE alone is enough to
      turn model passing off.
      **This is intentional; do not narrow it to `1`/`true`.** Claude Code
      applies FORCE silently, so no later check can see it. The two possible
      mistakes are not equal: treating an unusual value such as `yes` as on
      can only skip model passing, and the summary then names the variable
      and its value so the developer can fix it; treating it as off could
      print a model as requested while Claude Code forced another one.
   2. The Agent (Task) tool has no `model` parameter in its schema.
      REASON: `the Agent tool has no model parameter`.
3. **Claude Code, during the run (every start that passes `model`):** if a
   subagent start that included `model` fails with an error message that
   names the `model` parameter or says a model cannot be passed: start that
   same subagent again once, without `model`, and turn model passing off for
   the rest of the run. (This is step 3; it is separate from the start
   check of step 2.) REASON:
   `Claude Code rejected the model parameter: <error message>`. Any other
   start error is handled as today; it never turns model passing off.
4. **While model passing is off:** pass no `model` to any subagent, and put
   this line in the final summary: `Model settings were not applied: <REASON>.`
   The run continues normally.
5. **Antigravity, opencode:** pass nothing, and report as in 3.4.
6. **Summary line:** `Models requested: <role>=<value> ...` for each role
   whose configured model was passed. The line says "requested", never
   "ran", because Claude Code can still replace a requested model: an
   organization `availableModels` allowlist can substitute a blocked alias
   (sub-agents docs), and alias case 1 of 3.4 can apply.
7. **`CLAUDE_CODE_SUBAGENT_MODEL` note (Claude Code).** In the start check,
   also run `printenv CLAUDE_CODE_SUBAGENT_MODEL`. If it prints a value,
   add to the summary: `Note: CLAUDE_CODE_SUBAGENT_MODEL is set to <value>.
   Claude Code older than v2.1.251 lets it override the requested models
   (sub-agents docs).` Model passing stays on. The README states that model
   settings need Claude Code v2.1.251 or later when that variable is set.

---

## 6. `adt-run-agent.sh` (config init and external runners)

Path: `PLUGIN_ROOT/scripts/adt-run-agent.sh`. The `--init-config` mode (4.1)
is used by every command and by `install.sh`. All other modes are used only
by `/build-auto-reviewed` with `RUNS` on. Compatible with bash 3.2: no
associative arrays, no `mapfile`, no `${var,,}`, no `wait -n`, no
`readlink -f`, no `timeout` binary. Always call it as `bash <path> ...` so
the executable bit does not matter.

### 6.1 Interface

```
bash adt-run-agent.sh --init-config <project-root>      (4.1; exits 0 or 1, never stops a caller)

bash adt-run-agent.sh --identity <pid>      (internal: prints the process identity, 6.1)

bash adt-run-agent.sh --check <runner>
bash adt-run-agent.sh --check command --check-program <program>
                      --command-file <path> [--model <model>]

bash adt-run-agent.sh --runner <runner> --access <read-only|write>
                      --project-root <path>
                      --prompt-file <path> --output-file <path>
                      [--model <model>] [--timeout-minutes <n>]
                      [--command '<template>' | --command-file <path>]
                      [--check-program <program>]
                      [--allow-read <path>]...
                      [--detach]

bash adt-run-agent.sh --wait <output-file>... [--max-seconds <n>]

bash adt-run-agent.sh --hash <file>      (prints `git hash-object --no-filters -- <file>`)

bash adt-run-agent.sh --snapshot --project-root <path> [--guard-path <path>]...

bash adt-run-agent.sh --cancel <run dir>
```

`--timeout-seconds <n>` is also accepted (for tests). `--command-file`
reads the template from a file (the whole file, trailing newline removed);
the orchestrator always uses it, `--command` is for manual use.

Files for one run, all next to `--output-file` (call it `O`):

| File | Content |
|---|---|
| `O` | The agent's final answer |
| `O.log` | CLI progress and errors |
| `O.status` | Written last, atomically (`O.status.tmp`, then `mv`). The five `ADT_RUN` lines below. |
| `O.pid` | Detached runs only. Written **only by the `--detach` parent**, two lines: `<job pid> <timeout seconds>`, then the job's identity (see "Process identity" below). The job pid is also the job's process group ID. |
| `O.clipid` | Written **only by the CLI wrapper** (step 9), two lines: the CLI's pid (also its process group ID), then its identity. |
| `O.cancel` | Created only by the stop path of step 10.5, which `--wait` (lost path) and `--cancel` both use. The CLI wrapper does not start the CLI when it exists. |
| `O.elapsed` | Written only by the job: first the value `0`, as soon as the job owns `O.pid` (step 9), then by its timeout watcher, the awake seconds counted so far (step 6). |
| `O.timedout` | Written only by the job's timeout watcher when it stops the CLI at the timeout. |

**Process identity.** A pid alone can be reused by another process after
the first one ends (macOS wraps at 99999). So every stored pid comes with
an identity, taken when the pid is stored, by the function
`adt_proc_identity <pid>`:
- **Linux** (`/proc/<pid>/stat` exists): the process start time in clock
  ticks since boot, field 22 of `/proc/<pid>/stat`. Read it as the text
  after the last `)` in that file, split on spaces, item 20 of that
  remainder (the name field in parentheses can contain spaces). This
  value never changes, even when the wall clock is set.
- **macOS and others:** `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` (fixed
  locale and time zone, so the text is the same for every caller). On macOS this is the
  start time that the kernel stored when the process began; it does not
  move when the clock is set later.
A stored process **is alive** only when `kill -0 <pid>` succeeds **and**
`adt_proc_identity <pid>` still prints the stored identity. Every liveness
check uses this test.

**Signalling a process group** (the job's or the CLI's; the group ID is the
stored pid). Signal the group when either:
1. the leader is alive (identity test), or
2. the leader is gone (`kill -0 <pid>` fails) but the group still exists
   (`kill -0 -- -<pid>` succeeds). Its children can still be running. The
   group is still the original one: POSIX does not reuse a process group ID
   while that group exists, and no new process can get that pid while the
   group exists.
Do not signal when the pid is alive with a different identity (the pid was
reused), or when neither the leader nor the group exists.

Output lines (stdout, and the content of `O.status`):

```
ADT_RUN status=<status> runner=<runner> exit=<CLI exit status>
ADT_RUN marker=<last marker line, or empty>
ADT_RUN output=<O> log=<O.log> seconds=<run time>
ADT_RUN code=<this script's exit code>
ADT_RUN sha=<output of `--hash O` when the run ended, or empty>
```

Exit codes:

| Code | Status | Meaning |
|---|---|---|
| 0 | `ok` | Finished, marker found |
| 2 | `usage` | Bad arguments; a relative path where an absolute one is required (not for `--init-config`); not a git repo; `O` or `O.log` not git-ignored; a missing guard path |
| 3 | `missing-runner` | CLI not on `PATH` |
| 4 | `timeout` | Stopped at the timeout |
| 5 | `failed` | CLI exit status not 0 |
| 6 | `no-marker` | Finished without a marker line |
| 13 | `conflicting-markers` | Finished with marker lines of different known markers (6.2 step 8) |
| 14 | `cancelled` | Stopped by `--cancel` (written into `O.status` of each run that `--cancel` stopped) |
| 10 | `running` | `--wait` only: not finished yet |
| 11 | `lost` | `--wait` only: the detached job ended without writing `O.status`, or its timeout watcher is stuck |
| 12 | `not-started` | The CLI never started: the `--detach` parent could not write `O.pid`, the wrapper could not write `O.clipid`, `O.cancel` existed, or `--wait` found no `O.pid` |

Order of checks after a run: `timeout`, then `failed`, then
`conflicting-markers`, then `no-marker`, then `ok`. `lost` comes only from `--wait`. (There is no code 7: the script
does not check the tree during a run. The orchestrator's round snapshot,
7.5, covers every reviewer at once.)

**Paths.** Every path that the orchestrator passes to the script is
absolute (built from PROJECT_ROOT). The script exits 2 when `--wait`,
`--output-file`, `--prompt-file`, `--command-file`, `--allow-read`,
`--project-root` or `--cancel` gets a relative path. (`--init-config` follows its own
rule in 4.1: a warning and exit 1, which never stops the caller.) `--guard-path` is
the one exception: it may be relative to `--project-root`. So a later `cd`
in the orchestrator's shell can never change which file a call uses.

### 6.2 Behavior

1. **`--check`:** find the CLI binary with `command -v` and exit 0 or 3. The
   binary is `claude`, `codex`, `agy` or `opencode` for those runners. For
   `runner: command`, `--check-program` is required and is the binary
   that is checked; the template's program word must equal it (6.4);
   `--command-file` is required too (exit 2 without either): before the
   binary check, the script checks the template with the rules of 6.4
   ("Template check") and exits 2 with a message that names the broken
   rule. A run with `--runner command` (which needs `--command-file` and `--check-program` too; exit 2 without either) does the same check before it
   starts anything. So the template rules are enforced by code, not only
   by the orchestrator's reading of rule 6.
2. **Validation and cleanup (only for a run: `--runner`, with or without
   `--detach`).** The script dispatches on the mode first. `--init-config`
   uses only the rules of 4.1. `--check`, `--wait` and `--snapshot` do none
   of this step: they never check `O.pid` for a live job and never delete a
   file. For a run: the rules in 6.1, then the following. Reject any
   relative path with exit 2 ("Paths", 6.1; the script never makes a
   relative path absolute itself, except `--guard-path`). Create the
   directory of `--output-file` with `mkdir -p` if it does not exist. Then
   `cd` to `--project-root`,
   which must exist. The CLI runs in the project root, so the relative
   paths in its prompt file (PLAN_PATH, `AGENTS.md`, `./gradlew`) resolve
   as they do for a native agent. `git -C <project root> rev-parse
   --is-inside-work-tree` must succeed, or exit 2. Check
   `git check-ignore -q` for `O` and `O.log`, and exit 2 if either is not
   ignored (the round snapshot would see them). If `O.pid` exists and its job is alive (identity test, 6.1),
   exit 2: another run uses this output file.
   Then delete any old `O`, `O.log`, `O.status`, `O.status.tmp`, `O.pid`,
   `O.pid.tmp`, `O.clipid`, `O.clipid.tmp`, `O.cancel`, `O.timedout` and
   `O.elapsed`, so a result from an earlier run can never be read as this
   run's result.
3. **Instruction.** The CLI gets one fixed sentence, never the prompt text:
   `Read the file <absolute prompt file> in full and follow its instructions exactly. It is your complete task for this run. No human will answer questions during this run.`
4. **`--allow-read <path>`:** for each path, take `adt_physical_path`
   (6.5); for a file, use the directory part of the result. For `claude`,
   add `--add-dir <dir>` for each. For `claude`, also add
   `--add-dir <git top-level>` when the git top-level is not the project
   root, so a reviewer can open files that the Coder changed outside the
   project root in a larger repository (the round snapshot covers the
   whole repository for tracked files, 6.2 step 5).
   Other runners ignore it. Reason: in `dontAsk` mode, Claude Code denies
   reads outside the working directory, and the persona files and the
   pipeline doc can be outside it (plugin cache, or symlink targets in the
   `install.sh` clone).
5. **Snapshot** (used only by `--snapshot`, step 11). The hash, with
   `git hash-object --stdin`, of these, each run as
   `GIT_OPTIONAL_LOCKS=0 git -C "<project root>" -c diff.relative=false -c core.quotePath=false ...`
   with the pathspecs given below (the variable keeps git from taking the
   optional index lock, so a concurrent git process such as Android
   Studio's background status does not make the snapshot fail).
   **Independent of the developer's git settings:** every `git diff` call
   also gets `--no-ext-diff --no-textconv` (no external diff tool, no text
   conversion of binary files), `-c diff.relative=false` keeps the diff
   from being limited to the current directory, and every
   `git hash-object` call gets `--no-filters` (the raw file content is
   hashed). So `diff.relative`, `diff.external` and textconv drivers in
   the developer's config never change what the snapshot sees. **Scope:** the two tracked parts cover
   the **whole repository** (pathspec `:/`, the repository root), because
   the Coder can change tracked files outside the project root in a larger
   repository and the reviewers review them. The untracked part covers
   the whole repository too, for the same reason (the Coder can create new
   files outside the project root). `<EXCLUDES>` are added to
   the pathspec of **all three** parts.
   They leave out folders that build tools and IDEs change in the
   background (Android Studio also rewrites **tracked** `.idea` files after
   a Gradle sync). All of them are dot-folders or daemon files, which can
   never be a Kotlin or Java package, so no source file is ever excluded:
   `':(top,exclude,glob)**/.gradle/**' ':(top,exclude,glob)**/.kotlin/**'
   ':(top,exclude,glob)**/.idea/**' ':(top,exclude,glob)**/.cxx/**'
   ':(top,exclude,glob)**/*.salive'`. The `top` magic makes each exclude
   relative to the repository root, so it also works for the whole-
   repository parts when the project root is a subdirectory (without
   `top`, git resolves the exclude against the current directory and a
   top-level `.idea/` would not be excluded).
   `build/` is **not** excluded, because a package can be named `build`.
   Gradle's `build/` output folders are git-ignored in normal Android
   projects; the README says to keep them ignored.
   (The Gradle and Kotlin daemons keep running after the build gate and can
   write there during the review; that must not stop the run.) First,
   the **position of HEAD**: the output of `git rev-parse -q --verify HEAD`
   and of `git symbolic-ref -q HEAD`. `git rev-parse -q --verify HEAD`
   exits 1 with no output when there are no commits yet, and
   `git symbolic-ref -q HEAD` exits 1 with no output when HEAD is
   detached; for these two commands, exit 1 means "empty" and is **not**
   a failure (only another exit status is). So a reviewer that checks out another branch or resets to
   another commit changes the snapshot even when the tree looks clean.
   Then the three parts, each with `-- :/ <EXCLUDES>`:
   `git diff HEAD --binary` (only when `git rev-parse --verify -q HEAD`
   succeeds; in a repository with no commits yet, use
   `git diff --binary` instead; this choice is made **before** running the
   diff, so a new repository is not a failure), `git diff --cached
   --binary`, and the path and content hash
   of each file from `git ls-files -o --exclude-standard -z --full-name`
   (untracked files; `--full-name` makes every path relative to the top of
   the repository, `TOP` = `git rev-parse --show-toplevel`); plus the content hashes for each `--guard-path` (next paragraph).
   Hash many files with **one** process: `git hash-object --no-filters
   --stdin-paths` (one hash per input line, same order)
   instead of one call per file. `ls-files -z` separates paths with NUL,
   but `--stdin-paths` reads one path per line, so: read the NUL list in
   bash with `while IFS= read -r -d '' f`. For an entry that ends with
   `/` (an untracked nested git repository, which `ls-files -o` lists as a
   directory), add the line `nested-repo <path>` without a content hash
   (its inner files are not the Coder's changes to this repository). For a
   **symlink** (`[ -L ]`,
   also a broken one or one to a directory), hash the link text
   (`readlink "$TOP/$f"` into `git hash-object --stdin`), never its
   target. For
   a regular file, send the path to the batch call, one per line; hash a
   path that contains a newline on its own with
   `git hash-object --no-filters -- "$TOP/$f"`. The `[ -L ]` and `[ -f ]`
   tests also use `"$TOP/$f"`.
   Every listed path is in the snapshot with some hash; nothing is
   dropped. **Every path given to `hash-object` is absolute**: `TOP/` plus
   the `--full-name` path. (`git hash-object --stdin-paths` reads relative
   paths from the top of the repository, not from the `-C` directory, so a
   relative path would fail when the project root is a subdirectory.) The
   snapshot records the `--full-name` path text. Guard-path files are
   passed as absolute paths too.
   **Failures:** check the exit status of every git command. If any fails
   (for example the project root is not a git work tree, an `index.lock`
   conflict, or a file that vanished between listing and hashing), wait 1
   second and compute the whole snapshot once more. If it fails again,
   print the failing command and exit 2. A snapshot never prints a hash
   that is based on failed or partial output.

   **`--guard-path <path>`** (repeatable) adds git-ignored files to the
   snapshot, because the git commands above do not see ignored files and the
   plan and design doc live in git-ignored `pipeline_artifacts/`. For a file:
   its path and content hash. For a directory: the same for every regular
   file **and symlink** under it (a symlink is hashed by its link text, as
   in the untracked part), listed with
   `find <dir> \( -type f -o -type l \) -print0`, sorted with
   `LC_ALL=C sort -z`, and read with `while IFS= read -r -d '' f`, using
   the same rules as the untracked part (batch call for normal names; a
   name with a newline hashed on its own; one `--stdin-paths` call per
   guard directory).
   No file is excluded. The run directory `pipeline_artifacts/.runs/` is
   never under `pipeline_artifacts/<slug>`: a slug is lowercase and
   hyphen-separated (Part A, "Artifact Layout"), so it can never be `.runs`.
   The orchestrator's own run files are therefore never inside a guarded
   path. A guard path that does not exist: exit 2. The `<EXCLUDES>` above do
   not apply to guard paths.
   Known limit: a background process that writes another untracked,
   not-ignored file in the project during a review still stops the run. The
   stop report names the file; the fix is to add it to `.gitignore`.
6. **Timeout:** start the CLI (through the wrapper of step 9) with `set -m`,
   so it has its own process group, and run `set +m` **directly after** the
   CLI start, before the watcher starts. So the watcher stays in the job's
   process group, and the lost path's signal to the job's group also stops
   the watcher. A watcher subshell counts **awake seconds**: it loops `sleep 1`, adds 1
   to a counter, and writes the counter to `O.elapsed` (through a temp file
   and `mv`) every 5 seconds. `sleep` does not advance while the computer
   sleeps, so a laptop sleep does not count. When the counter reaches the
   timeout it writes `O.timedout`, sends `TERM` to the CLI's process group,
   waits 5 seconds, then sends `KILL`. The watcher stops by itself when the
   CLI ends (loop on `kill -0`), so no `sleep` process stays behind. The
   "timeout" result of a run means `O.timedout` exists.
   **After a read-only run's CLI ends** (a reviewer), the job stops what
   is left of the CLI's process group before it writes `O.status`: if the
   group still exists ("Signalling a process group", 6.1), `TERM`, up to 5
   seconds, then `KILL`. A reviewer that leaves a child process behind
   therefore cannot change the tree after its result is written. **A write
   run** (architect, coder, tester) is not cleaned up this way: it may
   legitimately leave helpers running, such as the Gradle and Kotlin
   daemons or the adb server, exactly as a native Coder does today.
7. **stdin** of the CLI is `/dev/null`.
8. **Marker:** only these eight **known markers** count:
   `✅ ARCHITECT DONE`, `✅ CODER DONE`, `✅ TESTER DONE`,
   `⛔ TESTER BLOCKED`, `✅ PLAN APPROVED`, `🔧 PLAN CHANGES REQUESTED`,
   `✅ CODE APPROVED`, `🔧 CODE CHANGES REQUESTED`.
   Before matching, remove every U+FE0F character (the invisible emoji
   variation selector, as in `⛔️`) from the line.
   A **marker line** starts in the first column: a line that begins with
   a space or tab (for example an indented continuation line of a
   numbered list) is never a marker line. Otherwise it is a marker line
   when, after these are removed from its start, in this order, it
   **starts with** a known marker:
   1. if present, `#` characters and spaces (a heading);
   2. if present, one `**` or `__` (bold);
   3. if present, the label `Verdict:` (any casing), then, if present, one
      `**` or `__` (the end of a bold label), then spaces, then, if
      present, one `**` or `__` (a bold marker after the label).
   All three are optional. So a plain `✅ CODE APPROVED` line (with a
   summary after it), `## ✅ CODE APPROVED`, `**✅ CODE APPROVED**`,
   `Verdict: ✅ CODE APPROVED`, `**Verdict:** ✅ CODE APPROVED` and
   `Verdict: **✅ CODE APPROVED**` are all marker lines. A single `*`, `-` or
   `+` followed by a space is a list bullet, not bold, so a bulleted line
   is never a marker line. A
   line that starts with `>`, a backtick, or any other character is never
   a marker line, so a quoted or code-formatted marker inside a findings
   list does not count. Lines that start with an emoji but not with a
   known marker (for example `✅ Item 1 is fixed`) are ignored.
   The marker of an answer: if every marker line starts with the **same**
   known marker, that marker (the last such line is reported). If marker
   lines with **different** known markers appear, the answer has no valid
   marker: the result is `conflicting-markers` (code 13), and `O.log`
   lists the lines. This is never guessed. The marker line can carry more text after the marker (for
   example `✅ CODE APPROVED` followed by a one-line summary), and other
   lines can follow it (a CHANGES REQUESTED marker is followed by its
   numbered list, as the reviewer personas require).
   **Everywhere in this plan, "the marker is X" means this rule found a
   line that starts with X.** The orchestrator applies the same rule to
   native answers.
9. **`--detach`:** do all validation and the cleanup of step 2 first (usage
   errors come back at once). Then start the same script again without
   `--detach` and with an internal flag (`--child`) that tells it to skip the
   cleanup and the live-`O.pid` check of step 2 (its own pid is in `O.pid`),
   as
   these lines in the script's own shell (no subshell, so `JOB` stays
   known):

   ```bash
   set -m
   nohup bash "$SELF" --child "${ARGS[@]}" </dev/null >/dev/null 2>&1 &
   # ARGS holds the original arguments with --detach removed (so the
   # child runs the job and never detaches again). Step 2 already rejected
   # every relative path, so the job does not depend on its working
   # directory.
   JOB=$!
   set +m
   if ! { [ -z "${ADT_RUN_TEST_FAIL_PID_WRITE:-}" ] &&
          { echo "$JOB $TIMEOUT_SECONDS"; adt_proc_identity "$JOB"; } > "$O.pid.tmp" &&
          mv "$O.pid.tmp" "$O.pid"; }; then
     # stop the job group, write O.status with code 12, exit 12 (below)
   fi
   ```

   `ADT_RUN_TEST_FAIL_PID_WRITE` is a test hook only (test 12.1 case 18).
   `O.pid` therefore exists before `--detach` returns, and only this parent
   writes it (the job never writes it). Two `--detach` calls on the **same**
   `O` at the same moment are not supported: the unique file names of 7.2
   step 1 prevent them, and the live-`O.pid` check of step 2 only protects
   against a later call while a job still runs. **The parent checks the result:** if writing or
   moving `O.pid` failed, it stops the job's process group (`TERM`, then
   `KILL`), writes `O.status` with `status=not-started`, `exit=-` and
   `code=12`, prints it, and exits 12. **The job waits for `O.pid` before it
   does anything else** (poll every 0.2 s, up to 30 s), then checks that the
   first field of the first line of `O.pid` equals its own pid (`$$`), and
   writes `O.elapsed` with the value `0` (so `--wait` can see progress from
   the start, 6.2 step 10.4). If `O.pid` never
   appears, or holds another pid (another `--detach` owns `O`), the job
   exits at once without writing any file. Otherwise the parent prints
   `ADT_RUN status=started output=<O>` and exits 0. The job has its own
   process group, so a tool that stops its shell command does not stop the
   run.

   **How the job starts the CLI (detached and normal runs).** The CLI must
   record its pid **before** the CLI program runs, so that a lost job can
   never leave an unknown CLI behind. Start it under `set -m` through this
   wrapper (it becomes the CLI through `exec`, so the pid stays the same):

   `bash -c '{ echo $$; bash "$2" --identity $$; } > "$1.clipid.tmp" && mv "$1.clipid.tmp" "$1.clipid" || exit 97; [ -e "$1.cancel" ] && exit 98; shift 2; exec "$@"' _ "$O" "$SELF" <CLI command>`

   `$SELF` is the absolute path of this script. `--identity <pid>` is an
   internal mode that prints `adt_proc_identity <pid>` and exits 0, so the
   wrapper and `--wait` use the **same** identity function. `$$` in the
   wrapper is the pid that the CLI keeps after `exec`.

   **Wrapper exit codes 97 and 98 are not CLI failures.** When the CLI
   command ends with 97 and `O.clipid` does not exist (it could not be
   written), or with 98 and `O.cancel` exists, the job writes
   `status=not-started`, `exit=-`, `code=12` (not `failed`).

   The order is: write `O.clipid`, then check `O.cancel`, then `exec`. The
   job uses the wrapper's pid (`$!`) for its own timeout watcher (step 6).
10. **`--wait O...`:** takes one or more output files. It polls in a
    loop of `sleep 1`, up to `--max-seconds` loop iterations (default 60,
    maximum 300). The 30-second window of step 4 counts **loop
    iterations** (awake seconds), never wall-clock time, so a laptop sleep
    never makes a healthy job look stuck. The call itself also ends (with
    blocks as described below) when `--max-seconds` of wall-clock time
    have passed since it started, even if fewer iterations ran; the clock
    is used only to **end the call early**, never to declare a job lost.
    So a call never runs longer than `--max-seconds` plus the lost
    handling (about 10 seconds), and the tool's shell timeout (7.2 step 4)
    always has room. It applies
    the steps below to **each** file that has no result yet; it returns as
    soon as every file has a result, or when `--max-seconds` passes. It
    prints one block per file (the five `ADT_RUN` lines, or
    `ADT_RUN status=running output=<O>`), in the order given. Exit code:
    10 if any file is still running, else 0; the result of each run is the
    `code` line in its block. With a single file, the exit code is that
    run's `code` (as before). **Lost handling of several files happens
    together:** first create every `O.cancel`, then send `TERM` to every
    job group that may be signalled, wait up to 5 seconds once for all of
    them, send `KILL` to those still there, then do the same for all CLI
    groups, then write every `O.status`. So it takes about 10 seconds for
    any number of files. The steps for one file decide that file's
    **result**; they never end the call by themselves. "Result X" means:
    that file is done, and its block is the content of `O.status` (or the
    block described). The call ends only as described above.
    1. If `O.status` exists: result = its content.
    2. If `O.pid` does not exist: result = the block
       `ADT_RUN status=not-started output=<O>` with `ADT_RUN code=12`, and
       the line `ADT_RUN note=no O.pid: the run never started (the
       --detach call may have been stopped before it wrote O.pid, or the
       path is wrong)`.
    3. If the job is not alive (identity test): read `O.status` once more (the job can
       finish between two checks). Still missing: the job died (for example
       `SIGKILL`, a crash, or a reboot). Go to step 5.
    4. **Stuck watcher.** Wall-clock time is never used here (a laptop
       sleep or a clock change must not stop a healthy run). Instead: if
       the job is alive and either the value in `O.elapsed` has not
       changed during 30 seconds of this `--wait` call, or it is greater
       than the `<timeout seconds>` stored in `O.pid` plus 120 (the
       watcher counted past the timeout but the CLI did not end, for
       example a process stuck in an uninterruptible device call), the job
       is stuck. A missing
       `O.elapsed` counts as a value that does not change. (The job writes
       `0` as soon as it owns `O.pid`, and its watcher updates it every 5
       seconds, so a healthy job always makes progress; a job that hangs
       before it starts the CLI stays at `0` and is caught here too.) Go to
       step 5.
       (For this check `--wait` must poll at least 30 seconds; the
       orchestrator's 60 is enough. A shorter call skips this check.)
    5. **Lost:** stop everything the run started, then decide:
       1. Create `O.cancel`.
       2. If the job's group may be signalled ("Signalling a process
          group", 6.1): send `TERM` to it, wait up to 5 seconds (check every
          0.5 s, stop waiting when it may no longer be signalled), then send
          `KILL` if it still may be. Otherwise send nothing and do not wait.
       3. Now read `O.clipid`. If it exists, do the same for the CLI's
          group.
          Why this is complete: the wrapper writes `O.clipid` before it
          checks `O.cancel`. If it checked before step 1, `O.clipid` already
          exists at step 3 and the CLI is stopped. If it checks after step
          1, it sees `O.cancel` and exits without starting the CLI. A job
          that hangs before it starts the wrapper is stopped in step 2.
       4. If `O.status` exists now (the job finished just before it was
          stopped): result = its content.
       5. Otherwise write `O.status` with `status=lost` and `code=11`;
          result = that content.
    A file with no result when `--max-seconds` passes gets the block
    `ADT_RUN status=running output=<O>`. Keep each call short so
    it fits every tool's shell timeout.
11. **`--snapshot`:** runs every git command of step 5 with
    `git -C "<project root>"`, and uses only absolute paths for files
    (`TOP/` plus the `--full-name` path for untracked files, absolute guard
    paths), exactly as step 5 says. So nothing depends on the caller's
    current directory, also when the project root is a subdirectory of the
    repository. Then print the snapshot
    hash of step 5 (with the given `--guard-path` values, made absolute
    against `--project-root`) and exit 0. A guard path that does not exist, or any failure of step 5: exit 2
    (never hash nothing and pass). The orchestrator treats any non-zero
    exit of `--snapshot` as a STOP of the run (7.5).
    It never checks `O.pid` and never deletes a file. The orchestrator uses
    it around a
    whole review round (7.5), which also covers native reviewers that the
    script does not run.
12. **`--cancel <run dir>`:** for every `O.pid` under `<run dir>/jobs/`
    whose run has no `O.status` yet, do the lost-path stop of step 10.5
    (all runs together) and write `O.status` with `status=cancelled` and
    `code=14`. Print one line per stopped run. Exit 0. It never touches a
    run that already has a result.

### 6.3 Command line for each runner

`I` is the instruction sentence. `M` is `--model`. `T` is the timeout in
seconds.

| Runner | read-only | write |
|---|---|---|
| `claude` | `env -u CLAUDECODE claude -p I --output-format text --permission-mode dontAsk --allowedTools "Read,Glob,Grep,Skill,Bash(git status:*),Bash(git diff:*),Bash(git ls-files:*),Bash(git log:*),Bash(git show:*)" --disallowedTools "Bash(*--output*)" [--model M] [--add-dir D]...` ; stdout → `O` | same start, with `--permission-mode acceptEdits --allowedTools "Read,Write,Edit,Glob,Grep,Skill,Bash,mcp__auto-mobile"` |
| `codex` | `codex exec --sandbox read-only --output-last-message O [--model M] I` ; stdout → `O.log` | `--sandbox workspace-write` |
| `agy` | `agy -p I --output-format text --print-timeout <ceil(T/60) + 5>m --dangerously-skip-permissions --sandbox [--model M]` ; stdout → `O` | same, without `--sandbox` |
| `opencode` | `opencode run --auto [--model M] I` ; stdout → `O` | same |
| `command` | the argument list built from the template (6.4), started directly, no shell | same |

Notes:

- `env -u CLAUDECODE`: a child `claude` started inside a Claude Code session
  must start as its own session.
- `--disallowedTools "Bash(*--output*)"`: `git diff`, `git log` and
  `git show` accept `--output=<file>`, which writes a file. The deny rule
  blocks every allowed git command that carries that option, so the
  read-only `claude` reviewer cannot write through them.
- `agy` has its own print timeout (default 5 minutes). It is set 5
  minutes longer than the script's timeout, so the script's own timeout
  (which counts only awake seconds) always ends a run first and reports it
  as `timeout`. A laptop sleep can still make `agy` stop first; the script
  then reports what `agy` returned (`failed` or `no-marker`).
- `agy` and `opencode` have no strict read-only mode. The tree guard (6.2
  step 5) is the protection for them.
- stderr of every runner goes to `O.log`.

### 6.4 `command` template

Placeholders: `{instruction}`, `{prompt_file}`, `{output_file}`, `{model}`.

**No shell runs the template.** The script turns the template into an
argument list itself and starts the program directly (through the CLI
wrapper of 6.2 step 9, whose `exec "$@"` runs it). So a placeholder value
is never parsed by any shell: it cannot be split into words, expanded, or
run as a command, whatever it contains (spaces, quotes, `$`, `&`, `*`,
`;`).

How the script builds the argument list, in this order:
1. **Split into words** on spaces and tabs that are **outside** double
   quotes. A double-quoted part groups text (spaces included) into the
   word, and the quote characters are removed. There is no other quoting
   or escaping (the Template check rejects `'` and `\`).
2. **Assignments.** Leading words of the form `NAME=value` (`NAME` matches
   `[A-Za-z_][A-Za-z0-9_]*`) become environment variables for the program;
   the first other word is the **program word**, the rest are its
   arguments. The Template check rejects assignments that change which
   code runs: `PATH`, `BASH_ENV`, `ENV`, `IFS`, and every name that starts
   with `LD_` or `DYLD_`.
3. **Placeholders.** In every word (and assignment value), replace each
   placeholder with its value by plain text replacement. This happens
   after step 1, so a value can never create or split words. Example:
   `gemini -p "Task: {instruction}" -m {model}` gives the argument list
   `gemini`, `-p`, `Task: Read the file ...`, `-m`, `<model>`.
4. **Start** the program with the arguments, with the assignments in its
   environment. The script first resolves the program word to an absolute
   path with `command -v` in its **own** environment (the same lookup that
   preflight did), and starts that absolute path, so an assignment can
   never make a different program run. The CLI command given to the
   wrapper is `env NAME=value ... <absolute program> <arguments>` (each
   element one array item; `env` is used only to set the variables, and
   without assignments the absolute program comes first). When the template has no `{output_file}`, stdout goes
   to `O`; otherwise stdout goes to `O.log`.

In bash 3.2 the script builds the list with a character loop over the
template (no `eval`, no `read -a` on unquoted text), into an array.

**Limit, stated in the README:** the script cannot know what the program
does with its arguments. A program that runs an argument as code (a shell
with `-c`, `python3 -c`, `node -e`, `ssh host`) would run the value. The
check below rejects the shell case; the developer is responsible for not
passing a placeholder to any other program that executes it.

**Template check** (done by the script, 6.2 step 1, and also by the
orchestrator as validation rule 6; this list is the one definition). The
template is rejected when:
- it contains `'`, `\`, a backtick, `$`, a newline or carriage return, or
  any of `|`, `;`, `&`, `<`, `>`. No shell runs the template, so this
  syntax would not work as a developer expects (a pipe would be passed as
  a literal argument, `$HOME` would not expand); rejecting it gives a clear
  message instead;
- its double quotes are not balanced (an odd number of `"`);
- it has neither `{instruction}` nor `{prompt_file}`;
- it uses `{model}` and `--model` (the slot's `model`) is missing;
- an assignment to `PATH`, `BASH_ENV`, `ENV`, `IFS`, or a name that starts
  with `LD_` or `DYLD_` (step 2);
- the **program word** (the first word after the `NAME=value`
  assignments, 6.4 step 2) is not exactly the slot's `check` value. So the
  program that runs is always the one that preflight checked, and **no
  wrapper can run in front of it** (`env`, `timeout`, `nohup`, `sudo`,
  `script`, `watch`, `flock`, `xargs`, and so on): a wrapper could start a
  shell or another program that no check sees. To set an environment
  variable, write `NAME=value` in front of the program word (step 2
  handles it without any wrapper); for a time limit, use `timeout_minutes`;
- the basename of the program word (the part after the last `/`) is a
  shell or a program that runs its arguments as commands: `sh`, `bash`,
  `rbash`, `zsh`, `dash`, `ksh`, `mksh`, `ash`, `fish`, `csh`, `tcsh`,
  `pwsh`, `powershell`, `busybox`, `env`, `sudo`, `su`, `ssh`. (This also
  makes the same `check` value a config error, rule 6.)

What remains is the limit stated above: the checked program itself
decides what it does with its arguments.

### 6.5 Path helper

The script has one function, `adt_physical_path <path>`, used by
`--init-config` (4.1 step 2) and `--allow-read` (6.2 step 4). It follows
file symlinks with a `readlink` loop (a relative target is relative to the
link's directory; at most 40 links, then it fails, so a symlink cycle
cannot hang the script: `--init-config` then warns and exits 1, the other
modes exit 2), then prints
`$(cd -P "$(dirname "$p")" && pwd -P)/$(basename "$p")`. For a directory
argument it prints `$(cd -P "$p" && pwd -P)`.

Why `cd -P`: a plain `cd dir/..` removes `dir/..` as text before any
symlink is resolved, so a later `pwd -P` is too late. In an `install.sh`
project the script is reached as `<clone>/.claude/scripts/adt-run-agent.sh`,
a regular file behind the directory symlink
`<clone>/.claude/scripts -> ../plugins/agentic-dev-team/scripts`. Only a
physical path gives `<clone>/plugins/agentic-dev-team/scripts`, next to the
template. `install.sh` keeps its own
`abs_readlink` unchanged. This is a known, accepted duplication of the
readlink loop: sharing code between `install.sh` and the plugin script
would need `install.sh` to source a file from the plugin, and `abs_readlink`
has its own rules for broken symlinks. (It is out of scope: it compares symlink targets that
are built the same way on both sides).

---

## 7. Configured runs of `/build-auto-reviewed` (`RUNS`)

All rules in this section apply only when `RUNS` is on.

### 7.1 Start

0. If ADT_ROOT is empty, STOP: the configured run needs the scripts.
   Report that the agentic-dev-team install is incomplete.
1. Run directory: `PROJECT_ROOT/pipeline_artifacts/.runs/<run id>/`
   (always used as an absolute path). `<run id>` is the UTC timestamp from
   `date -u +%Y%m%dT%H%M%SZ`, a `-`, and 6 random lowercase letters or
   digits, so two runs started in the same second get different
   directories. If the directory already exists, choose new random
   characters. Before you create it: create
   `PROJECT_ROOT/pipeline_artifacts/` with `mkdir -p` (in Phase 1 it may not
   exist yet, because the Architect normally creates it), then create
   `PROJECT_ROOT/pipeline_artifacts/.gitignore` with the single line `*` if
   it does not exist. Only then create the run directory.
2. Resolve paths (same rule as PIPELINE_DOC today):
   - RUNNER: `ADT_ROOT/scripts/adt-run-agent.sh`.
   - Persona of each agent: `ADT_ROOT/agents/<agent file>`.
   - PIPELINE_DOC_ABS: PIPELINE_DOC as an absolute path. The command text
     stores PIPELINE_DOC as `.claude/AGENTIC_DEV_TEAM_PIPELINE.md` (relative)
     in an `install.sh` project, so prefix it with `PROJECT_ROOT/` when it
     does not start with `/`. Use PIPELINE_DOC_ABS in every script call
     (`--allow-read`) and in the prompt file (7.3); native subagents keep
     getting PIPELINE_DOC as today.
   ADT_ROOT is absolute (9.1), so these paths are absolute.
   **Quoting:** in every shell command of this section, put each path
   (RUNNER, PROJECT_ROOT, O, P, and the others) in double quotes; paths can
   contain spaces.
3. Preflight.
   1. For each `runner: command` slot, write its command file first:
      `<run dir>/command-<slot>.txt`, where `<slot>` is `architect`,
      `coder`, `tester`, `architect_reviewer-<i>` or `code_reviewer-<i>`
      (`<i>` is the 1-based position of the entry in that `reviewers`
      list). One file per slot, never shared. It holds the **parsed string
      value** of `command` (the YAML string after parsing: no surrounding
      YAML quotes, no escapes), followed by one newline. `--command-file`
      avoids every shell-quoting problem.
   2. Run `bash "RUNNER" --check <runner>` once for each distinct runner
      among `claude`, `codex`, `agy` and `opencode` in the config.
   3. For each `runner: command` slot, run
      `bash "RUNNER" --check command --check-program <check> --command-file "<its command file>" [--model M]`
      (with `--model` when the slot has `model`). This checks the template
      (6.4, including that its program word is `<check>`) and the
      program. `<check>` is safe unquoted (rule 6).
   4. Exit 3 means the CLI is missing (the rules below). Exit 2 from a
      `command` check means the template is invalid: STOP before Phase 1
      and show the script's message. Any other non-zero exit is a bug in
      the orchestrator's call: STOP and report the command and its output.
   5. A missing CLI in a producer slot (`architect`, `coder`, `tester`) or
      in a required reviewer: stop before Phase 1, name the CLI. A missing
      CLI in an optional reviewer: remove that reviewer, and report it in
      the summary.
4. **Effective reviewer lists.** After the removals of step 3, fix each
   gate's reviewer list for the whole run: the configured list minus the
   removed reviewers, or one native reviewer when the role is not configured.
   If a configured gate's list is now empty: STOP before Phase 1 and report
   `<gate> has no available reviewer` (never fall back to the default
   reviewer; the developer configured this gate). The case of each gate
   (7.5, A, B or C) is chosen from its effective list here, one time, and
   does not change during the run. If the removals leave a single
   reviewer, that reviewer is required from now on (Case A or B), and the
   summary says so.

### 7.2 Starting an external agent

1. **File names are unique for each start.** Name the pair
   `<run dir>/jobs/<phase>-<role>[-s<section>]-a<attempt>.prompt.md` and
   `...-a<attempt>.out.md`. `<phase>` is `1`, `1R`, `2`, `2R`, `3`, `3B` or
   `3F<iteration>`; `-s<section>` is for parallel coders; `<attempt>` starts
   at 1 and goes up by one each time the same phase starts the same role
   again (a bounce, a fix run, a cross-section re-spawn, a resume). A file
   name is never used twice in one run. (The script also deletes old files
   of the same name, 6.2 step 2, as a second protection.)
   **All runner files live in `<run dir>/jobs/`**, never in a round
   directory. An external reviewer uses
   `O = <run dir>/jobs/<gate>-r<N>-<letter>.out.md` and
   `<run dir>/jobs/<gate>-r<N>-<letter>.prompt.md` (unique because the gate,
   round and letter are in the name); its `.log`, `.status`, `.pid` and
   other runner files are next to `O` in `jobs/`. When the run is
   complete, the orchestrator copies `O` to the round directory with
   `cp "O" "<run dir>/<gate>-r<N>/reviewer-<letter>.md"` (a byte copy in
   the shell; never through a read-and-write of the text) and the hash to
   compare is the `sha` line of `O.status` (7.5 step 6). So a round directory holds only reviewer answers,
   `judge.md` and `panel-map.md`, and nothing in it shows which tool wrote
   which answer.
2. Create the directory of the prompt file with `mkdir -p` (always
   `<run dir>/jobs/`), then write the prompt file
   (7.3). (A Case A reviewer is native and has no prompt file; see 7.5.)
3. Start it detached:
   `bash "RUNNER" --runner R --access A --project-root "PROJECT_ROOT" --prompt-file "P" --output-file "O" [--model M] --timeout-minutes N [--command-file "<run dir>/command-<slot>.txt" --check-program <check>] --allow-read "<persona path>" --allow-read "PIPELINE_DOC_ABS" --detach`
   **Check the result of this call before any `--wait`.** `--detach`
   prints `ADT_RUN status=started` and exits 0 when the job started. Any
   other exit (2 for a setup error such as a relative path, a project that
   is not a git repository, or output files that are not git-ignored; 12
   when `O.pid` could not be written) is a STOP of the run for a producer
   or a required reviewer (for an optional reviewer: drop it, as a failed
   reviewer), and the report shows the script's own output. Never call
   `--wait` for a job whose `--detach` did not exit 0.
   The orchestrator **always** passes `--timeout-minutes`: the slot's
   `timeout_minutes`, else the role default of 3.2 (30 for a reviewer, 120
   for `architect`, `coder`, `tester`). The script's own fallback when the
   flag is missing (30) is only for manual use.
   All paths absolute ("Paths", 6.1): the run dir is
   `PROJECT_ROOT/pipeline_artifacts/.runs/<run id>/` (7.1 step 1).
4. Wait with `bash "RUNNER" --wait "O" --max-seconds <W>` (`O` absolute).
   `<W>` is the longest wait that fits the tool's shell timeout: in Claude
   Code use `--max-seconds 240` and set the Bash tool's timeout to 330000
   ms (the 90 seconds between them leave room for the lost handling, which
   takes about 10 seconds for any number of files, 6.2 step 10); in a
   tool whose shell timeout is unknown or short, use 60 (the minimum for
   the stuck-job check of 6.2 step 10.4 is 30).
   **Repeat the `--wait` call until its exit code is not 10.** The
   stuck-job rules of 6.2 step 10.4 guarantee that this ends. For several
   jobs started together, pass all their output files to **one** `--wait`
   call and read each run's `code` from its block.
5. Access: `read-only` for reviewers, `write` for architect, coder, tester.
6. **Result of a producer** (architect, coder, tester), from the script code
   and marker:

   | Script result | Marker | Action |
   |---|---|---|
   | code 0 | `✅ ARCHITECT DONE` / `✅ CODER DONE` / `✅ TESTER DONE` | Continue as the command file says for that marker. |
   | code 0 | `⛔ TESTER BLOCKED` (tester only) | The Blocked Path, Phase 3B, exactly as for a native Tester. Not a failure. |
   | code 0 | any other marker | STOP: report role, runner, marker, output path. |
   | code 6 (`no-marker`) | none | The agent stopped without a marker. A native agent does this for its own STOP conditions, so relay the output file's text to the user as that agent's STOP report, and STOP the run. |
   | code 13 (`conflicting-markers`) | several | The verdict is ambiguous. STOP: report role, runner, the conflicting lines from `O.log`, and the output path. This is not the agent's own STOP. |
   | code 2, 3, 4, 5, 11, 12 | any | STOP: report role, runner, status, and the log path. |
   | code 14 (`cancelled`) | any | The run was stopped with `--cancel`. STOP: report the role and that its change may be incomplete. Never continue with its result. |

   Never retry, and never fall back to native.

Parallel runs (several coders in one group, several reviewers in a panel):
start all detached jobs first, then wait for all of them with one repeated
`--wait` call that lists every output file.

### 7.3 Prompt file template (exact)

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

Use only the access block that applies. **Never put `TEST CREDENTIALS`, or
any credential value, in a prompt file** (7.6). Two mechanical rules make
sure of it:
1. Text that comes from a Tester (findings, recommendations) is copied into
   a prompt file **only from `test-results.md`**, never from the Tester's
   chat answer. Part A already forbids credential values in
   `test-results.md`.
2. **No text from a human reply** (a `resume` reply included) is ever
   copied into a prompt file.
Why no redaction step is needed: prompt files are written to the same
git-ignored `pipeline_artifacts/` directory that already holds
`test-results.md`, so copying from `test-results.md` adds no new place where
a secret could be stored. The guarantee is Part A's rule that no credential
value is written to `test-results.md` (the Tester persona already enforces
it), plus the native-Tester rule of 7.6. A text-matching redaction was
considered and rejected: it cannot tell a PIN from a path or a word, so it
both corrupts prompts and misses letters-only secrets.

### 7.4 Blocks given to reviewers

**`BUILD GATE OUTPUT`**: given to every code reviewer in a Case B or Case
C code gate, after the build gate ran (passed or failed):

```
## BUILD GATE OUTPUT
The orchestrator ran the build gate from the plan's Section 0:
Command: <command>
Exit status: <n>
<last 200 lines of output>
```

**`EARLIER CONFIRMED FINDINGS`**: given to every reviewer in a Case B or
Case C gate (plan or code) whenever the list below is not empty: from
round 2 of the gate, and in every Phase 3F targeted gate.

The list holds every numbered item that the producing agent was told to fix
earlier in this run for this artifact, in order, with where it came from:
1. each earlier round's feedback in this gate: when the build gate failed
   in that round, its item as one line only, `Build gate failed: <command>
   exited <n>` (never the Gradle output: it is stale once the Coder fixed
   it); then the judge's Confirmed list (Case C) or the single reviewer's
   numbered **blocking** items (Case B; never the items under its
   "Nits / optional" sub-heading, which were not required fixes);
2. for a code gate in Phase 3F: also every item from Phase 2R and from the
   earlier Phase 3F iterations that came from a **reviewer, the judge, or a
   build gate**.
The Tester's findings are **never** in this block. A targeted re-review
already gets them as "the fix instructions the Coder worked from", and the
code reviewer's persona must stay free to flag a Tester-driven fix as plan
drift. Only review-driven items are declared in scope.

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

The judge gets the same block (7.5 step 6) and uses it for its REJECTED
rule (8.1).

For a native reviewer, the orchestrator adds the same blocks to the
subagent prompt.

### 7.5 Review gates with `RUNS` on

A gate uses its effective reviewer list (7.1 step 4), and the case chosen
there. **Marker matching:** in this section, "the marker is X" or "X
marker" means the marker line starts with X (6.2 step 8), for native and
external answers alike. `✅ CODE APPROVED` followed by a summary is an
APPROVED marker.

**Build gate first (Case B and Case C, code gates only).** Before the
reviewers start, the orchestrator runs the build gate from the plan's
Section 0 one time (in Phase 3F targeted re-reviews too), and keeps the
command, exit status and output. The reviewers run in either case, as a
single reviewer does today (it reports a build failure and its code
findings in the same round). **If the exit status is not 0**, the round
result is always `🔧 CODE CHANGES REQUESTED`, whatever the reviewers and the
judge say, and the orchestrator puts this item **first** in the numbered
feedback: `Build gate failed: <command> exited <n>. Fix the failures in
this output: <last 200 lines>.` The other items follow (the judge's
Confirmed list, or the single reviewer's list); when every reviewer
approved, the build item is the only one. The round counts once against
the gate's budget, as today. A failed build can therefore never pass a
gate.

**Tree guard for the whole round (Case B and Case C).** Order within a
round: (1) the build gate (code gates), (2) the first snapshot, (3) the
reviewers, (4) the judge when it runs, (5) the second snapshot. The first
snapshot is taken **after** the build gate, so files that Gradle creates or
changes are never counted as a reviewer's change. Command:
`bash "RUNNER" --snapshot --project-root "PROJECT_ROOT" --guard-path pipeline_artifacts/<slug>`. If the two hashes
differ: **STOP the run** (also when either `--snapshot` call exits non-zero),
whether
the reviewer was required or optional. Report the gate, the round, the
reviewers that ran in that round, and the output of `git status --short`.
Do not revert anything; the developer decides. Reviewers are read-only, so
any change means the tree is no longer the one that was reviewed.

**Every STOP stops the external jobs.** On every exit path of a configured
run (a STOP of any kind, the end of the run, or a failed gate), the
orchestrator first runs `bash "RUNNER" --cancel "<run dir>"`, so no
detached external agent keeps working on the tree after the run ended. The
STOP report and the final summary always include this line, so the
developer can do the same after an interruption the orchestrator could not
handle (for example Esc): `To stop any external agent that is still
running: bash "<RUNNER>" --cancel "<run dir>"`.

**Case A: the effective list is exactly one native reviewer.** This is
**today's gate**, unchanged: the native reviewer runs the build gate
itself, there is no orchestrator build gate, no tree guard, no extra
blocks, and no judge. The only differences are the model resolution of
3.4 and that the orchestrator writes the reviewer's final answer to
`<run dir>/<gate>-r<N>/reviewer-A.md` (creating the directory first) for
the developer. A gate that the developer did not configure is always
Case A, so configuring something else (for example an external Tester)
never changes how the review gates behave.

**Case B: the effective list is exactly one external reviewer.** For a
code gate, build gate first (above), then that reviewer gets `BUILD GATE OUTPUT`. Its own marker
is the verdict. No judge. A failure of this reviewer (script code not 0)
stops the run, whether it is marked required or not, because the gate has
no other reviewer. A code 0 result whose marker is not this gate's APPROVED
or CHANGES REQUESTED marker also stops the run (report the marker and the
output path).

**Case C: 2 to 5 reviewers (a panel).** One round:

1. Code gates only: build gate first (above). The rest of this list runs
   whether it passed or failed.
2. Create the round directory `<run dir>/<gate>-r<N>/` with `mkdir -p`
   (step 3 names the files in it). It holds **only** the reviewer answers,
   `judge.md` and `panel-map.md`. The prompt files, output files and all
   other runner files of external reviewers go in `<run dir>/jobs/`
   (7.2 step 1), never in the round directory.
   Assign the letters A, B, C, ... to the reviewers in a **random order,
   new for every round** (config order would let the judge match letters
   to the config file). Start all external reviewers
   detached, run the native reviewer(s) as subagents, then wait for all.
   The same task text goes to every reviewer, plus the 7.4 blocks. A native
   reviewer's final message is written by the orchestrator to its file.
3. Files in the round directory (all written by the orchestrator): for a
   native reviewer, its final message; for an external reviewer, a copy
   of its output file `O` from `jobs/`, made when its run is complete
   (7.2 step 1); both as `<run dir>/<gate>-r<N>/reviewer-<letter>.md`,
   where `<gate>` is
   `plan-review`, `code-review`, or `targeted-review-<k>` (`<k>` is a
   run-wide counter that starts at 1 and goes up by one each time a Phase
   3F targeted gate starts in this run; it never repeats, also after a
   blocked-and-resumed Tester), and `N`
   is the round of that gate, starting at 1. The same names apply in Case B
   (letter `A`). The orchestrator writes the judge's final message to
   `<run dir>/<gate>-r<N>/judge.md`. These files are for the developer and
   for building the `EARLIER CONFIRMED FINDINGS` block (7.4) and the
   judge's `EARLIER PANEL DECISIONS` block (step 6). Never pass whole
   `judge.md` files to a later judge or reviewer.
4. A reviewer **fails** when its script code is not 0, or its marker is not
   this gate's APPROVED or CHANGES REQUESTED marker (a native reviewer with
   no marker at all fails too). A failure: a required reviewer
   stops the run; an optional reviewer is dropped from this round and
   reported in the summary. If no reviewer output is left in the round:
   STOP. The case (C) does not change when reviewers drop out: one remaining
   output still goes through steps 5 to 8.
5. If every remaining reviewer's marker is the gate's APPROVED marker: the
   judge does not run, and the gate passes **unless the build gate
   failed** (then the result is CHANGES REQUESTED with the build item
   only). Their "Nits / optional" items go to
   the summary.
6. **Reviewer files are checked first.** All hashes here come from
   `bash "RUNNER" --hash <file>`, the same function that wrote the `sha`
   line, so they are always comparable. For each reviewer file that goes
   to the judge, compute its hash now and compare it with the hash taken
   when it was complete: for an external reviewer, the `sha` line of its
   `O.status` (its round-directory copy was made with `cp`, so it has the
   same bytes); for a native reviewer, the `--hash` result the
   orchestrator took right after writing its file. A difference means another
   process changed a reviewer's output during the round (the run
   directory is git-ignored, so the tree guard cannot see it): STOP the
   run and report the file.
   Then start the judge (native, `adt-android-review-judge`) with:
   gate type (`PLAN` or `CODE`), round number, targeted or full, PLAN_PATH,
   DOC_PATH when present, the `BUILD GATE OUTPUT` block (code gates), the
   `EARLIER CONFIRMED FINDINGS` block (7.4) when it is not empty; for a
   targeted re-review, the fix instructions the Coder worked from (the same
   text the reviewers get); from round 2, an `EARLIER PANEL DECISIONS`
   block (the "Rejected" and "Disputed" sections of this gate's earlier
   `judge.md` files, with their round numbers; for the judge only, never
   for reviewers); and the
   file paths of **only the reviewers that did not fail in this round**
   (their original letters; gaps such as A and C are allowed). Never pass
   the file of a failed or dropped reviewer. Do not tell the judge which
   tool wrote which file. Anonymity is best-effort: the judge can read
   files, so its prompt (8.1) allows it to open, inside the run directory,
   only the reviewer files it was given, and forbids opening
   `.agentic-dev-team/config.yaml`, any `panel-map.md`, and anything in
   `<run dir>/jobs/`.
7. At the **end of every round** (after the judge, or after the
   all-approve decision of step 5; in Case B too), write
   `<run dir>/<gate>-r<N>/panel-map.md` with the letter-to-runner-and-model
   map. It is written only after every reviewer and the judge have
   finished, so no agent of that round can read it.
8. The judge's marker is the gate verdict, **except** when the build gate
   failed in this round: then the verdict is always CHANGES REQUESTED, even
   if the judge approved. On CHANGES REQUESTED the producing agent gets, as
   its numbered feedback (where the command file today passes "the
   reviewer's numbered feedback"): the build-gate item first when the build
   gate failed, then the judge's **Confirmed** list (which may be empty).
9. **No valid judge verdict:** the judge's marker is found with the rule
   of 6.2 step 8 (so conflicting markers are invalid). The verdict is not
   valid when there is no marker, when it is not this gate's APPROVED or
   CHANGES REQUESTED marker (for example the judge stopped because an
   input was missing), when it is APPROVED but the Confirmed list is not
   empty, or when it is CHANGES REQUESTED but the Confirmed list is empty
   (`None`) and the build gate passed. Then STOP the run. Report the
   gate, the round, and the path of `judge.md`. Do not retry the judge, do
   not treat it as approval, and do not start another round.

**Budgets do not change.** A panel round counts as one review. Phase 1R and
2R: at most 2 re-runs. Phase 3F targeted re-review: at most 1 re-run. A
failed optional reviewer does not use budget.

### 7.6 Special cases

| Case | Rule |
|---|---|
| Parallel coders | Each section's coder uses the `coder` slot. External coders in one group run as parallel detached jobs. They run no Gradle, as today. The cross-section check after each group is unchanged. |
| Tester | May be external. That CLI must have the `auto-mobile` MCP server in its own config. |
| Tester and credentials | Test credentials must never be written to a file (Part A, "Test Credentials"), and an external run needs a prompt file. The orchestrator must not have to decide whether a reply contains a credential. So the rule is mechanical: **from the first reply at the blocked gate that is anything other than exactly `resume` or `stop`** (for example `resume: the PIN is 1234`, `PIN is 1234, resume`, or a PIN on its own line before `resume`), **every later Tester start in that run runs native**: that resume itself, every later resume, and every Phase 3F re-test. Only a reply that is exactly the word `resume` (spaces around it do not matter) keeps an external Tester external. Also, no text from a human reply is ever copied into a prompt file. Its model comes from items 2 and 3 of the list "Model resolution for a native agent" in 3.4 (`agents.tester.model`, else the frontmatter); the external slot's `model` is for its CLI, never for the native tool. The summary says so. Before that moment, an external Tester gets no credentials (it has none to get). |
| Architect | May be external (write). Its `✅ ARCHITECT DONE` line and artifact paths are read from the output file. |
| External Coder or Tester in Codex | Codex's `workspace-write` sandbox blocks writes outside the project (for example `~/.gradle`) and, by default, network access. So Gradle dependency downloads, the Gradle daemon, and `adb` (which talks to `localhost:5037`) can fail. Do not work around it in the script. Document it in the README: use another runner for the Coder and the Tester, or allow network and the needed paths in the developer's own Codex configuration (Codex docs, `sandbox_workspace_write`). At the start of a run whose `coder` or `tester` slot uses `runner: codex`, print one warning line with this advice. |

### 7.7 Summary additions (only with `RUNS` on)

Add a "Configured run" section to the final summary:

1. Each role: runner and model.
2. Each gate: panel members (letter, runner, model), rounds used, which
   letters raised each confirmed item, disputed items, failed or removed
   optional reviewers.
3. A warning when two reviewers of one gate are in the same model family.
   Family is decided from **what actually runs**:
   - A native reviewer whose model was not applied (Antigravity, opencode,
     or 5.2 step 2 or step 3 turned model passing off before it started)
     has the orchestrator tool's
     current model family when known, else unknown. Its configured `model`
     is ignored here.
   - Otherwise use the model value (case-insensitive) with the rules below;
     when no rule matches, or there is no model value, use the runner rule
     at the end.
   - For an `opencode` value `provider/model`, use the provider:
     `anthropic` is Anthropic, `openai` is OpenAI, `google` is Google; any
     other provider (for example `ollama`, `openrouter`) is unknown.
   - Anthropic: `claude-*`, `opus`, `sonnet`, `haiku`, `fable`, or any of
     these followed by `[` (for example `opus[1m]`).
   - OpenAI: `gpt-*`, or `o` followed by a digit (`o[0-9]*`, for example
     `o3`). `opus` and `ollama/...` do **not** match this rule.
   - Google: `gemini-*`.
   - Runner rule: `claude` runner is Anthropic, `codex` runner is OpenAI
     (so `codex-mini-latest` is OpenAI). A `command` runner uses the basename
     of its `check` value (so `/usr/local/bin/gemini` counts as `gemini`):
     `claude` is Anthropic, `codex` is OpenAI, `gemini` is Google. A
     native reviewer with no model value has the orchestrator tool's family
     when known. Anything else is unknown, including `agy` and `opencode`
     without a model value, because their default model is set by the
     developer's own CLI settings.
   Unknown family: no warning.
4. Every item from the judges' "Out of scope (for the developer)"
   sections, and every DISPUTED item, with gate and round: these are
   possible defects that no gate blocked on.
5. Nits: the items of the judges' "Nits / optional" sections, and, in a
   round where every reviewer approved, the reviewers' own "Nits /
   optional" items. They take the place of the existing summary item
   "Nits the reviewer declined to block on" for panel gates.
6. The run directory path.

---

## 8. The judge agent

### 8.1 `PLUGIN_ROOT/agents/adt-android-review-judge.md` (new)

Frontmatter (exact):

```yaml
---
name: adt-android-review-judge
description: >
  Only for /build-auto-reviewed when .agentic-dev-team/config.yaml sets a
  review panel (2 or more reviewers for one gate). The orchestrator starts it
  to verify and merge the panel's findings. Do not use it in any other case.
tools: Read, Glob, Grep, Bash, Skill
model: inherit
---
```

Body requirements:

1. **Mission:** decide which findings of a review panel are real, merge
   them, and give the gate's verdict. It never edits files and never adds a
   finding of its own.
2. **Inputs:** those listed in 7.5 step 6. Stop (report, no verdict) if
   PLAN_PATH or a reviewer file is missing.
3. **Required reading:** the consuming project's `AGENTS.md`/`CLAUDE.md`;
   Part A of PIPELINE_DOC; the plan; for a code gate, the changed-file
   manifest (Part A) so it can open the code each finding names.
4. **Procedure for each finding in each reviewer file:**
   - Open the cited file and lines (or plan section) and check the claim.
   - **CONFIRMED**: the defect is real and blocking under the reviewer's
     own rules (the code reviewer's or the architect reviewer's "What You
     Review"). A failing build gate is **not** listed by the judge: the
     orchestrator adds it itself as the first feedback item (7.5); reject
     a reviewer finding that only repeats the build failure.
   - **REJECTED**: wrong, already fixed, a style preference, or it only
     asks to undo a fix listed in the `EARLIER CONFIRMED FINDINGS` block
     without showing that the fix is wrong. Give a one-line reason. A
     finding that shows a real defect **in** such a fix (the fix broke
     something, or does not fix the item) is judged on its merits like any
     other finding, and is CONFIRMED when the defect is real.
   - **DISPUTED**: cannot be verified from the tree or the plan. Not
     blocking.
   - **Earlier decisions** (`EARLIER PANEL DECISIONS`): letters change
     every round, so match earlier decisions by **content** (the finding
     text and its file:line or plan section), never by letter. A finding
     that says the same as one an earlier round of this gate REJECTED is
     rejected again ("rejected in round N"), unless the code or plan at
     that place changed since then.
     This keeps verdicts consistent across rounds.
   - Merge findings that describe the same defect into one item, and list
     all the letters that raised it.
   - Items that a reviewer put under "Nits / optional" stay nits. They never
     become confirmed.
5. **Targeted re-review:** judge only findings about the fix and what it
   touched, as the code reviewer's targeted mode defines. Use the fix
   instructions in the input to decide what the fix was. A finding about
   code the fix did not touch is not blocking in this re-review: list it
   under "Out of scope (for the developer)", not under Rejected, so that a
   real defect is not lost.
6. **Read-only:** Bash only for inspection (`git diff`, `git status`,
   `git show`, `git log`). Inside the run directory, open only the
   reviewer files you were given. Never open `.agentic-dev-team/config.yaml`,
   any `panel-map.md` file, or anything in `<run dir>/jobs/`: which tool
   wrote a reviewer file must not influence the verdict. Never run Gradle (the output is given). Never
   edit, stage, commit, or stash.
7. **Output format (exact headings):**

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

   Write `None` under an empty heading.
8. **Last line:** exactly one marker. Code gate: `✅ CODE APPROVED` or
   `🔧 CODE CHANGES REQUESTED`. Plan gate: `✅ PLAN APPROVED` or
   `🔧 PLAN CHANGES REQUESTED`. APPROVED if and only if the Confirmed list is
   empty. The marker line is the **last** line of the judge's answer:
   nothing follows it (unlike a reviewer, the judge's findings are only
   under the headings above). The orchestrator takes the Coder's (or
   Architect's) feedback from the "Confirmed (blocking)" section only.

### 8.2 `.opencode/agents/adt-android-review-judge.md` (new)

Same pattern as the other opencode stubs: the description from 8.1,
`mode: subagent`, and a body that tells it to read
`.claude/agents/adt-android-review-judge.md` in full and follow it, read
PIPELINE_DOC Part A and `AGENTS.md`/`CLAUDE.md`, stay read-only, and end
with exactly one verdict marker.

### 8.3 Antigravity

Do **not** add the judge to `.agents/AGENTIC_DEV_TEAM.md` (that block is
loaded into every Antigravity conversation). Add one line to Part B,
"Subagent Tool & Environment Mappings" (10.4).

---

## 9. Command file changes

### 9.1 Preamble for all five commands (exact text)

Insert directly after the existing paragraph that ends "...alongside the
artifact paths you already pass." in each command:

```
Agent configuration: set PROJECT_ROOT to the absolute path of the
directory this command started in (your working directory at the start;
your tool shows it, no shell command is needed). All paths below are
relative to PROJECT_ROOT, whatever the shell's current directory is later.
Set ADT_ROOT to PROJECT_ROOT/.claude if
PROJECT_ROOT/.claude/scripts/adt-run-agent.sh exists, otherwise to
`${CLAUDE_PLUGIN_ROOT}` if `${CLAUDE_PLUGIN_ROOT}/scripts/adt-run-agent.sh`
exists, otherwise leave it empty. For every "exists" check in this
paragraph, read that exact path with your file-read tool, only its first
line (for example a line limit of 1). Never use a file-search tool:
search tools skip git-ignored files, and both the script link in an
`install.sh` project and the config file are git-ignored. Never use a
shell command for these checks.
Then read PROJECT_ROOT/.agentic-dev-team/config.yaml the same way. There
are exactly three outcomes:
(a) The read succeeds (an empty file counts as success): the file exists.
    Skip the init step.
(b) The read reports that the file does not exist, in any wording (for
    example "File does not exist.", "file not found", "no such file"):
    treat the file as missing. If ADT_ROOT is set, run
    `bash "ADT_ROOT/scripts/adt-run-agent.sh" --init-config "PROJECT_ROOT"`
    (with the real paths in place of the names, each in double quotes);
    if ADT_ROOT is empty, skip it. (A broken link is also reported as "not
    found"; the script then prints `ADT_INIT status=unreadable`, see
    below.)
(c) The read fails for a reason other than "the file does not exist"
    (the path is a directory, or no permission):
    a config error. Do not run the init step. STOP the command before the
    first agent and say: "agentic-dev-team:
    .agentic-dev-team/config.yaml exists but cannot be read; fix or
    delete it."
The init step creates the optional, git-ignored config once. After it:
- `ADT_INIT status=created` or `status=exists`: continue.
- `ADT_INIT status=unreadable`: a config error; STOP the command before
  the first agent and show the script's message.
- The permission was declined, the tool reported an error, or
  `ADT_INIT status=failed`: print this line once and continue. (When the
  init step was skipped, print nothing.)
"The optional config file .agentic-dev-team/config.yaml was not created. To
stop this question, allow the command, or create two files yourself:
.agentic-dev-team/.gitignore with the single line *, and
.agentic-dev-team/config.yaml copied from <TEMPLATE>."
where <TEMPLATE> is only the one that applies: in a plugin install
(ADT_ROOT is not PROJECT_ROOT/.claude), the real path of
ADT_ROOT/config.example.yaml; in an install.sh install (ADT_ROOT is
PROJECT_ROOT/.claude), the text "plugins/agentic-dev-team/config.example.yaml
in your agentic-dev-team clone".
Then follow PIPELINE_DOC Part B, "Agent Configuration": read and validate
that file, and set MODELS. If PIPELINE_DOC has no "Agent Configuration"
section (an older install) and ADT_ROOT is set, read that section, and
"Configured Runs", from ADT_ROOT/AGENTIC_DEV_TEAM_PIPELINE.md instead, so
the rules and the scripts are the same version. If neither file has the
section, do not use the config file at all, and, only when the file has
an active setting, print one line: "agentic-dev-team: the installed
pipeline doc is older than the config file support, so
.agentic-dev-team/config.yaml was not used." When the config file has no
active setting, none of this changes anything. When MODELS is on, follow Part B, "Agent
Configuration", every time you start an `adt-*` subagent in this command:
it says which model to pass, and when to pass none (it can turn model
passing off). When MODELS is off, ignore every rule that names MODELS: the
run is exactly as it would be without this paragraph.
```

### 9.2 `/build-auto-reviewed` only

1. After the 9.1 paragraph, add:

   ```
   Configured runs: the same section also sets RUNS from the
   `build_auto_reviewed:` part of the file. When RUNS is on, follow PIPELINE_DOC
   Part B, "Configured Runs (/build-auto-reviewed only)", for every phase
   below: it says where each role runs, and how a gate with 2 or more
   reviewers runs as a review panel with a judge. When RUNS is off, ignore
   every line that names RUNS.
   ```

2. At the end of each of Phase 1, 1R, 2, 2R, 3, 3B, 3F, add one line:
   `When RUNS is on, run this phase's roles as Part B, "Configured Runs", says.`
3. Add the sentence `(When RUNS is on, Part B, "Configured Runs", says
   what this feedback is: in a gate with an external reviewer or a panel,
   the build-gate item first when the build gate failed, then the judge's
   Confirmed list or the reviewer's list.)` directly
   after these phrases (each may wrap across two lines in the file):
   - Phase 1R: "re-run `adt-android-architect` with the reviewer's feedback"
     (the sentence ends later; put the note after the word "feedback");
   - Phase 2R: "with PLAN_PATH and the reviewer's numbered feedback";
   - Phase 3F: "re-run the Coder once with that numbered feedback".
   If one of these phrases is not found, stop and report it; do not guess
   another place.
4. At the end of the summary paragraphs, add:
   `When RUNS is on, add the "Configured run" section that Part B, "Configured Runs", defines.`
5. Do not change any other line.

### 9.3 The other four commands

Only the 9.1 paragraph. No other line changes.

---

## 10. Other file changes

### 10.1 `PLUGIN_ROOT/AGENTIC_DEV_TEAM_PIPELINE.md`, Part A

Only one change. In "The Changed-File Manifest", after the paragraph that
lists the four parts, add:

```
**Exception:** files under `.agentic-dev-team/` are the developer's pipeline
configuration, not part of any run's changes. They are normally git-ignored
and do not appear. If they appear (the developer un-ignored the config and
has not committed it yet), leave them out of the review and do not report
them.
```

No other change to Part A.

### 10.2 Part B: new section "Agent Configuration"

Add after "Subagent Tool & Environment Mappings". Content: sections 3.1,
3.2, 3.3, 3.4, 4 (short form: the files, `--init-config`, un-ignore), 5,
and from 6.4 the word-splitting and assignment steps 1 and 2 (they define
"word", "assignment" and "program word") together with the whole
"Template check" list (validation rule 6 refers to it, and every command
validates the whole file, also where the script's check never runs),
written as rules for the orchestrator.

### 10.3 Part B: new section "Configured Runs (/build-auto-reviewed only)"

Add after "The Targeted Re-Review". First line (exact):
`Only /build-auto-reviewed uses this section, and only when RUNS is on. Every other command, and a run with RUNS off, ignores it.`
Content: from section 6.1 the interface, the output lines (the `ADT_RUN`
block and its `code` line), the exit codes and the "Paths" rule (not the
process identity or signalling rules: only the script uses those); from
6.2 the marker rule (step 8) and the caller's view of `--wait` (step 10:
one block per file, exit 10 while any runs, and each run's result is the
`code` line of its block, never the exit code of a multi-file call);
section 7, and 8.1 items 4 and 7 (so the orchestrator knows the judge's
output format).

### 10.4 Part B: existing sections

1. "Subagent Tool & Environment Mappings": add
   `` - `adt-android-review-judge` (configured review panels only): system prompt from `.claude/agents/adt-android-review-judge.md`; `enable_write_tools = true` (for read-only Bash inspection; the judge never edits files per its prompt); `enable_subagent_tools = false`; `enable_mcp_tools = false`. ``
2. The model note under that list: add this sentence (exact text between
   the fences):

   ```
   The `agents:` model settings in .agentic-dev-team/config.yaml cannot change this; see "Agent Configuration".
   ```
3. "Orchestration Workflow (opencode)" item 3: add the same sentence.
4. "Orchestration Workflow (Antigravity)" step 1 ("Define Subagents"): after
   "also register `adt-android-architect-reviewer` and
   `adt-android-code-reviewer`", add: `When a review panel is configured
   (Part B, "Configured Runs"), also register adt-android-review-judge.`

### 10.5 `PLUGIN_ROOT/agents/adt-android-code-reviewer.md`

Add at the end of "What You Review", after item 6 (exact):

```
**Blocks from a configured run.** In a configured `/build-auto-reviewed`
run (Part B, "Configured Runs"), your prompt can contain two extra blocks:

- `BUILD GATE OUTPUT`: the orchestrator already ran the build gate. Use
  that output for item 6. If it failed, the orchestrator already reports
  the failure to the Coder as the first item, so do not repeat it; review
  the code as usual.
  While this block is present, **do not run Gradle at any point of this
  review**: not for item 6, not when item 1 says to re-run the build gate
  because the manifest changed, and not in the Targeted Re-Review ("Re-run
  the build gate"). Other reviewers may be reading the same tree, and the
  orchestrator checks that the tree does not change during the review.
- `EARLIER CONFIRMED FINDINGS`: changes made to fix those findings are
  review-driven and in scope (Part A, "Review-Driven Fixes Are In Scope"),
  even when another reviewer raised them. Do not report them as scope creep.

Without these blocks, nothing changes.
```

No other change. Do not change `adt-android-architect-reviewer.md` (it does
not run Gradle, and it has no scope-creep rule that 7.4 must override).

### 10.5a `.agents/AGENTIC_DEV_TEAM.md`

The Code Reviewer persona is inlined there and loaded by Antigravity in
every conversation, so it must carry the same exception as 10.5 (this is
how the inlined personas were kept in step with the full prompts before).
In "## The Code Reviewer", at the end of its **Constraint** line, add
(exact text):

```
When its prompt has a `BUILD GATE OUTPUT` block (a configured review panel), it runs no Gradle at all and uses that output instead; see its full prompt.
```

No other change to that file. The judge is not added there (8.3).

### 10.6 New files in PLUGIN_ROOT

`scripts/adt-run-agent.sh`, `config.example.yaml`,
`agents/adt-android-review-judge.md`. Commit the script with mode 100755.

### 10.7 This repo's `.claude/scripts`

New symlink `.claude/scripts -> ../plugins/agentic-dev-team/scripts` (same
pattern as `.claude/agents` and `.claude/commands`).

### 10.8 `.opencode/agents/adt-android-review-judge.md`

New (8.2).

### 10.9 `.claude-plugin/marketplace.json`

`"version": "0.3.0"` to `"version": "0.4.0"`.

### 10.10 `install.sh`

1. `build_desired_pairs`: add `"$REPO_DIR"/.claude/scripts/*.sh` to the glob
   list. This gives the per-file symlink `.claude/scripts/adt-run-agent.sh`,
   its line in the managed
   `.gitignore` block, and the existing refuse and stale-removal logic.
2. `do_install`: after the `.agents/agents.md` step, run
   `bash "$REPO_DIR/plugins/agentic-dev-team/scripts/adt-run-agent.sh" --init-config "$PROJECT_DIR"`
   (`PROJECT_DIR` is already absolute in `install.sh`). Call it as
   `... || true` and print its output either way: `install.sh` runs under
   `set -e`, and exit 1 must not stop the install. Print its output
   indented by two spaces, like the other lines of the install output.
3. `do_uninstall`: after the existing steps, print the message of 4.4 when
   `.agentic-dev-team/` exists. Touch nothing in it.
4. Header comment and `--help`: describe the config file and the scripts.
5. The final "Done." message: add
   `Optional config: .agentic-dev-team/config.yaml (see README, "Configuration").`

### 10.11 `README.md` and `HOW_IT_WORKS.md`

1. README: new section "Configuration": the file and how it is created
   (both install paths), un-ignore, `agents:` with the alias table and
   pinning (3.4), `build_auto_reviewed:` with runners, CLI requirements (each
   CLI installed and logged in; no API key), the panel and the judge, tool
   differences (3.4 and 7.6), cost (each panel round is N+1 agent runs),
   and the risks of section 13.
2. HOW_IT_WORKS: add the judge, the script and the config to the
   install tables and the agent list; describe the panel flow (1.1) and the
   switches; update "Model selection".

---

## 11. Files that must not change

- `agents/adt-android-pm.md`, `adt-android-architect.md`,
  `adt-android-architect-reviewer.md`, `adt-android-coder.md`,
  `adt-android-tester.md` (their frontmatter stays the default).
- The six existing `.opencode/agents/*.md` stubs.
- `AGENTIC_DEV_TEAM_PIPELINE.md` Part A, except the one exception paragraph
  of 10.1.
- In the four commands other than `/build-auto-reviewed`: every line except
  the inserted 9.1 paragraph.

---

## 12. Tests and acceptance

### 12.1 `tests/adt-run-agent.test.sh` (new)

Plain bash, no framework. Each case in a new temp git repo with
`pipeline_artifacts/.gitignore` = `*`. Fake `claude`, `codex`, `agy`,
`opencode` scripts on `PATH` write their arguments to a file and print a
configurable answer. Cases:

1. Each runner × each access mode: the exact arguments of 6.3.
2. `--allow-read` gives `--add-dir <real dir>` for `claude` only, with a
   symlinked file resolved to its real directory.
3. `claude`: `CLAUDECODE` is not in the child's environment.
4. Output: stdout to `O` (claude, agy, opencode, command without
   `{output_file}`); the `--output-last-message` file for codex.
5. Marker: plain, bold (`**✅ CODE APPROVED**`), in a heading,
   `Verdict: ✅ CODE APPROVED`, `**Verdict:** ✅ CODE APPROVED`,
   `Verdict: **✅ CODE APPROVED**`, with a
   summary after it on the same line; a `🔧 CODE CHANGES REQUESTED` line
   followed by a numbered list whose items start with `✅` or `🔧` (the
   marker is still the CHANGES REQUESTED line); only an unknown emoji line
   (`✅ done`): `no-marker`; a CHANGES REQUESTED answer with an indented
   continuation line `   ✅ CODE APPROVED only once X is fixed`: still
   CHANGES REQUESTED (indented lines never count); a CHANGES REQUESTED
   answer whose list has a
   line `` `✅ CODE APPROVED` must wait `` or `> ✅ PLAN APPROVED`: still
   CHANGES REQUESTED (quoted lines never count); the same with a bullet
   line `* ✅ CODE APPROVED only after X` or `- ✅ ...`: still CHANGES
   REQUESTED (bullets never count); two marker lines with
   different known markers: `conflicting-markers` (13) with the lines in
   `O.log`; the same marker twice: that marker.
6. `no-marker` (6), `failed` (5), `missing-runner` (3), `usage` (2) for a
   missing argument and for an output file that is not ignored.
7. `timeout` (4) with `--timeout-seconds 2`: the fake CLI starts a child
   `sleep 60`; after the run, neither process exists.
8. A read-only fake run that edits a file still returns `ok` (the script
   does not guard runs); `--snapshot` before and after shows a different
   hash (case 15).
9. `command` runner: `{instruction}` and `"Task: {instruction}"`; values
   with spaces, double quotes, `&`, `*` and `$` in paths reach the program
   as one unchanged argument (a fake program prints its arguments one per
   line). The template check (`--check command --check-program <c>
   --command-file F [--model M]`, exit 2) rejects each of: a template with
   `'`, `\`, a backtick, `$`, `|`, `;`, `&`, `<`, `>`, or a newline;
   unbalanced double quotes; a program word that differs from `<c>`
   (`env GEMINI_API_KEY=x gemini ...`, `timeout 900 gemini ...`,
   `/usr/bin/env -S "bash x"` with `<c>` = `gemini`); `<c>` = `bash`,
   `sh`, `env`, `busybox` or `ssh` (with a matching template);
   `PATH=/tmp/x gemini ...`, `LD_PRELOAD=x gemini ...`,
   `DYLD_INSERT_LIBRARIES=x gemini ...`; one without
   `{instruction}` or `{prompt_file}`; and `-m {model}` without `--model`.
   It accepts, with `<c>` = the program word: `gemini -p {instruction} -m
   {model}` with `--model`, `gemini -p "Task: {instruction}"`,
   `codex exec {instruction}` (`<c>` = `codex`),
   `GEMINI_API_KEY=x gemini -p {instruction}`,
   `SHELL=/bin/bash gemini -p {instruction}`,
   `/opt/bin/gemini -p {instruction}` (`<c>` = `/opt/bin/gemini`), and
   `gemini --flash -p {instruction} -c cfg`. A run with a value that
   contains spaces, `$(id)`, `;`, `*` and double quotes passes it to the
   fake program as one unchanged argument, and no command inside it
   runs.
10. `--detach` + `--wait`: `running` (10) before the end, the final status
    after; `O.status` has the five lines; usage errors return at once.
    `--wait O1 O2 O3` with three jobs of different lengths: one block per
    file in the given order, exit 10 while any runs, 0 when all have a
    result, each block with its own `code`. A **read-only** run whose
    CLI leaves a child process behind and exits 0: after `O.status`
    exists, the child is gone. The same with a **write** run: the child is
    still running after `O.status` exists (it is not cleaned up; stop it at
    the end of the test).
11. `--check`: 0 for a present CLI, 3 for a missing one.
12. Stale files: an `O.status` from an earlier run is deleted at the start of
    a new run; with a fake CLI that sleeps 5 seconds, `--wait
    --max-seconds 1` right after `--detach` returns 10, never the old
    result. A second `--detach` on an `O` whose job is alive exits 2.
13. `--snapshot --guard-path`: editing, adding, or deleting a file in a
    git-ignored guarded directory changes the hash; a missing guard path
    exits 2; `git checkout` of another branch, or `git reset --hard
    HEAD~1`, on a clean tree changes the hash; with the project root in a
    subdirectory of the repository, new untracked files inside and outside
    it are hashed without error (exit 0) and change the hash; a snapshot
    on a detached
    HEAD and in a repository with no commits succeeds (exit 0); the same hashes with
    `diff.relative=true`, a `diff.external`
    tool and a textconv driver set in the test repository's config (and a
    change to a binary file covered by that textconv driver changes the
    hash); in a larger repository, a change to a tracked file outside
    the project root, and a new untracked file outside it, both change the
    hash; a new untracked file under `.kotlin/` or
    `.gradle/` does not change the hash, but a new untracked file under
    `src/main/java/com/acme/build/` does; a snapshot of 200
    untracked files and one guarded directory of 50 files uses exactly two
    `git hash-object --stdin-paths` calls, one for the untracked files and
    one for the guarded directory (check with a fake `git` wrapper that
    counts calls with that argument; other `hash-object` calls, such as the
    final `--stdin` hash, are not counted).
14. Lost job: kill the detached job with `KILL` before it writes `O.status`;
    `--wait` returns 11, writes `O.status` with `status=lost`, and the fake
    CLI's process group is gone. A stuck watcher (test hook
    `ADT_RUN_TEST_STOP_WATCHER=1` stops `O.elapsed` updates): 11, and both
    the job and the CLI are gone afterwards. A job that hangs before it starts
    the wrapper (test hook: environment variable
    `ADT_RUN_TEST_HANG_BEFORE_CLI=<seconds>` makes the job sleep just before
    it starts the wrapper; the script reads it only for this test): 11, and
    the fake CLI never starts, not even after the sleep would have ended.
15. `--snapshot`: same hash twice on an unchanged tree; a different hash after
    a change in a tracked file, an untracked file, or a guarded ignored file.
16. `O.pid` is written only by the parent and `O.clipid` only by the CLI
    wrapper: run 20 detached jobs in parallel and check that in every
    `O.pid` the first line has exactly two fields and the second line
    equals `bash adt-run-agent.sh --identity <job pid>`, and that every `O.clipid` holds
    the live CLI pid and its identity while it runs.
17. Lost path with a CLI that was just started: stop the job with `KILL`
    right after the wrapper wrote `O.clipid`; `--wait` stops that CLI.
    Cancel before the wrapper: start with `ADT_RUN_TEST_HANG_BEFORE_CLI=3`,
    create `O.cancel` during the hang (after the step 2 cleanup has run),
    then let the hang end without stopping the job; the wrapper sees
    `O.cancel` and the fake CLI never starts.
18. `not-started`: with `ADT_RUN_TEST_FAIL_PID_WRITE=1`, `--detach` exits
    12, writes `O.status` with code 12, and no job or CLI keeps running
    (check with `kill -0` on the job's group). A job whose `O.pid` holds
    another pid exits without writing any file.
19. `--command-file` with a valid template (no `'`) runs the right
    command when the **values** (a project root and prompt path) contain
    single quotes, `$`, `&` and spaces. `--check command --check-program gemini
    --command-file F` with a valid template checks `gemini`; `--check
    command` without `--check-program` or without `--command-file` exits 2.
20. Identity: write an `O.pid` by hand with the pid of a live, unrelated
    test process and a wrong identity line: `--wait` treats the job as not
    alive and sends no signal to that process. A CLI leader that exits
    while its child keeps running in the same group: the lost path still
    stops the child.
21. `--cancel <run dir>`: with two running detached jobs and one finished
    one under `jobs/`, both running jobs and their CLIs are gone
    afterwards, their `O.status` has `status=cancelled` and `code=14`, and
    the finished run's `O.status` is unchanged.

### 12.2 `tests/adt-config.test.sh` (new)

1. `adt-run-agent.sh --init-config <abs project dir>` in a new git repo
   creates both files; `git status
   --porcelain` shows nothing; `git check-ignore` is true for both.
2. Second run: an edited `config.yaml` is unchanged (checksum).
3. Delete `.gitignore`, run again: it is not re-created.
4. `.agentic-dev-team` as a file: warning, exit 1. Missing template:
   warning, exit 1. Missing or relative `<project-root>`: warning, exit 1.
   `.gitignore` cannot be written (test hook
   `ADT_RUN_TEST_FAIL_GITIGNORE_WRITE=1`): no `config.yaml` is created,
   warning, exit 1. Config copy fails (test hook
   `ADT_RUN_TEST_FAIL_CONFIG_WRITE=1`): no `config.yaml`, exit 1. The test
   hooks work also when the tests run as root, where file permissions do
   not stop writes; a permission-based variant (unwritable project
   directory) runs only when `id -u` is not 0. `install.sh` with a failing
   init (hook set): the install still finishes with exit 0. Called from another
   current directory: the config is created in `<project-root>`, not in the
   current directory. A project root below the git top-level: the config
   is created in the project root.
5. Called the way an `install.sh` project calls it: build a fake clone with
   `plugins/agentic-dev-team/scripts/adt-run-agent.sh`, the template, and
   the **directory** symlink `.claude/scripts -> ../plugins/agentic-dev-team/scripts`;
   in a project, create the **file** symlink
   `.claude/scripts/adt-run-agent.sh -> <clone>/.claude/scripts/adt-run-agent.sh`.
   Calling the project symlink finds the template and creates the config.
   Also test a direct call and a relative symlink target.
6. Template check: for each role except `review_judge`, the commented model
   in `config.example.yaml` equals the `model:` in the agent frontmatter.
7. The template as created is valid YAML, and gives `agents: null` and
   `build_auto_reviewed: null` (so `MODELS` and `RUNS` are off). Also parse
   `tests/fixtures/config.full.yaml` (new: the template with every setting
   line active). Use `python3 -c 'import yaml'` if available; otherwise skip
   this case with a message.

### 12.3 `install.sh` comparison

In a script or by hand, recorded in the PR description:

1. Install from `main` and from the branch into two new temp git projects.
   Allowed differences: `.claude/scripts/` symlinks,
   `.claude/agents/adt-android-review-judge.md`,
   `.opencode/agents/adt-android-review-judge.md`, their lines in the managed
   `.gitignore` block, `.agentic-dev-team/` (two files), and output text.
   `.agents/agents.md` must differ only by the one sentence of 10.5a.
2. `git status --porcelain` in the project lists no `.agentic-dev-team/`
   path.
3. Edit the config, re-install: config unchanged. Delete
   `.agentic-dev-team/.gitignore`, re-install: not re-created.
4. Uninstall: `.agentic-dev-team/` and both files in it are unchanged
   (checksums), the message of 4.4 is printed, and `git status --porcelain`
   still lists nothing in `.agentic-dev-team/`.

### 12.4 Static checks

1. `bash -n` for all scripts. `shellcheck` if it can be installed.
2. `git diff main --stat` for the files of section 11 shows nothing, except
   the exact insertions allowed there.

### 12.5 Manual tests (in the PR description, for the developer)

1. Plugin install, no edits: `/build-auto` and `/build-auto-reviewed` behave
   as today; `.agentic-dev-team/config.yaml` appears and is ignored.
2. Claude Code with a **Sonnet** main session and
   `agents: { coder: { model: opus } }`: the Coder subagent runs on the Opus
   version that `opus` maps to (3.4, alias case 2). With an **Opus** main
   session, it runs on the main session's exact model (3.4, alias case 1).
3. A two-reviewer code panel (`native` + one external CLI) in Claude Code,
   in Antigravity, and in opencode. After each round, the round directory
   `<run dir>/code-review-r<N>/` holds only `reviewer-*.md`, `judge.md`
   (when the judge ran) and `panel-map.md`; every prompt, log, status and
   pid file is in `<run dir>/jobs/`.
4. An optional external reviewer whose CLI is not installed: the run
   continues and the summary reports it.
5. An external Tester on a locked device: the run reaches the Blocked Path
   and asks for the PIN; after `resume: ...` the Tester runs native.
6. Claude Code with `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` and a model setting:
   the run does not fail, and the summary says the model settings were not
   applied. With `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` and **no** edited
   config: no extra step and no extra summary line (R1).

### 12.6 Acceptance criteria

1. All of 12.1 to 12.4 pass.
2. R1 to R6 hold.
3. Every exact text of sections 4.5, 7.3, 7.4, 8.1 (frontmatter and output
   format), 9.1, 9.2, 10.1 and 10.5 is present unchanged.

---

## 13. Risks that stay

1. **LLM orchestrators read all text.** Rules behind a switch that is off
   can still have a small effect. Manual test 12.5 item 1 checks it.
2. **Aliases move.** `opus` and `sonnet` follow Claude Code and the provider.
   Pinning is described in 3.4.
3. **Antigravity and opencode ignore native model settings.** A tool limit.
   External runners are the workaround in `/build-auto-reviewed`.
4. **CLI flags change.** All runner flags are in `adt-run-agent.sh`. The
   flags in 6.3 were checked against the current docs of each CLI.
5. **No strict read-only mode in `agy` and `opencode`.** The tree guard
   detects a change and stops the run, but it cannot prevent it.
6. **Detached jobs.** A tool that kills every process it started, not only
   its process group, could stop a detached run. Manual test 12.5 item 3
   checks each tool. The other way round, a detached job outlives an
   orchestrator that is interrupted (Esc) before it can run `--cancel`;
   the STOP report and summary print the `--cancel` command for that case
   (7.5).
7. **External Coder in Codex** can fail Gradle (7.6).
8. **Cost.** Each panel round is N+1 agent runs.

## 14. Out of scope

- External runners or panels in any command except `/build-auto-reviewed`.
- A configurable judge runner.
- Changing the model of the orchestrator itself.
- Automatic migration of an existing config to a newer template.
