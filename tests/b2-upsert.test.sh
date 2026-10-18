#!/usr/bin/env bash
# b2-upsert.test.sh — fixture test for core/scripts/state-index-upsert.sh kind/ticket/status rules.
#
# Builds a throwaway workspace, upserts fixture state files, and asserts on index.json +
# state/schema-drift.log. Needs jq. Exit 0 = all assertions passed.
#
# Usage: tests/b2-upsert.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
UPSERT="$HERE/core/scripts/state-index-upsert.sh"
WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
export WORKSPACE_ROOT="$WS"
mkdir -p "$WS/.claude/state" "$WS/web-app/.claude/tickets" "$WS/web-app/.claude/debug"
INDEX="$WS/.claude/state/index.json"
DRIFT="$WS/.claude/state/schema-drift.log"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   - $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL - $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 :: $2"; fi; }
entry(){ jq -c --arg id "$1" '.entries[] | select(.id==$id)' "$INDEX"; }

echo "# 1. cover sidecar with ticket: null -> kind cover, id keyed by slug"
cat > "$WS/web-app/.claude/tickets/cover--orders-v2.md" <<'MD'
---
kind: cover
slug: orders-v2
ticket: null
branch: test/orders-v2
status: in-progress
created: 2026-04-21T10:00:00Z
updated: 2026-04-21T10:00:00Z
---
## Files Modified
- e2e/orders/checkout.spec.ts — new coverage
MD
"$UPSERT" "$WS/web-app/.claude/tickets/cover--orders-v2.md"
E=$(entry "web-app:cover:orders-v2")
check "entry exists with id web-app:cover:orders-v2" '[ -n "$E" ]'
check "kind is cover"                 '[ "$(echo "$E" | jq -r .kind)" = "cover" ]'
check "ticket is null"                '[ "$(echo "$E" | jq -r .ticket)" = "null" ]'
check "branch carried"                '[ "$(echo "$E" | jq -r .branch)" = "test/orders-v2" ]'
check "not archived"                  '[ "$(echo "$E" | jq -r .archived)" = "false" ]'
check "no drift line for a well-formed sidecar" '[ ! -s "$DRIFT" ]'

echo "# 2. /log writes ticket: PROJ-1 -> index ticket updated, id unchanged, single entry"
sed -i '' 's/^ticket: null$/ticket: PROJ-1/' "$WS/web-app/.claude/tickets/cover--orders-v2.md"
"$UPSERT" "$WS/web-app/.claude/tickets/cover--orders-v2.md"
E=$(entry "web-app:cover:orders-v2")
check "id unchanged after re-key"     '[ -n "$E" ]'
check "ticket now PROJ-1"             '[ "$(echo "$E" | jq -r .ticket)" = "PROJ-1" ]'
check "exactly one cover entry"       '[ "$(jq "[.entries[]|select(.kind==\"cover\")]|length" "$INDEX")" = "1" ]'

echo "# 3. legacy -test-plan sidecar (no kind:, no status:) -> kind test-plan, archived, no drift"
cat > "$WS/web-app/.claude/tickets/PROJ-77-test-plan.md" <<'MD'
---
ticket: PROJ-77
created: 2026-03-01T10:00:00Z
---
# Test plan
MD
"$UPSERT" "$WS/web-app/.claude/tickets/PROJ-77-test-plan.md"
E=$(entry "web-app:test-plan:PROJ-77-test-plan")
check "kind is test-plan"             '[ "$(echo "$E" | jq -r .kind)" = "test-plan" ]'
check "status defaults to blueprint"  '[ "$(echo "$E" | jq -r .status)" = "blueprint" ]'
check "archived (terminal)"           '[ "$(echo "$E" | jq -r .archived)" = "true" ]'
check "ticket derived PROJ-77"        '[ "$(echo "$E" | jq -r .ticket)" = "PROJ-77" ]'
check "terminal default status does not log drift" '[ ! -s "$DRIFT" ]'

