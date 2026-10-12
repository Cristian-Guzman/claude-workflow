#!/usr/bin/env bash
# b4-mine-history.test.sh — offline tests for core/scripts/mine-history.sh.
#
# Exercises the pure grouping/normalisation (candidates.json contract) on fixture JSON via
# MINE_FIXTURE_DIR — no gh, no network. Also covers the <10-PR degrade path and --dry-run.
#
# Usage: tests/b4-mine-history.test.sh        (exit 0 = all pass; failures are printed)
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/core/scripts/mine-history.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/b4-mine.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { # check "<name>" <jq-expr returning true/false> <file>
  local got; got="$(jq -r "$2" "$3" 2>&1)"
  if [ "$got" = "true" ]; then ok "$1"; else bad "$1" "jq '$2' -> $got"; fi
}

# ---------------------------------------------------------------- fixtures
FIX="$TMP/fixture"; mkdir -p "$FIX"
# 12 merged PRs (>= the 10-PR floor); bodies/titles are neutral
jq -n '[range(101; 113) | {number: ., title: ("chore: change " + (.|tostring)), body: "",
        files: [], reviews: [], reviewDecision: "APPROVED", mergedAt: "2026-09-01T00:00:00Z",
        baseRefName: "main", headRefName: ("feature/PROJ-" + (.|tostring)), labels: []}]' > "$FIX/prs.json"

# Review comments:
#  - PRs 101 + 102: same topic stem in the same dir (selector advice)         -> topic candidate, kind testing
#  - PRs 103 + 104 + 105: same FILE stem across PRs (src/http/retry.ts)         -> hotspot candidate (3 PRs)
#    (bodies differ so there is no topic group; 103/104 are gotcha-flavoured)
#  - PR 106 alone: a comment nobody else echoes                                 -> no candidate
#  - PR 107 + 107: same stem but ONE PR                                         -> no candidate (needs 2 PRs)
#  - PR 108: empty path (outdated comment) and empty body                       -> ignored
cat > "$FIX/review_comments.json" <<'JSON'
[
 {"pr":101,"id":1,"in_reply_to_id":null,"path":"e2e/items/list.spec.ts","line":10,"created_at":"2026-08-01T00:00:00Z",
  "body":"Please use `getByRole` instead of getByText here.\nIt survives copy changes."},
 {"pr":102,"id":2,"in_reply_to_id":null,"path":"e2e/items/create.spec.ts","line":22,"created_at":"2026-08-02T00:00:00Z",
  "body":"use getByRole rather than getByText — copy will change"},
 {"pr":103,"id":3,"in_reply_to_id":null,"path":"src/http/retry.ts","line":5,"created_at":"2026-08-03T00:00:00Z",
  "body":"This retries 4xx too, which silently turns a validation bug into a timeout."},
 {"pr":104,"id":4,"in_reply_to_id":null,"path":"src/http/retry.ts","line":9,"created_at":"2026-08-04T00:00:00Z",
  "body":"Careful: the backoff cap is per attempt, not total — a leak of wall-clock on slow hosts."},
 {"pr":105,"id":5,"in_reply_to_id":null,"path":"src/http/retry.test.ts","line":40,"created_at":"2026-08-05T00:00:00Z",
  "body":"Nit: prefer a table over three near-identical cases."},
 {"pr":106,"id":6,"in_reply_to_id":null,"path":"src/ui/Button.tsx","line":1,"created_at":"2026-08-06T00:00:00Z",
  "body":"Token instead of hex here."},
 {"pr":107,"id":7,"in_reply_to_id":null,"path":"src/api/client.ts","line":3,"created_at":"2026-08-07T00:00:00Z",
  "body":"Timeout should come from config"},
 {"pr":107,"id":8,"in_reply_to_id":7,"path":"src/api/client.ts","line":3,"created_at":"2026-08-07T00:01:00Z",
  "body":"timeout should come from config, agreed"},
 {"pr":108,"id":9,"in_reply_to_id":null,"path":"","line":null,"created_at":"2026-08-08T00:00:00Z","body":"outdated"},
 {"pr":108,"id":10,"in_reply_to_id":null,"path":"src/x.ts","line":null,"created_at":"2026-08-08T00:00:00Z","body":""}
]
JSON
printf '{"runner":"vitest","runners_detected":["vitest"],"total_test_files":7,"sampled":7,"idioms":{},"placement":{"colocated":5,"mirrored":2,"verdict":"colocated"},"fixture_dirs":[],"factories":[]}\n' > "$FIX/tests.json"

echo "mine-history.sh — fixture run"
OUT1="$TMP/out1"
MINE_FIXTURE_DIR="$FIX" "$SCRIPT" --repo "$HERE" --out "$OUT1" >"$TMP/run1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit 0" "rc=$rc: $(cat "$TMP/run1.log")"
for f in prs.json review_comments.json tests.json candidates.json; do
  [ -f "$OUT1/$f" ] && ok "wrote $f" || bad "wrote $f"
