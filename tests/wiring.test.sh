#!/usr/bin/env bash
#
# Wiring checks: every pipeline doc has its .claude/ link, every agent and
# command is wired up for all four tools, and the doc links, sections
# included, resolve. Plain bash and python3, no framework. Run from anywhere:
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

# ---------- agents and commands in Antigravity and OpenCode ----------

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

# ---------- Codex: agents, skills and the plugin ----------

for agent in "$PLUGIN"/agents/*.md; do
  name="$(basename "$agent" .md)"
  check "agent $name.md has a Codex agent" test -f "$REPO_DIR/.codex/agents/$name.toml"
done
for command in "$PLUGIN"/commands/*.md; do
  name="$(basename "$command" .md)"
  check "command $name.md is a Codex skill" test -f "$PLUGIN/codex/skills/$name/SKILL.md"
  check "  and the clone has it in .agents/skills/" test -f "$REPO_DIR/.agents/skills/$name/SKILL.md"
done
check ".agents/skills is a link to the plugin's skills" test -L "$REPO_DIR/.agents/skills"

if python3 -c 'import tomllib, yaml' 2>/dev/null; then
  out="$(python3 - "$REPO_DIR" <<'EOF'
import glob, json, os, re, sys, tomllib, yaml
repo = sys.argv[1]
plugin = os.path.join(repo, "plugins/agentic-dev-team")
problems = []

def frontmatter(path):
    return yaml.safe_load(open(path).read().split("---\n")[1])

# Each Codex agent is a stub of the agent file of the same name.
for path in sorted(glob.glob(os.path.join(repo, ".codex/agents/*.toml"))):
    name = os.path.basename(path)[:-5]
    agent = os.path.join(plugin, "agents", name + ".md")
    d = tomllib.load(open(path, "rb"))
    if set(d) != {"name", "description", "developer_instructions"}:
        problems.append(f"{name}.toml has the keys {sorted(d)}")
    if d.get("name") != name:
        problems.append(f"{name}.toml is named {d.get('name')!r}")
    if not os.path.exists(agent):
        problems.append(f"{name}.toml has no agent file")
        continue
    if " ".join(d["description"].split()) != " ".join(frontmatter(agent)["description"].split()):
        problems.append(f"{name}.toml: its description differs from {name}.md")
    if f".claude/agents/{name}.md" not in d["developer_instructions"]:
        problems.append(f"{name}.toml does not send the agent to its prompt")

# Each Codex skill runs the command of the same name, and only when typed.
for path in sorted(glob.glob(os.path.join(plugin, "codex/skills/*/SKILL.md"))):
    name = os.path.basename(os.path.dirname(path))
    command = os.path.join(plugin, "commands", name + ".md")
    if not os.path.exists(command):
        problems.append(f"skill {name} has no command")
        continue
    fm = frontmatter(path)
    if fm.get("name") != name:
        problems.append(f"skill {name} is named {fm.get('name')!r}")
    if not fm.get("description", "").startswith(frontmatter(command)["description"]):
        problems.append(f"skill {name}: its description does not start with the command's")
    text = open(path).read()
    for needle in (f".claude/commands/{name}.md", f"PLUGIN_ROOT/commands/{name}.md",
                   f"PLUGIN_ROOT/codex/skills/{name}/SKILL.md"):
        if needle not in text:
            problems.append(f"skill {name} does not name {needle}")
    meta = yaml.safe_load(open(os.path.join(os.path.dirname(path), "agents/openai.yaml")))
    if meta.get("policy", {}).get("allow_implicit_invocation") is not False:
        problems.append(f"skill {name} can run without the user typing it")

# The Codex plugin and its marketplace match the Claude Code ones.
codex = json.load(open(os.path.join(plugin, ".codex-plugin/plugin.json")))
claude = json.load(open(os.path.join(plugin, ".claude-plugin/plugin.json")))
if codex["name"] != claude["name"]:
    problems.append("the Codex plugin's name differs from the Claude Code plugin's")
if not codex["skills"].startswith("./") or not os.path.isdir(os.path.join(plugin, codex["skills"])):
    problems.append(f"the Codex plugin's skills path {codex['skills']!r} is not a ./ folder")
market = json.load(open(os.path.join(repo, ".agents/plugins/marketplace.json")))
if market["name"] != json.load(open(os.path.join(repo, ".claude-plugin/marketplace.json")))["name"]:
    problems.append("the Codex marketplace's name differs from the Claude Code one")
for entry in market["plugins"]:
    src = os.path.join(repo, entry["source"]["path"])
    if entry["name"] != codex["name"] or not os.path.exists(os.path.join(src, ".codex-plugin/plugin.json")):
        problems.append(f"the Codex marketplace entry {entry['name']!r} does not point at the plugin")
    if not {"installation", "authentication"} <= set(entry.get("policy", {})) or "category" not in entry:
        problems.append(f"the Codex marketplace entry {entry['name']!r} lacks a policy or category")

# The sections that the skills and the agent stubs send Codex to.
for doc, heading in (("AGENTIC_DEV_TEAM_ORCHESTRATION.md", "## Orchestration Workflow (Codex)"),
                     ("AGENTIC_DEV_TEAM_PIPELINE.md", "## Agents in Codex")):
    if heading not in open(os.path.join(plugin, doc)).read().splitlines():
        problems.append(f"{doc} has no {heading!r}")
print("\n".join(problems) or "ok")
EOF
)"
  eq "the Codex agents, skills and plugin are consistent" "ok" "$out"
else
  echo "SKIP: the Codex checks need python3 3.11 or later, with PyYAML"
fi

# ---------- links in the docs ----------

for md in README.md HOW_IT_WORKS.md; do
  dir="$(dirname "$REPO_DIR/$md")"
  for target in $(grep -o '](\([^)#][^)]*\))' "$REPO_DIR/$md" | sed 's/^](//; s/)$//; s/#.*$//' | grep -v '^[a-z]*:' | sort -u); do
    check "$md links to $target, which exists" test -e "$dir/$target"
  done
done
# A link to a section needs a heading with that GitHub anchor.
eq "every #section link in the docs has its heading" "" "$(python3 - "$REPO_DIR" <<'EOF'
import os, re, sys
repo = sys.argv[1]
def anchors(name):
    found, seen, fence = set(), {}, False
    for line in open(os.path.join(repo, name)):
        if line.startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"^#{1,6}\s+(.*?)\s*$", line)
        if m:
            slug = re.sub(r"[^\w\- ]", "", m.group(1).lower()).replace(" ", "-")
            n = seen.get(slug, 0)
            seen[slug] = n + 1
            found.add(slug if n == 0 else f"{slug}-{n}")
    return found
docs = {name: anchors(name) for name in ("README.md", "HOW_IT_WORKS.md")}
for name in docs:
    for target in re.findall(r"\]\(([^)#:]*)#([^)]*)\)", open(os.path.join(repo, name)).read()):
        doc = target[0] or name
        if doc in docs and target[1] not in docs[doc]:
            print(f"{name} -> {doc}#{target[1]}")
EOF
)"

# ---------- files that must parse ----------

check ".github/workflows/ci.yml is valid YAML" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$REPO_DIR/.github/workflows/ci.yml"

echo
echo "wiring.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
