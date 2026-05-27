#!/usr/bin/env bash
#
# agentic-dev-team installer
#
# Usage:
#   <repo-clone>/install.sh                # install into current working directory
#   <repo-clone>/install.sh <project-dir>  # install into the given project directory
#   <repo-clone>/install.sh --uninstall    # uninstall from current working directory
#
# What it does:
#   - For each agent, command, and workflow file in this repo, creates a
#     per-file symlink at the matching path in the consuming project.
#   - Manages a marker-fenced block in the project's .gitignore listing the
#     installed paths (so per-developer absolute symlink targets aren't
#     committed).
#   - Manages a marker-fenced block in the project's .agents/agents.md
#     containing the inlined persona stubs from this repo's
#     .agents/AGENTIC_DEV_TEAM.md (Antigravity auto-loads agents.md into
#     user_rules).
#
# Safety:
#   - Never overwrites a developer's own files. Real files at our install
#     destinations cause a refusal with a clear message.
#   - Only modifies content inside the marker-fenced blocks in .gitignore
#     and .agents/agents.md; content outside markers is left alone.
#   - --uninstall removes only what this script created.

set -euo pipefail

# ---------- paths ----------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args: first non-flag arg is project dir; --uninstall switches mode.
MODE="install"
PROJECT_DIR=""
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^#//'
      exit 0
      ;;
    --*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    *) PROJECT_DIR="$arg" ;;
  esac
done
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# ---------- markers ----------
GITIGNORE_MARK_START="# agentic-dev-team:start (managed by install.sh — do not edit by hand)"
GITIGNORE_MARK_END="# agentic-dev-team:end"
AGENTS_MARK_START="<!-- agentic-dev-team:start (managed by install.sh — do not edit) -->"
AGENTS_MARK_END="<!-- agentic-dev-team:end -->"

PIPELINE_ARTIFACTS_PATH="/pipeline_artifacts/"

# ---------- helpers ----------