done
C="$OUT1/candidates.json"
check "candidates is an array" 'type == "array"' "$C"
check "every candidate has occurrences >= 2" 'all(.[]; .occurrences >= 2)' "$C"
check "contract keys present on every candidate" \
  'all(.[]; (keys | sort) == ["evidence","files_hint","id","kind","occurrences","title"])' "$C"
check "kind within the closed vocabulary" 'all(.[]; .kind | IN("pattern","gotcha","testing","checklist"))' "$C"
check "evidence rows carry pr/path/excerpt" 'all(.[].evidence[]; (keys | sort) == ["excerpt","path","pr"])' "$C"
check "excerpts <= 200 chars and single-line" 'all(.[].evidence[]; (.excerpt | length) <= 200 and (.excerpt | contains("\n") | not))' "$C"
check "topic group: getByRole/getByText spans PRs 101+102" \
  'any(.[]; .id | startswith("topic--")) and (map(select(.id | startswith("topic--")))[0] | .occurrences == 2 and (.evidence | map(.pr) | sort) == [101,102] and .kind == "testing" and (.files_hint | sort) == ["e2e/items/create.spec.ts","e2e/items/list.spec.ts"])' "$C"
check "topic title is dir + stem words" \
  '(map(select(.id | startswith("topic--")))[0].title) == "e2e/items: getbyrole getbytext"' "$C"
check "hotspot group: src/http/retry spans 3 PRs (test file stem normalised)" \
  '(map(select(.id | startswith("hotspot--")))[0] | .occurrences == 3 and (.evidence | map(.pr) | sort) == [103,104,105] and (.title | endswith("src/http/retry: recurring review attention")))' "$C"
check "hotspot kind = majority (2 gotcha vs 1 testing)" '(map(select(.id | startswith("hotspot--")))[0].kind) == "gotcha"' "$C"
check "single-PR echoes (PR 107) do not become candidates" 'all(.[]; (.evidence | map(.pr) | unique | length) >= 2)' "$C"
check "lone comment (PR 106) absent" 'all(.[].evidence[]; .pr != 106)' "$C"
check "empty path / empty body (PR 108) ignored" 'all(.[].evidence[]; .pr != 108)' "$C"
check "exactly two candidates emitted" 'length == 2' "$C"
check "sorted by occurrences desc" '.[0].occurrences >= .[1].occurrences' "$C"
check "ids are stable slugs" 'all(.[]; .id | test("^(topic|hotspot)--[A-Za-z0-9_]+$"))' "$C"
check "fixture tests.json passed through" '.runner == "vitest"' "$OUT1/tests.json"

echo "mine-history.sh — --dry-run writes nothing"
OUT2="$TMP/out2"
dry="$(MINE_FIXTURE_DIR="$FIX" "$SCRIPT" --repo "$HERE" --out "$OUT2" --dry-run 2>/dev/null)"
[ ! -e "$OUT2" ] && ok "no output dir created" || bad "no output dir created"
case "$dry" in
  prs=12\ review_comments=10\ test_files=7\ candidates=2*) ok "counts line: $dry" ;;
  *) bad "counts line" "$dry" ;;
esac

echo "mine-history.sh — degrade on < 10 merged PRs"
FIX2="$TMP/fixture-thin"; mkdir -p "$FIX2"
jq '.[0:3]' "$FIX/prs.json" > "$FIX2/prs.json"
cp "$FIX/review_comments.json" "$FIX/tests.json" "$FIX2/"
OUT3="$TMP/out3"
MINE_FIXTURE_DIR="$FIX2" "$SCRIPT" --repo "$HERE" --out "$OUT3" >"$TMP/run3.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 on thin history" || bad "exit 0 on thin history" "rc=$rc"
grep -q "only 3 merged PR" "$TMP/run3.log" && ok "reason printed" || bad "reason printed" "$(cat "$TMP/run3.log")"
[ "$(cat "$OUT3/candidates.json" 2>/dev/null | jq -c .)" = "[]" ] && ok "empty candidates.json written" || bad "empty candidates.json written"
[ ! -f "$OUT3/prs.json" ] && ok "no partial data on degrade" || bad "no partial data on degrade"

echo "mine-history.sh — test survey runs on this repo when fixture has no tests.json"
FIX3="$TMP/fixture-survey"; mkdir -p "$FIX3"
cp "$FIX/prs.json" "$FIX/review_comments.json" "$FIX3/"
OUT4="$TMP/out4"
MINE_FIXTURE_DIR="$FIX3" "$SCRIPT" --repo "$HERE" --out "$OUT4" >/dev/null 2>&1
check "tests.json has the survey shape" \
  '(keys | sort) == ["factories","fixture_dirs","idioms","placement","runner","runners_detected","sampled","total_test_files"] and (.total_test_files | type) == "number" and (.placement.verdict | IN("colocated","mirrored","none"))' "$OUT4/tests.json"

echo "mine-history.sh — bash -n"
bash -n "$SCRIPT" && ok "syntax" || bad "syntax"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
