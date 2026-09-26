#!/usr/bin/env bash
#
# Tests for the config file: adt-run-agent.sh --init-config, the template,
# and the install.sh integration.
# Plain bash, no framework. Run from anywhere:
#   bash tests/adt-config.test.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO_DIR/plugins/agentic-dev-team"
S="$PLUGIN/scripts/adt-run-agent.sh"
TEMPLATE="$PLUGIN/config.example.yaml"
T="$(mktemp -d "${TMPDIR:-/tmp}/adt-config-test.XXXXXX")"
T="$(cd -P "$T" && pwd -P)"
PASS=0
FAIL=0
trap 'rm -rf "$T"' EXIT

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
not() { ! "$@"; }
eq() { if [ "$2" = "$3" ]; then pass; else fail "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi; }
sum() { cksum < "$1"; }
new_repo() { mkdir -p "$1" && git -C "$1" init -q; }
init() { bash "$S" --init-config "$@" 2>"$T/stderr"; }

# ---------- 1. creation ----------

P="$T/p1"; new_repo "$P"
out=$(init "$P"); rc=$?
eq "1 exit" 0 "$rc"
eq "1 status line" "ADT_INIT status=created" "$(printf '%s\n' "$out" | head -n 1)"
check "1 message" grep -qF "created .agentic-dev-team/config.yaml (git-ignored; see its header to share it)" <<< "$out"
eq "1 .gitignore content" "*" "$(cat "$P/.agentic-dev-team/.gitignore")"
eq "1 config is the template" "$(sum "$TEMPLATE")" "$(sum "$P/.agentic-dev-team/config.yaml")"
eq "1 git status is empty" "" "$(git -C "$P" status --porcelain)"
check "1 config is ignored" git -C "$P" check-ignore -q .agentic-dev-team/config.yaml
check "1 .gitignore is ignored" git -C "$P" check-ignore -q .agentic-dev-team/.gitignore
no_tmp() { local f; for f in "$1"/*.tmp.* "$1"/.*.tmp.*; do [ -e "$f" ] && return 1; done; return 0; }
check "1 no temp file left" no_tmp "$P/.agentic-dev-team"

# ---------- 2. an edited config is never changed ----------

echo "version: 1  # edited" >> "$P/.agentic-dev-team/config.yaml"
before=$(sum "$P/.agentic-dev-team/config.yaml")
out=$(init "$P"); rc=$?
eq "2 exit" 0 "$rc"
eq "2 status" "ADT_INIT status=exists" "$out"
eq "2 config unchanged" "$before" "$(sum "$P/.agentic-dev-team/config.yaml")"

# ---------- 3. a deleted .gitignore is not re-created ----------

rm "$P/.agentic-dev-team/.gitignore"
init "$P" > /dev/null
check "3 .gitignore not re-created" test ! -e "$P/.agentic-dev-team/.gitignore"
check "3 un-ignored config shows in git status" grep -q "agentic-dev-team" <<< "$(git -C "$P" status --porcelain)"

# ---------- 4. failures ----------

P="$T/p4"; new_repo "$P"; echo x > "$P/.agentic-dev-team"
out=$(init "$P"); rc=$?
eq "4 .agentic-dev-team is a file: exit" 1 "$rc"
eq "4 .agentic-dev-team is a file: status" "ADT_INIT status=failed" "$(printf '%s\n' "$out" | head -n 1)"
check "4 .agentic-dev-team is a file: warning" test -s "$T/stderr"

out=$(init "relative/path"); rc=$?
eq "4 relative root: exit" 1 "$rc"; eq "4 relative root: status" "ADT_INIT status=failed" "$out"
out=$(init); rc=$?
eq "4 missing root: exit" 1 "$rc"; eq "4 missing root: status" "ADT_INIT status=failed" "$out"
out=$(init "$T/does-not-exist"); rc=$?
eq "4 root does not exist: exit" 1 "$rc"
check "4 root is never created" test ! -e "$T/does-not-exist"

# Missing template: a copy of the script without config.example.yaml.
mkdir -p "$T/notpl/plugin/scripts"; cp "$S" "$T/notpl/plugin/scripts/"
P="$T/p4b"; new_repo "$P"
out=$(bash "$T/notpl/plugin/scripts/adt-run-agent.sh" --init-config "$P" 2>/dev/null); rc=$?
eq "4 missing template: exit" 1 "$rc"; eq "4 missing template: status" "ADT_INIT status=failed" "$out"
check "4 missing template: no config" test ! -e "$P/.agentic-dev-team/config.yaml"

P="$T/p4c"; new_repo "$P"
out=$(ADT_RUN_TEST_FAIL_GITIGNORE_WRITE=1 init "$P"); rc=$?
eq "4 .gitignore write fails: exit" 1 "$rc"
eq "4 .gitignore write fails: status" "ADT_INIT status=failed" "$out"
check "4 .gitignore write fails: no config" test ! -e "$P/.agentic-dev-team/config.yaml"
check "4 .gitignore write fails: no temp file" test -z "$(ls -A "$P/.agentic-dev-team" 2>/dev/null)"

P="$T/p4d"; new_repo "$P"
out=$(ADT_RUN_TEST_FAIL_CONFIG_WRITE=1 init "$P"); rc=$?
eq "4 config copy fails: exit" 1 "$rc"
eq "4 config copy fails: status" "ADT_INIT status=failed" "$out"
check "4 config copy fails: no config" test ! -e "$P/.agentic-dev-team/config.yaml"
check "4 config copy fails: no temp file" no_tmp "$P/.agentic-dev-team"

if [ "$(id -u)" != 0 ]; then
  P="$T/p4e"; new_repo "$P"; chmod 555 "$P"
  out=$(init "$P"); rc=$?
  eq "4 unwritable project: exit" 1 "$rc"; eq "4 unwritable project: status" "ADT_INIT status=failed" "$out"
  chmod 755 "$P"
fi

# config.yaml exists but cannot be read.
P="$T/p4f"; new_repo "$P"; mkdir -p "$P/.agentic-dev-team/config.yaml"
out=$(init "$P"); rc=$?
eq "4 config is a directory: exit" 1 "$rc"
eq "4 config is a directory: status" "ADT_INIT status=unreadable" "$(printf '%s\n' "$out" | head -n 1)"
check "4 config is a directory: message" grep -qF "config.yaml exists but is not a readable file; fix or delete it" <<< "$out"
P="$T/p4g"; new_repo "$P"; mkdir -p "$P/.agentic-dev-team"; ln -s nowhere "$P/.agentic-dev-team/config.yaml"
out=$(init "$P"); rc=$?
eq "4 broken symlink: status" "ADT_INIT status=unreadable" "$(printf '%s\n' "$out" | head -n 1)"
check "4 broken symlink is kept" test -L "$P/.agentic-dev-team/config.yaml"

# Called from another directory, and with the root below the git top-level.
P="$T/p4h"; new_repo "$P"; mkdir -p "$P/android" "$T/elsewhere"
out=$( (cd "$T/elsewhere" && bash "$S" --init-config "$P/android") ); rc=$?
eq "4 subdirectory root: exit" 0 "$rc"
check "4 created in the project root" test -f "$P/android/.agentic-dev-team/config.yaml"
check "4 not created in the current directory" test ! -e "$T/elsewhere/.agentic-dev-team"
check "4 not created at the git top-level" test ! -e "$P/.agentic-dev-team"

# install.sh with a failing init still finishes with exit 0.
P="$T/p4i"; new_repo "$P"
ADT_RUN_TEST_FAIL_CONFIG_WRITE=1 bash "$REPO_DIR/install.sh" "$P" > "$T/install.txt" 2>&1; rc=$?
eq "4 install.sh with a failing init: exit" 0 "$rc"
check "4 install.sh prints the init status" grep -q "ADT_INIT status=failed" "$T/install.txt"
bash "$REPO_DIR/install.sh" --uninstall "$P" > /dev/null 2>&1

# ---------- 5. install.sh layout: symlinks to the script ----------

C="$T/clone"
mkdir -p "$C/plugins/agentic-dev-team/scripts" "$C/.claude"
cp "$S" "$C/plugins/agentic-dev-team/scripts/"
cp "$TEMPLATE" "$C/plugins/agentic-dev-team/"
ln -s ../plugins/agentic-dev-team/scripts "$C/.claude/scripts"
P="$T/p5"; new_repo "$P"; mkdir -p "$P/.claude/scripts"
ln -s "$C/.claude/scripts/adt-run-agent.sh" "$P/.claude/scripts/adt-run-agent.sh"
out=$(bash "$P/.claude/scripts/adt-run-agent.sh" --init-config "$P"); rc=$?
eq "5 through the project symlink: exit" 0 "$rc"
eq "5 through the project symlink: config" "$(sum "$TEMPLATE")" "$(sum "$P/.agentic-dev-team/config.yaml")"
P="$T/p5b"; new_repo "$P"
out=$(bash "$C/plugins/agentic-dev-team/scripts/adt-run-agent.sh" --init-config "$P"); rc=$?
eq "5 direct call: exit" 0 "$rc"
P="$T/p5c"; new_repo "$P"; mkdir -p "$P/.claude/scripts"
ln -s "../../../clone/.claude/scripts/adt-run-agent.sh" "$P/.claude/scripts/adt-run-agent.sh"
out=$( (cd "$T" && bash "p5c/.claude/scripts/adt-run-agent.sh" --init-config "$P") ); rc=$?
eq "5 relative symlink target: exit" 0 "$rc"
check "5 relative symlink target: config" test -f "$P/.agentic-dev-team/config.yaml"
P="$T/p5d"; new_repo "$P"
ln -s "$P/loop-a" "$P/loop-b"; ln -s "$P/loop-b" "$P/loop-a"
out=$(bash "$P/loop-a" --init-config "$P" 2>/dev/null); rc=$?
check "5 symlink cycle does not hang (bash cannot even open it)" test "$rc" -ne 0

# ---------- 6. template models equal the agent frontmatter ----------

for role in pm architect architect_reviewer coder code_reviewer tester; do
  agent="adt-android-$(printf '%s' "$role" | tr '_' '-').md"
  fm=$(sed -n '2,/^---$/p' "$PLUGIN/agents/$agent" | sed -n 's/^model:[[:space:]]*//p')
  tpl=$(sed -n "s/^  # $role:[[:space:]]*{ model: \([a-z]*\) }.*/\1/p" "$TEMPLATE")
  eq "6 template model of $role equals the frontmatter" "$fm" "$tpl"
done
eq "6 judge frontmatter is inherit" "inherit" "$(sed -n '2,/^---$/p' "$PLUGIN/agents/adt-android-review-judge.md" | sed -n 's/^model:[[:space:]]*//p')"

# ---------- 7. the template is valid YAML and inert ----------

if python3 -c 'import yaml' 2>/dev/null; then
  eq "7 template parses to null sections" "{'version': 1, 'agents': None, 'build_auto_reviewed': None}" \
    "$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])))' "$TEMPLATE")"
  eq "7 full fixture parses" "ok" "$(python3 - "$REPO_DIR/tests/fixtures/config.full.yaml" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["version"] == 1
assert set(d["agents"]) == {"pm", "architect", "architect_reviewer", "coder", "code_reviewer", "tester", "review_judge"}
b = d["build_auto_reviewed"]
assert set(b) == {"architect", "coder", "tester", "architect_reviewer", "code_reviewer"}
assert len(b["code_reviewer"]["reviewers"]) == 4
assert b["code_reviewer"]["reviewers"][1]["required"] is False
print("ok")
EOF
)"
  # The fixture is the template with every setting line active.
  eq "7 fixture equals the uncommented template" "" \
    "$(sed -E -e 's/^(  )# /\1/' -e 's/^  (  +)# /  \1/' "$TEMPLATE" | diff - "$REPO_DIR/tests/fixtures/config.full.yaml")"
else
  echo "SKIP 7: python3 with PyYAML is not available"
fi

echo
echo "adt-config.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
