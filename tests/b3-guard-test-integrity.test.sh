#!/bin/bash
# Fixture test for roles/sdet/scripts/guard-test-integrity.sh.
# Builds a scratch workspace with one repo profile (jira_project PROJ, e2e spec_dir e2e/),
# feeds PreToolUse JSON through the hook and asserts exit codes:
#   block .only · block skip without key · allow skip with BUG PROJ-1 · allow deterministic
#   flag skip · ignore non-test file · exempt .cover-explore-* · Write judged on delta ·
#   fixme with FLAKY key allowed · MultiEdit inspected · test.skip(true,'x') blocked.
# Usage: bash tests/b3-guard-test-integrity.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/roles/sdet/scripts/guard-test-integrity.sh"
WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/.claude/repo-profiles" "$WS/web-app/e2e/items" "$WS/web-app/src"
cat > "$WS/.claude/repo-profiles/web-app.yaml" <<'YAML'
name: web-app
base_branch: main
e2e:
  enabled: true
  spec_dir: "e2e/"
tracker_system: jira
jira_project: "PROJ"
YAML
export CLAUDE_PROJECT_DIR="$WS"
SPEC="$WS/web-app/e2e/items/create.spec.ts"
printf 'test("creates an item", async ({ page }) => {\n  await expect(page.getByRole("heading")).toBeVisible();\n});\n' > "$SPEC"

pass=0; fail=0
run_hook() {  # run_hook <json> ; echoes exit code
  printf '%s' "$1" | "$HOOK" 2>"$WS/stderr"; echo $?
}
expect_code() {  # expect_code <want> <label> <json>
  local got; got=$(run_hook "$3")
  if [ "$got" = "$1" ]; then
    echo "ok   $2 (exit $got)"; pass=$((pass+1))
  else
    echo "FAIL $2 — wanted exit $1, got $got; stderr: $(cat "$WS/stderr")"; fail=$((fail+1))
  fi
}
edit_json() {  # edit_json <path> <old> <new>
  jq -cn --arg p "$1" --arg o "$2" --arg n "$3" \
    '{tool_name:"Edit", tool_input:{file_path:$p, old_string:$o, new_string:$n}}'
}
write_json() {  # write_json <path> <content>
  jq -cn --arg p "$1" --arg c "$2" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}'
}

expect_code 2 "block .only( added to a spec" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.only("creates an item"')"

expect_code 2 "block test.skip() without a key" \
  "$(edit_json "$SPEC" 'test("creates an item", async ({ page }) => {' 'test("creates an item", async ({ page }) => {
  test.skip();')"

expect_code 2 "block test.skip(true, 'reason') without a key" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.skip(true, "flaky lately");
test("creates an item"')"

expect_code 2 "block test.fail(true, ...) without a BUG key" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.fail(true, "totals wrong");
test("creates an item"')"

expect_code 0 "allow test.fail(true, 'BUG PROJ-1: ...')" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.fail(true, "BUG PROJ-1: totals wrong");
test("creates an item"')"

expect_code 2 "reject a foreign key when the profile names PROJ" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.fail(true, "BUG OTHER-7: totals wrong");
test("creates an item"')"

expect_code 0 "allow test.fixme(true, 'FLAKY FL-3')" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.fixme(true, "FLAKY FL-3 hangs on CI");
test("creates an item"')"

expect_code 0 "allow deterministic flag skip test.skip(!flag, 'reason')" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.skip(!flags.itemsV2, "ITEMS_V2 flag off in this environment");
test("creates an item"')"

expect_code 0 "allow multi-line arrow flag skip" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.skip(
  () => !isFlagEnabled("ITEMS_V2"),
  "ITEMS_V2 flag off",
);
test("creates an item"')"

expect_code 2 "block DOM-probe skip test.skip(!(await x.isVisible()), ...)" \
  "$(edit_json "$SPEC" 'test("creates an item"' 'test.skip(!(await page.getByTestId("x").isVisible().catch(() => false)), "feature off");
test("creates an item"')"

expect_code 0 "ignore a non-test file" \
  "$(edit_json "$WS/web-app/src/items.ts" 'export const a = 1;' 'export const a = 1; test.only(x); test.skip();')"

expect_code 0 "exempt .cover-explore-* throwaway spec" \
  "$(write_json "$WS/web-app/e2e/.cover-explore-items.spec.ts" 'test.only("probe", async () => {}); test.skip();')"

expect_code 0 "exempt .cover-b2v-* throwaway spec" \
  "$(write_json "$WS/web-app/e2e/.cover-b2v-items.spec.ts" 'test.skip();')"

expect_code 0 "Write: unchanged on-disk content (plus a comment) passes" \
  "$(write_json "$SPEC" "$(cat "$SPEC")
// nothing new")"

expect_code 2 "Write: rewrite that ADDS .skip() is blocked on the delta" \
  "$(write_json "$SPEC" "test.skip();
$(cat "$SPEC")")"

printf 'test.skip("already here");\n%s' "$(cat "$SPEC")" > "$WS/web-app/e2e/items/legacy.spec.ts"
expect_code 0 "Write: pre-existing skip on disk is not re-judged" \
  "$(write_json "$WS/web-app/e2e/items/legacy.spec.ts" "$(cat "$WS/web-app/e2e/items/legacy.spec.ts")
// touched")"

expect_code 0 "spec_dir match: a plain .ts under e2e/ counts as a test file (allowed when clean)" \
  "$(edit_json "$WS/web-app/e2e/utils/helpers.ts" 'a' 'b')"
expect_code 2 "spec_dir match: .only in e2e/utils/helpers.ts is blocked" \
  "$(edit_json "$WS/web-app/e2e/utils/helpers.ts" 'a' 'test.only(')"

expect_code 2 "MultiEdit: a violating edit among several is blocked" \
  "$(jq -cn --arg p "$SPEC" '{tool_name:"MultiEdit", tool_input:{file_path:$p, edits:[
     {old_string:"a", new_string:"b"},
     {old_string:"test(\"creates", new_string:"test.skip(\"creates"}]}}')"

expect_code 0 "__tests__/ file with a keyed skip is allowed" \
  "$(edit_json "$WS/web-app/src/__tests__/items.test.ts" 'it("x"' 'it.skip("x", "BUG PROJ-42"')"

expect_code 0 "postman collection with no quarantine call is allowed" \
  "$(edit_json "$WS/web-app/docs/items.postman_collection.json" '"a"' '"b"')"

expect_code 0 "Bash tool is ignored by this hook" \
  "$(jq -cn '{tool_name:"Bash", tool_input:{command:"rm e2e/items/create.spec.ts"}}')"

echo
echo "$((pass+fail)) checks, $pass passed, $fail failed"
[ "$fail" -eq 0 ]
