#!/usr/bin/env bash
#
# adt-run-agent.sh: config init and external agent runner for agentic-dev-team.
#
#   --init-config <project-root>   create .agentic-dev-team/config.yaml (all commands, install.sh)
#   every other mode               external runs of /build-auto-reviewed (RUNS on)
#
# Reference: AGENTIC_DEV_TEAM_PIPELINE.md Part B, "Agent Configuration" and
# "Configured Runs (/build-auto-reviewed only)".
#
# Usage:
#   bash adt-run-agent.sh --init-config <project-root>
#   bash adt-run-agent.sh --identity <pid>
#   bash adt-run-agent.sh --check <claude|codex|agy|opencode>
#   bash adt-run-agent.sh --check command --check-program <program>
#                         --command-file <path> [--model <model>]
#   bash adt-run-agent.sh --runner <runner> --access <read-only|write>
#                         --project-root <path>
#                         --prompt-file <path> --output-file <path>
#                         [--model <model>] [--timeout-minutes <n>]
#                         [--command '<template>' | --command-file <path>]
#                         [--check-program <program>]
#                         [--allow-read <path>]... [--detach]
#   bash adt-run-agent.sh --wait <output-file>... [--max-seconds <n>]
#   bash adt-run-agent.sh --hash <file>
#   bash adt-run-agent.sh --snapshot --project-root <path> [--guard-path <path>]...
#   bash adt-run-agent.sh --cancel <run dir>
#
# Compatible with bash 3.2: no associative arrays, no mapfile, no ${var,,},
# no wait -n, no readlink -f, no timeout binary.

# shellcheck disable=SC1003,SC2004,SC2016,SC2094
unset CDPATH

# ---------- helpers ----------

adt_note() { printf 'agentic-dev-team: %s\n' "$*" >&2; }

