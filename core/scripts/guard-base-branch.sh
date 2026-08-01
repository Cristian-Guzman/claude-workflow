#!/bin/bash
# PreToolUse guard — mechanical enforcement of rules that used to live only in memory prose:
#   1. No Edit/Write inside a product repo while it sits on a base branch (feedback_branch_before_edit)
#   2. No `git commit` while a product repo sits on a base branch
#   3. No `git commit`/`git push` in the workspace-root repo (feedback_no_commit_workflow_files)
# Exit 2 blocks the tool call and feeds stderr back to Claude. Exit 0 allows.
# Exemptions: any path under a .claude/ dir (state files), workspace-root *.md, non-git paths.

# Workspace root: the directory that holds the .claude workflow system.
# Resolution order: $WORKSPACE_ROOT env > $CLAUDE_PROJECT_DIR (set by Claude Code
# for every hook invocation) > cwd. No silent hardcoded fallback — a wrong root
# would disable the guard without telling anyone.
WORKSPACE="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
# Layout: "workspace" (default) = the root repo holds workflow files only and is
#         never committed. "single-repo" = the root IS the product repo; commits
#         are allowed there, but base-branch protection still applies to it.
# Set via `"env": {"WORKFLOW_LAYOUT": "single-repo"}` in .claude/settings.json.
LAYOUT="${WORKFLOW_LAYOUT:-workspace}"
# Protected base branches: main/master/develop always, plus every base_branch
# declared in the repo profiles — the profiles are the single source of truth,
# nothing project-specific is hardcoded here.
BASE_RE='^(main|master|develop)$'
extra=$(grep -h '^base_branch:' "$WORKSPACE/.claude/repo-profiles/"*.yaml 2>/dev/null \
        | awk '{print $2}' | grep -vE '^(main|master|develop)$' | grep -v '^$' | sort -u | paste -sd '|' -)
[ -n "$extra" ] && BASE_RE="^(main|master|develop|${extra})$"

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')

deny() { printf '%s\n' "$1" >&2; exit 2; }

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    [ -n "$file_path" ] || exit 0
    case "$file_path" in
      */.claude/*) exit 0 ;;                 # state, patterns, workflow files — any repo
    esac
    if [ "$LAYOUT" != "single-repo" ]; then
      case "$file_path" in
        "$WORKSPACE"/*.md) exit 0 ;;         # workspace-root notes (workspace layout only)
      esac
    fi
    root=$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel 2>/dev/null) || exit 0
    # Workspace layout: the root repo holds workflow files only — exempt.
    # Single-repo layout: the root IS the product repo — fall through to the branch check.
    [ "$root" = "$WORKSPACE" ] && [ "$LAYOUT" != "single-repo" ] && exit 0
    branch=$(git -C "$root" branch --show-current 2>/dev/null)
    if [[ "$branch" =~ $BASE_RE ]]; then
      deny "BLOCKED (guard-base-branch): $(basename "$root") is on base branch '$branch'. Create the ticket branch first: git checkout -b <fix|feat>/PROJ-XXXX-<slug> (feedback_branch_before_edit). If parallel sessions share this checkout, use a worktree per /ticket §5.0."
    fi
    ;;
  Bash)
    command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    printf '%s' "$command" | grep -qE 'git[^|;&]*[[:space:]](commit|push)([[:space:]]|$)' || exit 0
    dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
    cdir=$(printf '%s' "$command" | sed -n 's/.*git -C \([^ ]*\).*/\1/p' | head -1)
    [ -n "$cdir" ] && dir="$cdir"
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
    if [ "$root" = "$WORKSPACE" ] && [ "$LAYOUT" != "single-repo" ]; then
      deny "BLOCKED (guard-base-branch): commit/push in the workspace-root repo — the .claude workflow system is never committed (feedback_no_commit_workflow_files). Installing into a single product repo? Set WORKFLOW_LAYOUT=single-repo in settings.json env."
    fi
    branch=$(git -C "$root" branch --show-current 2>/dev/null)
    if printf '%s' "$command" | grep -qE 'git[^|;&]*[[:space:]]commit([[:space:]]|$)' && [[ "$branch" =~ $BASE_RE ]]; then
      deny "BLOCKED (guard-base-branch): committing on base branch '$branch' in $(basename "$root"). Create the ticket branch first (feedback_branch_before_edit)."
    fi
    ;;
esac
exit 0
