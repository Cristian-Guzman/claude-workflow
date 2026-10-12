#!/usr/bin/env bash
# mine-history.sh — cold-start mining of a repo's merged-PR history into /learn --mine input.
#
# Read-only on the repo. Collects (via gh + jq) the last N merged PRs, their inline review
# comments and a survey of the test suite, then pre-clusters the review comments
# deterministically into candidates.json — the data contract /learn --mine turns into
# pattern entries. The model generalises; this script only decides what recurs.
#
# Usage:
#   mine-history.sh [--repo <path>] [--limit N] [--out <dir>] [--dry-run]
#
#   --repo    repo root (default: the git toplevel of $PWD)
#   --limit   merged PRs to fetch (default: $N or 50)
#   --out     output dir (default: <repo>/.claude/state/mine/<UTC date>/)
#   --dry-run print counts only, write nothing
#
# Env:
#   N                 same as --limit
#   MINE_FIXTURE_DIR  skip collection; read prs.json, review_comments.json and (optionally)
#                     tests.json from this dir — the pure grouping runs offline (tests use it)
#
# Outputs (<out>/): prs.json, review_comments.json, tests.json, candidates.json
#   candidates.json = [{id, title, kind: pattern|gotcha|testing|checklist, occurrences,
#                       evidence: [{pr, path, excerpt}], files_hint}]
#   occurrences = distinct PRs in the group, >= 2 enforced here; excerpts <= 200 chars.
#
# Degrades (exit 0, empty candidates.json, reason printed): gh or jq missing, not a GitHub
# remote / not authenticated, fewer than 10 merged PRs.
set -euo pipefail

REPO=""
LIMIT="${N:-50}"
OUT=""
DRY_RUN=0
MIN_PRS=10
MAX_TEST_SAMPLE=30
MAX_CANDIDATES=40
MAX_EVIDENCE=6

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
REPO="$(cd "$REPO" && pwd)"
TODAY="$(date -u +%Y-%m-%d)"
[ -n "$OUT" ] || OUT="$REPO/.claude/state/mine/$TODAY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mine-history.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

log() { printf '%s\n' "$*" >&2; }

