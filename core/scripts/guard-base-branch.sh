#!/bin/bash
# PreToolUse guard — mechanical enforcement of rules that used to live only in memory prose:
#   1. No Edit/Write inside a product repo while it sits on a base branch (feedback_branch_before_edit)
#   2. No `git commit` while a product repo sits on a base branch
#   3. No `git commit`/`git push` in the workspace-root repo (feedback_no_commit_workflow_files)
# Exit 2 blocks the tool call and feeds stderr back to Claude. Exit 0 allows.
# Exemptions: any path under a .claude/ dir (state files), workspace-root *.md, non-git paths.

# Workspace root: the directory that holds the .claude workflow system (never committed).
# Set WORKSPACE_ROOT in your environment, or edit the fallback path below.
WORKSPACE="${WORKSPACE_ROOT:-$HOME/workspace}"
# Protected base branches. Defaults: main/master/develop.
# ADD PROJECT-SPECIFIC BASE BRANCHES HERE — some repos use a non-default base
# branch (e.g. develop-v2); record it in the repo profile and append it to this
# alternation, e.g. '^(main|master|develop|develop-v2)$'.
BASE_RE='^(main|master|develop|develop-v2)$'

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')

deny() { printf '%s\n' "$1" >&2; exit 2; }

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    [ -n "$file_path" ] || exit 0
    case "$file_path" in
      */.claude/*) exit 0 ;;                 # state, patterns, workflow files — any repo
      "$WORKSPACE"/*.md) exit 0 ;;           # workspace-root notes
    esac
    root=$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel 2>/dev/null) || exit 0
    [ "$root" = "$WORKSPACE" ] && exit 0     # workspace-root repo holds workflow files only
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
    if [ "$root" = "$WORKSPACE" ]; then
      deny "BLOCKED (guard-base-branch): commit/push in the workspace-root repo — the .claude workflow system is never committed (feedback_no_commit_workflow_files)."
    fi
    branch=$(git -C "$root" branch --show-current 2>/dev/null)
    if printf '%s' "$command" | grep -qE 'git[^|;&]*[[:space:]]commit([[:space:]]|$)' && [[ "$branch" =~ $BASE_RE ]]; then
      deny "BLOCKED (guard-base-branch): committing on base branch '$branch' in $(basename "$root"). Create the ticket branch first (feedback_branch_before_edit)."
    fi
    ;;
esac
exit 0