# Physical path of a file or directory, with every symlink resolved.
# A relative link target is relative to the link's directory. At most 40
# links, so a symlink cycle cannot hang the script.
adt_physical_path() {
  local p="$1" n=0 t d
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    t=$(readlink "$p") || return 1
    case "$t" in
      /*) p="$t" ;;
      *) p="$(dirname "$p")/$t" ;;
    esac
  done
  if [ -d "$p" ]; then
    (cd -P "$p" 2>/dev/null && pwd -P) || return 1
  else
    d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
    [ "$d" = / ] && d=""
    printf '%s/%s\n' "$d" "$(basename "$p")"
  fi
}

# Process identity: the start time of the process, which a reused pid never has.
adt_proc_identity() {
  local pid="$1" s
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    s=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    printf '%s\n' "${s##*)}" | awk '{ print $20 }'
  else
    LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null
  fi
}

# A zombie has ended; only its parent has not collected it yet.
adt_is_zombie() {
  local s st
  if [ -r "/proc/$1/stat" ]; then
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    st=$(printf '%s\n' "${s##*)}" | awk '{ print $1 }')
  else
    st=$(ps -o stat= -p "$1" 2>/dev/null)
  fi
  case "$st" in Z*) return 0 ;; esac
  return 1
}

# A stored process is alive only when kill -0 succeeds and its identity
# matches (and it is not a zombie).
adt_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(adt_proc_identity "$1")" = "$2" ] || return 1
  ! adt_is_zombie "$1"
}

# A process group may be signalled when its leader is alive (identity test),
# or when the leader is gone but the group still exists.
adt_may_signal() {
  if kill -0 "$1" 2>/dev/null; then
    [ "$(adt_proc_identity "$1")" = "$2" ]
  else
    kill -0 -- "-$1" 2>/dev/null
  fi
}

# Stop the groups in SG_PIDS / SG_IDS together: TERM, wait up to 5 seconds
# once for all of them, then KILL those that may still be signalled.
SG_PIDS=()
SG_IDS=()
adt_stop_groups() {
  local i=0 t=0 any live=()
  while [ "$i" -lt "${#SG_PIDS[@]}" ]; do
    if adt_may_signal "${SG_PIDS[$i]}" "${SG_IDS[$i]}"; then
      kill -TERM -- "-${SG_PIDS[$i]}" 2>/dev/null
      live+=("$i")
    fi
    i=$((i + 1))
  done
  [ "${#live[@]}" -gt 0 ] || return 0
  while [ "$t" -lt 10 ]; do
    any=0
    for i in "${live[@]}"; do
      adt_may_signal "${SG_PIDS[$i]}" "${SG_IDS[$i]}" && any=1
    done
    [ "$any" = 1 ] || return 0
    sleep 0.5
    t=$((t + 1))
  done
  for i in "${live[@]}"; do
    adt_may_signal "${SG_PIDS[$i]}" "${SG_IDS[$i]}" && kill -KILL -- "-${SG_PIDS[$i]}" 2>/dev/null
  done
  return 0
}

# Read "<pid> ..." and the identity line of a .pid or .clipid file.
# Sets RP_PID, RP_SECONDS, RP_ID. Fails when the file is missing or malformed.
adt_read_pidfile() {
  local l1="" l2=""
  RP_PID=""; RP_SECONDS=""; RP_ID=""
  [ -f "$1" ] || return 1
  { IFS= read -r l1; IFS= read -r l2; } < "$1" 2>/dev/null
  RP_PID="${l1%% *}"
  case "$l1" in *' '*) RP_SECONDS="${l1#* }" ;; esac
  RP_ID="$l2"
  case "$RP_PID" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

adt_hash() { git hash-object --no-filters -- "$1"; }

adt_is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ---------- --init-config ----------

adt_init_config() {
  local root="$1" dir cfg real tpl gt ct
  init_fail() {
    echo "ADT_INIT status=failed"
    adt_note "$*"
    exit 1
  }
  [ -n "$root" ] || init_fail "--init-config needs the absolute project root"
  case "$root" in /*) ;; *) init_fail "--init-config needs an absolute project root, got: $root" ;; esac
  [ -d "$root" ] || init_fail "project root is not a directory: $root"
  dir="$root/.agentic-dev-team"
  cfg="$dir/config.yaml"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] || init_fail "$dir exists and is not a directory"
  fi
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then
    if [ -f "$cfg" ] && [ -r "$cfg" ]; then
      echo "ADT_INIT status=exists"
      exit 0
    fi
    echo "ADT_INIT status=unreadable"
    echo "config.yaml exists but is not a readable file; fix or delete it"
    exit 1
  fi
  real=$(adt_physical_path "${BASH_SOURCE[0]}") || init_fail "cannot resolve the path of adt-run-agent.sh"
  tpl="$(dirname "$(dirname "$real")")/config.example.yaml"
  { [ -f "$tpl" ] && [ -r "$tpl" ]; } || init_fail "config template not found: $tpl"
  mkdir -p "$dir" 2>/dev/null || init_fail "cannot create $dir"
  if [ ! -e "$dir/.gitignore" ] && [ ! -L "$dir/.gitignore" ]; then
    gt="$dir/.gitignore.tmp.$$"
    if [ -n "${ADT_RUN_TEST_FAIL_GITIGNORE_WRITE:-}" ] ||
       ! { printf '*\n' > "$gt" && mv -f "$gt" "$dir/.gitignore"; } 2>/dev/null; then
      rm -f "$gt" 2>/dev/null
      init_fail "cannot write $dir/.gitignore; config.yaml was not created"
    fi
  fi
  ct="$cfg.tmp.$$"
  if [ -n "${ADT_RUN_TEST_FAIL_CONFIG_WRITE:-}" ] || ! cp "$tpl" "$ct" 2>/dev/null; then
    rm -f "$ct" 2>/dev/null
    init_fail "cannot copy $tpl to $cfg"
  fi
  mv -n "$ct" "$cfg" 2>/dev/null
  if [ -e "$ct" ] || [ -L "$ct" ]; then
    rm -f "$ct" 2>/dev/null
    if [ -e "$cfg" ] || [ -L "$cfg" ]; then
      echo "ADT_INIT status=exists"
      exit 0
    fi
    init_fail "cannot move the config into place: $cfg"
  fi
  [ -e "$cfg" ] || init_fail "the config disappeared after the move: $cfg"
  echo "ADT_INIT status=created"
  echo "created .agentic-dev-team/config.yaml (git-ignored; see its header to share it)"
  exit 0
}

# ---------- arguments ----------

SELF_REAL=""
MODE=""
CHECK_RUNNER=""
RUNNER=""
ACCESS=""
PROJECT_ROOT=""
PROMPT_FILE=""
OUT=""
MODEL=""
HAVE_MODEL=0
TIMEOUT_SECONDS=1800
COMMAND_TEXT=""
HAVE_COMMAND=0
COMMAND_FILE=""
CHECK_PROGRAM=""
ALLOW_READ=()
GUARD_PATHS=()
DETACH=0
CHILD=0
WAIT_FILES=()
MAX_SECONDS=60
HASH_FILE=""
CANCEL_DIR=""
ORIG_ARGS=("$@")

adt_usage() {
  adt_note "$*"
  echo "ADT_RUN status=usage"
  echo "ADT_RUN code=2"
  echo "ADT_RUN note=$*"
  exit 2
}

adt_set_mode() {
  [ -z "$MODE" ] || adt_usage "only one mode is allowed (got --$MODE and $1)"
  MODE="${1#--}"
}

adt_need_abs() { # <option> <value>
  case "$2" in
    /*) ;;
    '') adt_usage "$1 needs a value" ;;
    *) adt_usage "$1 needs an absolute path, got: $2" ;;
  esac
}

case "${1:-}" in
  --init-config)
    [ "$#" -le 2 ] || { echo "ADT_INIT status=failed"; adt_note "--init-config takes one argument"; exit 1; }
    adt_init_config "${2:-}"
    ;;
  --identity)
    adt_proc_identity "${2:-}"
    exit 0
    ;;
esac

while [ "$#" -gt 0 ]; do
  opt="$1"
  case "$opt" in
    --detach) DETACH=1; shift; continue ;;
    --child) CHILD=1; shift; continue ;;
    --snapshot) adt_set_mode "$opt"; shift; continue ;;
    --wait)
      adt_set_mode "$opt"; shift
      while [ "$#" -gt 0 ]; do
        case "$1" in --*) break ;; esac
        WAIT_FILES+=("$1"); shift
      done
      continue
      ;;
  esac
  [ "$#" -ge 2 ] || adt_usage "$opt needs a value"
  val="$2"
  shift 2
  case "$opt" in
    --check) adt_set_mode "$opt"; CHECK_RUNNER="$val" ;;
    --runner) adt_set_mode "$opt"; RUNNER="$val" ;;
    --hash) adt_set_mode "$opt"; HASH_FILE="$val" ;;
    --cancel) adt_set_mode "$opt"; CANCEL_DIR="$val" ;;
    --access) ACCESS="$val" ;;
    --project-root) PROJECT_ROOT="$val" ;;
    --prompt-file) PROMPT_FILE="$val" ;;
    --output-file) OUT="$val" ;;
    --model) MODEL="$val"; HAVE_MODEL=1 ;;
    --timeout-minutes)
      adt_is_uint "$val" && [ "$val" -ge 1 ] || adt_usage "--timeout-minutes needs a whole number >= 1"
      TIMEOUT_SECONDS=$((val * 60)) ;;
    --timeout-seconds)
      adt_is_uint "$val" && [ "$val" -ge 1 ] || adt_usage "--timeout-seconds needs a whole number >= 1"
      TIMEOUT_SECONDS="$val" ;;
    --command) COMMAND_TEXT="$val"; HAVE_COMMAND=1 ;;
    --command-file) COMMAND_FILE="$val" ;;
    --check-program) CHECK_PROGRAM="$val" ;;
    --allow-read) ALLOW_READ+=("$val") ;;
    --guard-path) GUARD_PATHS+=("$val") ;;
    --max-seconds)
      adt_is_uint "$val" && [ "$val" -ge 1 ] || adt_usage "--max-seconds needs a whole number >= 1"
      MAX_SECONDS="$val"
      [ "$MAX_SECONDS" -le 300 ] || MAX_SECONDS=300 ;;
    *) adt_usage "unknown option: $opt" ;;
  esac
done

[ -n "$MODE" ] || adt_usage "no mode given (see the header of adt-run-agent.sh)"

SELF_REAL=$(adt_physical_path "${BASH_SOURCE[0]}") || adt_usage "cannot resolve the path of adt-run-agent.sh"

# ---------- markers ----------

MARKERS=(
  "✅ ARCHITECT DONE"
  "✅ CODER DONE"
  "✅ TESTER DONE"
  "⛔ TESTER BLOCKED"
  "✅ PLAN APPROVED"
  "🔧 PLAN CHANGES REQUESTED"
  "✅ CODE APPROVED"
  "🔧 CODE CHANGES REQUESTED"
)

# Print "<marker index><TAB><line>" for each marker line of a file.
adt_marker_lines() (
  export LC_ALL=C
  fe0f=$'\xef\xb8\x8f'
  cr=$'\r'
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$fe0f/}"
    line="${line%"$cr"}"
    rest="$line"
    case "$rest" in '#'*)
      while :; do
        case "$rest" in '#'*|' '*) rest="${rest#?}" ;; *) break ;; esac
      done ;;
    esac
    case "$rest" in '**'*|'__'*) rest="${rest#??}" ;; esac
    case "$rest" in
      [Vv][Ee][Rr][Dd][Ii][Cc][Tt]:*)
        rest="${rest#????????}"
        case "$rest" in '**'*|'__'*) rest="${rest#??}" ;; esac
        while :; do
          case "$rest" in ' '*) rest="${rest#?}" ;; *) break ;; esac
        done
        case "$rest" in '**'*|'__'*) rest="${rest#??}" ;; esac
        ;;
    esac
    i=0
    for m in "${MARKERS[@]}"; do
      case "$rest" in "$m"*) printf '%s\t%s\n' "$i" "$line"; break ;; esac
      i=$((i + 1))
    done
  done < "$1"
)

# Sets MK_STATE (none|one|conflict), MK_LINE (last marker line) and MK_ALL.
adt_find_marker() {
  local first="" idx line
  MK_STATE=none; MK_LINE=""; MK_ALL=""
  [ -f "$1" ] || return 0
  MK_ALL=$(adt_marker_lines "$1")
  [ -n "$MK_ALL" ] || return 0
  MK_STATE=one
  while IFS="$(printf '\t')" read -r idx line; do
    [ -n "$first" ] || first="$idx"
    [ "$idx" = "$first" ] || MK_STATE=conflict
    MK_LINE="$line"
  done <<EOF
$MK_ALL
EOF
  [ "$MK_STATE" = one ] || MK_LINE=""
}

# ---------- command template (no shell ever runs it) ----------

TPL_WORDS=()
adt_split_words() {
  local t="$1" i=0 n c cur="" inword=0 inq=0
  TPL_WORDS=()
  n=${#t}
  while [ "$i" -lt "$n" ]; do
    c="${t:$i:1}"
    if [ "$inq" = 1 ]; then
      if [ "$c" = '"' ]; then inq=0; else cur="$cur$c"; fi
    else
      case "$c" in
        '"') inq=1; inword=1 ;;
        ' '|"$(printf '\t')")
          if [ "$inword" = 1 ]; then TPL_WORDS+=("$cur"); cur=""; inword=0; fi ;;
        *) cur="$cur$c"; inword=1 ;;
      esac
    fi
    i=$((i + 1))
  done
  [ "$inword" = 1 ] && TPL_WORDS+=("$cur")
  return 0
}

adt_is_assignment() {
  case "$1" in
    [A-Za-z_]*=*) ;;
    *) return 1 ;;
  esac
  local name="${1%%=*}"
  case "$name" in *[!A-Za-z0-9_]*) return 1 ;; esac
  return 0
}

CHECK_RE='^([A-Za-z0-9_+][A-Za-z0-9._+-]*|/[A-Za-z0-9._/+-]+)$'

# Template check: prints the broken rule and fails, or succeeds.
# Args: <template> <check program> <has model: 0|1>
adt_template_check() {
  local t="$1" check="$2" has_model="$3" q w name prog base i=0
  local nl=$'\n' cr=$'\r'
  if [[ ! $check =~ $CHECK_RE ]]; then
    echo "check '$check' must be a bare program name or an absolute path (no spaces, \$, ~ or quotes)"; return 1
  fi
  case "$t" in
    *"'"*) echo "the command template must not contain a single quote (')"; return 1 ;;
    *'\'*) echo "the command template must not contain a backslash (\\)"; return 1 ;;
    *'`'*) echo "the command template must not contain a backtick"; return 1 ;;
    *'$'*) echo "the command template must not contain \$ (no shell runs it)"; return 1 ;;
    *"$nl"*|*"$cr"*) echo "the command template must be a single line"; return 1 ;;
    *'|'*|*';'*|*'&'*|*'<'*|*'>'*) echo "the command template must not contain | ; & < > (no shell runs it)"; return 1 ;;
  esac
  q="${t//[!\"]/}"
  [ $(( ${#q} % 2 )) -eq 0 ] || { echo "the command template has unbalanced double quotes"; return 1; }
  case "$t" in
    *'{instruction}'*|*'{prompt_file}'*) ;;
    *) echo "the command template needs {instruction} or {prompt_file}"; return 1 ;;
  esac
  case "$t" in
    *'{model}'*) [ "$has_model" = 1 ] || { echo "the command template uses {model} but the slot sets no model"; return 1; } ;;
  esac
  adt_split_words "$t"
  prog=""
  while [ "$i" -lt "${#TPL_WORDS[@]}" ]; do
    w="${TPL_WORDS[$i]}"
    if adt_is_assignment "$w"; then
      name="${w%%=*}"
      case "$name" in
        PATH|BASH_ENV|ENV|IFS|LD_*|DYLD_*)
          echo "the command template must not assign $name"; return 1 ;;
      esac
    else
      prog="$w"; break
    fi
    i=$((i + 1))
  done
  [ -n "$prog" ] || { echo "the command template has no program word"; return 1; }
  [ "$prog" = "$check" ] || { echo "the program word of the command template ($prog) must be exactly the check value ($check)"; return 1; }
  base="${prog##*/}"
  case "$base" in
    sh|bash|rbash|zsh|dash|ksh|mksh|ash|fish|csh|tcsh|pwsh|powershell|busybox|env|sudo|su|ssh)
      echo "the program of the command template must not be a shell or command runner ($base)"; return 1 ;;
  esac
  return 0
}

