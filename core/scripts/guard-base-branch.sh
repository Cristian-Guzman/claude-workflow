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
# nothing project-specific is hardcoded here. Profile values are matched
# LITERALLY (grep -Fx), never injected into a regex: a branch named 'dev+next'
# or a quoted YAML value must not silently disable protection.
BASE_LIST=$(grep -h '^base_branch:' "$WORKSPACE/.claude/repo-profiles/"*.yaml 2>/dev/null \
        | awk '{print $2}' | tr -d '"' | tr -d "'" | grep -v '^$' | sort -u)
is_base_branch() {
  case "$1" in main|master|develop) return 0 ;; esac
  [ -n "$BASE_LIST" ] && printf '%s\n' "$BASE_LIST" | grep -qFx -- "$1"
}

# A command may START with shell variable assignments (`S=/w/x; cd /w/x && git commit`,
# `A=1 B=2 cd …`). The `cd` patterns below are anchored at ^, so without stripping these
# first the path is never found and the command is judged against the STALE shell cwd —
# a false-positive block. Handles double-quoted, single-quoted and bare values, with or
# without a `;` separator. Anchored at ^, so `git commit -m "a=b"` is untouched.
strip_leading_assignments() {
  local s="$1" prev="" q="'"
  while [ "$s" != "$prev" ]; do
    prev="$s"
    s=$(printf '%s' "$s" | sed -E "s/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|${q}[^${q}]*${q}|[^[:space:];&|]*)[[:space:]]*;?[[:space:]]*//")
  done
  printf '%s' "$s"
}

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
      # Workspace-root notes only — a *.md DIRECTLY under the root. The case
      # glob alone would cross directory boundaries and exempt every .md in
      # every product repo, so require the remainder to contain no slash.
      case "$file_path" in
        "$WORKSPACE"/*.md)
          rel="${file_path#"$WORKSPACE"/}"
          case "$rel" in
            */*) ;;                          # deeper than root — a product-repo file
            *) exit 0 ;;
          esac ;;
      esac
    fi
    # Walk up to the nearest EXISTING ancestor — a Write into a not-yet-created
    # subdir (dirname doesn't exist) must not bypass the guard.
    pdir=$(dirname "$file_path")
    while [ ! -d "$pdir" ] && [ "$pdir" != "/" ] && [ -n "$pdir" ]; do
      pdir=$(dirname "$pdir")
    done
    root=$(git -C "$pdir" rev-parse --show-toplevel 2>/dev/null) || exit 0
    # Workspace layout: the root repo holds workflow files only — exempt.
    # Single-repo layout: the root IS the product repo — fall through to the branch check.
    [ "$root" = "$WORKSPACE" ] && [ "$LAYOUT" != "single-repo" ] && exit 0
    branch=$(git -C "$root" branch --show-current 2>/dev/null)
    if is_base_branch "$branch"; then
      deny "BLOCKED (guard-base-branch): $(basename "$root") is on base branch '$branch'. Create the ticket branch first: git checkout -b <fix|feat>/PROJ-XXXX-<slug> (feedback_branch_before_edit). If parallel sessions share this checkout, use a worktree per /ticket §5.0."
    fi
    ;;
  Bash)
    command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    printf '%s' "$command" | grep -qE 'git[^|;&]*[[:space:]](commit|push)([[:space:]]|$)' || exit 0
    dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
    # The command may change directory before running git — honor `git -C <path>`
    # first, then a leading `cd <path> && ...` (double-quoted, single-quoted, or
    # bare). Otherwise a compound command like `cd /elsewhere && git commit` gets
    # judged against the STALE shell cwd (false positives when the shell happens
    # to sit in an unrelated repo).
    cmd_path=$(strip_leading_assignments "$command")
    cdir=$(printf '%s' "$cmd_path" | sed -n 's/.*git -C \([^ ]*\).*/\1/p' | head -1)
    if [ -z "$cdir" ]; then
      cdir=$(printf '%s' "$cmd_path" | sed -n 's/^[[:space:]]*cd[[:space:]]\{1,\}"\([^"]\{1,\}\)".*/\1/p' | head -1)
      [ -z "$cdir" ] && cdir=$(printf '%s' "$cmd_path" | sed -n "s/^[[:space:]]*cd[[:space:]]\\{1,\\}'\\([^']\\{1,\\}\\)'.*/\\1/p" | head -1)
      [ -z "$cdir" ] && cdir=$(printf '%s' "$cmd_path" | sed -n 's/^[[:space:]]*cd[[:space:]]\{1,\}\([^;&|[:space:]]\{1,\}\).*/\1/p' | head -1)
    fi
    # Normalize the extracted path: tilde and relative forms resolve against
    # the tool cwd — never leave them to chance.
    case "$cdir" in
      "~")   cdir="$HOME" ;;
      "~/"*) cdir="$HOME/${cdir#\~/}" ;;
    esac
    case "$cdir" in
      ""|/*) ;;
      *) cdir="$dir/$cdir" ;;
    esac
    # FAIL CLOSED: if the extracted target doesn't resolve to a repo, judge the
    # tool cwd instead of allowing — an unparseable `cd` must not bypass the guard.
    root=""
    if [ -n "$cdir" ]; then
      root=$(git -C "$cdir" rev-parse --show-toplevel 2>/dev/null) || root=""
    fi
    if [ -z "$root" ]; then
      root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
    fi
    if [ "$root" = "$WORKSPACE" ] && [ "$LAYOUT" != "single-repo" ]; then
      deny "BLOCKED (guard-base-branch): commit/push in the workspace-root repo — the .claude workflow system is never committed (feedback_no_commit_workflow_files). Installing into a single product repo? Set WORKFLOW_LAYOUT=single-repo in settings.json env."
    fi
    branch=$(git -C "$root" branch --show-current 2>/dev/null)
    # A command that CREATES the ticket branch before committing is not a base-branch
    # commit: `git checkout -b f/x && git commit` lands on f/x, but the guard runs BEFORE
    # the checkout, so the branch still reads as the base. Exempt it only when creation
    # comes first AND is chained with && — `git commit && git checkout -b x` commits on
    # the base, and `git checkout -b x; git commit` commits on the base when the checkout
    # fails, so both stay blocked.
    creates_branch_first='git[[:space:]]+(checkout|switch)[[:space:]]+-[bBcC][^;]*&&[^;]*git[^|;&]*[[:space:]]commit([[:space:]]|$)'
    if printf '%s' "$command" | grep -qE 'git[^|;&]*[[:space:]]commit([[:space:]]|$)' \
       && ! printf '%s' "$command" | grep -qE "$creates_branch_first" \
       && is_base_branch "$branch"; then
      deny "BLOCKED (guard-base-branch): committing on base branch '$branch' in $(basename "$root"). Create the ticket branch first (feedback_branch_before_edit). If you ARE on a ticket branch in another checkout, start the command with \`cd <worktree> &&\` and a literal path — the guard reads the target from a leading \`cd\` or \`git -C\`, and judges the session cwd when it finds neither."
    fi
    ;;
esac
exit 0
