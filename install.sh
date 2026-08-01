#!/usr/bin/env bash
set -euo pipefail

# install.sh — install or update the portable Claude Code workflow into a project.
#
# Usage:
#   ./install.sh /path/to/project              full install (single repo, or workspace root)
#   ./install.sh /path/to/repo --repo-only     seed only the per-repo files (for each extra
#                                              repo in a multi-repo workspace)
#
# Re-running is SAFE and is how you take updates:
#   - core/ files (commands, agents, scripts, hooks, docs) are refreshed in place
#   - seeded files the project owns (codebase-patterns.md, settings.json, ...) are
#     NEVER overwritten once they exist

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
MODE="${2:-full}"

if [ -z "$TARGET" ]; then
  echo "usage: ./install.sh /path/to/project [--repo-only]" >&2
  exit 1
fi
if [ ! -d "$TARGET" ]; then
  echo "error: $TARGET is not a directory" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
CLAUDE_DIR="$TARGET/.claude"

updated=0
seeded=0
skipped=0

copy_core() { # always refresh — these are upstream-owned
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  updated=$((updated + 1))
}

seed() { # copy only if missing — these become project-owned
  local src="$1" dst="$2"
  if [ -f "$dst" ]; then
    skipped=$((skipped + 1))
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    seeded=$((seeded + 1))
    echo "  seeded  ${dst#"$TARGET"/}"
  fi
}

seed_repo_files() {
  # The three files the commands depend on most — required for fast specialization.
  seed "$HERE/templates/repo/codebase-patterns.md" "$CLAUDE_DIR/codebase-patterns.md"
  seed "$HERE/templates/repo/testing-patterns.md"  "$CLAUDE_DIR/testing-patterns.md"
  seed "$HERE/templates/repo/ticket-checklist.md"  "$CLAUDE_DIR/ticket-checklist.md"
  # Optional — /pr falls back to a host default if absent, but seeding it helps.
  seed "$HERE/templates/repo/pr-template.md"       "$CLAUDE_DIR/pr-template.md"
  # Runtime dirs the commands write state into (gitignored below).
  mkdir -p "$CLAUDE_DIR/tickets" "$CLAUDE_DIR/state" "$CLAUDE_DIR/debug" "$CLAUDE_DIR/qa"
}

append_gitignore() {
  local gi="$TARGET/.gitignore"
  local marker="# --- claude-workflow local state ---"
  if [ -f "$gi" ] && grep -qF "$marker" "$gi"; then
    return
  fi
  {
    echo ""
    echo "$marker"
    echo ".claude/state/"
    echo ".claude/tickets/"
    echo ".claude/debug/"
    echo ".claude/qa/"
    echo ".claude/builds/"
    echo ".claude/refactors/"
    echo ".claude/metrics/"
    echo ".claude/screenshots/"
    echo ".claude/settings.local.json"
  } >>"$gi"
  echo "  updated .gitignore (local-state exclusions)"
}

echo "Installing claude-workflow into $TARGET"

if [ "$MODE" = "--repo-only" ]; then
  seed_repo_files
  append_gitignore
else
  # 1. Core — commands, agents, scripts (refreshed on every run)
  for f in "$HERE"/core/commands/*.md;  do copy_core "$f" "$CLAUDE_DIR/commands/$(basename "$f")"; done
  for f in "$HERE"/core/agents/*.md;    do copy_core "$f" "$CLAUDE_DIR/agents/$(basename "$f")"; done
  for f in "$HERE"/core/scripts/*;      do copy_core "$f" "$CLAUDE_DIR/scripts/$(basename "$f")"; done
  chmod +x "$CLAUDE_DIR/scripts/"*.sh 2>/dev/null || true
  # 2. System docs at .claude/ root — commands reference them by these exact paths
  for f in "$HERE"/core/docs/*.md;      do copy_core "$f" "$CLAUDE_DIR/$(basename "$f")"; done

  # 3. Workspace seeds — project-owned after first copy
  seed "$HERE/templates/workspace/settings.template.json" "$CLAUDE_DIR/settings.json"
  seed "$HERE/templates/workspace/repo-profiles/_schema.yaml" "$CLAUDE_DIR/repo-profiles/_schema.yaml"
  seed "$HERE/templates/workspace/repo-profiles/README.md"    "$CLAUDE_DIR/repo-profiles/README.md"

  # 4. Per-repo seeds + runtime dirs
  seed_repo_files
  append_gitignore
fi

echo ""
echo "Done. core updated: $updated | seeded: $seeded | left untouched (already yours): $skipped"
echo ""

if [ ! -f "$TARGET/CLAUDE.md" ]; then
  echo "!! No CLAUDE.md in $TARGET — the commands work far better with one."
  echo "   Run 'claude' in the project and use /init to generate it."
  echo ""
fi

cat <<'CHECKLIST'
Next steps to specialize this project (fastest path first):
  1. Open .claude/settings.json — set your ticket system (Jira CLI / MCP / none)
     and check the permission list matches your tooling.
  2. Run /project-context once — it generates .claude/repo-profiles/<repo>.yaml
     (base branch, CI command, dev server) that every other command reads.
  3. Skim .claude/codebase-patterns.md, testing-patterns.md, ticket-checklist.md —
     each has EXAMPLE entries showing the format. Replace with 2-3 real patterns
     from this codebase now, or just delete the examples and let /learn grow them
     after your first completed tickets.
  4. Work the pipeline: /clarify -> /ticket -> /verify -> /qa -> /pr -> /ci-check -> /learn
     /learn after each ticket is what makes the system project-specific over time.
CHECKLIST
