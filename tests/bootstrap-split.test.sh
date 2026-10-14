#!/usr/bin/env bash
# tests/bootstrap-split.test.sh — release.py · capability-probe.sh · adapt-plan.py
#
# Usage: tests/bootstrap-split.test.sh            (from the repo root)
# Env:   SCRIPTS=<dir>  override where the three scripts live (default: core/scripts)
#        INVENTORY=<file> override the inventory (default: core/docs/inventory.yaml)
# Every case creates its own scratch dir under $TMPDIR; nothing in the repo is written.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="${SCRIPTS:-$REPO/core/scripts}"
INVENTORY="${INVENTORY:-$REPO/core/docs/inventory.yaml}"
RELEASE="${RELEASE:-$REPO/scripts/release.py}"
T="$(mktemp -d "${TMPDIR:-/tmp}/bsplit.XXXXXX")"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
expect_exit() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1" "expected exit $2, got $3"; fi
}
GIT="git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false"

# ------------------------------------------------------------------ fixture: a repo copy
copy_repo() { # $1 = dest
  # working tree, not HEAD — uncommitted edits (a landing in progress) must be under test too
  mkdir -p "$1"; (cd "$REPO" && tar --exclude .git --exclude node_modules -cf - .) | tar -xf - -C "$1"
  (cd "$1" && $GIT init -q . && $GIT add -A && $GIT commit -q -m "snapshot")
}

