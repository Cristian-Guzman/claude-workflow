#!/usr/bin/env bash
set -euo pipefail

# install.sh — install or update the portable Claude Code workflow into a project.
#
# Usage:
#   ./install.sh /path/to/project                      full install, role(s) resolved as below
#   ./install.sh /path/to/project --role dev           pick roles explicitly (repeatable:
#                                 --role sdet            --role a --role b | --roles a,b | --role=a)
#   ./install.sh /path/to/project --stack <flavor>     also append templates/seed-packs/<flavor>/
#                                                      into the matching pattern files (once)
#   ./install.sh /path/to/repo --repo-only [--role X]  seed only the per-repo files (for each extra
#                                                      repo in a multi-repo workspace)
#
# Layout: core/ is always installed; roles/<name>/ adds a lane (dev = implementation,
# sdet = test engineering). Everything lands FLAT in .claude/ — commands/, agents/,
# scripts/, docs at the root — so the commands' hard-coded paths keep working.
#
# Role resolution when --role is omitted:
#   1. .claude/workflow-manifest.json  (written by the last full install; tracked with .claude/)
#   2. legacy inference — a role is on if any of its commands is already installed
#   3. dev
#
# Re-running is SAFE and is how you take updates:
#   - core/ + role files (commands, agents, scripts, docs) are refreshed in place
#   - seeded files the project owns (codebase-patterns.md, settings.json, ...) are
#     NEVER overwritten once they exist
#   - commands of a role you drop are ARCHIVED to .claude/_archived-commands/, never deleted
#   - local edits to generic commands are never lost: the first run on a pre-0.7.0 install
#     copies everything upstream-shaped to .claude/.upstream-prior/<date>/ before touching
#     anything; every later run compares the installed core against .upstream-base/ and, when
#     anything drifted, copies the drifted files + the old baseline there before refreshing
#   - --stack appends seed packs per templates/seed-packs/README.md (marker + H2 for the two
#     pattern files, DoD lines behind a marker in ticket-checklist.md, fullstack-monorepo
#     composes frontend-web + backend-api first); every unit is appended at most once

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
usage: ./install.sh /path/to/project [--repo-only] [--role <name> ...] [--roles a,b] [--stack <flavor>]
USAGE
}

TARGET=""
MODE=full
ROLES_ARG=""
STACKS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-only) MODE=repo-only ;;
    --role|--roles)
      [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; usage >&2; exit 1; }
      ROLES_ARG="${ROLES_ARG:+$ROLES_ARG,}$2"; shift ;;
    --role=*|--roles=*) ROLES_ARG="${ROLES_ARG:+$ROLES_ARG,}${1#*=}" ;;
    --stack)
      [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; usage >&2; exit 1; }
      STACKS="${STACKS:+$STACKS,}$2"; shift ;;
    --stack=*) STACKS="${STACKS:+$STACKS,}${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown flag $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "$TARGET" ]; then TARGET="$1"
      else echo "error: unexpected argument $1 (target already set to $TARGET)" >&2; usage >&2; exit 1
      fi ;;
  esac
  shift
done

if [ -z "$TARGET" ]; then
  usage >&2
  exit 1
fi
if [ ! -d "$TARGET" ]; then
  echo "error: $TARGET is not a directory" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
CLAUDE_DIR="$TARGET/.claude"
MANIFEST="$CLAUDE_DIR/workflow-manifest.json"
BASE="$CLAUDE_DIR/.upstream-base"
VERSION="$(sed -n 's/^version: *//p' "$HERE/core/docs/workflow-version.md" | head -1)"
VERSION="${VERSION:-unknown}"

updated=0
seeded=0
skipped=0
last_seed=""

rel() { printf '%s' "${1#"$TARGET"/}"; }
src() { printf '%s' "${1#"$HERE"/}"; }

# ---------------------------------------------------------------- roles
available_roles() {
  local d
  for d in "$HERE"/roles/*/; do
    [ -d "$d" ] && basename "$d"
  done
}

recorded_roles() { # $1 = manifest path; prints one role per line (empty if none)
  [ -f "$1" ] || return 0
  sed -n 's/.*"roles": *\[\([^]]*\)\].*/\1/p' "$1" | tr -d '" ' | tr ',' '\n' | grep -v '^$' || true
}

