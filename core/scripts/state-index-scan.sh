#!/usr/bin/env bash
# state-index-scan.sh — Full scan of all workspace repos; rebuilds or verifies .claude/state/index.json
#
# Usage:
#   state-index-scan.sh --bootstrap      # rebuild index from scratch by ingesting every state file
#   state-index-scan.sh --verify         # mark ghosts (entries with missing files) as archived; DO NOT rebuild
#   state-index-scan.sh --verify-tags    # report entries that have no tags and low-confidence auto-tagged ones
#   state-index-scan.sh --dry-run        # print what --bootstrap would do, write nothing

set -euo pipefail

WORKSPACE="${WORKSPACE:-${WORKSPACE_ROOT:-$PWD}}"
INDEX="$WORKSPACE/.claude/state/index.json"
UPSERT="$WORKSPACE/.claude/scripts/state-index-upsert.sh"

mode="${1:---bootstrap}"

case "$mode" in
  --bootstrap)
    # Rebuild from scratch (version 2 — must match state-index-upsert.sh + state/README.md)
    echo '{"version":2,"generated":"","entries":[]}' > "$INDEX"
    count=0
    for dir in "$WORKSPACE"/*/; do
      [ -d "$dir/.git" ] || continue
      for kind in tickets debug builds refactors e2e; do
        [ -d "$dir/.claude/$kind" ] || continue
        for f in "$dir/.claude/$kind/"*.md; do
          [ -f "$f" ] || continue
          "$UPSERT" "$f"
          count=$((count+1))
        done
      done
    done
    # Workspace-root .claude/ state files too (e.g. cross-repo dependabot batches live at
    # $WORKSPACE/.claude/tickets/). The live hook indexes them; without this block a
    # --bootstrap rebuild would silently DROP those entries (the */ glob never visits .claude).
    for kind in tickets debug builds refactors e2e; do
      [ -d "$WORKSPACE/.claude/$kind" ] || continue
      for f in "$WORKSPACE/.claude/$kind/"*.md; do
        [ -f "$f" ] || continue
        "$UPSERT" "$f"
        count=$((count+1))
      done
    done
    # Auto-archive terminal statuses (learned / abandoned → archived: true)
    jq '
      .entries |= map(
        if (.status == "learned" or .status == "abandoned") then
          . + {archived: true, archived_reason: ("status: " + .status)}
        else . end
      )
    ' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
    jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.generated = $now' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
    echo "bootstrap: $count state files ingested"
    ;;

  --verify)
    # Mark ghosts without rebuilding
    tmp="$(mktemp)"
    ghost_count=0
    jq -r '.entries[] | .path' "$INDEX" | while read -r p; do
      [ -z "$p" ] && continue
      if [ ! -f "$p" ]; then
        echo "ghost: $p"
        ghost_count=$((ghost_count+1))
      fi
    done
    jq '
      .entries |= map(
        if (.path | test("^/")) then
          if (.path | test("^.+$")) then
            . + {archived: (.archived // false)}
          else . end
        else . end
      )
    ' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
    # Full ghost-marking needs filesystem check; do it explicitly:
    tmp2="$(mktemp)"
    jq '.entries[] | .path' "$INDEX" | tr -d '"' > "$tmp2.paths"
    missing=()
    while IFS= read -r p; do
      [ -n "$p" ] && [ ! -f "$p" ] && missing+=("$p")
    done < "$tmp2.paths"
    if [ ${#missing[@]} -gt 0 ]; then
      missing_json=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)
      jq --argjson gone "$missing_json" '
        .entries |= map(
          if (.path | IN($gone[])) then
            .archived = true | .archived_reason = "file-missing"
          else . end
        )
      ' "$INDEX" > "$tmp2" && mv "$tmp2" "$INDEX"
      echo "verify: marked ${#missing[@]} ghosts as archived"
    else
      echo "verify: no ghosts"
    fi
    rm -f "$tmp2.paths"
    ;;

  --verify-tags)
    # Report entries that have no tags so the user can backfill
    untagged=$(jq '[.entries[] | select(.archived != true) | select((.tags // {}) | length == 0)] | length' "$INDEX")
    total_active=$(jq '[.entries[] | select(.archived != true)] | length' "$INDEX")
    tagged=$(( total_active - untagged ))
    echo "tag coverage: $tagged/$total_active active entries tagged"
    if [ "$untagged" -gt 0 ]; then
      echo ""
      echo "Untagged active entries:"
      jq -r '
        .entries[]
        | select(.archived != true)
        | select((.tags // {}) | length == 0)
        | "  - \(.id)\t\(.path)"
      ' "$INDEX"
    fi
    # Also report low-confidence entries (needs user audit)
    low_conf=$(jq '[.entries[] | select(.tag_confidence == "low")] | length' "$INDEX")
    if [ "$low_conf" -gt 0 ]; then
      echo ""
      echo "Low-confidence tags ($low_conf entries — needs audit):"
      jq -r '.entries[] | select(.tag_confidence == "low") | "  - \(.id)"' "$INDEX"
    fi
    ;;

  --dry-run)
    echo "dry-run: would ingest state files from these paths:"
    for dir in "$WORKSPACE"/*/; do
      [ -d "$dir/.git" ] || continue
      for kind in tickets debug builds refactors e2e; do
        [ -d "$dir/.claude/$kind" ] || continue
        for f in "$dir/.claude/$kind/"*.md; do
          [ -f "$f" ] && echo "  $f"
        done
      done
    done
    ;;

  *)
    echo "usage: $0 [--bootstrap|--verify|--dry-run]" >&2
    exit 1
    ;;
esac
