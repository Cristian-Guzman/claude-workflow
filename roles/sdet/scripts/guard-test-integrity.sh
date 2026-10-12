#!/bin/bash
# PreToolUse guard (Edit|Write|MultiEdit) — mechanical enforcement of the SDET hard rule:
#   real app bugs stay red. A test is never silenced without a trail.
#   1. No `.only(` added to a test file (a focused test silently drops the rest of the suite).
#   2. No `.skip(` / `.fixme(` / `.fail(` added UNLESS the added text carries a link:
#        BUG <KEY>-<n>   (KEY = jira_project from the repo profiles; any [A-Z][A-Z0-9]+ if none)
#        FLAKY FL-<n>    (a flaky-ledger row)
#      or is a deterministic flag read:  test.skip(!someFlag, "reason") / test.skip(() => !isOn(), "reason")
#      — the flag's value decides, never a DOM probe.
# Nothing else is checked here (no assertion counting, no rm detection, no escape hatch).
# Exit 2 blocks the tool call and feeds stderr back to Claude. Exit 0 allows.
# Applies only to test files: the profile's e2e spec_dir, *.spec.*, *.test.*, __tests__/,
# *postman_collection.json. Throwaway /cover files (.cover-explore-*, .cover-b2v-*) are exempt.
# For Write, the delta is computed against the on-disk file so a whole-file rewrite is judged
# on what it ADDS, not on what it carries over.

# Workspace root: $WORKSPACE_ROOT env > $CLAUDE_PROJECT_DIR (set by Claude Code for every
# hook invocation) > cwd. Same resolution as guard-base-branch.sh — no hardcoded fallback.
WORKSPACE="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
PROFILES="$WORKSPACE/.claude/repo-profiles"

# Profile values are consumed LITERALLY (case globs / grep -F), never injected into a regex.
SPEC_DIRS=$(awk '/^e2e:/{b=1;next} b&&/^[^[:space:]]/{b=0} b&&/spec_dir:/{v=$2; gsub(/["'"'"']/,"",v); if(v!="") print v}' \
            "$PROFILES"/*.yaml 2>/dev/null | sed 's#/*$##' | grep -v '^$' | sort -u)
KEYS=$(grep -h '^jira_project:' "$PROFILES"/*.yaml 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'" \
       | grep -E '^[A-Z][A-Z0-9]+$' | sort -u)
if [ -n "$KEYS" ]; then
  KEY_RX="($(printf '%s\n' "$KEYS" | paste -sd'|' -))"
else
  KEY_RX='[A-Z][A-Z0-9]+'
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case "$tool" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$file_path" ] || exit 0

is_test() {
  case "$1" in
    *.cover-explore-*|*.cover-b2v-*) return 1 ;;             # throwaway files, deleted by design
    *.spec.*|*.test.*|*/__tests__/*|*postman_collection.json) return 0 ;;
  esac
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$1" in */"$d"/*|"$d"/*) return 0 ;; esac
  done <<EOF
$SPEC_DIRS
EOF
  return 1
}
is_test "$file_path" || exit 0

deny() { printf '%s\n' "$1" >&2; exit 2; }

# Added text = lines present in the new text and absent from the old.
case "$tool" in
  Edit)
    old=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty')
    new=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty') ;;
  MultiEdit)
    old=$(printf '%s' "$input" | jq -r '[.tool_input.edits[]?.old_string // empty] | join("\n")')
    new=$(printf '%s' "$input" | jq -r '[.tool_input.edits[]?.new_string // empty] | join("\n")') ;;
  Write)
    new=$(printf '%s' "$input" | jq -r '.tool_input.content // empty')
    old=""; [ -f "$file_path" ] && old=$(cat "$file_path") ;;
esac
added=$(diff <(printf '%s\n' "$old") <(printf '%s\n' "$new") | grep '^> ' | sed 's/^> //')
[ -n "$added" ] || exit 0

printf '%s\n' "$added" | grep -qE '\.only\(' \
  && deny "BLOCKED (test-integrity): .only( added in $file_path — a focused test silently drops the rest of the suite. Remove it before saving."

# Judge every added quarantine call on its own snippet (flattened, so multi-line calls are seen whole).
flat=$(printf '%s' "$added" | tr '\n' ' ' | tr -s ' ')
snippets=$(printf '%s\n' "$flat" | awk '{ gsub(/\.(skip|fixme|fail)\(/, "\n&"); print }' \
           | grep -E '^\.(skip|fixme|fail)\(' | cut -c1-260 || true)
[ -n "$snippets" ] || exit 0

while IFS= read -r s; do
  [ -n "$s" ] || continue
  printf '%s' "$s" | grep -qE "BUG ${KEY_RX}-[0-9]+" && continue
  printf '%s' "$s" | grep -qE 'FLAKY FL-[0-9]+' && continue
  # Deterministic flag read: skip(<expr>, "reason") where <expr> is an identifier, member
  # access, call, negation, or a (possibly destructured-arg) arrow returning one — never a
  # bare true/false, never a string, never a DOM probe awaited inline.
  if printf '%s' "$s" | grep -qE '^\.skip\(' \
     && ! printf '%s' "$s" | grep -qE '^\.skip\( *(true|false) *,' \
     && ! printf '%s' "$s" | grep -qiE '^\.skip\([^,]*(isVisible|isHidden|\$\(|locator\(|getBy|waitFor)' \
     && printf '%s' "$s" | grep -qE '^\.skip\( *(\( *(\{[^}]*\})? *\) *=> *)?!? *[A-Za-z_$][A-Za-z0-9_.$]*( *\([^()]*\))? *(===?|!==?|[<>]=?|&&|\|\|)?[^,]*, *['"'"'"`]'; then
    continue
  fi
  deny "BLOCKED (test-integrity): $(printf '%s' "$s" | grep -oE '^\.(skip|fixme|fail)\(') added in $file_path without a link. Real app bugs stay red — never skip or delete. Quarantine only as test.fail(true, 'BUG ${KEYS:-KEY}-<n>: …') (test.fixme only for hangs), flaky as 'FLAKY FL-<n>', or gate on a deterministic flag read: test.skip(!flag, 'reason')."
done <<EOF
$snippets
EOF
exit 0