infer_legacy_roles() { # pre-manifest install: a role is on if any of its commands is installed
  local r f
  for r in $(available_roles); do
    for f in "$HERE/roles/$r"/commands/*.md; do
      [ -f "$f" ] || continue
      if [ -f "$CLAUDE_DIR/commands/$(basename "$f")" ]; then echo "$r"; break; fi
    done
  done
}

normalize_roles() { tr ', ' '\n\n' | grep -v '^$' | sort -u; }

if [ -n "$ROLES_ARG" ]; then
  ROLES="$(printf '%s' "$ROLES_ARG" | normalize_roles)"
  ROLE_SOURCE="--role"
elif [ -n "$(recorded_roles "$MANIFEST")" ]; then
  ROLES="$(recorded_roles "$MANIFEST" | normalize_roles)"
  ROLE_SOURCE="$(rel "$MANIFEST")"
elif [ "$MODE" = repo-only ] && [ -n "$(recorded_roles "$(dirname "$TARGET")/.claude/workflow-manifest.json")" ]; then
  ROLES="$(recorded_roles "$(dirname "$TARGET")/.claude/workflow-manifest.json" | normalize_roles)"
  ROLE_SOURCE="workspace manifest"
elif [ "$MODE" = full ] && [ -d "$CLAUDE_DIR/commands" ] && [ -n "$(infer_legacy_roles)" ]; then
  ROLES="$(infer_legacy_roles | normalize_roles)"
  ROLE_SOURCE="inferred from installed commands"
else
  ROLES="dev"
  ROLE_SOURCE="default"
fi

for r in $ROLES; do
  case "$r" in
    *[!A-Za-z0-9_-]*|'') echo "error: invalid role name '$r'" >&2; exit 1 ;;
  esac
  if [ ! -d "$HERE/roles/$r" ]; then
    echo "error: unknown role '$r' (available: $(available_roles | tr '\n' ' '))" >&2
    exit 1
  fi
done
ROLES_CSV="$(printf '%s\n' $ROLES | paste -sd, -)"

selected_sources() { # core first, then each selected role
  local r
  echo "$HERE/core"
  for r in $ROLES; do echo "$HERE/roles/$r"; done
}

shipped_command() { # $1 = basename; true if core or a selected role ships it
  local s
  for s in $(selected_sources); do
    [ -f "$s/commands/$1" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- collisions
check_collisions() { # kind/basename must be unique across core + selected roles; exit before any write
  local tmp s label f dups k
  tmp="$(mktemp)"
  emit() { printf '%s/%s\t%s\n' "$1" "$(basename "$2")" "$3" >>"$tmp"; }
  for s in $(selected_sources); do
    label="${s#"$HERE"/}"
    for f in "$s"/commands/*.md;  do [ -f "$f" ] || continue; emit commands  "$f" "$label"; done
    for f in "$s"/agents/*.md;    do [ -f "$f" ] || continue; emit agents    "$f" "$label"; done
    for f in "$s"/scripts/*;      do [ -f "$f" ] || continue; emit scripts   "$f" "$label"; done
    for f in "$s"/docs/*.md "$s"/docs/*.yaml; do [ -f "$f" ] || continue; emit docs "$f" "$label"; done
    if [ "$label" = core ]; then
      for f in "$HERE"/templates/repo/* "$HERE"/templates/workspace/*; do [ -f "$f" ] || continue; emit templates "$f" templates; done
    else
      for f in "$s"/templates/repo/* "$s"/templates/workspace/*; do [ -f "$f" ] || continue; emit templates "$f" "$label"; done
    fi
  done
  dups="$(cut -f1 "$tmp" | sort | uniq -d)"
  if [ -n "$dups" ]; then
    for k in $dups; do
      echo "error: $k is provided by more than one source: $(awk -F'\t' -v k="$k" '$1==k{print $2}' "$tmp" | paste -sd' ' -)" >&2
    done
    echo "error: name collision across core + roles ($ROLES_CSV) — nothing was written" >&2
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------- pre-install capture
sha256_list() { # stdin: file paths; stdout: "<sha>  <path>" lines
  if command -v shasum >/dev/null 2>&1; then xargs shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then xargs sha256sum
  else xargs -I{} sh -c 'printf "unavailable  %s\n" "{}"'
  fi
}

prior_dir() { # $1 = UTC day; prints a fresh .upstream-prior/<day>[.N] path (never an existing one)
  local dst="$CLAUDE_DIR/.upstream-prior/$1" n=1
  while [ -e "$dst" ]; do dst="$CLAUDE_DIR/.upstream-prior/$1.$n"; n=$((n + 1)); done
  printf '%s' "$dst"
}

base_dest() { # $1 = baseline top dir -> installed dir (same map as upstream.py CORE_MAP)
  case "$1" in docs) printf '%s' "$CLAUDE_DIR" ;; *) printf '%s/%s' "$CLAUDE_DIR" "$1" ;; esac
}

shipped_paths() { # every "top/rel" the selected sources will write this run
  local s r f
  for s in $(selected_sources); do
    for f in "$s"/commands/*.md; do [ -f "$f" ] && echo "commands/$(basename "$f")"; done
    for f in "$s"/agents/*.md;   do [ -f "$f" ] && echo "agents/$(basename "$f")"; done
    for f in "$s"/scripts/*;     do [ -f "$f" ] && echo "scripts/$(basename "$f")"; done
    for f in "$s"/docs/*.md;     do [ -f "$f" ] && echo "docs/$(basename "$f")"; done
    [ -f "$s/learn-targets.yaml" ] && echo "learn-targets/$(basename "$s").yaml"
  done
  return 0
}

capture_drifted() {
  # A baseline exists, so we can tell exactly which upstream-owned files the project edited.
  # The refresh below overwrites every shipped file and `rm -rf`s the baseline those edits would
  # be diffed against — so before either, copy the drifted files and the whole old baseline aside.
  # Nothing drifted -> nothing to lose -> nothing written.
  local top rel bp ip status drifted="" count=0 day dst prev_version line
  for top in commands agents scripts docs learn-targets; do
    [ -d "$BASE/$top" ] || continue
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      bp="$BASE/$top/$rel"; ip="$(base_dest "$top")/$rel"
      if [ ! -f "$ip" ]; then status=missing
      elif cmp -s "$bp" "$ip"; then continue
      else status=modified
      fi
      drifted="$drifted$status $top/$rel"$'\n'
    done <<EOF_BASE
$(cd "$BASE/$top" && find . -type f | sed 's|^\./||' | sort)
EOF_BASE
  done
  # Installed files the refresh is about to overwrite that the baseline cannot vouch for.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    top="${line%%/*}"; rel="${line#*/}"
    [ -f "$(base_dest "$top")/$rel" ] || continue
    [ -f "$BASE/$top/$rel" ] && continue
    drifted="${drifted}unbaselined $line"$'\n'
  done <<EOF_SHIPPED
