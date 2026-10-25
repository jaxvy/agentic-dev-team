#!/usr/bin/env bash
#
# Wiring checks: every pipeline doc has its .claude/ link, every agent and
# command is wired up for all three tools, and the doc links resolve. Plain
# bash and python3, no framework. Run from anywhere:
#   bash tests/wiring.test.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN="$REPO_DIR/plugins/agentic-dev-team"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then pass; else fail "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi; }

# ---------- the pipeline docs ----------

for doc in "$PLUGIN"/AGENTIC_DEV_TEAM_*.md; do
  name="$(basename "$doc")"
  check "$name has a .claude/ link" test -L "$REPO_DIR/.claude/$name"
  check "the .claude/$name link resolves" test -f "$REPO_DIR/.claude/$name"
done
for name in AGENTIC_DEV_TEAM_PIPELINE.md AGENTIC_DEV_TEAM_ORCHESTRATION.md AGENTIC_DEV_TEAM_CONFIG.md; do
  check "$name exists" test -f "$PLUGIN/$name"
done

# ---------- agents and commands in all three tools ----------

for agent in "$PLUGIN"/agents/*.md; do
  name="$(basename "$agent")"
  check "agent $name has an OpenCode stub" test -f "$REPO_DIR/.opencode/agents/$name"
  check "agent $name is in the Antigravity personas" grep -q "@${name%.md})" "$REPO_DIR/.agents/AGENTIC_DEV_TEAM.md"
done
for command in "$PLUGIN"/commands/*.md; do
  name="$(basename "$command")"
  check "command $name is an Antigravity workflow" test -f "$REPO_DIR/.agents/workflows/$name"
  check "command $name is an OpenCode command" test -f "$REPO_DIR/.opencode/commands/$name"
done

# ---------- links in the docs ----------

for md in README.md HOW_IT_WORKS.md; do
  dir="$(dirname "$REPO_DIR/$md")"
  for target in $(grep -o '](\([^)#][^)]*\))' "$REPO_DIR/$md" | sed 's/^](//; s/)$//; s/#.*$//' | grep -v '^[a-z]*:' | sort -u); do
    check "$md links to $target, which exists" test -e "$dir/$target"
  done
done

# ---------- files that must parse ----------

check ".github/workflows/ci.yml is valid YAML" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$REPO_DIR/.github/workflows/ci.yml"

echo
echo "wiring.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
