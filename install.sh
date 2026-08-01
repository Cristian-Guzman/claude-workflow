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
#   - core/ files (commands, agents, scripts, docs) are refreshed in place
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
  # Minimal CLAUDE.md skeleton — every command loads it first; /init can replace it.
  seed "$HERE/templates/repo/CLAUDE.template.md"   "$TARGET/CLAUDE.md"
  # Runtime dirs the commands and hooks write state into (gitignored below).
  mkdir -p "$CLAUDE_DIR/tickets" "$CLAUDE_DIR/state" "$CLAUDE_DIR/debug" "$CLAUDE_DIR/qa" \
           "$CLAUDE_DIR/builds" "$CLAUDE_DIR/refactors" "$CLAUDE_DIR/metrics" \
           "$CLAUDE_DIR/screenshots" "$CLAUDE_DIR/e2e" "$CLAUDE_DIR/demos"
  # State index — /status, /clarify and the analytics scripts read it; the
  # PostToolUse hook upserts into it. Same shape state-index-upsert.sh self-inits.
  [ -f "$CLAUDE_DIR/state/index.json" ] || printf '{"version":2,"generated":"","entries":[]}\n' > "$CLAUDE_DIR/state/index.json"
}

IGNORE_LINES=".claude/state/
.claude/tickets/
.claude/debug/
.claude/qa/
.claude/builds/
.claude/refactors/
.claude/metrics/
.claude/screenshots/
.claude/e2e/
.claude/demos/
.claude/settings.local.json"

append_gitignore() {
  local gi="$TARGET/.gitignore"
  local marker="# --- claude-workflow local state ---"
  local added=0 line
  if [ ! -f "$gi" ] || ! grep -qF "$marker" "$gi"; then
    { echo ""; echo "$marker"; printf '%s\n' "$IGNORE_LINES"; } >>"$gi"
    echo "  updated .gitignore (local-state exclusions)"
    return
  fi
  # Marker exists (an earlier install) — line-idempotent upgrade: append any
  # NEW exclusion lines a newer version introduced, never duplicate old ones.
  while IFS= read -r line; do
    grep -qxF "$line" "$gi" || { printf '%s\n' "$line" >>"$gi"; added=1; }
  done <<EOF_LINES
$IGNORE_LINES
EOF_LINES
  [ "$added" = 1 ] && echo "  updated .gitignore (new local-state exclusions)"
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

if grep -q '{placeholder}\|{One paragraph' "$TARGET/CLAUDE.md" 2>/dev/null; then
  echo "!! CLAUDE.md is the seeded skeleton — fill the {placeholders} or run /init"
  echo "   and merge. Every command loads it first; it's the highest-leverage file."
  echo ""
fi

cat <<'CHECKLIST'
Next steps to specialize this project (fastest path first):
  1. Open .claude/settings.json — check the permission list matches your tooling.
     Installing into a SINGLE repo (no multi-repo workspace)? Change the seeded
     env value to "WORKFLOW_LAYOUT": "single-repo" so the branch guard treats
     this root as a product repo.
  2. Run /project-context once — it generates .claude/repo-profiles/<repo>.yaml
     (base branch, CI command, tracker + transition ids, dev server) that every
     other command reads. tracker_system: none is a first-class mode.
  3. Skim .claude/codebase-patterns.md, testing-patterns.md, ticket-checklist.md —
     each has EXAMPLE entries showing the format. Replace with 2-3 real patterns
     from this codebase now, or just delete the examples and let /learn grow them
     after your first completed tickets.
  4. Work the pipeline: /clarify -> /ticket -> /verify -> /qa -> /pr -> /ci-check -> /learn
     (no tracker? /build replaces /clarify+/ticket)
     /learn after each ticket is what makes the system project-specific over time.
CHECKLIST
