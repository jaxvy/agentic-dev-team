#!/usr/bin/env bash
#
# Release checks: the versions agree, the doc links resolve, and every agent
# and command is wired up for all three tools. Plain bash and python3, no
# framework. Run from anywhere:
#   bash tests/release.test.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN="$REPO_DIR/plugins/agentic-dev-team"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then pass; else fail "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi; }

# ---------- versions ----------

json_field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
plugin_version="$(json_field "$PLUGIN/.claude-plugin/plugin.json" version)"
market_version="$(json_field "$REPO_DIR/.claude-plugin/marketplace.json" version)"
changelog_version="$(sed -n 's/^## \([0-9][0-9.]*\)$/\1/p' "$REPO_DIR/CHANGELOG.md" | head -n 1)"
check "plugin.json has a version" test -n "$plugin_version"
eq "marketplace.json and plugin.json agree" "$plugin_version" "$market_version"
eq "the newest CHANGELOG entry is the version" "$plugin_version" "$changelog_version"

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

for md in README.md HOW_IT_WORKS.md CHANGELOG.md RELEASING.md evals/README.md; do
  dir="$(dirname "$REPO_DIR/$md")"
  for target in $(grep -o '](\([^)#][^)]*\))' "$REPO_DIR/$md" | sed 's/^](//; s/)$//; s/#.*$//' | grep -v '^[a-z]*:' | sort -u); do
    check "$md links to $target, which exists" test -e "$dir/$target"
  done
done

# ---------- files that must parse ----------

check "examples/ci/android-e2e.yml is valid YAML" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$REPO_DIR/examples/ci/android-e2e.yml"
check ".github/workflows/ci.yml is valid YAML" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$REPO_DIR/.github/workflows/ci.yml"
check "evals/report.py compiles" python3 -m py_compile "$REPO_DIR/evals/report.py"

echo
echo "release.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
