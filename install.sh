#!/usr/bin/env bash
#
# agentic-dev-team installer
#
# Usage:
#   <repo-clone>/install.sh                # install for all tools into current working directory
#   <repo-clone>/install.sh <tools>        # install only for these tools, e.g. claude or claude,codex
#   <repo-clone>/install.sh <project-dir>  # install into the given project directory
#   <repo-clone>/install.sh --uninstall    # uninstall from current working directory
#   <repo-clone>/install.sh --no-allow     # install, but add no permission rules
#
# Tools: claude (Claude Code), codex, antigravity, opencode. Separate them
# with commas or spaces; with none, all four are installed. Each run installs
# exactly the tools it names and removes the links of the others, so re-run
# with the same tools to update. To install into a directory with one of
# these names, write it as a path (./claude).
#
# What it does:
#   - For each agent, command, workflow, pipeline script and driver adapter in
#     this repo, creates a per-file symlink at the matching path in the
#     consuming project, and one symlink per Codex skill folder. The agent
#     prompts, pipeline docs, scripts and driver adapters in .claude/ are
#     installed for every tool, because every tool reads them; the commands,
#     workflows, skills and agent stubs only for the tools that use them.
#   - Manages a marker-fenced block in the project's .gitignore listing the
#     installed paths (so per-developer absolute symlink targets aren't
#     committed).
#   - For antigravity, manages a marker-fenced block in the project's
#     .agents/agents.md containing the inlined persona stubs from this repo's
#     .agents/AGENTIC_DEV_TEAM.md (Antigravity auto-loads agents.md into
#     user_rules).
#   - Adds the pipeline's own permission rules: for claude, its script and the
#     test drivers' MCP tools in the project's .claude/settings.local.json, so
#     Claude Code does not stop to ask mid-run; for codex, a rules file,
#     .codex/rules/agentic-dev-team.rules, that lets Codex run the script
#     outside its sandbox. --no-allow skips this, and --uninstall removes
#     exactly the rules it added.
#   - Creates the optional pipeline config .agentic-dev-team/config.yaml
#     (every setting commented out, git-ignored by .agentic-dev-team/.gitignore)
#     when it does not exist yet. See HOW_IT_WORKS.md, "Configuration".
#
# Safety:
#   - Never overwrites a developer's own files. Real files at our install
#     destinations cause a refusal with a clear message.
#   - Only modifies content inside the marker-fenced blocks in .gitignore
#     and .agents/agents.md; content outside markers is left alone.
#   - --uninstall removes only what this script created.
#   - Never edits or deletes anything in .agentic-dev-team/, also not on
#     --uninstall: that is your configuration.

set -euo pipefail

# ---------- paths ----------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALL_TOOLS="claude codex antigravity opencode"

# True if the arg is a comma-separated list of one or more known tool names.
is_tool_list() {
  local item found=1
  for item in ${1//,/ }; do
    case " $ALL_TOOLS " in
      *" $item "*) found=0 ;;
      *) return 1 ;;
    esac
  done
  return "$found"
}

# Parse args: a tool list selects tools, any other non-flag arg is the
# project dir; --uninstall switches mode.
MODE="install"
PROJECT_DIR=""
ALLOW=1
TOOLS=""
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    --no-allow) ALLOW=0 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^#//'
      exit 0
      ;;
    --*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    *)
      if is_tool_list "$arg"; then
        TOOLS="$TOOLS ${arg//,/ }"
      elif [ -d "$arg" ]; then
        PROJECT_DIR="$arg"
      else
        echo "Not a tool or a directory: $arg" >&2
        echo "Tools: ${ALL_TOOLS// /, } (separate them with commas; none means all)." >&2
        exit 2
      fi
      ;;
  esac
done
if [ "$MODE" = "uninstall" ] && [ -n "$TOOLS" ]; then
  echo "--uninstall removes every tool. To remove only some, run install.sh with the tools you keep." >&2
  exit 2
fi
# Keep the canonical order and drop duplicates; no tools means all of them.
SELECTED=""
for tool in $ALL_TOOLS; do
  case " $TOOLS " in
    *" $tool "*) SELECTED="$SELECTED $tool" ;;
  esac
