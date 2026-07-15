#!/usr/bin/env bash
# archive-learned-tickets.sh — sweep terminal (status: learned) ticket state files,
# plus their sidecars (PROJ-XXXX-*.md/.yaml) and PROJ-XXXX-screenshots/ dirs, into
# {repo}/.claude/tickets/_archive/, then re-point .claude/state/index.json `path`
# fields so index-driven consumers (/clarify prior-art §1.5b, /status) keep resolving.
#
# Why this is safe: a plain `mv` does NOT fire the PostToolUse index hook, so the index
# would otherwise point at the old flat paths (file-missing on --verify). This script
# rewrites the paths itself. Learned tickets are already flagged `archived: true` in the
# index, so nothing changes how they're *treated* — only where the file lives.
#
# DEFAULT = DRY RUN (lists moves, touches nothing). Pass --apply to execute.
# Idempotent: re-running only sweeps newly-learned tickets.
#
# Known limitation (the cost of the cheap _archive approach): re-opening a learned ticket
# means its file is under _archive/; commands that direct-resolve `tickets/PROJ-XXXX.md`
# won't find it until you move it back out. Acceptable for terminal tickets.
set -euo pipefail

# Workspace root containing your repos (each with .claude/tickets/); override via env.
WS="${WORKSPACE_ROOT:?set WORKSPACE_ROOT to your workspace root (the directory containing your repos)}"
INDEX="$WS/.claude/state/index.json"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== archive-learned-tickets ($([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)) ==="
total_files=0
total_tickets=0

for tdir in "$WS"/*/.claude/tickets; do
  [ -d "$tdir" ] || continue
  repo=$(basename "$(dirname "$(dirname "$tdir")")")
  arch="$tdir/_archive"
  repo_tickets=0
  repo_files=0
  batch=""

  # learned parent state files only (skip anything already under _archive)
  for f in "$tdir"/*.md; do
    [ -e "$f" ] || continue
    grep -q '^status: learned' "$f" 2>/dev/null || continue
    # Ticket key prefix: adjust the regex to your ticket project key (e.g. PROJ), or set TICKET_KEY.
    id=$(basename "$f" .md | grep -oE "^${TICKET_KEY:-PROJ}-[0-9]+" || true)
    [ -n "$id" ] || continue
    repo_tickets=$((repo_tickets+1))

    # parent + sidecars + screenshot dir, exact-id matched
    for item in "$tdir/$id".md "$tdir/$id"-* "$tdir/$id"_*; do
      [ -e "$item" ] || continue
      case "$item" in *"/_archive/"*) continue;; esac
      repo_files=$((repo_files+1))
      batch="$batch$item"$'\n'
    done
  done

  [ "$repo_tickets" = 0 ] && continue
  total_tickets=$((total_tickets+repo_tickets))
  total_files=$((total_files+repo_files))
  printf '%-30s %s learned ticket(s), %s file(s)/dir(s) to move\n' "$repo" "$repo_tickets" "$repo_files"

  if [ "$APPLY" = 1 ]; then
    mkdir -p "$arch"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      mv "$item" "$arch"/
    done <<< "$batch"
  else
    # dry-run: show up to 4 examples
    echo "$batch" | grep -v '^$' | head -4 | sed 's,^,    would move: ,'
    [ "$repo_files" -gt 4 ] && echo "    … and $((repo_files-4)) more"
  fi
done

echo "---"
echo "TOTAL: $total_tickets learned tickets, $total_files files/dirs"

if [ "$APPLY" = 1 ]; then
  echo "=== re-pointing index.json paths ==="
  cp "$INDEX" "$INDEX.bak.$(date +%Y%m%d-%H%M%S)"
  python3 - "$INDEX" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
n = 0
for e in d["entries"]:
    path = e.get("path")
    if not path or os.path.exists(path):
        continue
    d2 = os.path.join(os.path.dirname(path), "_archive", os.path.basename(path))
    if os.path.exists(d2):
        e["path"] = d2
        n += 1
tmp = p + ".tmp"
json.dump(d, open(tmp, "w"), indent=2)
# validate before swap
json.load(open(tmp))
os.replace(tmp, p)
print(f"re-pointed {n} index entries to _archive/")
PY
  echo "Backup written: $INDEX.bak.*"
  echo "Done. Verify: /status should still list active work; /clarify prior-art still resolves learned tickets."
else
  echo "(dry run — nothing moved. Re-run with: bash $0 --apply)"
fi
