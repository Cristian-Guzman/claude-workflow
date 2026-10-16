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
# --- project-owned files (a step this project invented, e.g. commands/intake.md) ---
printf -- '---\nname: intake\ndescription: project-specific intake step\n---\n' > "$A/commands/intake.md"
mkdir -p "$A/scripts" && printf '#!/usr/bin/env bash\necho mine\n' > "$A/scripts/my-tool.sh"
# no baseline at all (< 0.7.0): nothing can be proven -> today's ORPHAN pre-baseline reason, and the header says why
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json")
grep -q "ORPHAN          command  intake .*predates the baseline" <<<"$out" && ok "adapt: no baseline -> unlisted file stays ORPHAN (pre-baseline reason)" || bad "adapt: pre-baseline intake" "$out"
grep -q "no .upstream-base/" <<<"$out" && ok "adapt: no baseline is said in the header" || bad "adapt: no-baseline header" "$out"
grep -qE "(ORPHAN|LOCAL) +script +my-tool" <<<"$out" && bad "adapt: script never labelled without a baseline" "$out" || ok "adapt: script never labelled without a baseline"
# baseline exists (0.7.0+): .upstream-base/<kind>/<name> is exactly what upstream ships
mkdir -p "$A/.upstream-base/commands" "$A/.upstream-base/agents" "$A/.upstream-base/scripts"
for f in "$REPO"/core/commands/*.md; do [ "$(basename "$f")" = README.md ] || cp "$f" "$A/.upstream-base/commands/"; done
cp "$SCRIPTS/adapt-plan.py" "$A/scripts/" && cp "$SCRIPTS/adapt-plan.py" "$A/.upstream-base/scripts/"
printf -- '---\nname: old-step\nversion: 0.9.0\n---\n' > "$A/commands/old-step.md" && cp "$A/commands/old-step.md" "$A/.upstream-base/commands/"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json"); rc=$?
expect_exit "adapt: baseline present" 0 $rc
grep -q "LOCAL           command  intake .*created in this project, never shipped upstream — install.sh and /bootstrap never touch it" <<<"$out" && ok "adapt: (a) no row + no baseline copy -> LOCAL with the project-owned reason" || bad "adapt: (a) LOCAL intake" "$out"
grep -qE "ORPHAN +command +intake" <<<"$out" && bad "adapt: (a) project-owned file is never ORPHAN" "$out" || ok "adapt: (a) project-owned file is never ORPHAN"
[ -f "$A/commands/intake.md" ] && ok "adapt: (a) project-owned file left in place" || bad "adapt: (a) intake moved"
grep -q "ORPHAN          command  old-step .*baseline proves it was upstream's" <<<"$out" && ok "adapt: (c) retired file in .upstream-base -> still ORPHAN" || bad "adapt: (c) ORPHAN old-step" "$out"
grep -qE "LOCAL +command +old-step" <<<"$out" && bad "adapt: (c) baselined file is never LOCAL" "$out" || ok "adapt: (c) baselined file is never LOCAL"
grep -q "ORPHAN          command  test-plan .*locally edited — install.sh kept it" <<<"$out" && ok "adapt: captured retired file stays ORPHAN once a baseline exists" || bad "adapt: captured orphan with baseline" "$out"
grep -q "LOCAL           script   my-tool.sh .*created in this project" <<<"$out" && ok "adapt: (d) scripts/my-tool.sh -> LOCAL" || bad "adapt: (d) LOCAL script" "$out"
grep -qE "ORPHAN +script" <<<"$out" && bad "adapt: (d) a script is never ORPHAN" "$out" || ok "adapt: (d) a script is never ORPHAN"
grep -qE "(LOCAL|ORPHAN|CONFLICT) +script +adapt-plan" <<<"$out" && bad "adapt: (d) baselined script gets no row" "$out" || ok "adapt: (d) baselined script gets no row"
grep -q "LOCAL 2" <<<"$out" && ok "adapt: LOCAL counted in the summary" || bad "adapt: LOCAL count" "$out"
# (b) the installer recorded a same-name collision in the tracked manifest
echo '{"schema": 1, "workflow_version": "0.10.2", "roles": ["dev"], "conflicts": ["commands/intake.md"]}' > "$A/workflow-manifest.json"
out=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json")
grep -q "CONFLICT        command  intake .*project-owned file with the same name as a new upstream command; install.sh kept yours and did not install upstream's — rename yours to adopt upstream's, or keep ignoring it" <<<"$out" && ok "adapt: (b) manifest conflicts -> CONFLICT with the rename advice" || bad "adapt: (b) CONFLICT intake" "$out"
grep -qE "(ORPHAN|LOCAL) +command +intake" <<<"$out" && bad "adapt: (b) a conflict is neither ORPHAN nor LOCAL" "$out" || ok "adapt: (b) a conflict is neither ORPHAN nor LOCAL"
grep -q "CONFLICT 1" <<<"$out" && ok "adapt: CONFLICT counted in the summary" || bad "adapt: CONFLICT count" "$out"
j=$(python3 "$SCRIPTS/adapt-plan.py" --root "$A" --vector "$T/vec.json" --json)
python3 - "$j" <<'EOF' && ok "adapt: --json carries LOCAL/CONFLICT counts, rows and the conflicts list" || bad "adapt: --json LOCAL/CONFLICT"
import json,sys; d=json.loads(sys.argv[1]); c=d["counts"]; by={(r["kind"],r["name"]):r["decision"] for r in d["rows"]}
assert c.get("CONFLICT")==1 and c.get("LOCAL")==1, c
assert by[("command","intake")]=="CONFLICT" and by[("script","my-tool.sh")]=="LOCAL" and by[("command","old-step")]=="ORPHAN", by
assert d["conflicts"]==["commands/intake.md"] and d["baseline"] is True, d
EOF
rm -f "$A/workflow-manifest.json" "$A/commands/intake.md" "$A/commands/old-step.md"

echo
echo "passed $pass · failed $fail · scratch: $T"
[ "$fail" = 0 ]
