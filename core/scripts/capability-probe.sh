#!/usr/bin/env bash
# capability-probe.sh — emit the project's capability vector as JSON.
#
# Usage: capability-probe.sh [PLACEMENT_DIR]      (default: $WORKSPACE_ROOT, else $CLAUDE_PROJECT_DIR, else CWD)
#
# This is the mechanical half of /bootstrap: every signal the gate matrix in
# core/docs/inventory.yaml evaluates comes from HERE, never from prose a model
# re-derives each run. Unknowns are emitted as "?" — the command asks the user one
# question per "?" and never guesses, because a wrong default silently installs or
# prunes the wrong commands.
#
# Vector: vcs_host ci ticket_system wiki e2e api_collection dev_server ui_surfaces repo_count memory_system team roles re_tooling
set -u

DIR="${1:-${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "error: $DIR not a directory" >&2; exit 1; }
CLAUDE_DIR="$DIR/.claude"

# Real repo profiles (never the schema example)
profiles() { ls "$CLAUDE_DIR"/repo-profiles/*.yaml 2>/dev/null | grep -v '/_schema\.yaml$' || true; }
# grep across the real profiles; exit 1 (no match) when there are none — never falls back to stdin
pgrep() { local f hit=1; for f in $(profiles); do grep -hE "$@" "$f" 2>/dev/null && hit=0; done; return $hit; }
pgrepq() { pgrep "$@" >/dev/null; }
# Git roots to inspect: the placement dir itself if it is a repo, else every child repo
# (a multi-repo workspace root is not a git repo; its signals are the union of its repos).
if [ -d "$DIR/.git" ]; then GIT_DIRS="$DIR"; else GIT_DIRS=$(find "$DIR" -mindepth 2 -maxdepth 2 -name .git 2>/dev/null | sed 's#/\.git$##' | sort); fi

# --- vcs_host: github | other-host | none
VCS_HOST=none
for g in $GIT_DIRS; do
  host_url=$(git -C "$g" remote get-url origin 2>/dev/null || true)
  case "$host_url" in
    *github.com*) VCS_HOST=github; break ;;
    "")           ;;
    *)            VCS_HOST=other-host ;;
  esac
done

# --- ci: yes | no
CI=no
for g in $GIT_DIRS; do
  for c in .github/workflows .gitlab-ci.yml azure-pipelines.yml .circleci Jenkinsfile bitbucket-pipelines.yml; do
    [ -e "$g/$c" ] && CI=yes && break 2
  done
done

# --- ticket_system: jira | github | ado | linear | none | "?"
#     Profile first (single home for tracker config), then CLIs, then git-log key shapes.
TICKET=""
prof_tracker=$(pgrep '^tracker_system:' | awk '{print $2}' | sort -u | head -1 || true)
case "$prof_tracker" in
  jira|github|linear|none) TICKET=$prof_tracker ;;
esac
if [ -z "$TICKET" ]; then
  keys=$(for g in $GIT_DIRS; do git -C "$g" log --oneline -200 2>/dev/null; done | grep -oE '\b[A-Z]{2,6}-[0-9]+\b|#[0-9]+|AB#[0-9]+' | sed -E 's/[0-9]+$//' | sort | uniq -c | sort -rn | head -3 || true)
  has_jira_cli=$(command -v jira >/dev/null 2>&1 && echo 1 || echo 0)
  has_gh=$(command -v gh >/dev/null 2>&1 && echo 1 || echo 0)
  has_az=$(command -v az >/dev/null 2>&1 && echo 1 || echo 0)
  if   echo "$keys" | grep -q 'AB#';                           then TICKET=$([ "$has_az" = 1 ] && echo ado || echo "?")
  elif echo "$keys" | grep -qE '[A-Z]{2,6}-$';                 then TICKET=$([ "$has_jira_cli" = 1 ] && echo jira || echo "?")
  elif echo "$keys" | grep -qE '^ *[0-9]+ #$';                 then TICKET=$([ "$has_gh" = 1 ] && [ "$VCS_HOST" = github ] && echo github || echo "?")
  elif [ "$has_jira_cli" = 1 ];                                then TICKET="?"   # CLI present, no evidence in history
  else TICKET=none; fi
fi
TICKET_PATTERN=$(for g in $GIT_DIRS; do git -C "$g" log --oneline -200 2>/dev/null; done | grep -oE '\b[A-Z]{2,6}-[0-9]+\b' | sed -E 's/-[0-9]+$//' | sort | uniq -c | sort -rn | awk 'NR==1{print $2"-[0-9]+"}' || true)

# --- wiki: confluence | notion | none
#     Project content only — never the workflow's own commands/docs, which mention every wiki.
WIKI=none
#     Placeholder lines ({…}) in a still-seeded CLAUDE.md are template text, not evidence.
proj_text() { cat "$DIR"/README.md "$DIR"/CLAUDE.md "$CLAUDE_DIR"/business-context.md 2>/dev/null | grep -v '{'; [ -d "$DIR/specs" ] && grep -rhi . "$DIR/specs" 2>/dev/null | head -2000; true; }
{ pgrepq '^confluence_space:[[:space:]]*"?[^"[:space:]]' \
  || proj_text | grep -qiE 'atlassian\.net/wiki|confluence'; } && WIKI=confluence
{ proj_text | grep -qiE 'notion\.so|notion\.site' || grep -iE 'notion\.site' "$CLAUDE_DIR"/upstream.json 2>/dev/null | grep -qv '<company>'; } && WIKI=${WIKI/none/notion}

# --- e2e: playwright | cypress | none   (profile e2e.enabled wins; else manifests one level down too)
E2E=none
if pgrepq '^\s*enabled:\s*true'; then
  fw=$(pgrep '^\s*framework:' | awk '{print $2}' | head -1); E2E=${fw:-playwright}
else
  for pj in "$DIR"/package.json "$DIR"/*/package.json; do
    [ -f "$pj" ] || continue
    grep -qE '"@?playwright' "$pj" && E2E=playwright && break
    grep -qE '"cypress"' "$pj" && E2E=cypress && break
  done
fi

# --- api_collection: postman | playwright-request | none
#     What the sdet lane can drive for API coverage: an IN-REPO Postman/newman collection, or
#     Playwright specs that use the `request` fixture. OpenAPI files are a contract source, not a collection.
API_COLLECTION=none
if find "$DIR" -maxdepth 4 -name '*.postman_collection.json' -not -path '*/node_modules/*' 2>/dev/null | grep -q .; then API_COLLECTION=postman
elif find "$DIR" -maxdepth 5 \( -name '*.spec.ts' -o -name '*.spec.js' -o -name '*.test.ts' \) -not -path '*/node_modules/*' 2>/dev/null \
       | head -400 | xargs grep -lE '\brequest\.(get|post|put|patch|delete|fetch)\(' 2>/dev/null | grep -q .; then API_COLLECTION=playwright-request; fi

# --- dev_server: yes | none
DEV_SERVER=none
pgrepq '^dev_server(_url)?:[[:space:]]*"?[^"[:space:]]' && DEV_SERVER=yes
for pj in "$DIR"/package.json "$DIR"/*/package.json; do
  [ -f "$pj" ] && grep -qE '"(dev|start|serve)"[[:space:]]*:' "$pj" && DEV_SERVER=yes && break
done

# --- ui_surfaces: comma list (web, word-addin, gdocs-addin, ios) | none   (profile ui_surface wins)
UI=""
prof_ui=$(pgrep '^ui_surface:' | awk '{print $2}' | tr -d '"' | grep -v '^$' | sort -u | paste -sd, - || true)
if [ -n "$prof_ui" ]; then UI="$prof_ui"; else
  for d in "$DIR" "$DIR"/*/; do
    [ -d "$d" ] || continue
    { grep -qE '"(react|vue|svelte|next|nuxt|angular)"' "$d"/package.json 2>/dev/null || [ -d "$d/src/components" ] || [ -d "$d/src/pages" ]; } && UI="web"
    [ -f "$d/manifest.xml" ] && grep -qi 'office' "$d/manifest.xml" && UI="${UI:+$UI,}word-addin"
    [ -f "$d/appsscript.json" ] && UI="${UI:+$UI,}gdocs-addin"
    ls -d "$d"/*.xcodeproj >/dev/null 2>&1 && UI="${UI:+$UI,}ios"
  done
  UI=$(printf '%s' "$UI" | tr ',' '\n' | grep -v '^$' | sort -u | paste -sd, -)
fi
[ -z "$UI" ] && UI=none

# --- commits / manifest: how much exists yet (day-zero detection for /bootstrap and /build)
COMMITS=0
for g in $GIT_DIRS; do c=$(git -C "$g" rev-list --count HEAD 2>/dev/null || echo 0); [ "$c" -gt "$COMMITS" ] && COMMITS=$c; done
MANIFEST=none
for d in "$DIR" "$DIR"/*/; do
  [ -d "$d" ] || continue
  for m in package.json go.mod pyproject.toml Cargo.toml pubspec.yaml Gemfile pom.xml build.gradle; do [ -f "$d/$m" ] && MANIFEST=yes && break 2; done
  ls -d "$d"/*.xcodeproj >/dev/null 2>&1 && MANIFEST=yes && break
done

# --- repo_count: git repos at depth <= 2 (the workspace root itself counts if it is a repo)
REPO_COUNT=$(find "$DIR" -maxdepth 2 -name .git 2>/dev/null | wc -l | tr -d ' ')

# --- memory_system: yes | no   (host auto-memory dir for THIS workspace, never assumed)
#     exact = this workspace's dir; the host may also keep one shared memory dir (home project) → "yes" too
MEMORY=no
enc=$(printf '%s' "$DIR" | sed 's#/#-#g')
if [ -f "$HOME/.claude/projects/$enc/memory/MEMORY.md" ]; then MEMORY=yes
elif ls "$HOME"/.claude/projects/*/memory/MEMORY.md >/dev/null 2>&1; then MEMORY=yes; fi

# --- team: true | false   (>1 distinct committer in recent history)
authors=$(for g in $GIT_DIRS; do git -C "$g" log --format='%ae' -200 2>/dev/null; done | sort -u | wc -l | tr -d ' ')
[ "${authors:-1}" -gt 1 ] && TEAM=true || TEAM=false

# --- re_tooling: rea | none   (reverse-engineering tooling for /reverse)
#     rea = the CLI is on PATH, or an MCP server named "rea" is registered for this client.
#     The CLI/server being present does NOT mean a native engine (Hopper/Ghidra/IDA) is configured;
#     /reverse checks that itself per target, because web/Electron/APK targets need none.
RE_TOOLING=none
command -v rea >/dev/null 2>&1 && RE_TOOLING=rea
if [ "$RE_TOOLING" = none ]; then
  for m in "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.local.json" "$DIR/.mcp.json" "$HOME/.claude.json"; do
    [ -f "$m" ] || continue
    grep -qE '"rea(-agents)?"[[:space:]]*:' "$m" 2>/dev/null && RE_TOOLING=rea && break
  done
fi

# --- roles: from workflow-manifest.json (written by install.sh); [] when absent
ROLES="[]"
if [ -f "$CLAUDE_DIR/workflow-manifest.json" ]; then
  r=$(sed -n 's/.*"roles": *\[\([^]]*\)\].*/\1/p' "$CLAUDE_DIR/workflow-manifest.json" | tr -d ' ')
  [ -n "$r" ] && ROLES="[$r]"
fi

cat <<EOF
{
  "placement_dir": "$DIR",
  "vcs_host": "$VCS_HOST",
  "ci": "$CI",
  "ticket_system": "$TICKET",
  "ticket_id_pattern": "${TICKET_PATTERN:-}",
  "wiki": "$WIKI",
  "e2e": "$E2E",
  "api_collection": "$API_COLLECTION",
  "dev_server": "$DEV_SERVER",
  "ui_surfaces": "$UI",
  "repo_count": $REPO_COUNT,
  "commits": $COMMITS,
  "manifest": "$MANIFEST",
  "memory_system": "$MEMORY",
  "team": $TEAM,
  "re_tooling": "$RE_TOOLING",
  "roles": $ROLES
}
EOF
# exit 3 when any value is "?" so a caller can branch on "needs a question"
[ "$TICKET" = "?" ] && exit 3
exit 0
