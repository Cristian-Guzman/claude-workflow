#!/usr/bin/env bash
# tag-tickets.sh — Backfill heuristic tags into every ticket state file.
#
# For each state file:
#   1. Parse branch, repo, Files Modified paths, Classification section
#   2. Apply heuristics → (layer, kind, surface, atomic_level, feature_area, concern)
#   3. Write or merge a `tags:` block into the file's frontmatter
#   4. Set tagged_by/tag_confidence/tags_verified audit fields
#   5. Record low-confidence picks in tag-audit.md
#
# Never overwrites a pre-existing `tags:` block (respects user-curated tags).
# Usage: tag-tickets.sh [--dry-run]

set -uo pipefail

# Root of your workspace (the directory containing .claude/). Override via $WORKSPACE_ROOT.
WORKSPACE="${WORKSPACE_ROOT:-$PWD}"
INDEX="$WORKSPACE/.claude/state/index.json"
AUDIT="$WORKSPACE/.claude/state/tag-audit.md"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Start a fresh audit file
if [ "$DRY_RUN" -eq 0 ]; then
  cat > "$AUDIT" <<EOF
# Tag Audit — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)

Low-confidence or partially-tagged entries. Review and flip \`tags_verified: true\` on each file when you're satisfied.

EOF
fi

# Map repo → layer, driven by the repo profile's `type:` field — the profiles are
# the single source of truth, no repo names are hardcoded here. Missing profile or
# unknown type → empty (the confidence scorer treats it as a missing axis).
repo_to_layer() {
  local profile="$WORKSPACE/.claude/repo-profiles/$1.yaml" t=""
  [ -f "$profile" ] && t=$(awk -F': *' '/^type:/{print $2; exit}' "$profile" | awk '{print $1}' | tr -d '"' | tr -d "'")
  case "$t" in
    frontend-ui|google-workspace-addin) echo "ui" ;;
    backend-bff)                        echo "bff" ;;
    backend-go|backend-service)         echo "backend" ;;
    mobile-ios)                         echo "mobile" ;;
    *)                                  echo "" ;;
  esac
}

# Derive kind from branch prefix
branch_to_kind() {
  case "$1" in
    fix/*|fix-*|bugfix/*)  echo "bugfix" ;;
    feat/*|feature/*)       echo "feature" ;;
    refactor/*)             echo "refactor" ;;
    chore/*|chore-*)        echo "chore" ;;
    spike/*|proto/*)        echo "spike" ;;
    docs/*)                 echo "docs" ;;
    *)                      echo "" ;;
  esac
}

# Derive surface from modified-file paths (UI only)
paths_to_surface() {
  local paths="$1"
  # Rank-ordered: whichever hits first wins
  if echo "$paths" | grep -qE 'auth|login|session'; then echo "auth-flow"; return; fi
  if echo "$paths" | grep -qE '\[.*\]/|/detail|/edit'; then echo "detail-view"; return; fi
  if echo "$paths" | grep -qE '/list|/playbooks/|/positions/|/documents/'; then echo "list-view"; return; fi
  if echo "$paths" | grep -qE 'Modal|Drawer|Dialog'; then echo "modal-form"; return; fi
  if echo "$paths" | grep -qE 'Sidebar|Nav|Header|Layout'; then echo "nav-shell"; return; fi
  if echo "$paths" | grep -qE 'Editor|Slate'; then echo "editor"; return; fi
  if echo "$paths" | grep -qE 'settings|preferences'; then echo "settings"; return; fi
  echo ""
}

# Derive feature_area from branch slug + file paths + repo fallback
# CUSTOMIZE: the first few keyword→area mappings are EXAMPLES — replace with
# your project's real feature areas (the generic auth/billing/dependabot
# mappings usually apply anywhere).
infer_feature_area() {
  local branch="$1" paths="$2" repo="$3"
  local areas=""
  echo "$branch $paths" | grep -qiE 'playbook|position|section' && areas+="playbook-v2\n"
  echo "$branch $paths" | grep -qiE 'word-addin|Word-Addin' && areas+="word-addin\n"
  echo "$branch $paths" | grep -qiE 'gdocs|google-docs|apps.script' && areas+="gdocs-addin\n"
  echo "$branch $paths" | grep -qiE 'buy.credit|buy.experience|credits-section|trial' && areas+="buy-credits\n"
  echo "$branch $paths" | grep -qiE 'billing|subscription|stripe|invoice' && areas+="billing\n"
  echo "$branch $paths" | grep -qiE 'auth|login|session|token' && areas+="auth\n"
  echo "$branch $paths" | grep -qiE 'dependabot' && areas+="dependabot\n"
  # Repo-based fallback ONLY if nothing else matched — read default_feature_area
  # from the repo profile (no hardcoded repo names).
  if [ -z "$areas" ]; then
    local profile="$WORKSPACE/.claude/repo-profiles/$repo.yaml"
    if [ -f "$profile" ]; then
      local def
      def=$(awk -F': *' '/^default_feature_area:/{print $2; exit}' "$profile" | awk '{print $1}' | tr -d '"')
      [ -n "$def" ] && areas="$def\n"
    fi
  fi
  echo -e "$areas" | sort -u | grep -v '^$'
}

# Derive concern (best-effort keyword match on retro + file paths)
infer_concerns() {
  local haystack="$1"
  local concerns=""
  echo "$haystack" | grep -qiE 'permission|scope|role|authoriz'    && concerns+="permissions\n"
  echo "$haystack" | grep -qiE 'useState|reducer|state mgmt'       && concerns+="state-mgmt\n"
  echo "$haystack" | grep -qiE 'api contract|type mismatch|swagger|endpoint shape' && concerns+="api-contract\n"
  echo "$haystack" | grep -qiE 'cache|optimistic|refetch'          && concerns+="caching\n"
  echo "$haystack" | grep -qiE 'i18n|translation|locale'           && concerns+="i18n\n"
  echo "$haystack" | grep -qiE 'a11y|accessibility|aria'           && concerns+="a11y\n"
  echo "$haystack" | grep -qiE 'perf|slow|optimiz'                 && concerns+="perf\n"
  echo "$haystack" | grep -qiE 'silent failure|error handling|try.catch|catch.*return' && concerns+="error-handling\n"
  echo "$haystack" | grep -qiE 'migration|snake_case|camelCase'    && concerns+="schema-migration\n"
  echo "$haystack" | grep -qiE 'styl|css|tailwind|color|spacing'   && concerns+="styling\n"
  echo -e "$concerns" | sort -u | grep -v '^$' | head -3
}

# Merge or create `tags:` block in a file's frontmatter.
# Idempotent: if the file already has a `tags:` block, skip (respect existing).
merge_tags() {
  local file="$1"
  shift
  local layer="$1" kind="$2" surface="$3" atomic="$4"
  local concern_csv="$5" area_csv="$6"
  local confidence="$7"

  # Skip if tags block already present
  if awk 'BEGIN{c=0} /^---$/{c++; next} c==1 && /^tags:[[:space:]]*$/{found=1; exit} c==2{exit} END{exit !found}' "$file"; then
    return 1   # signals "skipped — had tags"
  fi

  # Build the tags block
  local block=""
  block+="tags:\n"
  [ -n "$layer" ]   && block+="  layer: $layer\n"
  [ -n "$kind" ]    && block+="  kind: $kind\n"
  [ -n "$surface" ] && block+="  surface: $surface\n"
  [ -n "$atomic" ]  && block+="  atomic_level: $atomic\n"
  if [ -n "$concern_csv" ]; then
    block+="  concern: [$concern_csv]\n"
  fi
  if [ -n "$area_csv" ]; then
    block+="  feature_area: [$area_csv]\n"
  fi
  block+="tagged_by: heuristic\n"
  block+="tag_confidence: $confidence\n"
  block+="tags_verified: false\n"

  # Insert before the closing --- of frontmatter
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== would inject into $file ==="
    echo -e "$block"
    return 0
  fi

  # Find line number of the second --- (frontmatter close)
  close_line=$(awk '/^---$/{c++; if(c==2){print NR; exit}}' "$file")
  if [ -z "$close_line" ]; then
    echo "SKIP $file: no frontmatter closer found" >&2
    return 2
  fi

  tmp="$(mktemp)"
  head -n $((close_line - 1)) "$file" > "$tmp"
  printf '%b' "$block" >> "$tmp"
  tail -n +$close_line "$file" >> "$tmp"
  mv "$tmp" "$file"
  return 0
}

# Main loop
processed=0; tagged=0; skipped=0; low_conf=0

while IFS= read -r entry_json; do
  path=$(echo "$entry_json" | jq -r '.path')
  repo=$(echo "$entry_json" | jq -r '.repo')
  branch=$(echo "$entry_json" | jq -r '.branch // ""')
  [ -f "$path" ] || continue
  processed=$((processed + 1))

  # Parse state file sections
  files_modified=$(awk '/^## Files Modified/,/^## /' "$path" 2>/dev/null | grep -oE '[a-zA-Z_/.-]+(/[a-zA-Z_.-]+)+' | sort -u | tr '\n' ' ')
  retro=$(awk '/^## Retrospective/,/^## /' "$path" 2>/dev/null)
  classification_tier=$(awk '/^## Classification/,/^## /' "$path" 2>/dev/null | grep -oE 'Tier:[[:space:]]*\*?\*?[A-Za-z]+' | head -1 | awk '{print $NF}' | tr -d '*')

  # Axes
  layer=$(repo_to_layer "$repo")
  kind=$(branch_to_kind "$branch")

  # State-file-kind fallback: if we're tagging a refactor/debug file, that's authoritative
  entry_kind=$(echo "$entry_json" | jq -r '.kind')
  if [ -z "$kind" ]; then
    case "$entry_kind" in
      refactor) kind="refactor" ;;
      debug)    kind="bugfix" ;;
      e2e)      kind="chore" ;;
    esac
  fi

  # Classification tier fallback
  if [ -z "$kind" ] && [ -n "$classification_tier" ]; then
    case "$(echo "$classification_tier" | tr '[:upper:]' '[:lower:]')" in
      bugfix|bug)  kind="bugfix" ;;
      trivial)     kind="chore" ;;
      standard|complex) kind="feature" ;;
    esac
  fi
  [ -z "$kind" ] && kind="feature"

  # Surface & atomic-level only for UI
  surface=""
  atomic=""
  if [ "$layer" = "ui" ]; then
    surface=$(paths_to_surface "$files_modified")
  fi

  # feature_area — CSV of inferred values
  areas_multi=$(infer_feature_area "$branch" "$files_modified" "$repo" | paste -sd ',' -)

  # concern — CSV
  concerns_multi=$(infer_concerns "$(echo "$files_modified $retro")" | paste -sd ',' -)

  # Confidence: high if we got layer+kind+area, medium if 2 of 3, low otherwise
  conf="low"
  axes_hit=0
  [ -n "$layer" ]   && axes_hit=$((axes_hit + 1))
  [ -n "$kind" ]    && axes_hit=$((axes_hit + 1))
  [ -n "$areas_multi" ] && axes_hit=$((axes_hit + 1))
  [ "$axes_hit" -ge 3 ] && conf="high"
  [ "$axes_hit" -eq 2 ] && conf="medium"
  # Branch hints (e.g. "(to be determined)") force low
  case "$branch" in
    ""|"(to be determined)"|"(pending)"|"(current HEAD)"|"develop") conf="low" ;;
  esac

  # Merge
  if merge_tags "$path" "$layer" "$kind" "$surface" "$atomic" "$concerns_multi" "$areas_multi" "$conf"; then
    tagged=$((tagged + 1))
    [ "$conf" = "low" ] && low_conf=$((low_conf + 1))
    if [ "$conf" = "low" ] || [ "$conf" = "medium" ]; then
      if [ "$DRY_RUN" -eq 0 ]; then
        echo "- **$(echo "$entry_json" | jq -r '.id')** — confidence: \`$conf\` — path: \`$path\`" >> "$AUDIT"
        echo "  - layer=\`$layer\` kind=\`$kind\` surface=\`${surface:-—}\` area=\`${areas_multi:-—}\` concern=\`${concerns_multi:-—}\`" >> "$AUDIT"
        echo "  - branch: \`$branch\`" >> "$AUDIT"
        echo "" >> "$AUDIT"
      fi
    fi
  else
    skipped=$((skipped + 1))
  fi
done < <(jq -c '.entries[]' "$INDEX")

if [ "$DRY_RUN" -eq 0 ]; then
  echo ""                                   >> "$AUDIT"
  echo "---"                                >> "$AUDIT"
  echo "**Summary:** processed=$processed tagged=$tagged skipped=$skipped low_conf=$low_conf" >> "$AUDIT"
fi

echo "tag-tickets: processed=$processed tagged=$tagged skipped=$skipped low_confidence=$low_conf"
[ "$DRY_RUN" -eq 0 ] && echo "audit report: $AUDIT"
