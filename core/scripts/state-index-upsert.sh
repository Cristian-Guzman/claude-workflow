#!/usr/bin/env bash
# state-index-upsert.sh — Upsert one state-file entry into .claude/state/index.json
#
# Called by the PostToolUse hook when a file at **/.claude/{tickets,debug,builds,refactors,e2e}/*.md is written.
#
# Usage: state-index-upsert.sh <absolute-or-relative-path-to-state-file>

set -euo pipefail

# Set WORKSPACE_ROOT to your multi-repo workspace root (the directory containing your repos).
WORKSPACE="${WORKSPACE_ROOT:-$HOME/workspace}"
INDEX="$WORKSPACE/.claude/state/index.json"

path="${1:-}"
[ -z "$path" ] && { echo "usage: $0 <state-file-path>" >&2; exit 1; }
[ -f "$path" ] || { echo "not a file: $path" >&2; exit 0; }  # silent no-op on delete/move

abs=$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")

# Must live under THIS workspace — otherwise the prefix-strip below no-ops and we
# index a foreign repo (e.g. one outside the workspace) with repo:"" garbage ids.
case "$abs" in
  "$WORKSPACE"/*) ;;
  *) exit 0 ;;
esac

# Only act on paths under a repo's .claude/{tickets,debug,builds,refactors,e2e}/
if ! [[ "$abs" =~ /\.claude/(tickets|debug|builds|refactors|e2e)/[^/]+\.md$ ]]; then
  exit 0
fi

# Derive: repo, kind, key from the path
rel="${abs#$WORKSPACE/}"                  # e.g. addin-fe/.claude/tickets/PROJ-6143.md
repo="${rel%%/*}"                         # addin-fe
kind_dir_path="${rel#*.claude/}"          # tickets/PROJ-6143.md
kind="${kind_dir_path%%/*}"               # tickets
# Normalize plural dir name to singular kind
case "$kind" in
  tickets)   kind_singular="ticket" ;;
  debug)     kind_singular="debug" ;;
  builds)    kind_singular="build" ;;
  refactors) kind_singular="refactor" ;;
  e2e)       kind_singular="e2e" ;;
  *)         exit 0 ;;  # unknown kind, skip
esac

key=$(basename "$abs" .md)
id="${repo}:${kind_singular}:${key}"

# Parse YAML frontmatter into shell variables (simple key: value only)
# Frontmatter is between the first two --- lines
fm=$(awk 'BEGIN{c=0} /^---$/{c++; next} c==1{print} c==2{exit}' "$abs")

get_field() {
  # Usage: get_field "status"  -> echoes value or empty (scalar, top-level frontmatter)
  echo "$fm" | awk -v k="$1" '$1 == k":" { $1=""; sub(/^[ \t]+/,""); gsub(/^"|"$/,""); print; exit }'
}

status=$(get_field "status")
branch=$(get_field "branch")
created=$(get_field "created")
updated=$(get_field "updated")
pr_number=$(get_field "pr_number")
tagged_by=$(get_field "tagged_by")
tag_confidence=$(get_field "tag_confidence")

# Ticket ID: frontmatter `ticket:` wins; else derive from the filename key (PROJ-6499-clarify -> PROJ-6499).
# This is the citation key /clarify Step 1.5b prior-art uses — without it every hit shows `ticket: None`.
ticket=$(get_field "ticket")
# PROJ is your ticket project key — replace with your own (e.g. ABC-[0-9]+).
if [ -z "$ticket" ] && [[ "$key" =~ (PROJ-[0-9]+) ]]; then
  ticket="${BASH_REMATCH[1]}"
fi

# A file's own `kind:` frontmatter overrides the directory-derived kind. Review logs
# (`kind: review`, written by /review-pr into tickets/) carry a `verdict:`, not a
# lifecycle `status:` — index them as kind=review (terminal, archived, kept for
# /learn correlation) instead of letting them become ticket/status:unknown zombies.
file_kind=$(get_field "kind")
archived="false"
archived_reason=""
if [ "$file_kind" = "review" ] || [[ "$key" == *-review || "$key" == *-review-* ]]; then
  kind_singular="review"
  id="${repo}:${kind_singular}:${key}"
  [ -z "$status" ] && status="reviewed"
  archived="true"
  archived_reason="kind: review"
fi

# Blueprints: /clarify persists `PROJ-XXXX-clarify.md` into tickets/ — these are investigation
# artifacts (prior-art sources), not lifecycle entries. Without this rule they index as
# kind=ticket / status=unknown zombies (16 of the 18 "unknown" entries traced to this).
if [ "$file_kind" = "blueprint" ] || [[ "$key" == *-clarify || "$key" == *-clarify-* ]]; then
  kind_singular="blueprint"
  id="${repo}:${kind_singular}:${key}"
  [ -z "$status" ] && status="blueprint"
  archived="true"
  archived_reason="kind: blueprint"
fi

# Fallbacks
[ -z "$status" ] && status="unknown"
[ -z "$updated" ] && updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Closed status vocabulary (state-file-schema.md). A free-text status makes the
# entry invisible to /learn's delivered/learned scan — index it anyway, but log
# the drift so it surfaces instead of silently starving the learning loop.
case "$status" in
  planning|in-progress|ready-for-pr|pr-generated|delivered|learned|\
  investigating|root-cause-found|fixed|reviewed|blueprint|abandoned|unknown) ;;
  *) echo "$(date -u +%Y-%m-%d) non-schema status '$status' in $abs" \
       >> "$WORKSPACE/.claude/state/schema-drift.log" ;;
esac

# Terminal statuses auto-archive at upsert time (scan --bootstrap also does this as a
# post-pass, but live upserts used to leave e.g. fresh `learned` tickets unarchived
# until the next rebuild). `abandoned` = explicitly closed without delivery.
if [ "$archived" = "false" ]; then
  case "$status" in
    learned|abandoned)
      archived="true"
      archived_reason="status: $status"
      ;;
  esac
fi

# --- Multi-axis tag parsing ---------------------------------------------------
# Extract the `tags:` sub-block from frontmatter (lines indented under `tags:`
# until the next top-level key or end-of-frontmatter).

tags_block=$(echo "$fm" | awk '
  /^tags:[[:space:]]*$/ { in_block=1; next }
  in_block && /^[^[:space:]]/ { in_block=0 }
  in_block { print }
')

# get_tag_scalar KEY -> echoes value for a scalar axis (layer, kind, surface, atomic_level)
get_tag_scalar() {
  echo "$tags_block" | awk -v k="$1" '
    { sub(/^[[:space:]]+/,""); }
    $1 == k":" { $1=""; sub(/^[ \t]+/,""); gsub(/^"|"$/,""); print; exit }
  '
}

# get_tag_array KEY -> JSON array for list axes (concern, feature_area).
# Supports:
#   concern: [permissions, styling]
#   concern:
#     - permissions
#     - styling
get_tag_array() {
  local key="$1"
  # inline form first
  local inline
  inline=$(echo "$tags_block" | awk -v k="$key" '
    { sub(/^[[:space:]]+/,""); }
    $1 == k":" { sub("^[^:]+:[[:space:]]*",""); print; exit }
  ')
  if [[ "$inline" =~ ^\[.*\]$ ]]; then
    echo "$inline" | sed 's/^\[//; s/\]$//' \
      | tr ',' '\n' | sed 's/^[[:space:]"'\'']*//; s/[[:space:]"'\'']*$//' \
      | jq -R . | jq -cs 'map(select(length > 0))'
    return
  fi
  # block form
  echo "$tags_block" | awk -v k="$key" '
    { sub(/^[[:space:]]+/,""); }
    $0 ~ "^"k":[[:space:]]*$" { in_list=1; next }
    in_list && /^-[[:space:]]*/ { sub(/^-[[:space:]]*/,""); gsub(/^"|"$/,""); print; next }
    in_list && /^[^-]/ { in_list=0 }
  ' | jq -R . | jq -cs 'map(select(length > 0))'
}