# Degrade path: say why, leave an empty (but valid) candidates.json, exit 0 so callers
# that chain on this script keep going. No partial data is written.
degrade() {
  log "mine-history: $1 — nothing to mine."
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$OUT"
    printf '[]\n' > "$OUT/candidates.json"
    log "wrote empty $OUT/candidates.json"
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || degrade "jq is not installed"

# ---------------------------------------------------------------- collect
collect() {
  command -v gh >/dev/null 2>&1 || degrade "gh is not installed"
  local slug
  slug="$(cd "$REPO" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$slug" ] || degrade "not a GitHub remote (or gh is not authenticated) at $REPO"

  log "mine-history: fetching up to $LIMIT merged PRs from $slug"
  (cd "$REPO" && gh pr list --state merged --limit "$LIMIT" \
      --json number,title,body,files,reviews,reviewDecision,mergedAt,baseRefName,headRefName,labels) \
    > "$WORK/prs.json"

  # One paginated call per PR. Pages arrive as separate JSON arrays; slurp + add flattens.
  # Reviewer identities are dropped on purpose — the signal is the comment, not the person.
  printf '[]' > "$WORK/review_comments.json"
  local n total=0
  for n in $(jq -r '.[].number' "$WORK/prs.json"); do
    (cd "$REPO" && gh api "repos/{owner}/{repo}/pulls/$n/comments" --paginate 2>/dev/null || printf '[]') \
      | jq -s --argjson pr "$n" '
          add // [] | map(select((.user.type // "User") != "Bot"))
          | map({pr: $pr, id, in_reply_to_id: (.in_reply_to_id // null), path,
                 line: (.line // .original_line // null), created_at, body: (.body // "")})' \
      > "$WORK/rc.$n.json"
    total=$((total + 1))
  done
  jq -s 'add // []' "$WORK"/rc.*.json > "$WORK/review_comments.json" 2>/dev/null || printf '[]' > "$WORK/review_comments.json"
  log "mine-history: $total PRs, $(jq length "$WORK/review_comments.json") review comments"
}

# ---------------------------------------------------------------- test survey
# Everything here is grep/find over the working tree — no runner is executed.
survey_tests() {
  local runners="" primary="unknown" files
  if [ -f "$REPO/package.json" ]; then
    grep -qE '"vitest"'            "$REPO/package.json" && runners="$runners vitest"
    grep -qE '"jest"'              "$REPO/package.json" && runners="$runners jest"
    grep -qE '"mocha"'             "$REPO/package.json" && runners="$runners mocha"
    grep -qE '"@playwright/test"'  "$REPO/package.json" && runners="$runners playwright"
    grep -qE '"cypress"'           "$REPO/package.json" && runners="$runners cypress"
  fi
  [ -f "$REPO/go.mod" ] && runners="$runners go-test"
  [ -f "$REPO/Cargo.toml" ] && runners="$runners cargo-test"
  if [ -f "$REPO/pyproject.toml" ] || [ -f "$REPO/requirements.txt" ] || [ -f "$REPO/setup.py" ]; then
    runners="$runners pytest"
  fi
  if [ -f "$REPO/pom.xml" ] || [ -f "$REPO/build.gradle" ]; then runners="$runners junit"; fi
  runners="$(printf '%s' "$runners" | sed 's/^ //')"
  primary="${runners%% *}"
  [ -n "$primary" ] || primary="unknown"

  files="$WORK/test_files.txt"
  (cd "$REPO" && find . -type f \
      \( -name '*.test.*' -o -name '*.spec.*' -o -name '*_test.go' -o -name 'test_*.py' -o -name '*_test.py' -o -name '*Test.java' -o -name '*Tests.swift' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' \
      -not -path '*/vendor/*' -not -path '*/.next/*' -not -path '*/target/*' -not -path '*/coverage/*' \
    | sed 's|^\./||' | sort) > "$files"
  local total sample
  total="$(wc -l < "$files" | tr -d ' ')"
  head -n "$MAX_TEST_SAMPLE" "$files" > "$WORK/sample.txt"
  sample="$(wc -l < "$WORK/sample.txt" | tr -d ' ')"

  count_idiom() { # $1 = fixed string
    local c=0 f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      c=$((c + $(grep -cF -- "$1" "$REPO/$f" 2>/dev/null || true)))
    done < "$WORK/sample.txt"
    printf '%s' "$c"
  }

  # Placement: a test file whose directory is named like a test tree is "mirrored";
  # one that sits next to non-test sources is "colocated".
  local colocated=0 mirrored=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      test/*|tests/*|spec/*|__tests__/*|*/test/*|*/tests/*|*/spec/*|*/__tests__/*|e2e/*|*/e2e/*) mirrored=$((mirrored + 1)) ;;
      *) colocated=$((colocated + 1)) ;;
    esac
  done < "$WORK/sample.txt"
  local verdict="none"
  if [ "$colocated" -gt "$mirrored" ]; then verdict="colocated"; elif [ "$mirrored" -gt 0 ]; then verdict="mirrored"; fi

  (cd "$REPO" && find . -type d \( -name 'fixtures' -o -name '__fixtures__' -o -name 'testdata' -o -name '__mocks__' -o -name 'mocks' -o -name 'factories' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/vendor/*' \
    | sed 's|^\./||' | sort | head -20) > "$WORK/fixture_dirs.txt"

  # Factory helpers: make*/build*/create* identifiers in the sampled tests, top 15 by count.
  : > "$WORK/factories.txt"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -ohE '\b(make|build|create)[A-Z][A-Za-z0-9]*\b' "$REPO/$f" 2>/dev/null >> "$WORK/factories.txt" || true
  done < "$WORK/sample.txt"
  sort "$WORK/factories.txt" | uniq -c | sort -rn | head -15 \
    | awk '{printf "{\"name\":\"%s\",\"count\":%d}\n", $2, $1}' | jq -s '.' > "$WORK/factories.json"

  jq -n \
    --arg primary "$primary" \
    --arg runners "$runners" \
    --argjson total "$total" --argjson sample "$sample" \
    --argjson jest_mock "$(count_idiom 'jest.mock(')" \
    --argjson vi_mock "$(count_idiom 'vi.mock(')" \
    --argjson render_hook "$(count_idiom 'renderHook(')" \
    --argjson httptest "$(count_idiom 'httptest.')" \
    --argjson gomock "$(count_idiom 'gomock')" \
    --argjson testify "$(count_idiom 'testify')" \
    --argjson pytest_fixture "$(count_idiom 'pytest.fixture')" \
    --argjson unittest_mock "$(count_idiom 'unittest.mock')" \
    --argjson colocated "$colocated" --argjson mirrored "$mirrored" --arg verdict "$verdict" \
    --slurpfile factories "$WORK/factories.json" \
    --rawfile fixture_dirs "$WORK/fixture_dirs.txt" \
    '{
      runner: $primary,
      runners_detected: ($runners | split(" ") | map(select(length > 0))),
      total_test_files: $total, sampled: $sample,
      idioms: {"jest.mock(": $jest_mock, "vi.mock(": $vi_mock, "renderHook(": $render_hook,
               "httptest.": $httptest, "gomock": $gomock, "testify": $testify,
               "pytest.fixture": $pytest_fixture, "unittest.mock": $unittest_mock},
      placement: {colocated: $colocated, mirrored: $mirrored, verdict: $verdict},
      fixture_dirs: ($fixture_dirs | split("\n") | map(select(length > 0))),
      factories: ($factories[0] // [])
    }' > "$WORK/tests.json"
}

# ---------------------------------------------------------------- candidates (pure jq)
# Two groupings over review comments, both keyed by directory:
#   topic-*   directory + normalised stem of the comment's first line (two significant words)
#   hotspot-* directory + normalised FILE stem — the same module drawing review attention
# A group is a candidate only when its comments come from >= 2 distinct PRs.
read -r -d '' JQ_CANDIDATES <<'JQ' || true
def stopwords: ["the","this","that","these","those","with","from","have","here","there",
  "should","could","would","please","instead","rather","also","just","maybe","think","about",
  "than","then","what","when","where","which","will","your","into","over","some","same","only",
  "more","need","needs","like","want","make","sure","does","done","being","been","were","very",
  "much","still","since","because","while","after","before","using","used","uses","probably",
  "actually","really","might","thanks","good","nice","looks","seems","though","through","them",
  "they","their","each","other","another","maybe","perhaps","something","anything","everything"];
def first_line: (. // "") | split("\n") | map(select((. | gsub("\\s"; "")) | length > 0)) | (.[0] // "");
def tokens: ascii_downcase | gsub("```[^`]*```"; " ") | gsub("[^a-z0-9_]+"; " ") | split(" ")
  | map(select(length >= 4)) | map(select(. as $t | (stopwords | index($t)) == null))
  | map(sub("(ing|ed|es|s)$"; ""));
def body_stem: first_line | tokens | .[0:2] | join("-");
def dir_of: split("/") | .[:-1] | join("/") | if . == "" then "." else . end;
def file_stem: split("/") | last | ascii_downcase
  | sub("_test\\.go$"; "") | sub("^test_"; "") | sub("\\.(test|spec|stories)\\..*$"; "")
  | sub("\\.[a-z0-9]+$"; "");
def excerpt: first_line | .[0:200];
def is_test_path: test("(\\.|_)(test|spec)\\.|_test\\.go$|(^|/)(tests?|__tests__|e2e|spec)/|(^|/)test_[^/]*\\.py$|(^|/)(__)?(fixtures?|mocks)(__)?/"; "i");
def kind_of:
  if (.path | is_test_path) or ((.body // "") | test("\\b(test|tests|mock|mocks|spec|fixture|assert|expect|coverage)\\b"; "i")) then "testing"
  elif ((.body // "") | test("\\b(never|always|every|remember|make sure|don'?t forget|checklist|before (merging|opening)|in the same pr)\\b"; "i")) then "checklist"
  elif ((.body // "") | test("\\b(bug|breaks?|broken|crash|fails?|race|leak|undefined|null|silently|edge case|careful|gotcha|regression|infinite|stale)\\b"; "i")) then "gotcha"
  else "pattern" end;
def majority_kind: map(.kind) | group_by(.) | max_by(length) | .[0];
def slug: gsub("[^A-Za-z0-9]+"; "_") | gsub("^_+|_+$"; "");
def build($prefix; keyf; titlef):
  map(select((.path // "") != "" and (.body // "") != "") | . + {kind: kind_of, key: keyf})
  | map(select(.key != "" and (.key | endswith("|")) == false))
  | group_by(.key)
  | map(select((map(.pr) | unique | length) >= 2))
  | map({
      id: ($prefix + "--" + (.[0].key | slug)),
      title: (.[0] | titlef),
      kind: majority_kind,
      occurrences: (map(.pr) | unique | length),
      evidence: (sort_by(-.pr) | .[0:$max_evidence] | map({pr, path, excerpt: (.body | excerpt)})),
      files_hint: (map(.path) | unique | sort)
    });
. as $comments
| ($comments | build("topic"; ((.path | dir_of) + "|" + (.body | body_stem));
      ((.path | dir_of) + ": " + (.body | body_stem | gsub("-"; " ")))))
  + ($comments | build("hotspot"; ((.path | dir_of) + "|" + (.path | file_stem));
      ((.path | dir_of) + "/" + (.path | file_stem) + ": recurring review attention")))
| sort_by(-.occurrences, -(.evidence | length), .title)
| .[0:$max_candidates]
JQ

candidates() {
  jq --argjson max_evidence "$MAX_EVIDENCE" --argjson max_candidates "$MAX_CANDIDATES" \
     "$JQ_CANDIDATES" "$WORK/review_comments.json" > "$WORK/candidates.json"
}

# ---------------------------------------------------------------- main
if [ -n "${MINE_FIXTURE_DIR:-}" ]; then
  [ -f "$MINE_FIXTURE_DIR/prs.json" ] || { log "fixture dir lacks prs.json: $MINE_FIXTURE_DIR"; exit 1; }
  cp "$MINE_FIXTURE_DIR/prs.json" "$WORK/prs.json"
  if [ -f "$MINE_FIXTURE_DIR/review_comments.json" ]; then
    cp "$MINE_FIXTURE_DIR/review_comments.json" "$WORK/review_comments.json"
  else
    printf '[]' > "$WORK/review_comments.json"
  fi
  if [ -f "$MINE_FIXTURE_DIR/tests.json" ]; then
    cp "$MINE_FIXTURE_DIR/tests.json" "$WORK/tests.json"
  else
    survey_tests
  fi
  log "mine-history: fixture mode ($MINE_FIXTURE_DIR), collection skipped"
else
  collect
  survey_tests
fi

pr_count="$(jq length "$WORK/prs.json")"
[ "$pr_count" -ge "$MIN_PRS" ] || degrade "only $pr_count merged PR(s) found, need >= $MIN_PRS"

candidates

comment_count="$(jq length "$WORK/review_comments.json")"
cand_count="$(jq length "$WORK/candidates.json")"
test_total="$(jq -r '.total_test_files' "$WORK/tests.json")"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'prs=%s review_comments=%s test_files=%s candidates=%s (dry-run, nothing written)\n' \
    "$pr_count" "$comment_count" "$test_total" "$cand_count"
  exit 0
fi

mkdir -p "$OUT"
cp "$WORK/prs.json" "$WORK/review_comments.json" "$WORK/tests.json" "$WORK/candidates.json" "$OUT/"
printf 'prs=%s review_comments=%s test_files=%s candidates=%s -> %s\n' \
  "$pr_count" "$comment_count" "$test_total" "$cand_count" "$OUT"
log "next: /learn --mine (reads $OUT/candidates.json; nothing is written to pattern files without approval)"