# Replace the placeholders of one word, in one pass (a value is never re-scanned).
adt_subst() {
  local s="$1" out="" pre
  while :; do
    case "$s" in *'{'*) ;; *) out="$out$s"; break ;; esac
    pre="${s%%\{*}"
    out="$out$pre"
    s="${s:${#pre}}"
    case "$s" in
      '{instruction}'*) out="$out$V_INSTRUCTION"; s="${s:13}" ;;
      '{prompt_file}'*) out="$out$PROMPT_FILE"; s="${s:13}" ;;
      '{output_file}'*) out="$out$OUT"; s="${s:13}" ;;
      '{model}'*) out="$out$MODEL"; s="${s:7}" ;;
      *) out="$out{"; s="${s:1}" ;;
    esac
  done
  printf '%s' "$out"
}

# Absolute path of a program, with the same lookup that preflight uses.
adt_find_program() {
  local p
  case "$1" in
    */*) [ -f "$1" ] && [ -x "$1" ] && { printf '%s\n' "$1"; return 0; }; return 1 ;;
  esac
  p=$(type -P "$1" 2>/dev/null) || return 1
  [ -n "$p" ] || return 1
  case "$p" in /*) ;; *) p="$(pwd -P)/$p" ;; esac
  printf '%s\n' "$p"
}

adt_load_template() {
  if [ -n "$COMMAND_FILE" ]; then
    adt_need_abs --command-file "$COMMAND_FILE"
    [ -f "$COMMAND_FILE" ] && [ -r "$COMMAND_FILE" ] || adt_usage "command file not found: $COMMAND_FILE"
    COMMAND_TEXT=$(cat "$COMMAND_FILE")
    HAVE_COMMAND=1
  fi
  [ "$HAVE_COMMAND" = 1 ] || adt_usage "runner command needs --command-file (or --command)"
  [ -n "$CHECK_PROGRAM" ] || adt_usage "runner command needs --check-program"
  local msg
  msg=$(adt_template_check "$COMMAND_TEXT" "$CHECK_PROGRAM" "$HAVE_MODEL") || adt_usage "$msg"
}

# ---------- --check ----------

adt_program_of_runner() {
  case "$1" in
    claude|codex|agy|opencode) printf '%s\n' "$1" ;;
    command) printf '%s\n' "$CHECK_PROGRAM" ;;
    *) return 1 ;;
  esac
}

if [ "$MODE" = check ]; then
  case "$CHECK_RUNNER" in
    claude|codex|agy|opencode) ;;
    command) adt_load_template ;;
    *) adt_usage "--check needs claude, codex, agy, opencode or command, got: $CHECK_RUNNER" ;;
  esac
  prog=$(adt_program_of_runner "$CHECK_RUNNER")
  if found=$(adt_find_program "$prog"); then
    echo "ADT_RUN check=ok runner=$CHECK_RUNNER program=$found"
    exit 0
  fi
  echo "ADT_RUN check=missing-runner runner=$CHECK_RUNNER program=$prog"
  adt_note "$prog is not installed or not on PATH"
  exit 3
fi

# ---------- --hash ----------

if [ "$MODE" = hash ]; then
  adt_hash "$HASH_FILE" || exit 2
  exit 0
fi

# ---------- --snapshot ----------

EXCLUDES=(
  ':(top,exclude,glob)**/.gradle/**'
  ':(top,exclude,glob)**/.kotlin/**'
  ':(top,exclude,glob)**/.idea/**'
  ':(top,exclude,glob)**/.cxx/**'
  ':(top,exclude,glob)**/*.salive'
)