$(shipped_paths | sort -u)
EOF_SHIPPED
  if [ -z "$drifted" ]; then
    echo "  prior    core matches the baseline — nothing to capture before the refresh"
    return 0
  fi
  day="$(date -u +%Y-%m-%d)"
  dst="$(prior_dir "$day")"
  mkdir -p "$dst/installed" "$dst/baseline"
  cp -R "$BASE/." "$dst/baseline/"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    status="${line%% *}"; rel="${line#* }"
    count=$((count + 1))
    [ "$status" = missing ] && continue
    top="${rel%%/*}"
    mkdir -p "$(dirname "$dst/installed/$rel")"
    cp "$(base_dest "$top")/${rel#*/}" "$dst/installed/$rel"
  done <<EOF_DRIFT
$drifted
EOF_DRIFT
  prev_version="$(sed -n 's/^version: *//p' "$CLAUDE_DIR/workflow-version.md" 2>/dev/null | head -1 || true)"
  [ -n "$prev_version" ] || prev_version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$CLAUDE_DIR/.upstream-manifest.json" 2>/dev/null | head -1 || true)"
  (cd "$dst" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.md -print | sort | sha256_list >SHA256SUMS)
  {
    cat <<EOF_PRIOR
# Pre-upgrade capture — $day

Taken by install.sh before refreshing the core: these upstream-owned files differed from the
baseline recorded by the previous install (or had no baseline copy), so the refresh would have
overwritten them with no way to diff. Versions: ${prev_version:-unknown} -> $VERSION.

## Drifted files ($count)

EOF_PRIOR
    printf '%s' "$drifted" | sed 's/^\([a-z]*\) \(.*\)$/- `\2` (\1)/'
    cat <<EOF_PRIOR

- installed/  the project's copy of each drifted file, as it was before the refresh
- baseline/   the whole previous upstream baseline (.upstream-base/ as the last install wrote it)
- Verify:  (cd $(rel "$dst") && shasum -a 256 -c SHA256SUMS)
- Diff:    (cd $(rel "$dst") && for f in \$(cd installed && find . -type f); do diff -u "baseline/\$f" "installed/\$f"; done)
- Re-apply an edit: port the hunks from that diff onto the fresh .claude/<path> (docs/<name>.md lives at .claude/<name>.md)
- Carry an edit upstream: /upstream (drift against .claude/.upstream-base/ from now on)

This directory is local state (gitignored). Delete it once the diff has been reviewed.
EOF_PRIOR
  } >"$dst/MANIFEST.md"
  echo "  prior    $count core file(s) differ from the ${prev_version:-previous} baseline — copied to $(rel "$dst")/ before the refresh:"
  printf '%s' "$drifted" | sed 's/^\([a-z]*\) \(.*\)$/             \2 (\1)/'
  echo "           re-apply from $(rel "$dst")/installed/ (MANIFEST.md + SHA256SUMS inside)"
}

