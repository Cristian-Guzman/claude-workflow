#!/usr/bin/env bash
# setup-maintainer.sh — make this clone commit and push as the maintainer, whatever the
# machine's global git config and active `gh` account say. Run once per clone.
#
#   scripts/setup-maintainer.sh --name "Your Name" --email "<id>+<login>@users.noreply.github.com" --gh-user <login> [--no-sign]
#
# Writes ONLY repo-local config (shared by this repo's worktrees); never touches ~/.gitconfig:
#   user.name / user.email                       the commit identity
#   credential.https://github.com.username       the GitHub account git authenticates as (gh's
#                                                credential helper serves that account's token
#                                                even when another account is active)
#   maintainer.name / .email / .ghuser           what the hooks verify against
#   core.hooksPath = scripts/git-hooks           pre-commit (identity) + pre-push (pusher + authors)
#   commit.gpgsign = false  (with --no-sign)     when the global signing key belongs to another account
set -eu
NAME=""; EMAIL=""; GHUSER=""; NOSIGN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --gh-user) GHUSER="$2"; shift 2 ;;
    --no-sign) NOSIGN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$NAME" ] && [ -n "$EMAIL" ] && [ -n "$GHUSER" ] || { sed -n 2,6p "$0" >&2; exit 1; }
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
git config --local user.name "$NAME"
git config --local user.email "$EMAIL"
git config --local maintainer.name "$NAME"
git config --local maintainer.email "$EMAIL"
git config --local maintainer.ghuser "$GHUSER"
git config --local credential.https://github.com.username "$GHUSER"
git config --local core.hooksPath scripts/git-hooks
[ "$NOSIGN" = 1 ] && git config --local commit.gpgsign false
chmod +x scripts/git-hooks/* 2>/dev/null || true
echo "maintainer identity pinned for $ROOT (and its worktrees):"
echo "  commits as   $NAME <$EMAIL>"
echo "  pushes as    $GHUSER (credential pin; no gh auth switch needed)"
echo "  hooks        $(git config --get core.hooksPath)  — pre-commit + pre-push verify both"
[ "$NOSIGN" = 1 ] && echo "  signing      off for this repo"
if gh auth status >/dev/null 2>&1; then
  gh auth status 2>&1 | grep -q "account $GHUSER " || echo "  note: gh has no login for $GHUSER yet — run: gh auth login (the pin needs that account's token)"
fi