# Print the desired (src, dest) pairs by walking source dirs.
# Output format: "<abs-src>|<rel-dest>" one per line.
build_desired_pairs() {
  local f rel
  shopt -s nullglob
  for f in "$REPO_DIR"/.claude/commands/*.md \
           "$REPO_DIR"/.claude/agents/*.md \
           "$REPO_DIR"/.agents/workflows/*.md; do
    rel="${f#$REPO_DIR/}"
    printf '%s|%s\n' "$f" "$rel"
  done
  shopt -u nullglob
  if [ -f "$REPO_DIR/.claude/AGENTIC_DEV_TEAM_PIPELINE.md" ]; then
    printf '%s|%s\n' \
      "$REPO_DIR/.claude/AGENTIC_DEV_TEAM_PIPELINE.md" \
      ".claude/AGENTIC_DEV_TEAM_PIPELINE.md"
  fi
}

# Parse the previous installed-path list from the .gitignore marker block.
# Outputs one relative path per line (no leading slash, no trailing slash).
parse_gitignore_block() {
  local gi="$PROJECT_DIR/.gitignore"
  [ -f "$gi" ] || return 0
  awk -v s="$GITIGNORE_MARK_START" -v e="$GITIGNORE_MARK_END" '
    $0 == s { inblock=1; next }
    $0 == e { inblock=0; next }
    inblock && /^\// {
      line=$0
      sub(/^\//, "", line)
      sub(/\/$/, "", line)
      if (line != "" && line != "pipeline_artifacts") print line
    }
  ' "$gi"
}

# Read the absolute symlink target (or empty if not a symlink).
abs_readlink() {
  local p="$1"
  [ -L "$p" ] || { echo ""; return; }
  # readlink -f isn't on macOS by default; resolve manually.
  local target
  target="$(readlink "$p")"
  case "$target" in
    /*) echo "$target" ;;
    *) echo "$(cd "$(dirname "$p")" && cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")" ;;
  esac
}

# True if path is a symlink whose target resolves into REPO_DIR.
is_our_symlink() {
  local p="$1"
  [ -L "$p" ] || return 1
  local t
  t="$(abs_readlink "$p")"
  case "$t" in
    "$REPO_DIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Ensure parent directory exists.
ensure_parent_dir() {
  local p="$1"
  local d
  d="$(dirname "$p")"
  [ -d "$d" ] || mkdir -p "$d"
}

# Remove a now-empty directory (and its empty parents up to PROJECT_DIR).
prune_empty_dirs() {
  local d="$1"
  while [ "$d" != "$PROJECT_DIR" ] && [ "$d" != "/" ]; do
    [ -d "$d" ] || break
    rmdir "$d" 2>/dev/null || break
    d="$(dirname "$d")"
  done
}

# Rewrite the .gitignore marker block. Reads desired dest paths from stdin
# (one per line, no leading slash). If list is empty, the block is removed.
rewrite_gitignore_block() {
  local gi="$PROJECT_DIR/.gitignore"
  local tmp
  tmp="$(mktemp)"

  if [ -f "$gi" ]; then
    awk -v s="$GITIGNORE_MARK_START" -v e="$GITIGNORE_MARK_END" '
      $0 == s { skip=1; next }
      $0 == e { skip=0; next }
      !skip { print }
    ' "$gi" > "$tmp"
    # Trim trailing blank lines.
    # Use a portable shrink: read, then truncate trailing blank lines.
    awk 'BEGIN{blank=0} { if ($0=="") { blank++; next } else { for(i=0;i<blank;i++) print ""; blank=0; print } }' "$tmp" > "${tmp}.2"
    mv "${tmp}.2" "$tmp"
  fi

  local paths
  paths="$(cat)"  # all stdin

  if [ -n "$paths" ]; then
    # Ensure file ends with a newline before appending the block.
    if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | xxd -p 2>/dev/null || tail -c 1 "$tmp" | od -An -tx1)" != "0a" ] && [ "$(tail -c 1 "$tmp" | od -An -tx1 | tr -d ' ')" != "0a" ]; then
      echo "" >> "$tmp"
    fi
    {
      [ -s "$tmp" ] && echo ""
      echo "$GITIGNORE_MARK_START"
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        echo "/$p"
      done <<< "$paths"
      echo "$PIPELINE_ARTIFACTS_PATH"
      echo "$GITIGNORE_MARK_END"
    } >> "$tmp"
  fi

  if [ -s "$tmp" ] || [ -f "$gi" ]; then
    mv "$tmp" "$gi"
  else
    rm -f "$tmp"
  fi
}

# Rewrite the .agents/agents.md marker block with content from the second arg.
# If content is empty, the block is removed; if the file then ends up empty,
# the file is deleted.
rewrite_agents_block() {
  local content="$1"
  local af="$PROJECT_DIR/.agents/agents.md"
  local tmp
  tmp="$(mktemp)"

  if [ -f "$af" ]; then
    awk -v s="$AGENTS_MARK_START" -v e="$AGENTS_MARK_END" '
      $0 == s { skip=1; next }
      $0 == e { skip=0; next }
      !skip { print }
    ' "$af" > "$tmp"
  fi

  if [ -n "$content" ]; then
    if [ -s "$tmp" ]; then
      # Ensure separation between developer content and our block.
      echo "" >> "$tmp"
    fi
    {
      echo "$AGENTS_MARK_START"
      printf '%s\n' "$content"
      echo "$AGENTS_MARK_END"
    } >> "$tmp"
  fi

  # Check whether resulting file is empty / whitespace only.
  if [ -s "$tmp" ] && grep -q '[^[:space:]]' "$tmp"; then
    ensure_parent_dir "$af"
    mv "$tmp" "$af"
  else
    rm -f "$tmp"
    [ -f "$af" ] && rm -f "$af"
    [ -d "$(dirname "$af")" ] && prune_empty_dirs "$(dirname "$af")"
  fi
}


# ---------- install mode ----------
do_install() {
  echo "agentic-dev-team install"
  echo "  repo:    $REPO_DIR"
  echo "  project: $PROJECT_DIR"
  echo ""

  # Build desired pairs.
  local desired
  desired="$(build_desired_pairs)"

  # Build desired-dest set (relative paths).
  local desired_dests
  desired_dests="$(printf '%s\n' "$desired" | awk -F'|' '{print $2}')"

  # Read previous installed dests from .gitignore block.
  local previous
  previous="$(parse_gitignore_block || true)"

  # Stale = previous - desired. Remove stale symlinks that still point at us.
  local removed=0
  if [ -n "$previous" ]; then
    while IFS= read -r prev; do
      [ -z "$prev" ] && continue
      if ! grep -Fxq "$prev" <<< "$desired_dests"; then
        local abs="$PROJECT_DIR/$prev"
        if [ -L "$abs" ] && is_our_symlink "$abs"; then
          rm "$abs"
          prune_empty_dirs "$(dirname "$abs")"
          echo "  removed stale: $prev"
          removed=$((removed+1))
        fi
      fi
    done <<< "$previous"
  fi

  # Refuse phase: pre-check for hard collisions before mutating anything.
  local refusals=0
  while IFS='|' read -r src dest; do
    [ -z "$src" ] && continue
    local abs="$PROJECT_DIR/$dest"
    if [ -L "$abs" ]; then
      local t
      t="$(abs_readlink "$abs")"
      if [ "$t" != "$src" ]; then
        echo "  refuse: $dest" >&2
        echo "          symlink exists pointing elsewhere ($t)." >&2
        echo "          Move it aside or repoint it, then re-run." >&2
        refusals=$((refusals+1))
      fi
    elif [ -e "$abs" ]; then
      echo "  refuse: $dest" >&2
      echo "          real file exists at $abs." >&2
      echo "          Rename or delete it, then re-run." >&2
      refusals=$((refusals+1))
    fi
  done <<< "$desired"

  if [ "$refusals" -gt 0 ]; then
    echo "" >&2
    echo "Refusing to install: $refusals collision(s) above." >&2
    echo "No symlinks were created." >&2
    exit 1
  fi

  # Create / verify symlinks.
  local added=0 unchanged=0
  while IFS='|' read -r src dest; do
    [ -z "$src" ] && continue
    local abs="$PROJECT_DIR/$dest"
    if [ -L "$abs" ]; then
      unchanged=$((unchanged+1))
      continue
    fi
    ensure_parent_dir "$abs"
    ln -s "$src" "$abs"
    added=$((added+1))
  done <<< "$desired"

  # Rewrite .gitignore marker block.
  printf '%s\n' "$desired_dests" | rewrite_gitignore_block

  # Rewrite .agents/agents.md marker block with persona stubs.
  local persona_src="$REPO_DIR/.agents/AGENTIC_DEV_TEAM.md"
  local persona_content=""
  if [ -f "$persona_src" ]; then
    persona_content="$(cat "$persona_src")"
  fi
  rewrite_agents_block "$persona_content"
  if [ -n "$persona_content" ]; then
    echo "  synced: .agents/agents.md (marker block)"
  fi


  echo ""
  echo "Summary: $added added, $unchanged unchanged, $removed removed."
  echo ""
  echo "Done. Try /build-hitl or /build-auto in Claude Code or Antigravity."
}

# ---------- uninstall mode ----------
do_uninstall() {
  echo "agentic-dev-team uninstall"
  echo "  repo:    $REPO_DIR"
  echo "  project: $PROJECT_DIR"
  echo ""

  local desired
  desired="$(build_desired_pairs)"

  local previous
  previous="$(parse_gitignore_block || true)"

  # Union of current desired dests and previously installed dests.
  local all_dests
  all_dests="$(
    {
      printf '%s\n' "$desired" | awk -F'|' '{print $2}'
      printf '%s\n' "$previous"
    } | awk 'NF' | sort -u
  )"

  local removed=0
  while IFS= read -r dest; do
    [ -z "$dest" ] && continue
    local abs="$PROJECT_DIR/$dest"
    if [ -L "$abs" ] && is_our_symlink "$abs"; then
      rm "$abs"
      prune_empty_dirs "$(dirname "$abs")"
      echo "  removed: $dest"
      removed=$((removed+1))
    fi
  done <<< "$all_dests"

  # Remove gitignore block (pass empty stdin).
  echo "" | rewrite_gitignore_block
  echo "  cleaned: .gitignore marker block"

  # Remove agents.md block.
  rewrite_agents_block ""
  echo "  cleaned: .agents/agents.md marker block"

  echo ""
  echo "Uninstalled: $removed symlink(s) removed."
  echo "Your own files and the $REPO_DIR clone are untouched."
}

# ---------- main ----------
case "$MODE" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