layer=$(get_tag_scalar "layer")
kind_tag=$(get_tag_scalar "kind")
surface=$(get_tag_scalar "surface")
atomic_level=$(get_tag_scalar "atomic_level")
concern_json=$(get_tag_array "concern")
area_json=$(get_tag_array "feature_area")

# Body fallback: if no tags block in frontmatter, look for `## Tags` section
tags_source="frontmatter"
if [ -z "$tags_block" ]; then
  body_tags=$(awk '/^##[[:space:]]+Tags[[:space:]]*$/{p=1;next} p&&/^## /{p=0} p' "$abs")
  if [ -n "$body_tags" ]; then
    tags_source="body"
    layer=$(echo "$body_tags"        | awk -F': *' '/^- layer:/{print $2; exit}')
    kind_tag=$(echo "$body_tags"     | awk -F': *' '/^- kind:/{print $2; exit}')
    surface=$(echo "$body_tags"      | awk -F': *' '/^- surface:/{print $2; exit}')
    atomic_level=$(echo "$body_tags" | awk -F': *' '/^- atomic_level:/{print $2; exit}')
    concern_json=$(echo "$body_tags" | awk -F': *' '/^- concern:/{print $2; exit}' \
      | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -cs 'map(select(length>0))')
    area_json=$(echo "$body_tags"    | awk -F': *' '/^- feature_area:/{print $2; exit}' \
      | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -cs 'map(select(length>0))')
  else
    tags_source="none"
  fi
