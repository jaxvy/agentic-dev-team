#!/usr/bin/env bash
set -euo pipefail

CONFIG_REPO="${CONFIG_REPO:-https://github.com/jaxvy/agentic-dev-team.git}"
TARGET_DIR="${TARGET_DIR:-.agent-config}"

echo "Installing agentic dev team pipeline from ${CONFIG_REPO}"

if [ -d "$TARGET_DIR/.git" ]; then
  git -C "$TARGET_DIR" pull --ff-only
elif [ -e "$TARGET_DIR" ]; then
  echo "Refusing to continue: ${TARGET_DIR} exists but is not a git checkout."
  exit 1
else
  git clone "$CONFIG_REPO" "$TARGET_DIR"
fi

safe_link() {
  local source_path="$1"
  local link_path="$2"

  if [ -L "$link_path" ]; then
    rm "$link_path"
  elif [ -e "$link_path" ]; then
    echo "Refusing to overwrite existing ${link_path}."
    echo "Move it aside or migrate it manually, then rerun this installer."
    exit 1
  fi

  ln -s "$source_path" "$link_path"
}

safe_link "$TARGET_DIR/.claude" ".claude"
safe_link "$TARGET_DIR/.agents" ".agents"

if [ -e "AGENTS.md" ] && [ ! -e "CLAUDE.md" ] && [ ! -L "CLAUDE.md" ]; then
  ln -s AGENTS.md CLAUDE.md
fi

if [ ! -e "AGENTS.md" ]; then
  echo "No AGENTS.md found. Create one with this project's architecture, coding, and verification rules before running /build or /review."
fi

touch .gitignore
if ! grep -qxF "# Shared agent configuration installed by jaxvy/agentic-dev-team" .gitignore; then
  {
    echo ""
    echo "# Shared agent configuration installed by jaxvy/agentic-dev-team"
  } >> .gitignore
fi

for ignored_path in "/$TARGET_DIR/" "/.claude" "/.agents"; do
  if ! grep -qxF "$ignored_path" .gitignore; then
    echo "$ignored_path" >> .gitignore
  fi
done

echo "Installed. Keep project-specific rules in the consuming project's AGENTS.md."