capture_prior() {
  # A pre-0.7.0 install has commands but no baseline, so /upstream drift cannot tell which
  # generic files the project edited. Snapshot everything upstream-shaped exactly once,
  # before the first refresh overwrites it. With a baseline, capture only what drifted.
  [ -d "$CLAUDE_DIR/commands" ] || return 0
  if [ -d "$BASE" ]; then capture_drifted; return 0; fi
  local day dst d f prev_version
  day="$(date -u +%Y-%m-%d)"
  dst="$CLAUDE_DIR/.upstream-prior/$day"
  if [ -d "$dst" ]; then
    echo "  prior    .upstream-prior/$day/ already exists — not captured again"
    return 0
  fi
  mkdir -p "$dst"
  for d in commands agents scripts hooks; do
    [ -d "$CLAUDE_DIR/$d" ] || continue; cp -R "$CLAUDE_DIR/$d" "$dst/$d"
  done
  mkdir -p "$dst/docs"
  for f in "$HERE"/core/docs/*.md "$HERE"/core/docs/*.yaml "$HERE"/roles/*/docs/*.md; do
    [ -f "$f" ] || continue
    [ -f "$CLAUDE_DIR/$(basename "$f")" ] || continue; cp "$CLAUDE_DIR/$(basename "$f")" "$dst/docs/"
  done
  rmdir "$dst/docs" 2>/dev/null || true
  prev_version="$(sed -n 's/^version: *//p' "$CLAUDE_DIR/workflow-version.md" 2>/dev/null | head -1 || true)"
  (cd "$dst" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.md -print | sort | sha256_list >SHA256SUMS)
  cat >"$dst/MANIFEST.md" <<EOF_PRIOR
# Pre-install capture — $day

Taken by install.sh before the first install that records an upstream baseline.
Previously installed workflow version: ${prev_version:-unknown}. Files: $(grep -c . "$dst/SHA256SUMS").

- Verify:  (cd .claude/.upstream-prior/$day && shasum -a 256 -c SHA256SUMS)
- Diff:    diff -r .claude/.upstream-prior/$day/commands .claude/commands
- Restore one file: cp .claude/.upstream-prior/$day/commands/<name>.md .claude/commands/
- Carry an edit upstream: /upstream (drift against .claude/.upstream-base/ from now on)

This directory is local state (gitignored). Delete it once the diff has been reviewed.
EOF_PRIOR
  echo "  prior    captured $(grep -c . "$dst/SHA256SUMS") files to $(rel "$dst")/ (MANIFEST.md + SHA256SUMS)"
  echo "           compare: diff -r $(rel "$dst")/commands .claude/commands"
}

# ---------------------------------------------------------------- copy / seed
copy_core() { # always refresh — upstream-owned; mirrored into the baseline in the same step
  local src="$1" dst="$2" top="$3"
  mkdir -p "$(dirname "$dst")" "$BASE/$top"
  cp "$src" "$dst"
  cp "$src" "$BASE/$top/$(basename "$dst")"
  updated=$((updated + 1))
}

