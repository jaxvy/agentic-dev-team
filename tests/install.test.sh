#!/usr/bin/env bash
#
# Tests for install.sh: the tools it installs for, and what each one gets.
# Plain bash, no framework. Run from anywhere:
#   bash tests/install.test.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/adt-install-test.XXXXXX")"
T="$(cd -P "$T" && pwd -P)"
PASS=0
FAIL=0
trap 'rm -rf "$T"' EXIT

# Keep the developer's own state and git config out of the tests.
export ADT_HOME="$T/adt-home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$T/xdg"

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
not() { ! "$@"; }
eq() { if [ "$2" = "$3" ]; then pass; else fail "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi; }
new_repo() { mkdir -p "$1" && git -C "$1" init -q; }
run_install() { bash "$REPO_DIR/install.sh" "$@" > "$T/out" 2>&1; }
count() { local n=0 f; for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
links() { find "$1" -path "$1/.git" -prune -o -type l -print | wc -l | tr -d ' '; }
block() { awk '/^# agentic-dev-team:start/ { b=1; next } /^# agentic-dev-team:end/ { b=0 } b' "$1/.gitignore"; }
rules() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["permissions"]["allow"]))' "$1/.claude/settings.local.json"; }

CORE=$(( $(count "$REPO_DIR"/.claude/agents/*.md) + $(count "$REPO_DIR"/.claude/adt/scripts/*.sh) \
       + $(count "$REPO_DIR"/.claude/adt/drivers/*.md) + $(count "$REPO_DIR"/.claude/AGENTIC_DEV_TEAM_*.md) ))
CLAUDE=$(count "$REPO_DIR"/.claude/commands/*.md)
ANTIGRAVITY=$(count "$REPO_DIR"/.agents/workflows/*.md)
OPENCODE=$(( $(count "$REPO_DIR"/.opencode/agents/*.md) + $(count "$REPO_DIR"/.opencode/commands/*.md) ))
# Codex also gets the CLAUDE links: its skills find their command file there.
CODEX=$(( $(count "$REPO_DIR"/.agents/skills/*/) + $(count "$REPO_DIR"/.codex/agents/*.toml) ))
ALL=$((CORE + CLAUDE + CODEX + ANTIGRAVITY + OPENCODE))
CODEX_RULES=.codex/rules/agentic-dev-team.rules

# ---------- 1. no tools: all four ----------

P="$T/p1"; new_repo "$P"
run_install "$P"; rc=$?
eq "1 exit" 0 "$rc"
eq "1 every link" "$ALL" "$(links "$P")"
check "1 names every tool" grep -q "^  tools:   claude, codex, antigravity, opencode\$" "$T/out"
check "1 agents.md block" grep -q "agentic-dev-team:start" "$P/.agents/agents.md"
eq "1 permission rules" 3 "$(rules "$P")"
check "1 Codex rules file" test -f "$P/$CODEX_RULES"
eq "1 .gitignore block lists every link" "$(links "$P")" "$(block "$P" | grep -vc '^/pipeline_artifacts/$')"
check "1 says to try it in the three slash-command tools" grep -q "in Claude Code, Antigravity, or OpenCode.\$" "$T/out"
check "1 and how in Codex" grep -q '^In Codex, type \$build-auto-fast and the others.$' "$T/out"

# ---------- 2. claude only ----------

P="$T/p2"; new_repo "$P"
run_install claude "$P"; rc=$?
eq "2 exit" 0 "$rc"
eq "2 core and Claude Code links only" "$((CORE + CLAUDE))" "$(links "$P")"
check "2 commands" test -L "$P/.claude/commands/build-auto.md"
check "2 agent prompts" test -L "$P/.claude/agents/adt-android-coder.md"
check "2 scripts" test -L "$P/.claude/adt/scripts/adt.sh"
check "2 no .agents/" test ! -e "$P/.agents"
check "2 no .opencode/" test ! -e "$P/.opencode"
check "2 no .codex/" test ! -e "$P/.codex"
eq "2 permission rules" 3 "$(rules "$P")"
check "2 says to try it in Claude Code" grep -q "in Claude Code.\$" "$T/out"
check "2 and not in Codex" not grep -q "Codex" "$T/out"
eq "2 .gitignore block lists only its links" "$((CORE + CLAUDE))" "$(block "$P" | grep -vc '^/pipeline_artifacts/$')"

# ---------- 2b. codex only ----------

P="$T/p2b"; new_repo "$P"
run_install codex "$P"; rc=$?
eq "2b exit" 0 "$rc"
eq "2b core, command and Codex links only" "$((CORE + CLAUDE + CODEX))" "$(links "$P")"
check "2b the command files its skills read" test -L "$P/.claude/commands/build-auto.md"
check "2b skills" test -L "$P/.agents/skills/build-auto"
check "2b agents" test -L "$P/.codex/agents/adt-android-coder.toml"
check "2b Codex rules file" test -f "$P/$CODEX_RULES"
check "2b no settings.local.json" test ! -e "$P/.claude/settings.local.json"
check "2b no workflows" test ! -e "$P/.agents/workflows"
check "2b no agents.md" test ! -e "$P/.agents/agents.md"
check "2b no .opencode/" test ! -e "$P/.opencode"
check "2b says to try it in Codex" grep -q '^Done. Try \$build-auto-fast.* in Codex.$' "$T/out"

P="$T/p2c"; new_repo "$P"
run_install claude,codex "$P"; rc=$?
eq "2b claude,codex: exit" 0 "$rc"
eq "2b claude,codex: links" "$((CORE + CLAUDE + CODEX))" "$(links "$P")"
eq "2b claude,codex: Claude Code rules" 3 "$(rules "$P")"
check "2b claude,codex: Codex rules file" test -f "$P/$CODEX_RULES"

# ---------- 3. commas, spaces, duplicates and order ----------

P="$T/p3a"; new_repo "$P"; run_install claude,opencode "$P"
P2="$T/p3b"; new_repo "$P2"; run_install "$P2" opencode claude,claude
eq "3 claude,opencode links" "$((CORE + CLAUDE + OPENCODE))" "$(links "$P")"
eq "3 the same with spaces, a duplicate, and the project first" "$(block "$P")" "$(block "$P2")"
check "3 tools in their own order" grep -q "^  tools:   claude, opencode\$" "$T/out"
check "3 no .agents/" test ! -e "$P/.agents"

# ---------- 4. opencode only: no Claude Code rules ----------

P="$T/p4"; new_repo "$P"
run_install opencode "$P"; rc=$?
eq "4 exit" 0 "$rc"
eq "4 core and OpenCode links only" "$((CORE + OPENCODE))" "$(links "$P")"
check "4 no Claude Code commands" test ! -e "$P/.claude/commands"
check "4 no settings.local.json" test ! -e "$P/.claude/settings.local.json"
check "4 no .agents/" test ! -e "$P/.agents"
check "4 no .codex/" test ! -e "$P/.codex"

# ---------- 5. antigravity only ----------

P="$T/p5"; new_repo "$P"
run_install antigravity "$P"; rc=$?
eq "5 exit" 0 "$rc"
eq "5 core and Antigravity links only" "$((CORE + ANTIGRAVITY))" "$(links "$P")"
check "5 agents.md block" grep -q "agentic-dev-team:start" "$P/.agents/agents.md"
check "5 no settings.local.json" test ! -e "$P/.claude/settings.local.json"

# ---------- 6. a later run with fewer tools removes the others ----------

P="$T/p6"; new_repo "$P"; mkdir -p "$P/.agents"
printf '# My rules\n' > "$P/.agents/agents.md"
run_install "$P"
run_install claude "$P"; rc=$?
eq "6 exit" 0 "$rc"
eq "6 only core and Claude Code links are left" "$((CORE + CLAUDE))" "$(links "$P")"
check "6 says it removed the stale links" grep -q "removed stale: .opencode/agents/adt-android-coder.md" "$T/out"
check "6 says it removed the block" grep -q "removed: .agents/agents.md (marker block)" "$T/out"
eq "6 agents.md keeps your own lines" "# My rules" "$(cat "$P/.agents/agents.md")"
check "6 no .opencode/" test ! -e "$P/.opencode"
check "6 no .agents/workflows/" test ! -e "$P/.agents/workflows"
check "6 no .agents/skills/" test ! -e "$P/.agents/skills"
check "6 no .codex/agents/" test ! -e "$P/.codex/agents"
check "6 the Codex rules file an earlier run wrote stays" test -f "$P/$CODEX_RULES"

P="$T/p6b"; new_repo "$P"
run_install "$P"; run_install claude "$P"
check "6 an agents.md with only our block is deleted" test ! -e "$P/.agents"
run_install opencode "$P"; rc=$?
eq "6 claude to opencode: exit" 0 "$rc"
check "6 claude to opencode: commands removed" test ! -e "$P/.claude/commands"
eq "6 claude to opencode: the rules stay" 3 "$(rules "$P")"
run_install "$P"
eq "6 back to all four" "$ALL" "$(links "$P")"

# A file of yours at another tool's path is no collision when that tool is not installed.
P="$T/p6c"; new_repo "$P"; mkdir -p "$P/.opencode/commands"
printf 'mine\n' > "$P/.opencode/commands/build-auto.md"
run_install claude "$P"; rc=$?
eq "6 your file at an opencode path: claude installs" 0 "$rc"
run_install opencode "$P"; rc=$?
eq "6 your file at an opencode path: opencode refuses" 1 "$rc"
eq "6 your file is kept" "mine" "$(cat "$P/.opencode/commands/build-auto.md")"

# ---------- 7. bad arguments ----------

P="$T/p7"; new_repo "$P"
run_install cursor "$P"; rc=$?
eq "7 an unknown tool: exit" 2 "$rc"
check "7 an unknown tool: names it" grep -q "Not a tool or a directory: cursor" "$T/out"
check "7 an unknown tool: lists the tools" grep -q "Tools: claude, codex, antigravity, opencode" "$T/out"
run_install claude,cursor "$P"; rc=$?
eq "7 a list with an unknown tool: exit" 2 "$rc"
run_install , "$P"; rc=$?
eq "7 a list with no tool: exit" 2 "$rc"
eq "7 nothing was installed" 0 "$(links "$P")"
run_install --uninstall claude "$P"; rc=$?
eq "7 --uninstall with a tool: exit" 2 "$rc"
check "7 --uninstall with a tool: says why" grep -q "^--uninstall removes every tool" "$T/out"

# A project directory with a tool's name is written as a path.
mkdir -p "$T/dirs"; new_repo "$T/dirs/claude"
( cd "$T/dirs" && bash "$REPO_DIR/install.sh" ./claude opencode > "$T/out" 2>&1 ); rc=$?
eq "7 ./claude is the project: exit" 0 "$rc"
eq "7 ./claude is the project: opencode links" "$((CORE + OPENCODE))" "$(links "$T/dirs/claude")"

# ---------- 8. uninstall removes every tool's links ----------

P="$T/p8"; new_repo "$P"
run_install "$P"
run_install claude,antigravity "$P"
run_install --uninstall "$P"; rc=$?
eq "8 exit" 0 "$rc"
eq "8 no links left" 0 "$(links "$P")"
check "8 no agents.md" test ! -e "$P/.agents"
check "8 no settings.local.json" test ! -e "$P/.claude/settings.local.json"
check "8 no Codex rules file, also from an earlier run" test ! -e "$P/$CODEX_RULES"
run_install --uninstall "$P"; rc=$?
eq "8 a second uninstall: exit" 0 "$rc"
check "8 a second uninstall finishes" grep -q "^Uninstalled: 0 symlink(s) removed." "$T/out"

echo
echo "install.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
