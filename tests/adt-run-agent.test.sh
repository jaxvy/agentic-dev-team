#!/usr/bin/env bash
#
# Tests for plugins/agentic-dev-team/scripts/adt-run-agent.sh (runner modes).
# Plain bash, no framework. Run from anywhere:
#   bash tests/adt-run-agent.test.sh
# The lost-job cases wait for the 30-second stuck check, so a full run takes
# a few minutes.

# shellcheck disable=SC2009,SC2016,SC2086
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO_DIR/plugins/agentic-dev-team/scripts/adt-run-agent.sh"
REAL_GIT="$(command -v git)"
T="$(mktemp -d "${TMPDIR:-/tmp}/adt-run-test.XXXXXX")"
T="$(cd -P "$T" && pwd -P)"
PASS=0
FAIL=0
trap 'rm -rf "$T"' EXIT

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { # <description> <command...>
  local d="$1"; shift
  if "$@"; then pass; else fail "$d"; fi
}
eq() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass; else fail "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi
}
not() { ! "$@"; }
has_line() { printf '%s\n' "$2" | grep -qxF -- "$1"; }
field() { printf '%s\n' "$2" | sed -n "s/^ADT_RUN $1=//p" | head -n 1; }
# A process is gone when kill -0 fails or it is a zombie (this sandbox's
# PID 1 may not collect orphans).
gone() {
  kill -0 "$1" 2>/dev/null || return 0
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 0 ;; esac
  return 1
}
wait_for() { # <file> <seconds>
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt $(($2 * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# ---------- fake CLIs ----------

FAKEBIN="$T/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/fake-cli" <<'EOF'
#!/usr/bin/env bash
# Fake agent CLI: records its arguments and environment, prints an answer.
name=$(basename "$0")
[ -n "$FAKE_ARGS" ] && printf '%s\n' "$name" "$@" > "$FAKE_ARGS"
[ -n "$FAKE_ENV" ] && env > "$FAKE_ENV"
[ -n "$FAKE_STARTED" ] && echo "$$" > "$FAKE_STARTED"
if [ -n "$FAKE_CHILD" ]; then sleep 60 & echo "$!" > "$FAKE_CHILD"; fi
[ -n "$FAKE_SLEEP" ] && sleep "$FAKE_SLEEP"
[ -n "$FAKE_EDIT" ] && echo "edited" >> "$FAKE_EDIT"
answer=""
[ -n "$FAKE_ANSWER_FILE" ] && answer=$(cat "$FAKE_ANSWER_FILE")
if [ "$name" = codex ]; then
  out=""
  while [ "$#" -gt 0 ]; do
    [ "$1" = --output-last-message ] && out="$2"
    shift
  done
  printf '%s\n' "$answer" > "$out"
  echo "codex progress line"
else
  printf '%s\n' "$answer"
fi
echo "stderr line" >&2
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$FAKEBIN/fake-cli"
for n in claude codex agy opencode gemini; do ln -s fake-cli "$FAKEBIN/$n"; done
mkdir -p "$T/opt/bin"
ln -s "$FAKEBIN/fake-cli" "$T/opt/bin/gemini"
export PATH="$FAKEBIN:$PATH"
unset FAKE_ARGS FAKE_ENV FAKE_STARTED FAKE_CHILD FAKE_SLEEP FAKE_EDIT FAKE_ANSWER_FILE FAKE_EXIT

# New git repo with an ignored pipeline_artifacts/ and one commit.
new_repo() {
  local r="$1"
  mkdir -p "$r/pipeline_artifacts"
  "$REAL_GIT" -C "$r" init -q
  "$REAL_GIT" -C "$r" config user.email t@example.com
  "$REAL_GIT" -C "$r" config user.name t
  echo '*' > "$r/pipeline_artifacts/.gitignore"
  echo "one" > "$r/tracked.txt"
  "$REAL_GIT" -C "$r" add tracked.txt
  "$REAL_GIT" -C "$r" commit -q -m init
  echo "Do the task." > "$r/pipeline_artifacts/prompt.md"
}

R="$T/repo"
new_repo "$R"
P="$R/pipeline_artifacts/prompt.md"
J="$R/pipeline_artifacts/.runs/run1/jobs"
ANS="$T/answer.md"
answer() { printf '%s\n' "$@" > "$ANS"; }
INSTR="Read the file $P in full and follow its instructions exactly. It is your complete task for this run. No human will answer questions during this run."
RO_TOOLS="Read,Glob,Grep,Skill,Bash(git status:*),Bash(git diff:*),Bash(git ls-files:*),Bash(git log:*),Bash(git show:*)"

run() { # <runner> <access> <output> [extra args...]
  local r="$1" a="$2" o="$3"; shift 3
  bash "$S" --runner "$r" --access "$a" --project-root "$R" --prompt-file "$P" --output-file "$o" "$@" 2>/dev/null
}

# ---------- 1. exact arguments per runner and access ----------

answer "✅ CODE APPROVED"
export FAKE_ANSWER_FILE="$ANS" FAKE_ARGS="$T/args"
run claude read-only "$J/c1.out.md" --model opus > /dev/null
eq "1 claude read-only args" "$(printf '%s\n' claude -p "$INSTR" --output-format text --permission-mode dontAsk --allowedTools "$RO_TOOLS" --disallowedTools 'Bash(*--output*)' --model opus)" "$(cat "$T/args")"
run claude write "$J/c2.out.md" > /dev/null
eq "1 claude write args" "$(printf '%s\n' claude -p "$INSTR" --output-format text --permission-mode acceptEdits --allowedTools "Read,Write,Edit,Glob,Grep,Skill,Bash,mcp__auto-mobile")" "$(cat "$T/args")"
run codex read-only "$J/x1.out.md" --model gpt-5 > /dev/null
eq "1 codex read-only args" "$(printf '%s\n' codex exec --sandbox read-only --output-last-message "$J/x1.out.md" --model gpt-5 "$INSTR")" "$(cat "$T/args")"
run codex write "$J/x2.out.md" > /dev/null
eq "1 codex write args" "$(printf '%s\n' codex exec --sandbox workspace-write --output-last-message "$J/x2.out.md" "$INSTR")" "$(cat "$T/args")"
run agy read-only "$J/a1.out.md" --timeout-minutes 30 --model m1 > /dev/null
eq "1 agy read-only args" "$(printf '%s\n' agy -p "$INSTR" --output-format text --print-timeout 35m --dangerously-skip-permissions --sandbox --model m1)" "$(cat "$T/args")"
run agy write "$J/a2.out.md" --timeout-seconds 61 > /dev/null
eq "1 agy write args (ceil)" "$(printf '%s\n' agy -p "$INSTR" --output-format text --print-timeout 7m --dangerously-skip-permissions)" "$(cat "$T/args")"
run opencode read-only "$J/o1.out.md" --model anthropic/x > /dev/null
eq "1 opencode read-only args" "$(printf '%s\n' opencode run --auto --model anthropic/x "$INSTR")" "$(cat "$T/args")"
run opencode write "$J/o2.out.md" > /dev/null
eq "1 opencode write args" "$(printf '%s\n' opencode run --auto "$INSTR")" "$(cat "$T/args")"
run command read-only "$J/g1.out.md" --check-program gemini --command 'gemini -p {instruction} -m {model}' --model gm > /dev/null
eq "1 command args" "$(printf '%s\n' gemini -p "$INSTR" -m gm)" "$(cat "$T/args")"

# ---------- 2. --allow-read ----------

mkdir -p "$T/real dir" "$T/links"
echo persona > "$T/real dir/persona.md"
ln -s "$T/real dir/persona.md" "$T/links/persona.md"
mkdir -p "$T/docdir"
run claude read-only "$J/c3.out.md" --allow-read "$T/links/persona.md" --allow-read "$T/docdir" > /dev/null
eq "2 --add-dir with the real directory" "$(printf '%s\n' claude -p "$INSTR" --output-format text --permission-mode dontAsk --allowedTools "$RO_TOOLS" --disallowedTools 'Bash(*--output*)' --add-dir "$T/real dir" --add-dir "$T/docdir")" "$(cat "$T/args")"
run codex read-only "$J/x3.out.md" --allow-read "$T/links/persona.md" > /dev/null
check "2 codex ignores --allow-read" not grep -q -- --add-dir "$T/args"
# Project root below the git top-level: the top-level is added too.
mkdir -p "$R/sub/pipeline_artifacts"
echo '*' > "$R/sub/pipeline_artifacts/.gitignore"
echo "task" > "$R/sub/pipeline_artifacts/p.md"
bash "$S" --runner claude --access read-only --project-root "$R/sub" --prompt-file "$R/sub/pipeline_artifacts/p.md" --output-file "$R/sub/pipeline_artifacts/c.out.md" > /dev/null 2>&1
check "2 claude gets --add-dir <git top-level> for a subdirectory root" grep -qxF -- "$R" "$T/args"
rm -rf "$R/sub"

# ---------- 3. CLAUDECODE is removed ----------

export FAKE_ENV="$T/env"
CLAUDECODE=1 run claude read-only "$J/c4.out.md" > /dev/null
check "3 CLAUDECODE is not in the claude child's environment" not grep -q '^CLAUDECODE=' "$T/env"
CLAUDECODE=1 run agy read-only "$J/a4.out.md" > /dev/null
check "3 CLAUDECODE stays for other runners" grep -q '^CLAUDECODE=' "$T/env"
unset FAKE_ENV

# ---------- 4. where stdout goes ----------

answer "the answer" "✅ CODE APPROVED"
for r in claude agy opencode; do
  run "$r" read-only "$J/s-$r.out.md" > /dev/null
  eq "4 $r stdout goes to O" "$(cat "$ANS")" "$(cat "$J/s-$r.out.md")"
  check "4 $r stderr goes to O.log" grep -q "stderr line" "$J/s-$r.out.md.log"
done
run codex read-only "$J/s-codex.out.md" > /dev/null
eq "4 codex answer from --output-last-message" "$(cat "$ANS")" "$(cat "$J/s-codex.out.md")"
check "4 codex stdout goes to O.log" grep -q "codex progress line" "$J/s-codex.out.md.log"
run command read-only "$J/s-cmd.out.md" --check-program gemini --command 'gemini -p {instruction}' > /dev/null
eq "4 command without {output_file}: stdout to O" "$(cat "$ANS")" "$(cat "$J/s-cmd.out.md")"
run command read-only "$J/s-cmd2.out.md" --check-program gemini --command 'gemini -p {instruction} -o {output_file}' > /dev/null
check "4 command with {output_file}: stdout to O.log" grep -q "✅ CODE APPROVED" "$J/s-cmd2.out.md.log"

# ---------- 5. markers ----------

marker_case() { # <description> <expected status> <expected marker> <answer lines...>
  local d="$1" st="$2" mk="$3" out; shift 3
  answer "$@"
  out=$(run claude read-only "$J/m.out.md")
  eq "5 $d: status" "$st" "$(printf '%s\n' "$out" | sed -n 's/^ADT_RUN status=\([^ ]*\).*/\1/p')"
  [ -z "$mk" ] || eq "5 $d: marker" "$mk" "$(field marker "$out")"
}
marker_case "plain with summary" ok "✅ CODE APPROVED looks good" "Review." "✅ CODE APPROVED looks good"
marker_case "bold" ok "**✅ CODE APPROVED**" "**✅ CODE APPROVED**"
marker_case "heading" ok "## ✅ CODE APPROVED" "## ✅ CODE APPROVED"
marker_case "Verdict:" ok "Verdict: ✅ CODE APPROVED" "Verdict: ✅ CODE APPROVED"
marker_case "**Verdict:**" ok "**Verdict:** ✅ CODE APPROVED" "**Verdict:** ✅ CODE APPROVED"
marker_case "Verdict: **marker**" ok "Verdict: **✅ CODE APPROVED**" "Verdict: **✅ CODE APPROVED**"
marker_case "variation selector" ok "⛔ TESTER BLOCKED" "$(printf '\xe2\x9b\x94\xef\xb8\x8f TESTER BLOCKED')"
marker_case "changes requested with emoji list items" ok "🔧 CODE CHANGES REQUESTED" \
  "🔧 CODE CHANGES REQUESTED" "1. ✅ keep the test" "2. 🔧 fix the bug"
marker_case "unknown emoji line only" no-marker "" "✅ done"
marker_case "indented continuation line" ok "🔧 CODE CHANGES REQUESTED" \
  "🔧 CODE CHANGES REQUESTED" "1. fix X" "   ✅ CODE APPROVED only once X is fixed"
marker_case "backtick and quote lines" ok "🔧 CODE CHANGES REQUESTED" \
  "🔧 CODE CHANGES REQUESTED" '`✅ CODE APPROVED` must wait' "> ✅ PLAN APPROVED"
marker_case "bullet lines" ok "🔧 CODE CHANGES REQUESTED" \
  "🔧 CODE CHANGES REQUESTED" "* ✅ CODE APPROVED only after X" "- ✅ CODE APPROVED later" "+ ✅ PLAN APPROVED"
marker_case "conflicting markers" conflicting-markers "" "✅ CODE APPROVED" "🔧 CODE CHANGES REQUESTED"
check "5 conflicting lines are in O.log" grep -q "🔧 CODE CHANGES REQUESTED" "$J/m.out.md.log"
out=$(run claude read-only "$J/m.out.md"); eq "5 conflicting-markers exit code" 13 "$(field code "$out")"
marker_case "same marker twice" ok "✅ CODE APPROVED second" "✅ CODE APPROVED first" "✅ CODE APPROVED second"

# ---------- 6. result codes ----------

answer "no marker here"
run claude read-only "$J/r.out.md" > /dev/null; eq "6 no-marker exit" 6 "$?"
answer "✅ CODE APPROVED"
FAKE_EXIT=3 run claude read-only "$J/r.out.md" > /dev/null; eq "6 failed exit" 5 "$?"
out=$(FAKE_EXIT=3 run claude read-only "$J/r.out.md"); check "6 failed shows the CLI exit" has_line "ADT_RUN status=failed runner=claude exit=3" "$out"
bash "$S" --runner command --access read-only --project-root "$R" --prompt-file "$P" --output-file "$J/r.out.md" \
  --check-program nosuchprogram-adt --command 'nosuchprogram-adt -p {instruction}' > /dev/null 2>&1
eq "6 missing-runner exit" 3 "$?"
bash "$S" --runner claude --access read-only --project-root "$R" --prompt-file "$P" > /dev/null 2>&1
eq "6 usage: missing --output-file" 2 "$?"
bash "$S" --runner claude --access read-only --project-root "$R" --prompt-file "$P" --output-file "$R/notignored.md" > /dev/null 2>&1
eq "6 usage: output file not ignored" 2 "$?"
bash "$S" --runner claude --access read-only --project-root "$R" --prompt-file "$P" --output-file "pipeline_artifacts/rel.md" > /dev/null 2>&1
eq "6 usage: relative output path" 2 "$?"
bash "$S" --runner claude --access maybe --project-root "$R" --prompt-file "$P" --output-file "$J/r.out.md" > /dev/null 2>&1
eq "6 usage: bad --access" 2 "$?"
mkdir -p "$T/nogit"
bash "$S" --runner claude --access read-only --project-root "$T/nogit" --prompt-file "$P" --output-file "$T/nogit/o.md" > /dev/null 2>&1
eq "6 usage: not a git repo" 2 "$?"
check "6 usage leaves no O.status" test ! -e "$R/notignored.md.status"

# ---------- 7. timeout ----------

answer "✅ CODE APPROVED"
FAKE_STARTED="$T/t7.pid" FAKE_CHILD="$T/t7.child" FAKE_SLEEP=60 run claude read-only "$J/t.out.md" --timeout-seconds 2 > /dev/null
eq "7 timeout exit" 4 "$?"
check "7 O.timedout exists" test -e "$J/t.out.md.timedout"
check "7 CLI is gone" gone "$(cat "$T/t7.pid")"
check "7 CLI child is gone" gone "$(cat "$T/t7.child")"

# ---------- 8. a read-only run that edits still returns ok; snapshot sees it ----------

h1=$(bash "$S" --snapshot --project-root "$R")
FAKE_EDIT="$R/tracked.txt" run claude read-only "$J/e.out.md" > /dev/null
eq "8 editing read-only run returns ok" 0 "$?"
h2=$(bash "$S" --snapshot --project-root "$R")
check "8 snapshot changed" test "$h1" != "$h2"
"$REAL_GIT" -C "$R" checkout -q -- tracked.txt

# ---------- 9. command runner and template check ----------

TF="$T/tpl.txt"
tpl_check() { # <template> <check program> [--model M]
  local t="$1" c="$2"; shift 2
  printf '%s\n' "$t" > "$TF"
  bash "$S" --check command --check-program "$c" --command-file "$TF" "$@" > /dev/null 2>&1
}
for t in "gemini -p {instruction} 'x'" 'gemini -p {instruction} \x' 'gemini -p {instruction} `id`' \
         'gemini -p {instruction} $HOME' 'gemini -p {instruction} | cat' 'gemini -p {instruction}; id' \
         'gemini -p {instruction} & id' 'gemini -p {instruction} < x' 'gemini -p {instruction} > x' \
         'gemini -p "{instruction}' 'env GEMINI_API_KEY=x gemini -p {instruction}' \
         'timeout 900 gemini -p {instruction}' '/usr/bin/env -S "bash x" {instruction}' \
         'PATH=/tmp/x gemini -p {instruction}' 'LD_PRELOAD=x gemini -p {instruction}' \
         'DYLD_INSERT_LIBRARIES=x gemini -p {instruction}' 'gemini -p hello' 'gemini -p {instruction} -m {model}'; do
  tpl_check "$t" gemini; eq "9 template rejected: $t" 2 "$?"
done
printf 'gemini -p {instruction}\nid\n' > "$TF"
bash "$S" --check command --check-program gemini --command-file "$TF" > /dev/null 2>&1
eq "9 template rejected: newline" 2 "$?"
for c in bash sh env busybox ssh; do
  tpl_check "$c -c {instruction}" "$c"; eq "9 template rejected: program $c" 2 "$?"
done
tpl_check 'gemini -p {instruction} -m {model}' gemini --model gm; eq "9 accepted: {model} with --model" 0 "$?"
tpl_check 'gemini -p "Task: {instruction}"' gemini; eq "9 accepted: quoted placeholder" 0 "$?"
tpl_check 'codex exec {instruction}' codex; eq "9 accepted: codex" 0 "$?"
tpl_check 'GEMINI_API_KEY=x gemini -p {instruction}' gemini; eq "9 accepted: assignment" 0 "$?"
tpl_check 'SHELL=/bin/bash gemini -p {instruction}' gemini; eq "9 accepted: SHELL assignment" 0 "$?"
tpl_check '/opt/bin/gemini -p {instruction}' /opt/bin/gemini; eq "9 accepted: absolute program (missing, so 3)" 3 "$?"
tpl_check "$T/opt/bin/gemini -p {instruction}" "$T/opt/bin/gemini"; eq "9 accepted: absolute program" 0 "$?"
tpl_check 'gemini --flash -p {instruction} -c cfg' gemini; eq "9 accepted: flags" 0 "$?"
tpl_check 'gemini -p {prompt_file}' gemini; eq "9 accepted: {prompt_file} only" 0 "$?"
# Values reach the program unchanged, and nothing in them runs.
V='a b $(touch '"$T"'/pwned); * "q" `id` & x'
run command read-only "$J/v.out.md" --check-program gemini --command 'GEMINI_API_KEY={model} gemini -p "Task: {instruction}" -m {model}' --model "$V" > /dev/null
eq "9 values are single, unchanged arguments" "$(printf '%s\n' gemini -p "Task: $INSTR" -m "$V")" "$(cat "$T/args")"
check "9 nothing inside a value ran" test ! -e "$T/pwned"

# ---------- 10. --detach and --wait ----------

answer "✅ CODE APPROVED"
O="$J/d.out.md"
FAKE_SLEEP=4 run claude read-only "$O" --detach > "$T/d.txt"; rc=$?
eq "10 --detach exit" 0 "$rc"
check "10 --detach prints started" has_line "ADT_RUN status=started output=$O" "$(cat "$T/d.txt")"
bash "$S" --wait "$O" --max-seconds 1 > /dev/null; eq "10 --wait while running" 10 "$?"
bash "$S" --wait "$O" --max-seconds 30 > "$T/w.txt"; eq "10 --wait at the end" 0 "$?"
eq "10 O.status has five lines" 5 "$(wc -l < "$O.status" | tr -d ' ')"
start=$(date +%s)
bash "$S" --runner claude --access read-only --project-root "$R" --prompt-file "$P" --detach > /dev/null 2>&1
eq "10 usage error from --detach" 2 "$?"
check "10 usage error returns at once" test $(( $(date +%s) - start )) -le 2
O1="$J/w1.out.md"; O2="$J/w2.out.md"; O3="$J/w3.out.md"
printf 'nothing\n' > "$T/nothing.md"
FAKE_SLEEP=1 run claude read-only "$O1" --detach > /dev/null
FAKE_SLEEP=3 FAKE_EXIT=4 run claude read-only "$O2" --detach > /dev/null
FAKE_ANSWER_FILE="$T/nothing.md" FAKE_SLEEP=6 run claude read-only "$O3" --detach > /dev/null
sleep 2
out=$(bash "$S" --wait "$O1" "$O2" "$O3" --max-seconds 1); rc=$?
eq "10 multi-wait while one runs" 10 "$rc"
check "10 running block for the last file" has_line "ADT_RUN status=running output=$O3" "$out"
out=$(bash "$S" --wait "$O1" "$O2" "$O3" --max-seconds 30); rc=$?
eq "10 multi-wait when all are done" 0 "$rc"
eq "10 blocks in order" "$O1 $O2 $O3" "$(printf '%s\n' "$out" | sed -n 's/^ADT_RUN output=\([^ ]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
eq "10 codes per block" "0 5 6" "$(printf '%s\n' "$out" | sed -n 's/^ADT_RUN code=//p' | tr '\n' ' ' | sed 's/ $//')"
FAKE_CHILD="$T/c10r" run claude read-only "$J/k1.out.md" --detach > /dev/null
bash "$S" --wait "$J/k1.out.md" --max-seconds 30 > /dev/null
check "10 read-only run: child is gone after O.status" gone "$(cat "$T/c10r")"
FAKE_CHILD="$T/c10w" run claude write "$J/k2.out.md" --detach > /dev/null
bash "$S" --wait "$J/k2.out.md" --max-seconds 30 > /dev/null
check "10 write run: child still runs after O.status" not gone "$(cat "$T/c10w")"
kill "$(cat "$T/c10w")" 2>/dev/null

# ---------- 11. --check ----------

bash "$S" --check claude > /dev/null 2>&1; eq "11 --check present" 0 "$?"
PATH="/usr/bin:/bin" bash "$S" --check agy > /dev/null 2>&1; rc=$?
if PATH="/usr/bin:/bin" command -v agy > /dev/null; then pass; else eq "11 --check missing" 3 "$rc"; fi
bash "$S" --check native > /dev/null 2>&1; eq "11 --check native is a usage error" 2 "$?"

# ---------- 12. stale files ----------

O="$J/st.out.md"
printf 'ADT_RUN status=ok runner=claude exit=0\nADT_RUN code=0\n' > "$O.status"
FAKE_SLEEP=5 run claude read-only "$O" --detach > /dev/null
bash "$S" --wait "$O" --max-seconds 1 > /dev/null; eq "12 old O.status is never read" 10 "$?"
run claude read-only "$O" --detach > /dev/null; eq "12 second --detach on a live O" 2 "$?"
bash "$S" --wait "$O" --max-seconds 30 > /dev/null

# ---------- 13 and 15. --snapshot ----------

snap() { bash "$S" --snapshot --project-root "$1" "${@:2}" 2>/dev/null; }
S2="$T/snap"
new_repo "$S2"
mkdir -p "$S2/pipeline_artifacts/slug"
echo plan > "$S2/pipeline_artifacts/slug/plan.md"
a=$(snap "$S2" --guard-path pipeline_artifacts/slug); b=$(snap "$S2" --guard-path pipeline_artifacts/slug)
eq "15 same hash twice" "$a" "$b"
check "15 hash is 40 hex characters" test "${#a}" -eq 40
echo two >> "$S2/tracked.txt"; c=$(snap "$S2" --guard-path pipeline_artifacts/slug)
check "15 tracked change" test "$c" != "$b"
echo u > "$S2/untracked.txt"; d=$(snap "$S2" --guard-path pipeline_artifacts/slug)
check "15 untracked file" test "$d" != "$c"
echo edit >> "$S2/pipeline_artifacts/slug/plan.md"; e=$(snap "$S2" --guard-path pipeline_artifacts/slug)
check "13 guarded edit" test "$e" != "$d"
echo new > "$S2/pipeline_artifacts/slug/new.md"; f=$(snap "$S2" --guard-path pipeline_artifacts/slug)
check "13 guarded add" test "$f" != "$e"
rm "$S2/pipeline_artifacts/slug/new.md"; g=$(snap "$S2" --guard-path pipeline_artifacts/slug)
eq "13 guarded delete" "$e" "$g"
ln -s nowhere "$S2/pipeline_artifacts/slug/link"; h=$(snap "$S2" --guard-path pipeline_artifacts/slug)
check "13 guarded symlink" test "$h" != "$g"
rm "$S2/pipeline_artifacts/slug/link"
check "13 guarded file outside git is not seen without --guard-path" test "$(snap "$S2")" = "$(echo more >> "$S2/pipeline_artifacts/slug/plan.md"; snap "$S2")"
snap "$S2" --guard-path pipeline_artifacts/missing > /dev/null; eq "13 missing guard path" 2 "$?"
bash "$S" --snapshot --project-root "$T/nogit" > /dev/null 2>&1; eq "13 not a git repo" 2 "$?"
"$REAL_GIT" -C "$S2" add -A && "$REAL_GIT" -C "$S2" commit -q -m two
"$REAL_GIT" -C "$S2" checkout -q -b other && echo other > "$S2/o.txt" && "$REAL_GIT" -C "$S2" add o.txt && "$REAL_GIT" -C "$S2" commit -q -m o
"$REAL_GIT" -C "$S2" checkout -q -
m1=$(snap "$S2"); "$REAL_GIT" -C "$S2" checkout -q other; m2=$(snap "$S2")
check "13 checkout of another branch" test "$m1" != "$m2"
"$REAL_GIT" -C "$S2" reset -q --hard HEAD~1; m3=$(snap "$S2")
check "13 reset --hard HEAD~1" test "$m3" != "$m2"
check "13 same tree on two branches differs by HEAD" test "$m3" != "$m1"
"$REAL_GIT" -C "$S2" checkout -q --detach HEAD
snap "$S2" > /dev/null; eq "13 detached HEAD" 0 "$?"
mkdir -p "$T/empty"; "$REAL_GIT" -C "$T/empty" init -q; echo x > "$T/empty/x"
snap "$T/empty" > /dev/null; eq "13 repository without commits" 0 "$?"
# Project root in a subdirectory of a larger repository.
L="$T/large"; new_repo "$L"; mkdir -p "$L/app/pipeline_artifacts" "$L/lib"
echo '*' > "$L/app/pipeline_artifacts/.gitignore"; echo lib > "$L/lib/l.txt"
"$REAL_GIT" -C "$L" add -A && "$REAL_GIT" -C "$L" commit -q -m sub
s1=$(snap "$L/app"); rc=$?; eq "13 subdirectory root" 0 "$rc"
echo in > "$L/app/new.txt"; s2=$(snap "$L/app"); rc=$?
eq "13 untracked inside subdirectory root" 0 "$rc"; check "13 untracked inside changes hash" test "$s2" != "$s1"
echo out > "$L/lib/new.txt"; s3=$(snap "$L/app"); rc=$?
eq "13 untracked outside subdirectory root" 0 "$rc"; check "13 untracked outside changes hash" test "$s3" != "$s2"
echo change >> "$L/lib/l.txt"; s4=$(snap "$L/app")
check "13 tracked change outside the root" test "$s4" != "$s3"
mkdir -p "$L/.kotlin/x" "$L/app/.gradle"; echo k > "$L/.kotlin/x/k"; echo g > "$L/app/.gradle/g"; echo i >> "$L/app/x.salive"
s5=$(snap "$L/app"); eq "13 .kotlin, .gradle and .salive are excluded" "$s4" "$s5"
mkdir -p "$L/app/src/main/java/com/acme/build"; echo 'package x' > "$L/app/src/main/java/com/acme/build/B.kt"
s6=$(snap "$L/app"); check "13 a package named build is not excluded" test "$s6" != "$s5"
mkdir -p "$L/.idea"; echo '<x/>' > "$L/.idea/w.xml"; "$REAL_GIT" -C "$L" add -f .idea/w.xml && "$REAL_GIT" -C "$L" commit -q -m idea
s7=$(snap "$L/app"); echo '<y/>' > "$L/.idea/w.xml"; s8=$(snap "$L/app")
eq "13 tracked .idea change at the top is excluded" "$s7" "$s8"
# Independent of the developer's diff settings.
D="$T/diffcfg"; new_repo "$D"
printf '\x00\x01bin' > "$D/b.bin"; echo '*.bin diff=hex' > "$D/.gitattributes"
"$REAL_GIT" -C "$D" add -A && "$REAL_GIT" -C "$D" commit -q -m bin
echo more >> "$D/tracked.txt"; mkdir -p "$D/sub"
plain=$( (cd "$D/sub" && bash "$S" --snapshot --project-root "$D") )
"$REAL_GIT" -C "$D" config diff.relative true
"$REAL_GIT" -C "$D" config diff.external "$T/nope-extdiff"
"$REAL_GIT" -C "$D" config diff.hex.textconv "od -c"
set2=$( (cd "$D/sub" && bash "$S" --snapshot --project-root "$D") )
eq "13 same hash with diff.relative, diff.external and textconv set" "$plain" "$set2"
printf '\x00\x02bin' > "$D/b.bin"; set3=$(snap "$D")
check "13 binary change with a textconv driver changes the hash" test "$set3" != "$set2"
# Two --stdin-paths calls for 200 untracked files and one guarded directory of 50.
C="$T/count"; new_repo "$C"; mkdir -p "$C/u" "$C/pipeline_artifacts/slug"
i=0; while [ "$i" -lt 200 ]; do echo "$i" > "$C/u/f$i"; i=$((i + 1)); done
i=0; while [ "$i" -lt 50 ]; do echo "$i" > "$C/pipeline_artifacts/slug/g$i"; i=$((i + 1)); done
mkdir -p "$T/gitwrap"
cat > "$T/gitwrap/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = --stdin-paths ] && echo x >> "$T/stdin-paths.count"; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/gitwrap/git"
rm -f "$T/stdin-paths.count"
PATH="$T/gitwrap:$PATH" bash "$S" --snapshot --project-root "$C" --guard-path pipeline_artifacts/slug > /dev/null
eq "13 exactly two --stdin-paths calls" 2 "$(wc -l < "$T/stdin-paths.count" | tr -d ' ')"
# Odd file names.
echo n > "$C/u/$(printf 'new\nline')"; ln -s /nowhere "$C/u/broken"
n1=$(snap "$C"); rc=$?; eq "13 newline name and broken link" 0 "$rc"
echo n2 > "$C/u/$(printf 'new\nline')"; n2=$(snap "$C")
check "13 newline name content is hashed" test "$n1" != "$n2"

# ---------- 14 and 17. lost jobs ----------

answer "✅ CODE APPROVED"
job_pid() { sed -n '1s/ .*//p' "$1.pid"; }
cli_pid() { sed -n '1p' "$1.clipid"; }

O="$J/l1.out.md"
FAKE_SLEEP=60 run claude read-only "$O" --detach > /dev/null
wait_for "$O.clipid" 10
jp=$(job_pid "$O"); cp=$(cli_pid "$O")
kill -KILL "$jp"
bash "$S" --wait "$O" --max-seconds 30 > "$T/l1.txt"; rc=$?
eq "14 killed job: --wait exit" 11 "$rc"
check "14 killed job: status=lost" grep -q '^ADT_RUN status=lost' "$O.status"
check "14/17 killed job: the CLI is gone" gone "$cp"

O="$J/l2.out.md"
ADT_RUN_TEST_STOP_WATCHER=1 FAKE_SLEEP=120 run claude read-only "$O" --detach > /dev/null
wait_for "$O.clipid" 10
jp=$(job_pid "$O"); cp=$(cli_pid "$O")
bash "$S" --wait "$O" --max-seconds 60 > /dev/null; rc=$?
eq "14 stuck watcher: --wait exit" 11 "$rc"
check "14 stuck watcher: job is gone" gone "$jp"
check "14 stuck watcher: CLI is gone" gone "$cp"

O="$J/l3.out.md"
ADT_RUN_TEST_HANG_BEFORE_CLI=36 FAKE_STARTED="$T/l3.started" run claude read-only "$O" --detach > /dev/null
jp=$(job_pid "$O")
bash "$S" --wait "$O" --max-seconds 60 > /dev/null; rc=$?
eq "14 hang before the CLI: --wait exit" 11 "$rc"
check "14 hang before the CLI: job is gone" gone "$jp"
sleep 6
check "14 hang before the CLI: the CLI never starts" test ! -e "$T/l3.started"

O="$J/l4.out.md"
ADT_RUN_TEST_HANG_BEFORE_CLI=3 FAKE_STARTED="$T/l4.started" run claude read-only "$O" --detach > /dev/null
sleep 1
: > "$O.cancel"
bash "$S" --wait "$O" --max-seconds 30 > /dev/null; rc=$?
eq "17 O.cancel before the wrapper: not-started" 12 "$rc"
check "17 O.cancel before the wrapper: the CLI never starts" test ! -e "$T/l4.started"

# ---------- 16. O.pid and O.clipid writers ----------

answer "✅ CODE APPROVED"
i=0; while [ "$i" -lt 20 ]; do
  FAKE_SLEEP=4 run claude read-only "$J/p$i.out.md" --detach > /dev/null &
  i=$((i + 1))
done
wait
sleep 1.5
ok16=1
i=0; while [ "$i" -lt 20 ]; do
  o="$J/p$i.out.md"
  l1=$(sed -n 1p "$o.pid"); l2=$(sed -n 2p "$o.pid")
  set -- $l1
  [ "$#" -eq 2 ] || { ok16=0; echo "  O.pid line 1: $l1"; }
  [ "$l2" = "$(bash "$S" --identity "$1")" ] || { ok16=0; echo "  O.pid identity differs for $o"; }
  c1=$(sed -n 1p "$o.clipid"); c2=$(sed -n 2p "$o.clipid")
  { kill -0 "$c1" 2>/dev/null && [ "$c2" = "$(bash "$S" --identity "$c1")" ]; } || { ok16=0; echo "  O.clipid wrong for $o"; }
  i=$((i + 1))
done
eq "16 20 parallel jobs: O.pid and O.clipid" 1 "$ok16"
W=(); i=0; while [ "$i" -lt 20 ]; do W+=("$J/p$i.out.md"); i=$((i + 1)); done
bash "$S" --wait "${W[@]}" --max-seconds 30 > /dev/null; eq "16 all 20 finish" 0 "$?"

# ---------- 18. not-started ----------

O="$J/n1.out.md"
ADT_RUN_TEST_FAIL_PID_WRITE=1 FAKE_STARTED="$T/n1.started" run claude read-only "$O" --detach > /dev/null; rc=$?
eq "18 O.pid write failure: exit" 12 "$rc"
check "18 O.status code 12" grep -qx 'ADT_RUN code=12' "$O.status"
sleep 1
check "18 no job keeps running" test -z "$(ps -eo args | grep -F -- "--child" | grep -F -- "$O" | grep -v grep)"
check "18 the CLI never started" test ! -e "$T/n1.started"
O="$J/n2.out.md"
printf '1 1800\nnot-me\n' > "$O.pid"
bash "$S" --child --runner claude --access read-only --project-root "$R" --prompt-file "$P" --output-file "$O" > /dev/null 2>&1
check "18 job with another pid in O.pid writes nothing" test ! -e "$O.status" -a ! -e "$O.elapsed" -a ! -e "$O.log" -a ! -e "$O"
bash "$S" --wait "$J/never.out.md" --max-seconds 1 > "$T/n3.txt"; rc=$?
eq "18 --wait without O.pid" 12 "$rc"
check "18 --wait without O.pid prints a note" grep -q '^ADT_RUN note=no O.pid' "$T/n3.txt"

# ---------- 19. --command-file with unusual values ----------

Q="$T/it's \$x & y"
new_repo "$Q"
printf '%s\n' 'gemini -p {instruction} --prompt {prompt_file}' > "$T/cmd19.txt"
answer "✅ CODE APPROVED"
bash "$S" --runner command --access read-only --project-root "$Q" --prompt-file "$Q/pipeline_artifacts/prompt.md" \
  --output-file "$Q/pipeline_artifacts/jobs/q.out.md" --command-file "$T/cmd19.txt" --check-program gemini > /dev/null 2>&1
eq "19 run with quotes, \$, & and spaces in paths" 0 "$?"
eq "19 exact arguments" "$(printf '%s\n' gemini -p "Read the file $Q/pipeline_artifacts/prompt.md in full and follow its instructions exactly. It is your complete task for this run. No human will answer questions during this run." --prompt "$Q/pipeline_artifacts/prompt.md")" "$(cat "$T/args")"
bash "$S" --check command --check-program gemini --command-file "$T/cmd19.txt" > /dev/null 2>&1; eq "19 --check command" 0 "$?"
bash "$S" --check command --command-file "$T/cmd19.txt" > /dev/null 2>&1; eq "19 --check command without --check-program" 2 "$?"
bash "$S" --check command --check-program gemini > /dev/null 2>&1; eq "19 --check command without --command-file" 2 "$?"

# ---------- 20. process identity ----------

sleep 120 &
other=$!
O="$J/i1.out.md"
printf '%s 1800\nwrong identity\n' "$other" > "$O.pid"
bash "$S" --wait "$O" --max-seconds 5 > /dev/null; rc=$?
eq "20 a reused pid is not the job" 11 "$rc"
check "20 no signal to the unrelated process" kill -0 "$other"
kill "$other" 2>/dev/null
O="$J/i2.out.md"
FAKE_CHILD="$T/i2.child" FAKE_SLEEP=60 run claude write "$O" --detach > /dev/null
wait_for "$T/i2.child" 10
jp=$(job_pid "$O"); cp=$(cli_pid "$O")
kill -KILL -- "-$jp"
kill -KILL "$cp"
sleep 0.5
check "20 the CLI child still runs" not gone "$(cat "$T/i2.child")"
bash "$S" --wait "$O" --max-seconds 10 > /dev/null
check "20 the lost path stops the child of an exited CLI leader" gone "$(cat "$T/i2.child")"

# ---------- 21. --cancel ----------

RD="$R/pipeline_artifacts/.runs/run21"
answer "✅ CODE APPROVED"
run claude read-only "$RD/jobs/done.out.md" > /dev/null
before=$(cat "$RD/jobs/done.out.md.status")
FAKE_STARTED="$T/x1" FAKE_SLEEP=60 run claude read-only "$RD/jobs/a.out.md" --detach > /dev/null
FAKE_STARTED="$T/x2" FAKE_SLEEP=60 run claude write "$RD/jobs/b.out.md" --detach > /dev/null
wait_for "$T/x1" 10; wait_for "$T/x2" 10
ja=$(job_pid "$RD/jobs/a.out.md"); jb=$(job_pid "$RD/jobs/b.out.md")
out=$(bash "$S" --cancel "$RD"); rc=$?
eq "21 --cancel exit" 0 "$rc"
eq "21 one line per stopped run" 2 "$(printf '%s\n' "$out" | grep -c '^ADT_RUN status=cancelled')"
for x in a b; do
  check "21 $x has status=cancelled" grep -q '^ADT_RUN status=cancelled' "$RD/jobs/$x.out.md.status"
  check "21 $x has code 14" grep -qx 'ADT_RUN code=14' "$RD/jobs/$x.out.md.status"
done
check "21 job a is gone" gone "$ja"
check "21 job b is gone" gone "$jb"
check "21 CLI a is gone" gone "$(cat "$T/x1")"
check "21 CLI b is gone" gone "$(cat "$T/x2")"
eq "21 the finished run is unchanged" "$before" "$(cat "$RD/jobs/done.out.md.status")"
bash "$S" --cancel "$R/pipeline_artifacts/.runs/none" > /dev/null; eq "21 --cancel without jobs" 0 "$?"
bash "$S" --cancel "relative/dir" > /dev/null 2>&1; eq "21 --cancel with a relative path" 2 "$?"

# ---------- --hash ----------

eq "--hash equals the sha line" "$(bash "$S" --hash "$RD/jobs/done.out.md")" "$(field sha "$before")"

echo
echo "adt-run-agent.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