echo "== release.py"
R="$T/repo"; copy_repo "$R"
python3 "$RELEASE" --root "$R" check >/dev/null 2>&1; expect_exit "check: clean tree" 0 $?
# frontmatter mismatch
f=$(ls "$R"/core/commands/*.md | grep -v README | head -1)
sed -i '' '1,8s/^version: .*/version: 0.0.1/' "$f"
out=$(python3 "$RELEASE" --root "$R" check 2>&1); rc=$?
expect_exit "check: version mismatch detected" 1 $rc
grep -q "$(basename "$f")" <<<"$out" && ok "check: names the file" || bad "check: names the file" "$out"
(cd "$R" && $GIT checkout -q -- .)
# inventory row without file
cp "$R/core/docs/inventory.yaml" "$T/inv.bak" 2>/dev/null || true
# rows are section-scoped: insert the ghost directly under `commands:` (appending would land in `structural:`)
sed -i '' 's/^commands:$/commands:\
  - {name: ghost, role: core, priority: optional, since: 0.1.0, gate: always}/' "$R/core/docs/inventory.yaml" 2>/dev/null \
  || sed -i 's/^commands:$/commands:\n  - {name: ghost, role: core, priority: optional, since: 0.1.0, gate: always}/' "$R/core/docs/inventory.yaml"
out=$(python3 "$RELEASE" --root "$R" check 2>&1); rc=$?
expect_exit "check: inventory row without file" 1 $rc
grep -q "ghost" <<<"$out" && ok "check: names the row" || bad "check: names the row"
(cd "$R" && $GIT checkout -q -- .)
# shipped file without row
printf -- '---\nname: stray\nversion: %s\n---\n' "$(sed -n 's/^version: //p' "$R/core/docs/workflow-version.md" | head -1)" > "$R/core/commands/stray.md"
out=$(python3 "$RELEASE" --root "$R" check 2>&1); rc=$?
expect_exit "check: shipped file without row" 1 $rc
rm "$R/core/commands/stray.md"
# install-time placeholder
printf '\n{TARGET_VERSION}\n' >> "$R/core/commands/learn.md"
python3 "$RELEASE" --root "$R" check >/dev/null 2>&1; expect_exit "check: install placeholder flagged" 1 $?
(cd "$R" && $GIT checkout -q -- .)
# bump
v0=$(sed -n 's/^version: //p' "$R/core/docs/workflow-version.md" | head -1)
python3 "$RELEASE" --root "$R" bump patch --theme t >/dev/null; expect_exit "bump: dry-run exits 0" 0 $?
[ "$(sed -n 's/^version: //p' "$R/core/docs/workflow-version.md" | head -1)" = "$v0" ] && ok "bump: dry-run wrote nothing" || bad "bump: dry-run wrote nothing"
python3 "$RELEASE" --root "$R" bump patch --theme t --apply >/dev/null; expect_exit "bump: --apply" 0 $?
v1=$(sed -n 's/^version: //p' "$R/core/docs/workflow-version.md" | head -1)
[ "$v1" != "$v0" ] && ok "bump: version advanced $v0 -> $v1" || bad "bump: version advanced"
n=$(grep -l "^version: $v1" "$R"/core/commands/*.md "$R"/roles/*/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
m=$(ls "$R"/core/commands/*.md "$R"/roles/*/commands/*.md 2>/dev/null | grep -v README | wc -l | tr -d ' ')
[ "$n" = "$m" ] && ok "bump: propagated to all $m commands" || bad "bump: propagated" "$n of $m"
grep -q "### $v1 — " "$R/core/docs/workflow-version.md" && ok "bump: changelog scaffold" || bad "bump: changelog scaffold"
python3 "$RELEASE" --root "$R" check >/dev/null 2>&1; expect_exit "check: clean after bump" 0 $?

echo "== capability-probe.sh"
P="$T/probe"; mkdir -p "$P/.claude/repo-profiles"; (cd "$P" && $GIT init -q . && touch a && $GIT add a && $GIT commit -q -m a)
cp "$REPO/templates/workspace/repo-profiles/_schema.yaml" "$P/.claude/repo-profiles/" 2>/dev/null || true
out=$("$SCRIPTS/capability-probe.sh" "$P" </dev/null); rc=$?
grep -q '"vcs_host": "none"' <<<"$out" && ok "probe: no remote -> vcs none" || bad "probe: vcs none" "$out"
grep -q '"ci": "no"' <<<"$out" && ok "probe: no CI" || bad "probe: no CI"
grep -q '"wiki": "none"' <<<"$out" && ok "probe: schema-only profiles give no wiki" || bad "probe: wiki none" "$out"
grep -q '"roles": \[\]' <<<"$out" && ok "probe: no manifest -> roles []" || bad "probe: roles []"
# profile wins + workflow-manifest roles + "?" exit
cat > "$P/.claude/repo-profiles/app.yaml" <<'EOF'
tracker_system: linear
ui_surface: ios
dev_server_url: "http://localhost:3000"
EOF
echo '{"roles": ["dev", "sdet"]}' > "$P/.claude/workflow-manifest.json"
out=$("$SCRIPTS/capability-probe.sh" "$P" </dev/null); rc=$?
grep -q '"ticket_system": "linear"' <<<"$out" && ok "probe: profile tracker wins" || bad "probe: profile tracker" "$out"
grep -q '"ui_surfaces": "ios"' <<<"$out" && ok "probe: profile ui_surface wins" || bad "probe: ui_surface"
grep -q '"dev_server": "yes"' <<<"$out" && ok "probe: profile dev_server" || bad "probe: dev_server"
grep -q '"roles": \[dev,sdet\]\|"roles": \["dev","sdet"\]' <<<"$out" && ok "probe: roles from manifest" || bad "probe: roles from manifest" "$out"
expect_exit "probe: resolved vector exits 0" 0 $rc
grep -q '"api_collection": "none"' <<<"$out" && ok "probe: no collection -> api_collection none" || bad "probe: api_collection none" "$out"
mkdir -p "$P/api" && echo '{"info":{"name":"x"}}' > "$P/api/x.postman_collection.json"
out=$("$SCRIPTS/capability-probe.sh" "$P" </dev/null)
grep -q '"api_collection": "postman"' <<<"$out" && ok "probe: in-repo postman collection detected" || bad "probe: postman" "$out"

echo "== adapt-plan.py"
A="$T/adapt/.claude"; mkdir -p "$A/commands" "$A/agents" "$A/_archived-commands" "$A/state"
cp "$INVENTORY" "$A/inventory.yaml"
for f in "$REPO"/core/commands/*.md "$REPO"/roles/dev/commands/*.md; do [ "$(basename "$f")" = README.md ] || cp "$f" "$A/commands/"; done
for f in "$REPO"/core/agents/*.md; do [ "$(basename "$f")" = README.md ] || cp "$f" "$A/agents/"; done
echo '{"version":2,"entries":[]}' > "$A/state/index.json"
cat > "$T/vec.json" <<'EOF'
{"vcs_host":"github","ci":"yes","ticket_system":"jira","wiki":"none","e2e":"playwright","api_collection":"none","dev_server":"yes",
 "ui_surfaces":"web","repo_count":3,"memory_system":"yes","team":true,"roles":["dev"]}
EOF
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json"); rc=$?
expect_exit "adapt: full vector" 0 $rc
grep -qE "^  PRUNE" <<<"$out" && bad "adapt: nothing pruned on a full vector" "$out" || ok "adapt: nothing pruned on a full vector"
grep -q "IGNORE 3" <<<"$out" && ok "adapt: sdet rows ignored for roles=dev" || bad "adapt: sdet ignored" "$out"
# sdet gate: e2e none + api_collection postman -> cover gate true (MISSING, since no sdet files in this fixture)
python3 - "$T/vec.json" "$T/vec-sdet.json" <<'EOF2'
import json,sys; v=json.load(open(sys.argv[1])); v.update(e2e="none", api_collection="postman", roles=["dev","sdet"]); json.dump(v, open(sys.argv[2],"w"))
EOF2
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec-sdet.json")
grep -q "MISSING         command  cover" <<<"$out" && ok "adapt: api_collection satisfies the cover gate" || bad "adapt: cover gate via api_collection" "$out"
python3 - "$T/vec.json" "$T/vec-be.json" <<'EOF'
import json,sys; v=json.load(open(sys.argv[1])); v.update(ui_surfaces="none", team=False, memory_system="no", e2e="none", dev_server="none"); json.dump(v, open(sys.argv[2],"w"))
EOF
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec-be.json")
grep -q "PRUNE           command  qa" <<<"$out" && ok "adapt: fresh install, false gate -> PRUNE (file age is not evidence)" || bad "adapt: PRUNE on fresh install" "$out"
mkdir -p "$A/qa" && echo x > "$A/qa/PROJ-1.md"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec-be.json")
grep -q "KEEP(in-use)    command  qa" <<<"$out" && ok "adapt: artifacts in .claude/qa/ protect qa" || bad "adapt: artifact protection" "$out"
rm -rf "$A/qa"
grep -qE "PRUNE +command +(learn|pr|bootstrap) " <<<"$out" && bad "adapt: core never pruned" || ok "adapt: core never pruned"
echo '{"version":2,"entries":[{"id":"r:qa:x","kind":"qa","path":".claude/qa/x.md"}]}' > "$A/state/index.json"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec-be.json")
grep -q "KEEP(in-use)    command  qa" <<<"$out" && ok "adapt: index entry protects qa" || bad "adapt: index protection" "$out"
mv "$A/commands/screenshot.md" "$A/_archived-commands/"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json")
grep -q "UN-ARCHIVE      command  screenshot" <<<"$out" && ok "adapt: archived + gate true -> UN-ARCHIVE" || bad "adapt: UN-ARCHIVE" "$out"
sed -i '' 's/gate: "memory_system == yes"/gate: "memory_system !! yes"/' "$A/inventory.yaml" 2>/dev/null || sed -i 's/gate: "memory_system == yes"/gate: "memory_system !! yes"/' "$A/inventory.yaml"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec-be.json")
grep -q "KEEP            command  memory-lint .*parse_error" <<<"$out" && ok "adapt: broken gate -> KEEP + parse_error" || bad "adapt: parse_error" "$out"
python3 - "$T/vec.json" "$T/vec-q.json" <<'EOF'
import json,sys; v=json.load(open(sys.argv[1])); v["ticket_system"]="?"; json.dump(v, open(sys.argv[2],"w"))
EOF
python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec-q.json" >/dev/null 2>&1; expect_exit "adapt: unresolved ? -> exit 3" 3 $?
printf -- '---\nname: test-plan\nversion: 0.6.0\n---\n' > "$A/commands/test-plan.md"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json")
grep -q "ORPHAN          command  test-plan" <<<"$out" && ok "adapt: retired file with no row -> ORPHAN (reported, not moved)" || bad "adapt: ORPHAN" "$out"
grep -q "predates the baseline" <<<"$out" && ok "adapt: orphan without a capture is explained as pre-baseline" || bad "adapt: pre-baseline reason" "$out"
[ -f "$A/commands/test-plan.md" ] && ok "adapt: orphan left in place" || bad "adapt: orphan moved"
mkdir -p "$A/.upstream-prior/2026-01-01/installed/commands" && cp "$A/commands/test-plan.md" "$A/.upstream-prior/2026-01-01/installed/commands/"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json")
grep -q "locally edited — install.sh kept it; your copy is at .claude/.upstream-prior/2026-01-01/installed/commands/test-plan.md" <<<"$out" && ok "adapt: orphan with a capture is explained as locally edited + where the copy is" || bad "adapt: captured-orphan reason" "$out"

echo
echo "passed $pass · failed $fail · scratch: $T"
[ "$fail" = 0 ]