install_tree() { # $1 = $HERE/core or $HERE/roles/<name>
  local s="$1" f
  for f in "$s"/commands/*.md; do [ -f "$f" ] || continue; copy_core "$f" "$CLAUDE_DIR/commands/$(basename "$f")" commands; done
  for f in "$s"/agents/*.md;   do [ -f "$f" ] || continue; copy_core "$f" "$CLAUDE_DIR/agents/$(basename "$f")"   agents;   done
  for f in "$s"/scripts/*;     do [ -f "$f" ] || continue; copy_core "$f" "$CLAUDE_DIR/scripts/$(basename "$f")"  scripts;  done
  # System docs land at .claude/ root — commands reference them by these exact paths
  for f in "$s"/docs/*.md "$s"/docs/*.yaml; do [ -f "$f" ] || continue; copy_core "$f" "$CLAUDE_DIR/$(basename "$f")" docs; done
  if [ -f "$s/learn-targets.yaml" ]; then
    copy_core "$s/learn-targets.yaml" "$CLAUDE_DIR/learn-targets/$(basename "$s").yaml" learn-targets
  fi
}

seed() { # copy only if missing — these become project-owned
  local src="$1" dst="$2"
  if [ -f "$dst" ]; then
    skipped=$((skipped + 1))
    last_seed=skipped
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    seeded=$((seeded + 1))
    last_seed=seeded
    echo "  seeded  $(rel "$dst")"
  fi
}

seed_repo_files() {
  # The three files the commands depend on most — required for fast specialization.
  seed "$HERE/templates/repo/codebase-patterns.md" "$CLAUDE_DIR/codebase-patterns.md"
  seed "$HERE/templates/repo/testing-patterns.md"  "$CLAUDE_DIR/testing-patterns.md"
  seed "$HERE/templates/repo/ticket-checklist.md"  "$CLAUDE_DIR/ticket-checklist.md"
  # Optional — /pr falls back to a host default if absent, but seeding it helps.
  seed "$HERE/templates/repo/pr-template.md"       "$CLAUDE_DIR/pr-template.md"
  # Minimal CLAUDE.md skeleton — every command loads it first; /init can replace it.
  seed "$HERE/templates/repo/CLAUDE.template.md"   "$TARGET/CLAUDE.md"
  # Runtime dirs the commands and hooks write state into (gitignored below).
  mkdir -p "$CLAUDE_DIR/tickets" "$CLAUDE_DIR/state" "$CLAUDE_DIR/debug" "$CLAUDE_DIR/qa" \
           "$CLAUDE_DIR/builds" "$CLAUDE_DIR/refactors" "$CLAUDE_DIR/metrics" \
           "$CLAUDE_DIR/screenshots" "$CLAUDE_DIR/e2e" "$CLAUDE_DIR/demos"
  # State index — /status, /clarify and the analytics scripts read it; the
  # PostToolUse hook upserts into it. Same shape state-index-upsert.sh self-inits.
  [ -f "$CLAUDE_DIR/state/index.json" ] || printf '{"version":2,"generated":"","entries":[]}\n' > "$CLAUDE_DIR/state/index.json"
}

seed_role_repo_files() { # roles/<r>/templates/repo/* -> .claude/<basename>, never overwritten
  local r f
  for r in $ROLES; do
    for f in "$HERE/roles/$r"/templates/repo/*; do
      [ -f "$f" ] || continue; seed "$f" "$CLAUDE_DIR/$(basename "$f")"
    done
  done
}

# ---------------------------------------------------------------- settings fragments
fragment_already_wired() { # true when every script a fragment references appears in settings.json
  local frag="$1" tok found=0
  for tok in $(grep -oE '[A-Za-z0-9_-]+\.(sh|py)' "$frag" | sort -u); do
    found=1
    grep -qF "$tok" "$CLAUDE_DIR/settings.json" || return 1
  done
  [ "$found" = 1 ]
}

print_fragment_instruction() {
  local frag="$1" why="$2"
  echo "  fragment $(src "$frag") NOT merged ($why)."
  echo "           settings.json is project-owned, so install.sh never rewrites it. Open the fragment,"
  echo "           copy each entry under \"hooks\" into the same event array in .claude/settings.json and"
  echo "           add its \"permissions.allow\" entries to yours. Re-running install.sh prints this until"
  echo "           the scripts the fragment references appear in settings.json."
}

merge_settings_fragment() { # deep-merge one role fragment into a settings.json seeded in THIS run
  local frag="$1" settings="$CLAUDE_DIR/settings.json" tmp
  if ! command -v jq >/dev/null 2>&1; then
    print_fragment_instruction "$frag" "jq not found"
    return 0
  fi
  tmp="$(mktemp)"
  if jq -s '
    def dedupe: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
    def merge_hooks($a; $b):
      ($a // {}) as $a | ($b // {}) as $b
      | ([$a, $b] | map(keys[]) | unique) as $ks
      | reduce $ks[] as $k ({}; .[$k] = (($a[$k] // []) + ($b[$k] // [])));
    .[0] as $base | .[1] as $frag
    | ($base * $frag)
    | (if ($base.permissions.allow // $frag.permissions.allow) != null
       then .permissions.allow = ((($base.permissions.allow // []) + ($frag.permissions.allow // [])) | dedupe)
       else . end)
    | (if ($base.hooks // $frag.hooks) != null
       then .hooks = merge_hooks($base.hooks; $frag.hooks)
       else . end)
  ' "$settings" "$frag" >"$tmp"; then
    mv "$tmp" "$settings"
    echo "  merged  $(src "$frag") -> settings.json"
  else
    rm -f "$tmp"
    print_fragment_instruction "$frag" "jq merge failed"
  fi
}

seed_workspace_files() {
  seed "$HERE/templates/workspace/settings.template.json" "$CLAUDE_DIR/settings.json"
  local settings_state="$last_seed" r f
  seed "$HERE/templates/workspace/repo-profiles/_schema.yaml" "$CLAUDE_DIR/repo-profiles/_schema.yaml"
  seed "$HERE/templates/workspace/repo-profiles/README.md"    "$CLAUDE_DIR/repo-profiles/README.md"
  # Denylist + aliases for /upstream (gitignored; fill before the first harvest)
  seed "$HERE/templates/workspace/upstream.template.json"      "$CLAUDE_DIR/upstream.json"
  for r in $ROLES; do
    for f in "$HERE/roles/$r"/templates/workspace/*; do
      [ -f "$f" ] || continue
      case "$f" in
        *.fragment.json)
          if [ "$settings_state" = seeded ]; then merge_settings_fragment "$f"
          elif fragment_already_wired "$f"; then :
          else print_fragment_instruction "$f" "settings.json already existed"
          fi ;;
        *) seed "$f" "$CLAUDE_DIR/$(basename "$f")" ;;
      esac
    done
  done
}

# ---------------------------------------------------------------- archive / manifests
archive_one() { # $1 = basename in commands/, $2 = reason
  local b="$1" dst
  mkdir -p "$CLAUDE_DIR/_archived-commands"
  dst="$CLAUDE_DIR/_archived-commands/$b"
  [ -e "$dst" ] && dst="$dst.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$CLAUDE_DIR/commands/$b" "$dst"
  echo "  archived commands/$b -> $(rel "$dst") ($2)"
}

archive_removed_roles() { # /bootstrap PRUNE semantics: archive, never rm
  local r f b
  for r in $(available_roles); do
    case " $(printf '%s ' $ROLES)" in *" $r "*) continue ;; esac
    for f in "$HERE/roles/$r"/commands/*.md; do
      [ -f "$f" ] || continue
      b="$(basename "$f")"
      [ -f "$CLAUDE_DIR/commands/$b" ] || continue
      shipped_command "$b" && continue
      archive_one "$b" "role '$r' not selected"
    done
    if [ -f "$CLAUDE_DIR/learn-targets/$r.yaml" ]; then
      mkdir -p "$CLAUDE_DIR/_archived-commands/learn-targets"
      mv "$CLAUDE_DIR/learn-targets/$r.yaml" "$CLAUDE_DIR/_archived-commands/learn-targets/$r.yaml"
      echo "  archived learn-targets/$r.yaml -> .claude/_archived-commands/learn-targets/ (role '$r' not selected)"
    fi
  done
  # Commands the previous baseline shipped that no source ships any more (retired upstream).
  # Only an unmodified copy is archived; a locally edited one is left for the owner to judge.
  local line sha b2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha="${line%% *}"; b2="${line##* }"
    [ -f "$CLAUDE_DIR/commands/$b2" ] || continue
    shipped_command "$b2" && continue
    if [ "$(printf '%s\n' "$CLAUDE_DIR/commands/$b2" | sha256_list | cut -d' ' -f1)" = "$sha" ]; then
      archive_one "$b2" "retired upstream in $VERSION"
    else
      echo "  kept     commands/$b2 — retired upstream in $VERSION but locally modified; review and archive by hand"
    fi
  done <<EOF_PREV
$PREV_BASE_COMMANDS
EOF_PREV
}

write_manifests() {
  local commit remote roles_json="" r
  for r in $ROLES; do roles_json="${roles_json:+$roles_json, }\"$r\""; done
  roles_json="[$roles_json]"
  commit="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  remote="$(git -C "$HERE" remote get-url origin 2>/dev/null || echo unknown)"
  # Tracked with .claude/ — a fresh clone of a team-shared workspace remembers its roles.
  printf '{\n  "schema": 1,\n  "workflow_version": "%s",\n  "roles": %s\n}\n' "$VERSION" "$roles_json" >"$MANIFEST"
  # Machine-local provenance for /upstream (gitignored; rewritten every run).
  cat >"$CLAUDE_DIR/.upstream-manifest.json" <<EOF_MANIFEST
{
  "version": "$VERSION",
  "source_commit": "$commit",
  "upstream_repo": "$remote",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "roles": $roles_json
}
EOF_MANIFEST
  echo "  baseline $(basename "$BASE")/ + .upstream-manifest.json (version $VERSION, $commit) | workflow-manifest.json roles $roles_json"
}

# ---------------------------------------------------------------- seed packs
# Convention: templates/seed-packs/README.md "The append convention". Each unit (one pack file
# -> one target) is appended at most once; the H2 / DoD marker already present means skip.
ensure_trailing_newline() { # $1 = file; a pack appended after an unterminated last line must not glue to it
  [ -s "$1" ] || return 0
  [ "$(tail -c 1 "$1" | od -An -c | tr -d ' \n')" = '\n' ] || printf '\n' >>"$1"
}

pack_has_files() { # $1 = pack dir; true if it ships at least one unit
  local f
  for f in "$1"/*.seed.md "$1"/ticket-checklist.dod.md; do [ -f "$f" ] && return 0; done
  return 1
}

apply_pack_unit() { # $1 = flavor (dir under templates/seed-packs/); appends its files per the convention
  local flavor="$1" dir="$HERE/templates/seed-packs/$1" f name target h2 marker n=0 today
  today="$(date -u +%Y-%m-%d)"
  h2="## Seed pack: $flavor"
  # 1-3. pattern files: <!-- seed-pack: <flavor> YYYY-MM-DD --> immediately before "## Seed pack: <flavor>"
  for f in "$dir"/*.seed.md; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    name="$(basename "$f" .seed.md)"
    target="$CLAUDE_DIR/$name.md"
    if [ ! -f "$target" ]; then
      echo "  seed-pack $flavor: $name.md is not present in .claude/ — entry skipped"
      continue
    fi
    if grep -qxF "$h2" "$target"; then
      echo "  seed-pack $flavor already in $name.md — already present, left as is"
      continue
    fi
    ensure_trailing_newline "$target"
    { printf '\n<!-- seed-pack: %s %s -->\n%s\n\n' "$flavor" "$today" "$h2"; cat "$f"; printf '\n'; } >>"$target"
    echo "  seed-pack $flavor -> $name.md"
  done
  # 4. DoD lines: appended at the END of ticket-checklist.md behind one marker (the idempotency check)
  f="$dir/ticket-checklist.dod.md"
  if [ -f "$f" ]; then
    n=$((n + 1))
    target="$CLAUDE_DIR/ticket-checklist.md"
    marker="<!-- seed-pack: $flavor DoD -->"
    if [ ! -f "$target" ]; then
      echo "  seed-pack $flavor: ticket-checklist.md is not present in .claude/ — DoD lines skipped"
    elif grep -qxF "$marker" "$target"; then
      echo "  seed-pack $flavor DoD already in ticket-checklist.md — already present, left as is"
    else
      ensure_trailing_newline "$target"
      { printf '%s\n' "$marker"; cat "$f"; } >>"$target"
      ensure_trailing_newline "$target"
      echo "  seed-pack $flavor DoD -> ticket-checklist.md"
    fi
  fi
  [ "$n" = 0 ] && echo "  no seed pack $flavor (no *.seed.md / ticket-checklist.dod.md under templates/seed-packs/$flavor/) — skipped"
  return 0
}

apply_seed_pack() { # --stack <flavor>[/<sub>]: resolve composition, then append each unit once
  local flavor="$1" dir="$HERE/templates/seed-packs/$1" parent
  case "$flavor" in
    *[!A-Za-z0-9_/.-]*|/*|*/|*..*|'') echo "  no seed pack '$flavor' (not a valid pack name) — skipped"; return 0 ;;
  esac
  if [ ! -d "$dir" ]; then
    echo "  no seed pack $flavor (templates/seed-packs/$flavor/ not in this checkout) — skipped"
    return 0
  fi
  case "$flavor" in
    fullstack-monorepo) # composes: frontend-web, then backend-api, then its own entries
      apply_pack_unit frontend-web
      apply_pack_unit backend-api ;;
    */*) # a sub-pack lands AFTER its flavor pack, so the flavor pack goes first (idempotent)
      parent="${flavor%/*}"
      if pack_has_files "$HERE/templates/seed-packs/$parent"; then apply_pack_unit "$parent"; fi ;;
  esac
  apply_pack_unit "$flavor"
  return 0
}

# ---------------------------------------------------------------- gitignore
IGNORE_LINES=".claude/state/
.claude/tickets/
.claude/debug/
.claude/qa/
.claude/builds/
.claude/refactors/
.claude/metrics/
.claude/screenshots/
.claude/e2e/
.claude/demos/
.claude/upstream/
.claude/.upstream-base/
.claude/.upstream-prior/
.claude/.upstream-manifest.json
.claude/upstream.json
.claude/settings.local.json"

append_gitignore() {
  local gi="$TARGET/.gitignore"
  local marker="# --- claude-workflow local state ---"
  local added=0 line
  if [ ! -f "$gi" ] || ! grep -qF "$marker" "$gi"; then
    { echo ""; echo "$marker"; printf '%s\n' "$IGNORE_LINES"; } >>"$gi"
    echo "  updated .gitignore (local-state exclusions)"
    return
  fi
  # Marker exists (an earlier install) — line-idempotent upgrade: append any
  # NEW exclusion lines a newer version introduced, never duplicate old ones.
  while IFS= read -r line; do
    grep -qxF "$line" "$gi" || { printf '%s\n' "$line" >>"$gi"; added=1; }
  done <<EOF_LINES
$IGNORE_LINES
EOF_LINES
  if [ "$added" = 1 ]; then echo "  updated .gitignore (new local-state exclusions)"; fi
}

# ================================================================ main
echo "Installing claude-workflow $VERSION into $TARGET"
echo "  roles    $ROLES_CSV ($ROLE_SOURCE)"

check_collisions

if [ "$MODE" = repo-only ]; then
  seed_repo_files
  seed_role_repo_files
  append_gitignore
else
  capture_prior
  PREV_BASE_COMMANDS=""
  if [ -d "$BASE/commands" ]; then
    PREV_BASE_COMMANDS="$(cd "$BASE/commands" && find . -maxdepth 1 -type f -name '*.md' -print | sort | sha256_list | sed 's|  \./|  |' || true)"
  fi
  # 1. Core, then each role — commands, agents, scripts, docs refreshed on every run;
  #    every file mirrored into .upstream-base/ so /upstream drift sees the merged set.
  rm -rf "$BASE"
  for s in $(selected_sources); do install_tree "$s"; done
  chmod +x "$CLAUDE_DIR/scripts/"*.sh 2>/dev/null || true
  # 2. Commands no selected source ships any more move aside (never deleted).
  archive_removed_roles
  # 3. Role record (tracked) + upstream provenance (local).
  write_manifests
  # 4. Workspace seeds — project-owned after first copy; role fragments merge only into a
  #    settings.json created in this run.
  seed_workspace_files
  # 5. Per-repo seeds + runtime dirs
  seed_repo_files
  seed_role_repo_files
  append_gitignore
  # 6. Stack seed packs (opt-in, appended once)
  for s in $(printf '%s' "$STACKS" | normalize_roles); do apply_seed_pack "$s"; done
fi

echo ""
echo "Done. roles: $ROLES_CSV | core updated: $updated | seeded: $seeded | left untouched (already yours): $skipped"
echo ""

if grep -q '{placeholder}\|{One paragraph' "$TARGET/CLAUDE.md" 2>/dev/null; then
  echo "!! CLAUDE.md is the seeded skeleton — fill the {placeholders} or run /init"
  echo "   and merge. Every command loads it first; it's the highest-leverage file."
  echo ""
fi

[ "$MODE" = repo-only ] && exit 0

cat <<'CHECKLIST'
Next steps to specialize this project (fastest path first):
  1. Open .claude/settings.json — check the permission list matches your tooling.
     Installing into a SINGLE repo (no multi-repo workspace)? Change the seeded
     env value to "WORKFLOW_LAYOUT": "single-repo" so the branch guard treats
     this root as a product repo.
  2. Create .claude/repo-profiles/<repo>.yaml by copying _schema.yaml and filling
     base_branch + ci_command (tracker + transition ids, dev server as you learn them).
     Every other command reads it; tracker_system: none is a first-class mode.
     (/project-context maps cross-repo dependencies; it does not write profiles.)
  3. Skim .claude/codebase-patterns.md, testing-patterns.md, ticket-checklist.md —
     each has EXAMPLE entries showing the format. Replace with 2-3 real patterns
     from this codebase now, or just delete the examples and let /learn grow them
     after your first completed tickets.
     Cold start on a repo with history: run .claude/scripts/mine-history.sh, then
     /learn --mine — it lands only the patterns that occurred in 2+ merged PRs (dev).
  4. Start here, by role (the roles line above says which you have; change with
     ./install.sh <target> --role dev --role sdet):
       dev   /ticket (or /build without a tracker) -> /pr -> /learn
       sdet  /cover -> /pr -> /learn
     Everything else (/clarify, /verify, /qa, /ci-check, /triage, ...) is listed in
     .claude/commands/README.md. Each step is run on its own — nothing auto-chains.
     /learn after each ticket is what makes the system project-specific over time.
  5. Confidential project? Fill .claude/upstream.json once (denylist, domains, repo
     aliases, your PRIVATE inbox repo, personal git identity), then run /upstream
     monthly: it harvests the GENERIC learnings into a redacted, provenance-free
     bundle and files it as an issue in your private inbox. /upstream --intake on
     your own machine turns a month of bundles into one PR on the public repo.
  6. Run /bootstrap once: it probes this project and proposes which installed
     commands to keep or archive (nothing is deleted). When a newer release is
     out, /update shows what changed since your version and re-installs with
     your local edits kept.
CHECKLIST