echo "# 4. status-less lifecycle file -> status unknown + drift log line"
cat > "$WS/web-app/.claude/tickets/PROJ-88.md" <<'MD'
---
id: PROJ-88
branch: feature/PROJ-88-thing
---
## Plan
MD
"$UPSERT" "$WS/web-app/.claude/tickets/PROJ-88.md"
E=$(entry "web-app:ticket:PROJ-88")
check "status indexed as unknown"     '[ "$(echo "$E" | jq -r .status)" = "unknown" ]'
check "drift log has a 'missing status' line for PROJ-88" 'grep -q "missing status in .*PROJ-88.md" "$DRIFT"'

echo "# 5. non-schema status -> indexed as written + drift line; env-blocked is accepted"
cat > "$WS/web-app/.claude/tickets/triage--flaky-login.md" <<'MD'
---
kind: triage
slug: flaky-login
ticket: ~
branch: test/flaky-login
status: env-blocked
updated: 2026-04-21T10:00:00Z
---
MD
"$UPSERT" "$WS/web-app/.claude/tickets/triage--flaky-login.md"
E=$(entry "web-app:triage:flaky-login")
check "triage kind via kind: passthrough" '[ "$(echo "$E" | jq -r .kind)" = "triage" ]'
check "tilde ticket indexes as null"       '[ "$(echo "$E" | jq -r .ticket)" = "null" ]'
check "env-blocked accepted (no drift)"    '! grep -q "env-blocked" "$DRIFT"'
cat > "$WS/web-app/.claude/debug/api-null.md" <<'MD'
---
status: poking-around
updated: 2026-04-21T10:00:00Z
---
MD
"$UPSERT" "$WS/web-app/.claude/debug/api-null.md"
check "free-text status logged as non-schema" 'grep -q "non-schema status .poking-around. in .*api-null.md" "$DRIFT"'
check "free-text status still indexed"         '[ "$(entry web-app:debug:api-null | jq -r .status)" = "poking-around" ]'

echo "# 6. existing behaviours kept: -clarify and -review suffix rules, kind: review passthrough"
printf -- '---\nticket: PROJ-5\n---\n' > "$WS/web-app/.claude/tickets/PROJ-5-clarify.md"
printf -- '---\nkind: review\nverdict: approve\n---\n' > "$WS/web-app/.claude/tickets/PROJ-5-review.md"
"$UPSERT" "$WS/web-app/.claude/tickets/PROJ-5-clarify.md"
"$UPSERT" "$WS/web-app/.claude/tickets/PROJ-5-review.md"
check "-clarify -> blueprint/archived" '[ "$(entry web-app:blueprint:PROJ-5-clarify | jq -r "\"\\(.status) \\(.archived)\"")" = "blueprint true" ]'
check "review -> reviewed/archived"    '[ "$(entry web-app:review:PROJ-5-review | jq -r "\"\\(.status) \\(.archived)\"")" = "reviewed true" ]'

echo "# 7. declared kind outside the enum -> directory kind wins + drift line"
printf -- '---\nkind: stabilize\nstatus: planning\n---\n' > "$WS/web-app/.claude/tickets/stabilize--x.md"
"$UPSERT" "$WS/web-app/.claude/tickets/stabilize--x.md"
check "unknown declared kind falls back to ticket" '[ "$(entry web-app:ticket:stabilize--x | jq -r .kind)" = "ticket" ]'
check "unknown declared kind logged"               'grep -q "non-schema kind .stabilize." "$DRIFT"'

echo "# 8. qa sidecar (manual-QA results, roles/qa) -> kind qa, no drift line"
printf -- '---\nkind: qa\nkey: PROJ-9\nticket: PROJ-9\narea: checkout\nstatus: in-progress\n---\n\n## QA Results\n| # | Step | Expected | Result | Evidence | Bug |\n|---|---|---|---|---|---|\n| 1 | open /checkout | summary | pass | | |\n' > "$WS/web-app/.claude/tickets/qa--PROJ-9.md"
"$UPSERT" "$WS/web-app/.claude/tickets/qa--PROJ-9.md"
check "qa sidecar indexed with kind qa" '[ "$(entry web-app:qa:PROJ-9 | jq -r .kind)" = "qa" ]'
check "qa sidecar status kept"          '[ "$(entry web-app:qa:PROJ-9 | jq -r .status)" = "in-progress" ]'
check "qa is in the enum (no drift)"    '! grep -q "non-schema kind .qa." "$DRIFT"'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