adt_git() {
  GIT_OPTIONAL_LOCKS=0 git -C "$PROJECT_ROOT" -c diff.relative=false -c core.quotePath=false "$@"
}

# Hash a NUL-separated path list into the snapshot text.
# Args: <list file> <path prefix, "" when the list holds absolute paths> <work dir> <snapshot file> <tag>
adt_snap_paths() {
  local list="$1" prefix="$2" w="$3" s="$4" tag="$5" f p t h n c1 c2
  { : > "$w/batch" && : > "$w/names"; } || { SNAP_FAIL="write $w"; return 1; }
  while IFS= read -r -d '' f; do
    case "$f" in */) printf 'nested-repo %s\n' "$f" >> "$s"; continue ;; esac
    p="$prefix$f"
    if [ -L "$p" ]; then
      t=$(readlink "$p") || { SNAP_FAIL="readlink $p"; return 1; }
      h=$(printf '%s' "$t" | adt_git hash-object --stdin) || { SNAP_FAIL="git hash-object --stdin (link $p)"; return 1; }
      printf '%s-link %s %s\n' "$tag" "$h" "$f" >> "$s"
    elif [ -f "$p" ]; then
      case "$f" in
        *$'\n'*)
          h=$(adt_git hash-object --no-filters -- "$p") || { SNAP_FAIL="git hash-object --no-filters -- $p"; return 1; }
          printf '%s-file %s %s\n' "$tag" "$h" "$f" >> "$s" ;;
        *)
          printf '%s\n' "$p" >> "$w/batch"
          printf '%s\n' "$f" >> "$w/names" ;;
      esac
    elif [ -e "$p" ]; then
      printf '%s-other %s\n' "$tag" "$f" >> "$s"
    else
      SNAP_FAIL="file vanished during the snapshot: $p"; return 1
    fi
  done < "$list"
  [ -s "$w/batch" ] || return 0
  adt_git hash-object --no-filters --stdin-paths < "$w/batch" > "$w/hashes" ||
    { SNAP_FAIL="git hash-object --no-filters --stdin-paths"; return 1; }
  c1=$(wc -l < "$w/hashes"); c2=$(wc -l < "$w/names")
  [ "$c1" -eq "$c2" ] || { SNAP_FAIL="git hash-object --stdin-paths returned $c1 hashes for $c2 files"; return 1; }
  while IFS= read -r h <&3 && IFS= read -r n <&4; do
    printf '%s-file %s %s\n' "$tag" "$h" "$n" >> "$s"
  done 3< "$w/hashes" 4< "$w/names"
  return 0
}