fi

# Compose tags object; omit axes that are empty
tags_obj=$(jq -n \
  --arg layer "${layer:-}" \
  --arg kind  "${kind_tag:-}" \
  --arg surface "${surface:-}" \
  --arg atom  "${atomic_level:-}" \
  --argjson concern "${concern_json:-[]}" \
  --argjson area    "${area_json:-[]}" \
  '{
     layer:        (if $layer   == "" then null else $layer   end),
     kind:         (if $kind    == "" then null else $kind    end),
     surface:      (if $surface == "" then null else $surface end),
     atomic_level: (if $atom    == "" then null else $atom    end),
     concern:      $concern,
     feature_area: $area
   } | with_entries(select(.value != null and .value != []))')

# Build the new entry as JSON
entry=$(jq -n \
  --arg id "$id" \
  --arg repo "$repo" \
  --arg kind "$kind_singular" \
  --arg key "$key" \
  --arg ticket "${ticket:-}" \
  --arg path "$abs" \
  --arg status "$status" \
  --arg branch "${branch:-}" \
  --arg pr "${pr_number:-}" \
  --arg created "${created:-}" \
  --arg updated "$updated" \
  --argjson tags "$tags_obj" \
  --arg tsrc "$tags_source" \
  --arg tby "${tagged_by:-}" \
  --arg tconf "${tag_confidence:-}" \
  --arg archived "$archived" \
  --arg areason "${archived_reason:-}" \
  '{
    id: $id, repo: $repo, kind: $kind, key: $key, path: $path,
    ticket: (if $ticket == "" then null else $ticket end),
    status: $status,
    branch: (if $branch == "" then null else $branch end),
    pr: (if $pr == "" then null else ($pr | tonumber? // null) end),
    created: (if $created == "" then null else $created end),
    updated: $updated,
    archived: ($archived == "true"),
    archived_reason: (if $areason == "" then null else $areason end),
    tags: $tags,
    tags_source: $tsrc,
    tagged_by: (if $tby == "" then null else $tby end),
    tag_confidence: (if $tconf == "" then null else $tconf end)
  }')

# Ensure index file exists
[ -f "$INDEX" ] || echo '{"version":2,"generated":"","entries":[]}' > "$INDEX"

# Upsert: replace existing entry with matching id, else append.
# Preserve archived:true if the existing entry had it — archiving is sticky. But ONLY
# true is preserved: an existing archived:false must NOT overwrite a newly-computed
# archived:true (e.g. a ticket just flipped to a terminal status), or terminal entries
# stay active forever.
tmp="$(mktemp)"
jq --argjson new "$entry" '
  .version = 2 |
  .generated = (now | todate) |
  .entries = (
    [.entries[] | select(.id == $new.id) | select(.archived == true) | {archived, archived_reason}] as $keep
    | ([.entries[] | select(.id != $new.id)]) + [
        ($new + (if ($keep | length) > 0 then ($keep[0] | del(.. | nulls)) else {} end))
      ]
  )
' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
