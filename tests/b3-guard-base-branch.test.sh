#!/bin/bash
# Fixture test for core/scripts/guard-base-branch.sh — path detection and the
# base-branch commit rule. Builds a scratch workspace with a product repo on the
# base branch plus a worktree on a ticket branch, feeds PreToolUse JSON through the
# hook and asserts exit codes (2 = blocked, 0 = allowed).
#
# Regressions covered (harvest 2026-11-a, 5 occurrences):
#   leading `NAME=value` before the `cd` · compound `git checkout -b x && git commit`
# Fail-closed cases that must STAY blocked are asserted alongside each, because a
# path-detection fix is only correct if it does not become a bypass.
#
# Usage: bash tests/b3-guard-base-branch.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/core/scripts/guard-base-branch.sh"
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/.claude/repo-profiles"
cat > "$WS/.claude/repo-profiles/web-app.yaml" <<'YAML'
name: web-app
base_branch: develop_documents_v2
YAML
export CLAUDE_PROJECT_DIR="$WS"
unset WORKSPACE_ROOT WORKFLOW_LAYOUT 2>/dev/null || true

q() { git "$@" >/dev/null 2>&1; }
# workspace root is itself a repo (workflow files only — commits there are blocked)
q init "$WS"; q -C "$WS" commit --allow-empty -m root
# product repo on the base branch, plus a worktree on a ticket branch
q init -b main "$WS/web-app"
q -C "$WS/web-app" -c user.email=t@t -c user.name=t commit --allow-empty -m init
q -C "$WS/web-app" worktree add "$WS/wt" -b feature/PROJ-1-thing
# a second product repo sitting on a PROFILE-declared base branch
q init -b develop_documents_v2 "$WS/api-bff"
q -C "$WS/api-bff" -c user.email=t@t -c user.name=t commit --allow-empty -m init

pass=0; fail=0
check() {  # check <want-exit> <label> <cwd> <command>
  local want="$1" label="$2" cwd="$3" cmd="$4" got
  jq -cn --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}' \
    | "$HOOK" >/dev/null 2>"$WS/err"; got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   %s (exit %s)\n' "$label" "$got"; pass=$((pass+1))
  else
    printf 'FAIL %s — wanted %s, got %s; stderr: %s\n' "$label" "$want" "$got" "$(head -c 160 "$WS/err")"; fail=$((fail+1))
  fi
}

echo "# regressions: the command names a ticket-branch checkout, the guard must find it"
check 0 "leading assignment + cd to worktree on a ticket branch" \
        "$WS/web-app" "S=$WS/wt; cd $WS/wt && git commit -m x"
check 0 "several leading env assignments, no semicolon" \
        "$WS/web-app" "A=1 B=2 cd $WS/wt && git commit -m x"
check 0 "leading assignment + git -C to the worktree" \
        "$WS/web-app" "S=1; git -C $WS/wt commit -m x"
check 0 "quoted assignment value" \
        "$WS/web-app" "S=\"$WS/wt\"; cd $WS/wt && git commit -m x"
check 0 "plain cd still works (no regression)" \
        "$WS/web-app" "cd $WS/wt && git commit -m x"

echo "# regression: branch creation chained before the commit"
check 0 "git checkout -b <new> && git commit on base" \
        "$WS/web-app" "git checkout -b feature/PROJ-2 && git commit -m x"
check 0 "git switch -c <new> && git commit on base" \
        "$WS/web-app" "git switch -c feature/PROJ-3 && git commit -m x"
check 0 "branch creation, intermediate step, then commit" \
        "$WS/web-app" "git checkout -b feature/PROJ-4 && yarn ci && git commit -m x"

echo "# fail closed: the fixes must not become a bypass"
check 2 "plain commit on base branch" \
        "$WS/web-app" "git commit -m x"
check 2 "commit BEFORE the branch creation" \
        "$WS/web-app" "git commit -m x && git checkout -b feature/PROJ-5"
check 2 "branch creation with ';' (no short-circuit) then commit" \
        "$WS/web-app" "git checkout -b feature/PROJ-6; git commit -m x"
check 2 "leading assignment + cd to a repo that IS on a base branch" \
        "$WS/wt" "S=1; cd $WS/web-app && git commit -m x"
check 2 "commit message that merely LOOKS like an assignment" \
        "$WS/web-app" "git commit -m \"a=b\""
check 2 "cd to a nonexistent path falls back to the session cwd" \
        "$WS/web-app" "cd $WS/nope && git commit -m x"
check 2 "profile-declared base branch is protected too" \
        "$WS/api-bff" "git commit -m x"
check 2 "commit in the workspace-root repo" \
        "$WS" "git commit -m x"

echo "# allowed as before"
check 0 "commit from a ticket-branch cwd" \
        "$WS/wt" "git commit -m x"
check 0 "a command with no commit/push is ignored" \
        "$WS/web-app" "git status --porcelain"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
