#!/bin/bash
# Weekly wrapper around audit_metrics.py — invoked by launchd/cron from
# e.g. ~/Library/LaunchAgents/com.<you>.claude-audit.plist.
#
# Each run:
#   - writes .claude/metrics/YYYY-MM-DD.json (the snapshot)
#   - appends a one-line summary + delta vs previous snapshot to .run.log
#   - exits 0 on success so launchd doesn't backoff
set -uo pipefail

# launchd spawns us with an inherited cwd that may be unreadable (the source of the
# historical `getcwd: Operation not permitted` failures). Anchor to a safe cwd first.
cd /tmp 2>/dev/null || true

WORKSPACE="${WORKSPACE:-${WORKSPACE_ROOT:-$PWD}}"
export WORKSPACE
SCRIPT="$WORKSPACE/.claude/scripts/audit_metrics.py"
METRICS_DIR="$WORKSPACE/.claude/metrics"
LOG="$METRICS_DIR/.run.log"
PYTHON="/usr/bin/python3"
TS="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY_FILE="$METRICS_DIR/$(date '+%Y-%m-%d').json"

mkdir -p "$METRICS_DIR"

{
  echo "===== $TS ====="
  if "$PYTHON" "$SCRIPT"; then
    echo "[$TS] snapshot OK -> $TODAY_FILE"
    # Find the previous snapshot (if any) for a delta line
    PREV=$(ls -1t "$METRICS_DIR"/*.json 2>/dev/null | grep -v "$(basename "$TODAY_FILE")" | head -1 || true)
    if [ -n "${PREV:-}" ] && [ -f "$TODAY_FILE" ]; then
      echo "--- delta vs $(basename "$PREV") ---"
      "$PYTHON" "$SCRIPT" --diff "$PREV" "$TODAY_FILE" || true
    fi
  else
    rc=$?
    echo "[$TS] FAILED rc=$rc"
  fi
  echo
} >> "$LOG" 2>&1

exit 0