adt_snapshot_once() {
  local w="$1" s="$1/snap" top head sym rc g
  SNAP_FAIL=""
  : > "$s" || { SNAP_FAIL="write $s"; return 1; }
  top=$(adt_git rev-parse --show-toplevel) || { SNAP_FAIL="git rev-parse --show-toplevel"; return 1; }
  head=$(adt_git rev-parse -q --verify HEAD); rc=$?
  [ "$rc" -le 1 ] || { SNAP_FAIL="git rev-parse -q --verify HEAD (exit $rc)"; return 1; }
  sym=$(adt_git symbolic-ref -q HEAD); rc=$?
  [ "$rc" -le 1 ] || { SNAP_FAIL="git symbolic-ref -q HEAD (exit $rc)"; return 1; }
  printf 'head %s\nref %s\n== worktree\n' "$head" "$sym" >> "$s"
  if [ -n "$head" ]; then
    adt_git diff HEAD --binary --no-color --no-ext-diff --no-textconv -- ':/' "${EXCLUDES[@]}" >> "$s" ||
      { SNAP_FAIL="git diff HEAD --binary"; return 1; }
  else
    adt_git diff --binary --no-color --no-ext-diff --no-textconv -- ':/' "${EXCLUDES[@]}" >> "$s" ||
      { SNAP_FAIL="git diff --binary"; return 1; }
  fi
  printf '== index\n' >> "$s"
  adt_git diff --cached --binary --no-color --no-ext-diff --no-textconv -- ':/' "${EXCLUDES[@]}" >> "$s" ||
    { SNAP_FAIL="git diff --cached --binary"; return 1; }
  printf '== untracked\n' >> "$s"
  adt_git ls-files -o --exclude-standard -z --full-name -- ':/' "${EXCLUDES[@]}" > "$w/untracked" ||
    { SNAP_FAIL="git ls-files -o --exclude-standard"; return 1; }
  adt_snap_paths "$w/untracked" "$top/" "$w" "$s" u || return 1
  for g in "${ABS_GUARDS[@]}"; do
    printf '== guard %s\n' "$g" >> "$s"
    if [ -L "$g" ] || [ ! -d "$g" ]; then
      printf '%s\0' "$g" > "$w/guard"
    else
      find "$g" \( -type f -o -type l \) -print0 > "$w/guard.raw" || { SNAP_FAIL="find $g"; return 1; }
      LC_ALL=C sort -z < "$w/guard.raw" > "$w/guard" || { SNAP_FAIL="sort -z"; return 1; }
    fi
    adt_snap_paths "$w/guard" "" "$w" "$s" g || return 1
  done
  git hash-object --stdin < "$s" > "$w/hash" || { SNAP_FAIL="git hash-object --stdin"; return 1; }
}