done
TOOLS="${SELECTED# }"
TOOLS="${TOOLS:-$ALL_TOOLS}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# ---------- markers ----------
GITIGNORE_MARK_START="# agentic-dev-team:start (managed by install.sh — do not edit by hand)"
GITIGNORE_MARK_END="# agentic-dev-team:end"
AGENTS_MARK_START="<!-- agentic-dev-team:start (managed by install.sh — do not edit) -->"
AGENTS_MARK_END="<!-- agentic-dev-team:end -->"

PIPELINE_ARTIFACTS_PATH="/pipeline_artifacts/"

# ---------- helpers ----------

# True if the tool is selected.
has_tool() {
  case " $TOOLS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# The display names of the selected tools that run the commands as slash
# commands, e.g. "Claude Code or OpenCode". Codex runs them as skills.
tool_names() {
  local tool names=() i
  for tool in $TOOLS; do
    case "$tool" in
      claude) names+=("Claude Code") ;;
      antigravity) names+=("Antigravity") ;;
      opencode) names+=("OpenCode") ;;
    esac
  done
  case "${#names[@]}" in
    0) ;;
    1) echo "${names[0]}" ;;
    2) echo "${names[0]} or ${names[1]}" ;;
    *)
      for ((i = 0; i < ${#names[@]} - 1; i++)); do printf '%s, ' "${names[$i]}"; done
      echo "or ${names[${#names[@]} - 1]}"
      ;;
  esac
}

# Print the desired (src, dest) pairs by walking source dirs.
# Output format: "<abs-src>|<rel-dest>" one per line.
build_desired_pairs() {
  local f rel files=()
  shopt -s nullglob
  # The agent prompts, scripts and driver adapters are read by every tool;
  # the rest only by the tools that use it. The Codex skills find their
  # command file in .claude/commands/, so codex needs those links too.
  if has_tool claude || has_tool codex; then files+=("$REPO_DIR"/.claude/commands/*.md); fi
  files+=("$REPO_DIR"/.claude/agents/*.md)
  if has_tool antigravity; then files+=("$REPO_DIR"/.agents/workflows/*.md); fi
  if has_tool opencode; then files+=("$REPO_DIR"/.opencode/agents/*.md "$REPO_DIR"/.opencode/commands/*.md); fi
  if has_tool codex; then files+=("$REPO_DIR"/.agents/skills/*/ "$REPO_DIR"/.codex/agents/*.toml); fi
  files+=("$REPO_DIR"/.claude/adt/scripts/*.sh "$REPO_DIR"/.claude/adt/drivers/*.md)
  for f in ${files[@]+"${files[@]}"}; do
    # A Codex skill is a folder, linked whole (Codex follows a linked skill
    # folder), so the glob above ends in a slash: drop it.
    f="${f%/}"
    rel="${f#$REPO_DIR/}"
    printf '%s|%s\n' "$f" "$rel"
  done
  # The pipeline docs: Part A for agents, Part B and the config rules for
  # the orchestrator.
  for f in "$REPO_DIR"/.claude/AGENTIC_DEV_TEAM_*.md; do
    printf '%s|%s\n' "$f" ".claude/$(basename "$f")"
  done
  shopt -u nullglob
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
    *)
      local parent
      if parent="$(cd "$(dirname "$p")" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && pwd)" \
         && [ -n "$parent" ]; then
        echo "$parent/$(basename "$target")"
      else
        # The target's parent doesn't exist (broken symlink). Echo the raw
        # readlink value so the caller still sees a foreign target instead of
        # an empty string it would misclassify.
        echo "$target"
      fi
      ;;
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

# Print a file's octal mode, or empty if it doesn't exist.
# stat's flags differ between GNU (-c) and BSD/macOS (-f).
file_mode() {
  local p="$1"
  [ -f "$p" ] || { echo ""; return; }
  stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null || echo ""
}

# Move a temp file into place without inheriting mktemp's 0600. Restores the
# destination's previous mode, or falls back to the user's umask for a new file.
install_tmp_over() {
  local tmp="$1" dest="$2"
  local mode
  mode="$(file_mode "$dest")"
  mv "$tmp" "$dest"
  if [ -n "$mode" ]; then
    chmod "$mode" "$dest"
  else
    # New file: apply umask to 666 the way a normal shell redirect would.
    chmod "$(printf '%o' $(( 0666 & ~$(umask) )))" "$dest"
  fi
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
    install_tmp_over "$tmp" "$gi"
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
    # Trim trailing blank lines left behind by the removed block, so that
    # repeated install/uninstall cycles don't accumulate them. Interior blank
    # lines in the developer's own content are preserved.
    awk 'BEGIN{blank=0} { if ($0=="") { blank++; next } else { for(i=0;i<blank;i++) print ""; blank=0; print } }' "$tmp" > "${tmp}.2"
    mv "${tmp}.2" "$tmp"
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
    install_tmp_over "$tmp" "$af"
  else
    rm -f "$tmp"
    rm -f "$af"
    if [ -d "$(dirname "$af")" ]; then
      prune_empty_dirs "$(dirname "$af")"
    fi
  fi
}

# True if .agents/agents.md has our marker block.
has_agents_block() {
  [ -f "$PROJECT_DIR/.agents/agents.md" ] && grep -qxF "$AGENTS_MARK_START" "$PROJECT_DIR/.agents/agents.md"
}


# ---------- install mode ----------
do_install() {
  echo "agentic-dev-team install"
  echo "  repo:    $REPO_DIR"
  echo "  project: $PROJECT_DIR"
  echo "  tools:   ${TOOLS// /, }"
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

  # Rewrite .agents/agents.md marker block with persona stubs, for
  # Antigravity only. Without it, remove a block an earlier run added, and
  # leave a file without our block alone.
  local persona_src="$REPO_DIR/.agents/AGENTIC_DEV_TEAM.md"
  local persona_content=""
  if has_tool antigravity && [ -f "$persona_src" ]; then
    persona_content="$(cat "$persona_src")"
  fi
  if [ -n "$persona_content" ]; then
    rewrite_agents_block "$persona_content"
    echo "  synced: .agents/agents.md (marker block)"
  elif has_agents_block; then
    rewrite_agents_block ""
    echo "  removed: .agents/agents.md (marker block)"
  fi

  # Pre-approve the pipeline's own commands in Claude Code and Codex, each
  # only when it is installed. Rules an earlier run added for a tool not
  # installed now stay: the script they allow is still installed, and that
  # tool's plugin may use them.
  local allow_args=(allow --project "$PROJECT_DIR")
  if ! has_tool codex; then allow_args+=(--only claude); fi
  if ! has_tool claude; then allow_args+=(--only codex); fi
  if { has_tool claude || has_tool codex; } && [ "$ALLOW" = 1 ] && [ -f "$REPO_DIR/.claude/adt/scripts/adt.sh" ]; then
    bash "$REPO_DIR/.claude/adt/scripts/adt.sh" "${allow_args[@]}" 2>&1 | sed 's/^adt: /  /'
  fi

  # Create the optional config once. It never overwrites an existing file,
  # and a failure (exit 1) never stops the install.
  local init_out
  init_out="$(bash "$REPO_DIR/plugins/agentic-dev-team/scripts/adt-run-agent.sh" --init-config "$PROJECT_DIR" 2>&1 || true)"
  if [ -n "$init_out" ]; then
    printf '%s\n' "$init_out" | sed 's/^/  /'
  fi

  echo ""
  echo "Summary: $added added, $unchanged unchanged, $removed removed."
  echo ""
  local names
  names="$(tool_names)"
  if [ -n "$names" ]; then
    echo "Done. Try /build-auto-fast, /build-auto, /build-guided, /plan-spec, or /plan-design in $names."
    if has_tool codex; then echo "In Codex, type \$build-auto-fast and the others."; fi
  else
    echo "Done. Try \$build-auto-fast, \$build-auto, \$build-guided, \$plan-spec, or \$plan-design in Codex."
  fi
  echo "Optional config: .agentic-dev-team/config.yaml (see HOW_IT_WORKS.md, \"Configuration\")."
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

  # Remove the permission rules install added, and only those.
  if [ -f "$REPO_DIR/.claude/adt/scripts/adt.sh" ]; then
    bash "$REPO_DIR/.claude/adt/scripts/adt.sh" allow --remove --project "$PROJECT_DIR" 2>&1 | sed 's/^adt: /  /'
  fi

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

  if [ -d "$PROJECT_DIR/.agentic-dev-team" ]; then
    echo "  kept .agentic-dev-team/ (your configuration; delete it yourself if you do not need it)"
  fi

  echo ""
  echo "Uninstalled: $removed symlink(s) removed."
  echo "Your own files and the $REPO_DIR clone are untouched."
}

# ---------- main ----------
case "$MODE" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