if [ "$MODE" = snapshot ]; then
  adt_need_abs --project-root "$PROJECT_ROOT"
  [ -d "$PROJECT_ROOT" ] || adt_usage "project root is not a directory: $PROJECT_ROOT"
  ABS_GUARDS=()
  for g in "${GUARD_PATHS[@]}"; do
    case "$g" in /*) ;; *) g="$PROJECT_ROOT/$g" ;; esac
    [ -e "$g" ] || [ -L "$g" ] || adt_usage "guard path not found: $g"
    ABS_GUARDS+=("$g")
  done
  SNAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/adt-snapshot.XXXXXX") || adt_usage "cannot create a temp directory"
  trap 'rm -rf "$SNAP_DIR"' EXIT
  if adt_snapshot_once "$SNAP_DIR" 2>/dev/null; then
    cat "$SNAP_DIR/hash"; exit 0
  fi
  sleep 1
  if adt_snapshot_once "$SNAP_DIR"; then
    cat "$SNAP_DIR/hash"; exit 0
  fi
  adt_usage "snapshot failed: $SNAP_FAIL"
fi

# ---------- lost and cancelled runs ----------

# Stop the runs of the given output files together (6.2 step 10.5).
adt_stop_runs() {
  local o
  for o in "$@"; do : > "$o.cancel" 2>/dev/null; done
  SG_PIDS=(); SG_IDS=()
  for o in "$@"; do
    adt_read_pidfile "$o.pid" && { SG_PIDS+=("$RP_PID"); SG_IDS+=("$RP_ID"); }
  done
  adt_stop_groups
  SG_PIDS=(); SG_IDS=()
  for o in "$@"; do
    adt_read_pidfile "$o.clipid" && { SG_PIDS+=("$RP_PID"); SG_IDS+=("$RP_ID"); }
  done
  adt_stop_groups
}

# Write O.status for a run that the script did not finish itself.
# Args: <O> <status> <code>
adt_write_other_status() {
  local o="$1" secs="-"
  [ -f "$o.elapsed" ] && secs=$(cat "$o.elapsed" 2>/dev/null)
  {
    echo "ADT_RUN status=$2 runner=- exit=-"
    echo "ADT_RUN marker="
    echo "ADT_RUN output=$o log=$o.log seconds=${secs:--}"
    echo "ADT_RUN code=$3"
    echo "ADT_RUN sha="
  } > "$o.status.tmp" && mv -f "$o.status.tmp" "$o.status"
}

# ---------- --cancel ----------

if [ "$MODE" = cancel ]; then
  adt_need_abs --cancel "$CANCEL_DIR"
  STOP=()
  for p in "$CANCEL_DIR"/jobs/*.pid; do
    [ -f "$p" ] || continue
    o="${p%.pid}"
    [ -e "$o.status" ] || STOP+=("$o")
  done
  [ "${#STOP[@]}" -gt 0 ] || exit 0
  adt_stop_runs "${STOP[@]}"
  for o in "${STOP[@]}"; do
    [ -e "$o.status" ] && continue
    adt_write_other_status "$o" cancelled 14
    echo "ADT_RUN status=cancelled output=$o"
  done
  exit 0
fi

# ---------- --wait ----------

if [ "$MODE" = wait ]; then
  [ "${#WAIT_FILES[@]}" -gt 0 ] || adt_usage "--wait needs at least one output file"
  for o in "${WAIT_FILES[@]}"; do adt_need_abs --wait "$o"; done
  n=${#WAIT_FILES[@]}
  RESULT=(); LAST_EL=(); SAME=(); SEEN=()
  i=0
  while [ "$i" -lt "$n" ]; do RESULT[$i]=""; LAST_EL[$i]=""; SAME[$i]=0; SEEN[$i]=0; i=$((i + 1)); done
  started=$(date +%s)
  iter=0
  while :; do
    LOST=(); LOST_I=()
    i=0
    while [ "$i" -lt "$n" ]; do
      o="${WAIT_FILES[$i]}"
      if [ -n "${RESULT[$i]}" ]; then i=$((i + 1)); continue; fi
      if [ -f "$o.status" ]; then
        RESULT[$i]=$(cat "$o.status")
      elif [ ! -f "$o.pid" ]; then
        RESULT[$i]="ADT_RUN status=not-started output=$o
ADT_RUN code=12
ADT_RUN note=no O.pid: the run never started (the --detach call may have been stopped before it wrote O.pid, or the path is wrong)"
      elif ! adt_read_pidfile "$o.pid" || ! adt_alive "$RP_PID" "$RP_ID"; then
        if [ -f "$o.status" ]; then RESULT[$i]=$(cat "$o.status"); else LOST+=("$o"); LOST_I+=("$i"); fi
      else
        el="missing"
        [ -f "$o.elapsed" ] && el=$(cat "$o.elapsed" 2>/dev/null)
        [ -n "$el" ] || el="missing"
        if [ "${SEEN[$i]}" = 1 ] && [ "$el" = "${LAST_EL[$i]}" ]; then
          SAME[$i]=$(( ${SAME[$i]} + 1 ))
        else
          SAME[$i]=0
        fi
        SEEN[$i]=1
        LAST_EL[$i]="$el"
        over=0
        if adt_is_uint "$el" && adt_is_uint "$RP_SECONDS" && [ "$el" -gt $((RP_SECONDS + 120)) ]; then over=1; fi
        if [ "${SAME[$i]}" -ge 30 ] || [ "$over" = 1 ]; then LOST+=("$o"); LOST_I+=("$i"); fi
      fi
      i=$((i + 1))
    done
    if [ "${#LOST[@]}" -gt 0 ]; then
      adt_stop_runs "${LOST[@]}"
      j=0
      while [ "$j" -lt "${#LOST[@]}" ]; do
        o="${LOST[$j]}"
        [ -f "$o.status" ] || adt_write_other_status "$o" lost 11
        RESULT[${LOST_I[$j]}]=$(cat "$o.status")
        j=$((j + 1))
      done
    fi
    alldone=1
    i=0
    while [ "$i" -lt "$n" ]; do [ -n "${RESULT[$i]}" ] || alldone=0; i=$((i + 1)); done
    [ "$alldone" = 1 ] && break
    [ "$iter" -lt "$MAX_SECONDS" ] || break
    [ $(( $(date +%s) - started )) -lt "$MAX_SECONDS" ] || break
    sleep 1
    iter=$((iter + 1))
  done
  rc=0; last=0
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ -n "${RESULT[$i]}" ]; then
      printf '%s\n' "${RESULT[$i]}"
      code=$(printf '%s\n' "${RESULT[$i]}" | sed -n 's/^ADT_RUN code=//p' | tail -n 1)
      adt_is_uint "$code" || code=11
      last="$code"
    else
      echo "ADT_RUN status=running output=${WAIT_FILES[$i]}"
      rc=10; last=10
    fi
    i=$((i + 1))
  done
  [ "$n" -eq 1 ] && exit "$last"
  exit "$rc"
fi

# ---------- --runner ----------

[ "$MODE" = runner ] || adt_usage "unknown mode: $MODE"
case "$RUNNER" in
  claude|codex|agy|opencode|command) ;;
  *) adt_usage "--runner needs claude, codex, agy, opencode or command, got: $RUNNER" ;;
esac
case "$ACCESS" in
  read-only|write) ;;
  *) adt_usage "--access needs read-only or write, got: $ACCESS" ;;
esac
adt_need_abs --project-root "$PROJECT_ROOT"
adt_need_abs --prompt-file "$PROMPT_FILE"
adt_need_abs --output-file "$OUT"
for a in "${ALLOW_READ[@]}"; do adt_need_abs --allow-read "$a"; done
[ -d "$PROJECT_ROOT" ] || adt_usage "project root is not a directory: $PROJECT_ROOT"
[ -f "$PROMPT_FILE" ] || adt_usage "prompt file not found: $PROMPT_FILE"
[ "$RUNNER" = command ] && adt_load_template
mkdir -p "$(dirname "$OUT")" 2>/dev/null || adt_usage "cannot create the directory of $OUT"
cd "$PROJECT_ROOT" || adt_usage "cannot enter the project root: $PROJECT_ROOT"
git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1 ||
  adt_usage "the project root is not inside a git work tree: $PROJECT_ROOT"
git -C "$PROJECT_ROOT" check-ignore -q -- "$OUT" 2>/dev/null ||
  adt_usage "the output file is not git-ignored: $OUT"
git -C "$PROJECT_ROOT" check-ignore -q -- "$OUT.log" 2>/dev/null ||
  adt_usage "the log file is not git-ignored: $OUT.log"

# --allow-read gives --add-dir for claude only (6.2 step 4).
DIRS=()
if [ "$RUNNER" = claude ]; then
  for a in "${ALLOW_READ[@]}"; do
    d=$(adt_physical_path "$a") || adt_usage "cannot resolve --allow-read $a"
    [ -d "$d" ] || d=$(dirname "$d")
    DIRS+=("$d")
  done
  top=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)
  top=$(adt_physical_path "$top") || adt_usage "cannot resolve the git top-level"
  root=$(adt_physical_path "$PROJECT_ROOT") || adt_usage "cannot resolve the project root"
  [ "$top" = "$root" ] || DIRS+=("$top")
fi

if [ "$CHILD" = 1 ]; then
  # The job owns O only when the --detach parent wrote its pid into O.pid.
  t=0
  while [ ! -f "$OUT.pid" ] && [ "$t" -lt 150 ]; do sleep 0.2; t=$((t + 1)); done
  adt_read_pidfile "$OUT.pid" || exit 0
  [ "$RP_PID" = "$$" ] || exit 0
else
  if adt_read_pidfile "$OUT.pid" && adt_alive "$RP_PID" "$RP_ID"; then
    adt_usage "another run still uses this output file: $OUT"
  fi
  for s in "" .log .status .status.tmp .pid .pid.tmp .clipid .clipid.tmp .cancel .timedout .elapsed .elapsed.tmp; do
    rm -f "$OUT$s" 2>/dev/null
  done
fi

V_INSTRUCTION="Read the file $PROMPT_FILE in full and follow its instructions exactly. It is your complete task for this run. No human will answer questions during this run."

adt_write_status() { # <status> <exit> <marker> <seconds> <code>
  local sha=""
  [ -f "$OUT" ] && sha=$(adt_hash "$OUT" 2>/dev/null)
  {
    echo "ADT_RUN status=$1 runner=$RUNNER exit=$2"
    echo "ADT_RUN marker=$3"
    echo "ADT_RUN output=$OUT log=$OUT.log seconds=$4"
    echo "ADT_RUN code=$5"
    echo "ADT_RUN sha=$sha"
  } > "$OUT.status.tmp" && mv -f "$OUT.status.tmp" "$OUT.status"
  cat "$OUT.status" 2>/dev/null
}

# The CLI must be installed.
PROGRAM=$(adt_program_of_runner "$RUNNER")
if ! PROGRAM_PATH=$(adt_find_program "$PROGRAM"); then
  adt_note "$PROGRAM is not installed or not on PATH"
  adt_write_status missing-runner - "" 0 3
  exit 3
fi

# ---------- --detach: start the job in its own process group ----------

if [ "$DETACH" = 1 ] && [ "$CHILD" = 0 ]; then
  ARGS=()
  for a in "${ORIG_ARGS[@]}"; do
    [ "$a" = --detach ] || ARGS+=("$a")
  done
  set -m
  nohup bash "$SELF_REAL" --child "${ARGS[@]}" < /dev/null > /dev/null 2>&1 &
  JOB=$!
  set +m
  if ! { [ -z "${ADT_RUN_TEST_FAIL_PID_WRITE:-}" ] &&
         { echo "$JOB $TIMEOUT_SECONDS"; adt_proc_identity "$JOB"; } > "$OUT.pid.tmp" &&
         mv -f "$OUT.pid.tmp" "$OUT.pid"; } 2>/dev/null; then
    rm -f "$OUT.pid.tmp" 2>/dev/null
    kill -TERM -- "-$JOB" 2>/dev/null
    t=0
    while [ "$t" -lt 10 ] && kill -0 -- "-$JOB" 2>/dev/null; do sleep 0.5; t=$((t + 1)); done
    kill -KILL -- "-$JOB" 2>/dev/null
    adt_note "could not write $OUT.pid; the run was not started"
    adt_write_status not-started - "" 0 12
    exit 12
  fi
  echo "ADT_RUN status=started output=$OUT"
  exit 0
fi

# ---------- the job ----------

{ echo 0 > "$OUT.elapsed.tmp" && mv -f "$OUT.elapsed.tmp" "$OUT.elapsed"; } 2>/dev/null

# Build the CLI command (6.3, 6.4).
CMD=()
OUT_TO="$OUT"
case "$RUNNER" in
  claude)
    if [ "$ACCESS" = read-only ]; then
      CMD=(env -u CLAUDECODE claude -p "$V_INSTRUCTION" --output-format text
           --permission-mode dontAsk
           --allowedTools "Read,Glob,Grep,Skill,Bash(git status:*),Bash(git diff:*),Bash(git ls-files:*),Bash(git log:*),Bash(git show:*)"
           --disallowedTools "Bash(*--output*)")
    else
      CMD=(env -u CLAUDECODE claude -p "$V_INSTRUCTION" --output-format text
           --permission-mode acceptEdits
           --allowedTools "Read,Write,Edit,Glob,Grep,Skill,Bash,mcp__auto-mobile")
    fi
    [ "$HAVE_MODEL" = 1 ] && CMD+=(--model "$MODEL")
    for d in "${DIRS[@]}"; do CMD+=(--add-dir "$d"); done
    ;;
  codex)
    if [ "$ACCESS" = read-only ]; then sb=read-only; else sb=workspace-write; fi
    CMD=(codex exec --sandbox "$sb" --output-last-message "$OUT")
    [ "$HAVE_MODEL" = 1 ] && CMD+=(--model "$MODEL")
    CMD+=("$V_INSTRUCTION")
    OUT_TO="$OUT.log"
    ;;
  agy)
    CMD=(agy -p "$V_INSTRUCTION" --output-format text
         --print-timeout "$(( (TIMEOUT_SECONDS + 59) / 60 + 5 ))m"
         --dangerously-skip-permissions)
    [ "$ACCESS" = read-only ] && CMD+=(--sandbox)
    [ "$HAVE_MODEL" = 1 ] && CMD+=(--model "$MODEL")
    ;;
  opencode)
    CMD=(opencode run --auto)
    [ "$HAVE_MODEL" = 1 ] && CMD+=(--model "$MODEL")
    CMD+=("$V_INSTRUCTION")
    ;;
  command)
    adt_split_words "$COMMAND_TEXT"
    ENVS=(); ARGV=(); i=0; seen_prog=0
    while [ "$i" -lt "${#TPL_WORDS[@]}" ]; do
      w="${TPL_WORDS[$i]}"
      if [ "$seen_prog" = 0 ] && adt_is_assignment "$w"; then
        ENVS+=("${w%%=*}=$(adt_subst "${w#*=}")")
      elif [ "$seen_prog" = 0 ]; then
        seen_prog=1
      else
        ARGV+=("$(adt_subst "$w")")
      fi
      i=$((i + 1))
    done
    if [ "${#ENVS[@]}" -gt 0 ]; then
      CMD=(env "${ENVS[@]}" "$PROGRAM_PATH" "${ARGV[@]}")
    else
      CMD=("$PROGRAM_PATH" "${ARGV[@]}")
    fi
    case "$COMMAND_TEXT" in *'{output_file}'*) OUT_TO="$OUT.log" ;; esac
    ;;
esac

if [ -n "${ADT_RUN_TEST_HANG_BEFORE_CLI:-}" ]; then sleep "$ADT_RUN_TEST_HANG_BEFORE_CLI"; fi

STARTED=$(date +%s)
WRAP='{ echo $$; bash "$2" --identity $$; } > "$1.clipid.tmp" && mv "$1.clipid.tmp" "$1.clipid" || exit 97; [ -e "$1.cancel" ] && exit 98; shift 2; exec "$@"'
set -m
if [ "$OUT_TO" = "$OUT.log" ]; then
  bash -c "$WRAP" _ "$OUT" "$SELF_REAL" "${CMD[@]}" < /dev/null >> "$OUT.log" 2>&1 &
else
  bash -c "$WRAP" _ "$OUT" "$SELF_REAL" "${CMD[@]}" < /dev/null > "$OUT" 2>> "$OUT.log" &
fi
CLI=$!
set +m

# Timeout watcher: counts awake seconds; stays in the job's process group.
(
  n=0
  while kill -0 "$CLI" 2>/dev/null; do
    sleep 1
    n=$((n + 1))
    if [ $((n % 5)) -eq 0 ] && [ -z "${ADT_RUN_TEST_STOP_WATCHER:-}" ]; then
      { echo "$n" > "$OUT.elapsed.tmp" && mv -f "$OUT.elapsed.tmp" "$OUT.elapsed"; } 2>/dev/null
    fi
    if [ "$n" -ge "$TIMEOUT_SECONDS" ] && [ ! -e "$OUT.timedout" ]; then
      : > "$OUT.timedout"
      kill -TERM -- "-$CLI" 2>/dev/null
      t=0
      while [ "$t" -lt 10 ] && kill -0 -- "-$CLI" 2>/dev/null; do sleep 0.5; t=$((t + 1)); done
      kill -KILL -- "-$CLI" 2>/dev/null
    fi
  done
) &
WATCH=$!

wait "$CLI"
RC=$?

# A read-only run leaves nothing behind that could change the tree later.
if [ "$ACCESS" = read-only ] && kill -0 -- "-$CLI" 2>/dev/null; then
  kill -TERM -- "-$CLI" 2>/dev/null
  t=0
  while [ "$t" -lt 10 ] && kill -0 -- "-$CLI" 2>/dev/null; do sleep 0.5; t=$((t + 1)); done
  kill -KILL -- "-$CLI" 2>/dev/null
fi
wait "$WATCH" 2>/dev/null
SECONDS_RUN=$(( $(date +%s) - STARTED ))

if { [ "$RC" = 97 ] && [ ! -e "$OUT.clipid" ]; } || { [ "$RC" = 98 ] && [ -e "$OUT.cancel" ]; }; then
  adt_write_status not-started - "" "$SECONDS_RUN" 12
  exit 12
fi
if [ -e "$OUT.timedout" ]; then
  adt_write_status timeout "$RC" "" "$SECONDS_RUN" 4
  exit 4
fi
if [ "$RC" != 0 ]; then
  adt_write_status failed "$RC" "" "$SECONDS_RUN" 5
  exit 5
fi
adt_find_marker "$OUT"
case "$MK_STATE" in
  conflict)
    {
      echo "agentic-dev-team: conflicting marker lines in $OUT:"
      printf '%s\n' "$MK_ALL" | cut -f 2-
    } >> "$OUT.log"
    adt_write_status conflicting-markers "$RC" "" "$SECONDS_RUN" 13
    exit 13 ;;
  none)
    adt_write_status no-marker "$RC" "" "$SECONDS_RUN" 6
    exit 6 ;;
esac
adt_write_status ok "$RC" "$MK_LINE" "$SECONDS_RUN" 0
exit 0
