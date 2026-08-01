---
name: bootstrap
version: 0.6.0
description: Set up a portable .claude command system in any project, OR manage the workflow version when run with --bump.
argument-hint: "[project description] | --bump [minor|patch] | --check | --root <path> | --flavor <name>"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - AskUserQuestion
  - EnterPlanMode
---

<objective>
Two modes:

**Setup mode** (default): Bootstrap a complete .claude command system for a project or workspace. Investigates the codebase, then creates everything needed for the slash-command workflow. Drop this single file into any project's `.claude/commands/` directory and run `/bootstrap`.

**Release-manager mode** (`--bump` or `--check`): Maintain `<WORKSPACE_ROOT>/.claude/workflow-version.md`. Bump versions across commands, write changelog entries, detect drift.

This file is portable. Every path is derived from `WORKSPACE_ROOT` (resolved in step 0). Nothing is hardcoded — drop it into any workspace and it works.
</objective>

## The two installers (who does what)

- **`install.sh`** (repo root of claude-workflow) — the file copier and the canonical FIRST step: clone the repo, run it, get core files refreshed + project-owned seeds + runtime dirs + `state/index.json`. Re-running it is the update mechanism (`git pull` + re-run).
- **`/bootstrap`** (this command) — the adapter and release manager, run AFTER `install.sh`: probes capabilities (§3i), prunes gate-false commands to `_archived-commands/`, writes `capability-manifest.md`, and owns versioning (`--bump` / `--check`).
- **Self-sufficient fallback** — dropped into a project as a single file with no repo clone, `/bootstrap` can still generate a minimal system from its inlined specs. That is the fallback path, not the primary one.

## Canonical inventory (single source of truth)

The tables below define what a complete install at the current workflow version looks like (`workflow-version.md` is the version authority). Both fresh-install and upgrade flows read from here. To change what bootstrap installs, edit these tables — nothing else. The `### Commands` table is **capability-gated** (the Gate column is a capability expression evaluated against the §3i probe), so the same canonical inventory yields a different installed set per project — and prunes commands whose gate goes false (§4).

### Commands (capability-gated — this table IS the capability→command matrix)

Tiers are install priority; the **Gate** column is the capability expression that must hold for the command to be installed AND, on re-run, KEPT. When a gate that was true becomes false, the command is **pruned to `_archived-commands/`** (§4), never deleted. Capabilities come from the §3i probe and are recorded in `capability-manifest.md` (§7.5). `always` = stack/host-agnostic — installed everywhere. Reconcile this table with the real command set on every `--bump`; a row with no matching `commands/*.md` (or vice-versa) is drift the `--check` flow must flag.

| Command | Tier | Since | Gate (install/keep if…) |
|---|---|---|---|
| `bootstrap` | core | 0.1.0 | always |
| `verify` | core | 0.1.0 | always (stack-agnostic AC verification) |
| `build` | core | 0.1.0 | always (ad-hoc dev needs no ticket) |
| `project-debug` | core | 0.1.0 | always (debugging is universal) |
| `resume-ticket` | core | 0.1.0 | always (state-resume is universal) |
| `refactor` | core | 0.1.0 | always (every project gets pattern files) |
| `learn` | core | 0.1.0 | always (learns from conversation even without a ticket system) |
| `clarify` | core | 0.1.0 | `ticket_system != none` |
| `ticket` | core | 0.1.0 | `ticket_system != none` |
| `pr` | core | 0.1.0 | `vcs_host != none` |
| `review-pr` | recommended | 0.1.1 | `vcs_host != none` |
| `review-comments` | recommended | 0.1.1 | `vcs_host != none` |
| `ci-check` | recommended | 0.1.1 | `vcs_host != none AND ci == yes` |
| `test-plan` | recommended | 0.6.0 | always (SDET lane: reads the ticket state file when present, pasted ACs otherwise) |
| `qa` | conditional | 0.1.0 | `ui_surfaces != none` |
| `ui-fidelity` | conditional | 0.4.0 | `ui_surfaces != none` |
| `screenshot` | conditional | 0.1.1 | `ui_surfaces != none AND (e2e == playwright OR dev_server present)` |
| `project-context` | multi-repo | 0.2.0 | `repo_count >= 2` |
| `status` | multi-repo | 0.2.0 | `repo_count >= 2 OR ticket_system != none` |
| `demo-summary` | optional | 0.4.0 | `ticket_system != none AND team == true` (install only when there's a demo audience) |
| `memory-lint` | optional | 0.4.0 | `memory_system == yes` (the host assistant exposes a persistent-memory directory — e.g. Claude Code auto-memory; probe for it, never assume) |

**Archived designs (NOT shipped):** `/do`, `/queue`, `/retro`, `/docs`, `/e2e` were pruned from the shipped set in 0.5.0; their designs live in `command-proposals.md` and the original deployment's `_archived-commands/`. Reintroducing one requires BOTH a row here AND a shipped `commands/*.md` — a row without a file (or a file without a row) is drift the `--check` flow must flag.

### Structural files (relative to WORKSPACE_ROOT)

| Path | Since | Required |
|---|---|---|
| `.claude/workflow-version.md` | 0.1.0 | yes |
| `.claude/codebase-patterns.md` | 0.1.0 | yes |
| `.claude/testing-patterns.md` | 0.1.0 | yes |
| `.claude/ticket-checklist.md` | 0.1.0 | yes |
| `.claude/pr-template.md` | 0.1.0 | yes |
| `.claude/state-file-schema.md` | 0.1.1 | yes |
| `.claude/command-proposals.md` | 0.2.0 | auto-created by `/learn` on first proposal — never seeded |
| `.claude/capability-manifest.md` | 0.4.0 | yes — written by `/bootstrap` §7.5 (capability vector + per-command install/prune decision + reason) |
| `.claude/state/index.json` | 0.1.1 | yes — initialized by `install.sh`; `state-index-upsert.sh` also self-inits |
| `CLAUDE.md` (project root) | 0.6.0 | yes — seeded as a skeleton by `install.sh`; `/init` can replace it |
| `.claude/scripts/state-index-upsert.sh` | 0.1.1 | yes |
| `.claude/scripts/state-index-scan.sh` | 0.1.1 | yes |
| `.claude/scripts/guard-base-branch.sh` | 0.5.0 | yes (PreToolUse branch guard — layout-aware, profile-driven base branches) |
| `.claude/scripts/audit_metrics.py` | 0.2.0 | yes (self-learning measurement) |
| `.claude/scripts/run_audit.sh` | 0.2.0 | optional (launchd wrapper; only if tier ≥ recommended AND user opts in) |
| `.claude/repo-profiles/_schema.yaml` | 0.1.1 | yes — single home for base branch, tracker (`tracker_system`, `jira_transition_*`), CI commands, UI surface |
| `.claude/agents/codebase-investigator.md` | 0.1.1 | yes |
| `.claude/agents/verifier.md` | 0.1.0 | yes |
| `.claude/agents/commit-drafter.md` | 0.5.0 | when `vcs_host != none` |
| `.claude/agents/pr-branch-reviewer.md` | 0.5.0 | when `vcs_host != none` |
| `.claude/agents/jira-context-loader.md` | 0.1.1 | when ticket system = jira |
| `.claude/agents/contract-verifier.md` | 0.5.0 | when an API spec source exists (swagger/OpenAPI files) |
| `.claude/agents/ui-fidelity.md` | 0.5.0 | when `ui_surfaces != none` |

### State directories

`tickets/`, `state/`, `debug/`, `qa/`, `builds/`, `refactors/`, `metrics/`, `screenshots/`, `e2e/`, `demos/` under `.claude/` — created empty by `install.sh` (all gitignored). `metrics/` accumulates one JSON snapshot per `audit_metrics.py` run; the directory listing IS the trend history.

---

## 0. Resolve WORKSPACE_ROOT (always run first)

Both modes start here. Resolve once, use everywhere.

```bash
resolve_workspace_root() {
  # 1. --root <path> arg wins
  while [ $# -gt 0 ]; do
    if [ "$1" = "--root" ]; then echo "$2"; return; fi
    shift
  done
  # 2. Walk up from CWD looking for an existing .claude/commands/ ancestor
  d=$(pwd)
  while [ "$d" != "/" ]; do
    if [ -d "$d/.claude/commands" ]; then echo "$d"; return; fi
    d=$(dirname "$d")
  done
  # 3. Fallback: CWD (fresh install)
  pwd
}

WORKSPACE_ROOT=$(resolve_workspace_root "$@")
echo "WORKSPACE_ROOT=$WORKSPACE_ROOT"
```

Use `$WORKSPACE_ROOT` exclusively. Never hardcode a user-specific path. Never write `/Users/...` or `/home/...` literals into generated files.

Also extract the bootstrap version from this file's own frontmatter — that's the **target** version the workspace will be brought up to:

```bash
TARGET_VERSION=$(awk '/^version:/{print $2; exit}' "$WORKSPACE_ROOT/.claude/commands/bootstrap.md")
echo "TARGET_VERSION=$TARGET_VERSION"
```

---

<release-manager-mode>

## If $ARGUMENTS starts with `--bump` or `--check`

Workflow-version stays consistent across the command set. `<WORKSPACE_ROOT>/.claude/workflow-version.md` is the source of truth; every command's frontmatter `version:` should match it.

### `--check` — verify consistency

```bash
WORKFLOW_VERSION=$(awk '/^version:/{print $2; exit}' "$WORKSPACE_ROOT/.claude/workflow-version.md")
echo "Workflow version: $WORKFLOW_VERSION"
echo ""
echo "Drift check:"
for f in "$WORKSPACE_ROOT"/.claude/commands/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  cmd_ver=$(awk '/^version:/{print $2; exit}' "$f")
  if [ "$cmd_ver" != "$WORKFLOW_VERSION" ]; then
    echo "  DRIFT  $(basename "$f" .md)  has $cmd_ver (expected $WORKFLOW_VERSION)"
  fi
done
```

Also compute each command's content hash and diff against the hash ledger in `workflow-version.md` (see **Hash ledger** below). Any command whose hash changed since the last bump is a candidate for the next changelog entry.

### `--bump minor` — adds/deletes/reshapes commands

Use when you've added, deleted, or reshaped a command's interface.

### `--bump patch` — refinements only

Use when you've polished existing commands without changing the surface.

### Bump procedure (both flavors)

1. Read current version from `$WORKSPACE_ROOT/.claude/workflow-version.md` frontmatter.
2. Compute new version (`patch` = Z+1, `minor` = Y+1 & Z=0).
3. Collect changed commands by diffing current hashes against the ledger; ask the user for a one-line summary of each (auto-draft from `git log` if the workflow is in git).
4. Propagate to every command's frontmatter:
   ```bash
   NEW_VERSION={X.Y.Z}
   for f in "$WORKSPACE_ROOT"/.claude/commands/*.md; do
     [ "$(basename "$f")" = "README.md" ] && continue
     # macOS sed needs '' after -i; GNU sed does not. Detect:
     if sed --version 2>/dev/null | grep -q GNU; then
       sed -i -E "s/^version: .*/version: $NEW_VERSION/" "$f"
     else
       sed -i '' -E "s/^version: .*/version: $NEW_VERSION/" "$f"
     fi
   done
   ```
5. Update `$WORKSPACE_ROOT/.claude/workflow-version.md`:
   - Bump `version:` and `last-updated:` in frontmatter.
   - Prepend a new changelog entry under `## Changelog`.
   - Regenerate the "Command inventory at this version" table.
   - Refresh the hash ledger.
6. Show the diff and ask "apply?" Only write on approval.

### Hash ledger format

```markdown
## Hash Ledger (auto-managed — do not edit by hand)

Generated YYYY-MM-DD at version X.Y.Z.
<!-- Format: filename SHA256 first-8-chars -->

- bootstrap.md        3f9a7b2c
- build.md            8c1e5d4a
```

Recompute with:
```bash
for f in "$WORKSPACE_ROOT"/.claude/commands/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  echo "- $(basename "$f")  $(shasum -a 256 "$f" | cut -c1-8)"
done
```

### Changelog format (enforced)

```markdown
### X.Y.Z — YYYY-MM-DD
**Refinements:**
- `/clarify` — {one-line summary}
- `/verify` — {one-line summary}
```

For minor bumps use `**Additions:**`, `**Deletions:**`, `**Merges:**`, `**Enhancements:**` subheadings.

After `--bump`:
```
✓ Bumped workflow to {NEW_VERSION}
✓ Updated N command frontmatters
✓ Appended changelog entry
✓ Refreshed hash ledger
```

**Stop here. Do NOT continue into Setup mode when `--bump` or `--check` was the argument.**

</release-manager-mode>

---

## Setup mode (default)

<process>

## 1. Detect existing setup → choose flow

```bash
echo "=== Existing setup ==="
for f in "$WORKSPACE_ROOT"/CLAUDE.md \
         "$WORKSPACE_ROOT"/.claude/workflow-version.md \
         "$WORKSPACE_ROOT"/.claude/state-file-schema.md \
         "$WORKSPACE_ROOT"/.claude/state/index.json; do
  [ -f "$f" ] && echo "EXISTS  ${f#$WORKSPACE_ROOT/}" || echo "MISSING ${f#$WORKSPACE_ROOT/}"
done

cmd_count=$(ls "$WORKSPACE_ROOT"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
agent_count=$(ls "$WORKSPACE_ROOT"/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
profile_count=$(ls "$WORKSPACE_ROOT"/.claude/repo-profiles/*.yaml 2>/dev/null | wc -l | tr -d ' ')
echo "Commands: $cmd_count  Agents: $agent_count  Repo profiles: $profile_count"

if [ -f "$WORKSPACE_ROOT/.claude/workflow-version.md" ]; then
  ACTUAL_VERSION=$(awk '/^version:/{print $2; exit}' "$WORKSPACE_ROOT/.claude/workflow-version.md")
else
  ACTUAL_VERSION="0.0.0"
fi
echo "Actual: $ACTUAL_VERSION  Target: $TARGET_VERSION"
```

Decide the flow from `ACTUAL_VERSION` vs `TARGET_VERSION` AND the file presence:

| Detected state | Flow |
|---|---|
| No `.claude/` dir at all | **Fresh install** — run all of Section 2 onward, no prompts about overwrites |
| `.claude/` exists, no `workflow-version.md`, < 5 files | **Sparse pre-version install** — treat as fresh install but ask before overwriting any file that exists |
| `.claude/` exists, no `workflow-version.md`, ≥ 5 files | **Legacy install (pre-versioning)** — files were placed by an older bootstrap or by hand. Run a discovery pass: list every existing file, hash it, classify as `matches-current-template` / `user-modified` / `unknown-origin`. Ask per category before touching. NEVER bulk-overwrite a legacy install. |
| `workflow-version.md` exists, `ACTUAL_VERSION == TARGET_VERSION` | **Health check** — run audit, report drift, exit without writes |
| `workflow-version.md` exists, `ACTUAL_VERSION < TARGET_VERSION` | **Upgrade** — see version-step migration below |
| `workflow-version.md` exists, `ACTUAL_VERSION > TARGET_VERSION` | **Mismatch** — your bootstrap.md is older than the workspace; refuse and ask user to update bootstrap.md or pass `--root` to a different workspace |

### Version-step migration (Upgrade flow)

When `ACTUAL_VERSION` is several versions behind `TARGET_VERSION` (e.g. 0.1.0 → 0.2.0), don't jump. Walk the inventory in version order:

```
for V in versions_between(ACTUAL_VERSION, TARGET_VERSION):
  install items where since == V AND missing
  apply migrations described in V's changelog entry (workflow-version.md)
  bump workflow-version.md to V
  print "✓ migrated to $V"
```

This guarantees a user 3 versions behind ends up in the same state as a user 1 version behind, regardless of when they last ran bootstrap.

Tell the user which flow you picked and what it implies. Do not proceed without their confirmation on **Upgrade**, **Legacy**, or **Mismatch** flows.

## 2. Resolve placement (workspace-root vs per-repo)

Ask the user, with three options:
1. **Workspace root** (default for multi-repo) — `.claude/` lives at `WORKSPACE_ROOT`, gitignored, personal setup covering many repos.
2. **Inside this repo** — `.claude/` lives in the current repo, tracked with git, shared with team.
3. **Auto-detect** — count git repos under WORKSPACE_ROOT; ≥2 → workspace root; 1 → inside repo.

Store the choice in `PLACEMENT_DIR` (the directory under which `.claude/` is created). All paths below are relative to `PLACEMENT_DIR`. The placement choice is recorded in `workflow-version.md` so subsequent upgrades respect it.

**Hard rule.** Commands live ONLY in `PLACEMENT_DIR/.claude/commands/`. If a sub-repo `.claude/commands/` directory already exists alongside a workspace-root `.claude/commands/`, that's drift — surface it and offer to delete after confirmation.

## 3. Investigate the project (fresh install + upgrade both)

Gather facts. Do not guess.

### 3a. Stack and package manager

```bash
ls "$PLACEMENT_DIR"/package.json "$PLACEMENT_DIR"/yarn.lock "$PLACEMENT_DIR"/pnpm-lock.yaml \
   "$PLACEMENT_DIR"/go.mod "$PLACEMENT_DIR"/Cargo.toml "$PLACEMENT_DIR"/build.gradle \
   "$PLACEMENT_DIR"/pom.xml "$PLACEMENT_DIR"/Gemfile "$PLACEMENT_DIR"/requirements.txt \
   "$PLACEMENT_DIR"/pyproject.toml 2>/dev/null
```

Detect: language, framework, package manager, monorepo or not.

### 3a.1 Stack flavor detection

Pick ONE flavor that drives template choices downstream. Detect from manifests + directory layout:

| Flavor | Signals (any match) |
|---|---|
| `frontend-web` | `package.json` with `react`/`vue`/`svelte`/`next`/`nuxt`/`angular` AND no backend manifest |
| `backend-api` | `go.mod` / `Cargo.toml` / `pom.xml` / `requirements.txt` (with Flask/FastAPI/Django) / `Gemfile` (Rails) AND no frontend manifest |
| `fullstack-monorepo` | Both a frontend signal AND a backend signal under WORKSPACE_ROOT (different repos or workspaces) |
| `cli-tool` | Single executable target, no HTTP framework, no UI framework. Detect: `bin/` dir, `cmd/<name>/main.go`, `[[bin]]` in Cargo.toml, `console_scripts` in pyproject.toml |
| `library` | Package metadata declares it's published (npm `private: false`, `[lib]` in Cargo.toml, `setup.py` with `packages=`). No app entry point. |

If multiple match, pick in this order: `fullstack-monorepo` > `frontend-web`/`backend-api` > `library`/`cli-tool`. Show the user what you picked and let them override.

Store as `STACK_FLAVOR`. The flavor gates these downstream choices:

| Surface | frontend-web | backend-api | fullstack-monorepo | cli-tool | library |
|---|---|---|---|---|---|
| Atomic-design language in `/clarify` | render | skip entirely | render only for FE-side investigations | skip | skip |
| Live URL/UI check in `/verify` | enable | skip | enable when diff touches FE | skip | skip |
| Contract smoke test in `/verify` | when calling API | enable | enable | skip | skip |
| Stack-flavored seed rules in `codebase-patterns.md` | FE rules below | BE rules below | both | CLI rules below | LIB rules below |
| `/verify` simplify-check checklist | FE checklist | BE checklist | both | CLI checklist | LIB checklist |
| `screenshot` install gate | yes if Playwright | no | yes if Playwright | no | no |

### Stack-flavored seed rules for `codebase-patterns.md`

Write 3–5 starter rules into `codebase-patterns.md` based on STACK_FLAVOR. These are placeholders to seed the file — `/learn` will replace and grow them with real lessons.

**frontend-web seed:**
- No hardcoded color hexes — use design tokens / CSS variables. _source: convention_
- Components don't fetch their own data; data lives in the route/page or a hook. _source: convention_
- New components ship with at least one render test. _source: convention_

**backend-api seed:**
- No string-concat SQL — parameterized queries only. _source: security_
- Every handler accepts `context.Context` (Go) / `Context` (equiv) and respects cancellation. _source: convention_
- Errors include the operation name; never bare `errors.New("failed")`. _source: convention_
- New endpoints update the OpenAPI spec in the same PR. _source: contract_
- DB transactions have explicit commit/rollback paths; no implicit rollback-on-defer-only. _source: correctness_

**fullstack-monorepo seed:** both `frontend-web` and `backend-api` rules, plus:
- API contract is the source of truth — TS types regenerate from OpenAPI, not the other way. _source: contract_
- New endpoints land with both backend handler test AND frontend contract test. _source: convention_

**cli-tool seed:**
- Errors print to stderr, results to stdout — never mixed. _source: convention_
- Every flag has a help string and a long-form (`--flag`) plus short (`-f`) when frequently typed. _source: convention_
- Exit codes are documented; non-zero on any non-success path. _source: convention_

**library seed:**
- Public API changes require a changelog entry and a semver bump. _source: contract_
- No process-level state; nothing that mutates global env, signal handlers, or stdout in import-time. _source: convention_
- Every public function has a doc comment with at least one usage example. _source: convention_

### Stack-flavored DoD additions for `ticket-checklist.md`

Append flavor-specific items to the Definition of Done:

- **frontend-web:** "No console errors on the changed routes (verified manually or via `/qa`)."
- **backend-api:** "OpenAPI spec updated for any new/changed endpoint." + "Migration tested against a fresh DB and an existing-data DB."
- **fullstack-monorepo:** both of the above.
- **cli-tool:** "Help output (`--help`) reflects the new flags and exit codes."
- **library:** "CHANGELOG entry written. Semver bump applied (patch/minor/major) per the change."

### Stack-flavored simplify checklist for `/verify` step 3.3

Render only the relevant column based on STACK_FLAVOR:

| Smell | frontend-web | backend-api | cli-tool | library |
|---|---|---|---|---|
| Unused imports / dead branches | ✓ | ✓ | ✓ | ✓ |
| Inline styles where tokens exist | ✓ | — | — | — |
| Native HTML where a component exists | ✓ | — | — | — |
| String-concat SQL | — | ✓ | — | — |
| Goroutine without ctx cancellation (Go) | — | ✓ | ✓ | ✓ |
| Missing transaction boundary on multi-write | — | ✓ | — | — |
| Bare `panic()` / unwrap in non-test code | — | ✓ | ✓ | ✓ |
| `console.log` / `fmt.Println` left in | ✓ | ✓ | — | — |
| Stdout pollution in library code | — | — | — | ✓ |
| Print to stdout when stderr is correct | — | — | ✓ | ✓ |

This makes `/verify` give a backend dev backend-shaped feedback, a frontend dev frontend-shaped feedback, and a fullstack dev both — without any manual configuration.

### 3b. Project structure

```bash
ls -d "$PLACEMENT_DIR"/*/ 2>/dev/null | \
  grep -vE 'node_modules|\.git|dist|build|\.next|__pycache__|target|vendor'
```

Identify: source dir, test dir, config files.

### 3c. Available scripts / commands

For each detected package manager, read the script list (e.g., `package.json scripts`, `Makefile` targets, `gradle tasks`). Find the EXACT command for: dev server, tests, lint, build, full CI. Do not guess `npm test` if the project uses `yarn test`.

### 3d. Test patterns

Open 2–3 existing test files. Note: framework, file naming, mock pattern, organization. If no tests exist, mark `testing-patterns.md` as a stub and warn the user it will grow via `/learn`.

### 3e. Git remote and host

```bash
git -C "$PLACEMENT_DIR" remote get-url origin 2>/dev/null
```

Map to host: `github.com` → GitHub, `gitlab.com` → GitLab, `dev.azure.com` → Azure DevOps, `bitbucket.org` → Bitbucket, anything else → manual.

### 3f. Ticket system

Probe in this order:
```bash
which gh && gh issue list --limit 1 >/dev/null 2>&1 && echo "TICKET_SYSTEM=github"
which jira && echo "TICKET_SYSTEM=jira"
which az && az boards -h >/dev/null 2>&1 && echo "TICKET_SYSTEM=ado"
which linear && echo "TICKET_SYSTEM=linear"
git -C "$PLACEMENT_DIR" log --oneline -20 2>/dev/null | \
  grep -oE '[A-Z]+-[0-9]+|#[0-9]+|AB#[0-9]+' | sort -u | head -3
```

Also check for an Atlassian MCP entry in `~/.claude/settings.json` or `.mcp.json` for Jira via MCP.

Store:
- `TICKET_SYSTEM`: `github` | `jira` | `ado` | `linear` | `manual`
- `TICKET_CLI`: exact fetch command (e.g. `gh issue view`, `jira issue view --plain`)
- `TICKET_ID_PATTERN`: regex from git log (e.g. `PROJ-[0-9]+`, `#[0-9]+`) — if none detected, default to `PROJ-[0-9]+` and tell the user.

### 3g. Multi-repo detection

```bash
repo_count=$(find "$WORKSPACE_ROOT" -maxdepth 2 -type d -name .git 2>/dev/null | wc -l | tr -d ' ')
echo "Repos under WORKSPACE_ROOT: $repo_count"
```

If `repo_count >= 2` and PLACEMENT_DIR = WORKSPACE_ROOT, multi-repo addons (project-context, status, retro) get installed and `repo-profiles/` gets seeded.

### 3h. Tooling presence (gates the recommended tier)

```bash
which gh >/dev/null 2>&1   && HAS_GH=1   || HAS_GH=0
grep -lE 'playwright|cypress' "$PLACEMENT_DIR"/package.json 2>/dev/null && HAS_E2E=1 || HAS_E2E=0
```

### 3i. Capability probe (assemble the project's capability vector)

Consolidate 3a–3h into ONE capability vector — this is exactly what the `### Commands` matrix gates on and what gets persisted to `capability-manifest.md` (§7.5). Probe autonomously; only ASK where a signal is genuinely ambiguous (that questioning IS the "gather the required info" step — don't guess silently).

```bash
# vcs_host — from the git remote + host CLI
host_url=$(git -C "$PLACEMENT_DIR" remote get-url origin 2>/dev/null)
case "$host_url" in
  *github.com*) VCS_HOST=github ;;
  *gitlab*|*gitea*|*bitbucket*) VCS_HOST=other-host ;;
  "") VCS_HOST=none ;;
  *) VCS_HOST=other-host ;;
esac

# ci — any CI config present
CI=no
for c in .github/workflows .gitlab-ci.yml azure-pipelines.yml .circleci Jenkinsfile; do
  [ -e "$PLACEMENT_DIR/$c" ] && CI=yes && break
done

# ticket_system — reuse 3f result: jira | ado | github-issues | linear | none
#   none/manual → /ticket and /clarify are PRUNED (project is /build-centric)

# wiki — Confluence (or other) referenced anywhere → gates /docs
WIKI=none
grep -rqiE 'atlassian\.net/wiki|confluence' "$PLACEMENT_DIR" 2>/dev/null && WIKI=confluence

# e2e — Playwright/Cypress in manifest OR an e2e.enabled repo-profile
E2E=none
grep -lqE 'playwright' "$PLACEMENT_DIR"/package.json 2>/dev/null && E2E=playwright
grep -lqE 'cypress'   "$PLACEMENT_DIR"/package.json 2>/dev/null && E2E=cypress

# ui_surfaces — does this project render UI, and which? Resolve from STACK_FLAVOR + file probes:
#   manifest.xml / Office.js → word-addin ; appsscript.json → gdocs-addin ; *.xcodeproj → ios ;
#   a frontend framework + dev server → web. none → backend/CLI/library (drop /qa /screenshot /ui-fidelity).
UI_SURFACES=none   # comma-list when present, e.g. "web" or "word-addin,web"

# repo_count — git repos under WORKSPACE_ROOT (gates the multi-repo tier)
REPO_COUNT=$(find "$WORKSPACE_ROOT" -maxdepth 2 -name .git 2>/dev/null | wc -l | tr -d ' ')

# memory_system — is the personal auto-memory dir wired? gates /memory-lint
MEMORY_SYSTEM=no
ls "$HOME"/.claude/projects/*/memory/MEMORY.md >/dev/null 2>&1 && MEMORY_SYSTEM=yes

# team vs solo — >1 distinct committer in recent history → gates /retro, /demo-summary
authors=$(git -C "$PLACEMENT_DIR" log --format='%ae' -200 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ "${authors:-1}" -gt 1 ] && TEAM=true || TEAM=false
```

Resolved vector (carried into §4 and §7.5):
```
{ vcs_host, ci, ticket_system, wiki, e2e, ui_surfaces[], repo_count, memory_system, team }
```
When a capability can't be resolved confidently (UI present but surface unclear, ticket system ambiguous, host unknown), ASK the user one targeted question per unknown rather than defaulting — a wrong default silently installs/prunes the wrong commands.

## 4. Compute the install plan

Evaluate each `### Commands` entry's **Gate** against the §3i capability vector, then decide one of FOUR actions:
- **Install** — gate TRUE AND (file missing OR `since-version > ACTUAL_VERSION`).
- **Skip** — gate TRUE AND file exists AND `since-version <= ACTUAL_VERSION` (already current).
- **Upgrade** — gate TRUE AND file exists AND content drifted from the inline template. Ask before overwriting a user-modified file.
- **Prune** — gate FALSE AND the command file EXISTS. It applied once (or an older generic bootstrap installed it) but no longer fits this project — e.g. `/qa` in a backend-only repo, `/memory-lint` with no auto-memory dir, `/demo-summary` on a solo project. **Move it to `<PLACEMENT_DIR>/.claude/_archived-commands/<cmd>.md` — NEVER `rm`** — and log the reason. This is the "se deshaga de comandos" behavior that makes the installed set match the project.

Build four lists: `WILL_INSTALL`, `WILL_UPGRADE`, `WILL_SKIP`, `WILL_PRUNE`. To keep re-runs quiet, diff the computed gates against the prior `capability-manifest.md` (§7.5) when present — only prune/install what actually FLIPPED since last run. **Never prune a `core` command whose gate is `always`.** Pruning always requires explicit approval in §5 (it's a removal, even though reversible from `_archived-commands/`).

## 5. Present the plan and wait for approval

Enter `EnterPlanMode` and present:

```
# Bootstrap plan: {project}
WORKSPACE_ROOT: {path}
PLACEMENT_DIR:  {path}
Flow: {fresh | upgrade {ACTUAL → TARGET} | health-check}

## Stack
Language:      {detected}
Framework:     {detected}
Pkg manager:   {detected}
Test runner:   {detected}

## Commands
Dev:    {command}
Test:   {command}
Lint:   {command}
Build:  {command}
CI:     {command}

## Ticket system
Platform: {github | jira | ado | linear | manual}
CLI:      {command}
ID regex: {pattern}

## Capabilities (probed — drives install/prune)
vcs_host: {github|other|none} · ci: {yes|no} · ticket_system: {…} · wiki: {confluence|none}
e2e: {playwright|cypress|none} · ui_surfaces: {web|word-addin|…|none} · repo_count: {N}
memory_system: {yes|no} · team: {true|false}

## Will install ({n})
- /ticket, /verify, /pr, /learn, ...
- .claude/codebase-patterns.md
- .claude/state-file-schema.md
...

## Will upgrade ({n})
- /clarify   (0.1.0 → 0.2.0; section "Atomic-design lens" added)
...

## Will skip ({n})
- /pr        (already at 0.2.0, no drift)
...

## Will prune ({n}) — gate now FALSE, archived not deleted
- /qa            (ui_surfaces=none — backend-only project) → _archived-commands/
- /memory-lint   (memory_system=no) → _archived-commands/
...

## What I will NOT touch
- Any file you have edited that drifts from the template (will ask per-file)
- Existing CLAUDE.md content (only adds missing sections)
- Existing pattern files (only appends, never replaces)

Proceed? (yes / show details / cancel)
```

Wait for `yes`. On `show details`, dump the planned diffs.

## 6. Create directories

```bash
mkdir -p "$PLACEMENT_DIR/.claude/commands" \
         "$PLACEMENT_DIR/.claude/agents" \
         "$PLACEMENT_DIR/.claude/scripts" \
         "$PLACEMENT_DIR/.claude/state" \
         "$PLACEMENT_DIR/.claude/tickets" \
         "$PLACEMENT_DIR/.claude/builds" \
         "$PLACEMENT_DIR/.claude/debug" \
         "$PLACEMENT_DIR/.claude/refactors" \
         "$PLACEMENT_DIR/.claude/e2e" \
         "$PLACEMENT_DIR/.claude/docs" \
         "$PLACEMENT_DIR/.claude/metrics"

# Multi-repo only
[ "$repo_count" -ge 2 ] && mkdir -p "$PLACEMENT_DIR/.claude/repo-profiles"
```

## 7. Write structural files

Use the inline templates in `<templates>` below. Substitute the captured variables (`PLACEMENT_DIR`, `TARGET_VERSION`, `TICKET_SYSTEM`, etc.) before writing.

For each file:
1. If missing → write template directly.
2. If exists and content matches the prior version's template (no user edits) → overwrite with current template.
3. If exists and user has edited it → show a diff and ask before overwriting. Default to "skip and add a TODO comment in the file pointing the user at the new template."

## 8. Write commands

For each entry in `WILL_INSTALL` of tier `core`/`recommended`/`multi-repo`/`optional`, generate `$PLACEMENT_DIR/.claude/commands/{cmd}.md` from the spec in `<command-specs>` below. Substitute:
- `{TICKET_CLI}`, `{TICKET_ID_PATTERN}`, `{TICKET_SYSTEM}`
- `{CI_COMMAND}`, `{TEST_COMMAND}`, `{LINT_COMMAND}`, `{BUILD_COMMAND}`
- `{PR_HOST}` (github.com / dev.azure.com / etc.)
- `{TARGET_VERSION}` in frontmatter
- `{PLACEMENT_DIR}` for any path that needs to be absolute

Each command's frontmatter `version:` field MUST equal `$TARGET_VERSION`.

## 8.5 Prune commands whose gate went false (archive, never delete)

For each entry in `WILL_PRUNE` (approved in §5), move the command out of the active set:

```bash
ARCH="$PLACEMENT_DIR/.claude/_archived-commands"
mkdir -p "$ARCH"
mv "$PLACEMENT_DIR/.claude/commands/$cmd.md" "$ARCH/$cmd.md"   # never rm — reversible
```

Record one line per prune in the manifest (§8.6) with the reason (`gate=<expr> → false because <capability>=<value>`). A later re-run whose probe flips the gate back to TRUE restores the command from `_archived-commands/` instead of regenerating it (preserves any local edits). Never prune a `core`/`always` command. If `_archived-commands/` ends up empty, remove it.

## 8.6 Write the capability manifest (the auditable map — Lockton's skill-manifest lesson)

Write `$PLACEMENT_DIR/.claude/capability-manifest.md` recording WHAT was detected and WHY each command is present or absent. This is what makes the adaptive decision auditable and re-runs diffable; downstream commands and the next bootstrap read it instead of re-deriving from scratch.

```markdown
# Capability manifest — {project}
<!-- Written by /bootstrap §8.6. Auto-managed; re-run /bootstrap to refresh. -->
Generated: {date} · bootstrap {TARGET_VERSION} · STACK_FLAVOR: {flavor}

## Capability vector
| capability | value |
|---|---|
| vcs_host | github |
| ci | yes |
| ticket_system | jira |
| wiki | none |
| e2e | playwright |
| ui_surfaces | web, word-addin |
| repo_count | 10 |
| memory_system | yes |
| team | true |

## Command decisions
| command | gate | resolved | action |
|---|---|---|---|
| ticket | `ticket_system != none` | true | installed |
| qa | `ui_surfaces != none` | true | installed |
| docs | `wiki != none` | false | pruned → _archived-commands/ (wiki=none) |
| memory-lint | `memory_system == yes` | true | installed |
| demo-summary | `ticket_system != none AND team` | true | installed |
```

On re-run, diff the new vector against this file's tables; only surface/apply the deltas in §5. This file plus `_archived-commands/` together answer "why is command X (not) here?" without re-probing.

## 9. Write subagents

Always write `verifier.md` (goal-backward AC verifier) and `codebase-investigator.md`. Write `jira-context-loader.md` only if `TICKET_SYSTEM=jira`. Templates are in `<agent-specs>` below.

## 10. Configure the PostToolUse hook (portable form)

Append to `$PLACEMENT_DIR/.claude/settings.local.json` (create if missing):

```jsonc
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{
          "type": "command",
          "command": "path=$(jq -r '.tool_input.file_path // empty'); root=\"${CLAUDE_PROJECT_DIR:-$PWD}\"; [[ \"$path\" =~ /\\.claude/(tickets|debug|builds|refactors|e2e)/[^/]+\\.md$ ]] && \"$root/.claude/scripts/state-index-upsert.sh\" \"$path\" || true",
          "timeout": 5,
          "async": true
        }]
      }
    ]
  }
}
```

Key changes for portability:
- Uses `$CLAUDE_PROJECT_DIR` (set by the harness) with `$PWD` fallback — no hardcoded path.
- Calls the upsert script via absolute path computed at runtime.

If a `PostToolUse` block already exists, merge — don't overwrite.

## 10.5 Install self-learning measurement (`audit_metrics.py` + pre-push hooks)

Bootstrap installs the deterministic metrics script at `$PLACEMENT_DIR/.claude/scripts/audit_metrics.py` (template in `<scripts>` below). This is the file every command that wants to track self-learning quality reads/writes against — Sigrid-style snapshots.

**Snapshot trigger options** (pick the one that matches the user's environment):

1. **Pre-push hook (recommended — works everywhere on macOS/Linux without TCC grants).** When ≥1 git repo is detected under `WORKSPACE_ROOT`, install a pre-push hook into each repo's `.git/hooks/pre-push`. The hook:
   - Fires `audit_metrics.py` in the background (non-blocking — the push is never delayed)
   - Throttles to 1 run per hour via `$PLACEMENT_DIR/.claude/metrics/.last-run` lockfile
   - Returns exit 0 unconditionally so a script failure never blocks a push
   - Inherits Full Disk Access from the user's terminal context, so it works on macOS without granting FDA to anything

   Hook body (single source of truth — copy verbatim, do not paraphrase):

   ```bash
   #!/usr/bin/env bash
   # pre-push hook — claude-audit-hook v1
   # Fires a .claude/metrics snapshot before pushing. Non-blocking, throttled to 1/hr,
   # silent on success. Failures here NEVER block the push.

   (
     AUDIT="{PLACEMENT_DIR}/.claude/scripts/audit_metrics.py"
     LOCK="{PLACEMENT_DIR}/.claude/metrics/.last-run"

     [ -x "$AUDIT" ] || exit 0

     if [ -f "$LOCK" ]; then
       last=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)
       now=$(date +%s)
       [ $((now - last)) -lt 3600 ] && exit 0
     fi

     touch "$LOCK"
     /usr/bin/python3 "$AUDIT" >/dev/null 2>&1 &
   ) || true

   exit 0
   ```

   Install procedure (idempotent):

   ```bash
   for repo_path in $(detected_repos); do
     hook="$repo_path/.git/hooks/pre-push"
     if [ -f "$hook" ] && grep -q "claude-audit-hook v1" "$hook"; then
       continue   # already installed
     fi
     if [ -f "$hook" ]; then
       echo "$repo_path: pre-push exists — appending claude-audit block (review afterwards)" >&2
       printf '\n%s\n' "$HOOK_BODY" >> "$hook"
     else
       printf '%s' "$HOOK_BODY" > "$hook"
       chmod +x "$hook"
     fi
   done
   ```

2. **launchd LaunchAgent (macOS, weekly cadence).** Optional. Requires the user to grant Full Disk Access to `/usr/bin/python3` in System Settings → Privacy & Security if `WORKSPACE_ROOT` lives under `~/Documents/`, `~/Desktop/`, or `~/Downloads/` — otherwise launchd cannot read those directories. Bootstrap writes the plist to `$HOME/Library/LaunchAgents/com.<user>.claude-audit.plist` only if the user explicitly opts in. Default: skip launchd, use the pre-push hook.

3. **Manual.** User runs `python3 .claude/scripts/audit_metrics.py` whenever they want a snapshot. No automation. The script is still installed; only the trigger is skipped.

**Decision rule:** install option 1 (pre-push hook) by default. Show options 2 and 3 in the install-plan summary so the user can override before approval.

The script `audit_metrics.py` itself is portable — every path it touches is derived from its own location, no `/Users/...` literals. See `<scripts>` for the template.

## 11. Update .gitignore

If `$PLACEMENT_DIR/.claude/` is tracked in git (run `git check-ignore` to test), append:

```
# Per-developer state (not shared across the team)
.claude/tickets/
.claude/builds/
.claude/debug/
.claude/refactors/
.claude/e2e/
.claude/state/
.claude/docs/
.claude/metrics/
```

If `.claude/` itself is gitignored at workspace level, do nothing.

> Note on `metrics/`: this is per-developer state by default — your snapshots reflect *your* local checkout, not the team's. If a team wants a shared trend line, they should commit `metrics/` (remove from this list) and rely on a CI job to produce snapshots, not the local pre-push hook.

## 12. Apply flavor pack (optional)

If `--flavor <name>` was passed, look for `$PLACEMENT_DIR/.claude/flavors/<name>/`. If found, overlay each file in that directory on top of what was just written (append if file exists, write if new). Flavor packs are how teams add domain-specific lenses (atomic-design, prototype-branch handling, custom AC patterns) without forking bootstrap.md itself.

If `<name>` is `none` or omitted, skip this step. If specified but not found, error: "flavor `<name>` not found at $PLACEMENT_DIR/.claude/flavors/<name>/. Create it first or run without --flavor."

## 13. Stamp the version

Write or update `$PLACEMENT_DIR/.claude/workflow-version.md`:
- `version:` = `$TARGET_VERSION`
- `last-updated:` = today
- `placement:` = `workspace-root | inside-repo` (so future upgrades remember)
- Prepend a changelog entry: "Bootstrapped at $TARGET_VERSION" or "Upgraded from $ACTUAL_VERSION → $TARGET_VERSION; added: …"
- Regenerate the inventory table from the canonical inventory above.
- Refresh the hash ledger.

## 14. Summary

```
Bootstrap complete: {project} at {TARGET_VERSION}

Wrote:
  CLAUDE.md                          ({new | sections appended})
  .claude/commands/                  ({n} commands)
  .claude/agents/                    ({n} subagents)
  .claude/codebase-patterns.md       (seed)
  .claude/testing-patterns.md        (seed)
  .claude/ticket-checklist.md        ({CI_COMMAND} wired in)
  .claude/pr-template.md
  .claude/state-file-schema.md
  .claude/state/index.json           (empty registry)
  .claude/scripts/state-index-*.sh
  .claude/capability-manifest.md     (capability vector + per-command decision)
  .claude/workflow-version.md        ({TARGET_VERSION})

Skipped (already current):
  {list}

Pruned (gate now false — archived to _archived-commands/, not deleted):
  {list, with reason — e.g. "/qa (ui_surfaces=none)"}  |  (none)
  → restore by re-running /bootstrap if the project later gains the capability

Next steps:
  1. Review CLAUDE.md for accuracy.
  2. Try /ticket {TICKET_ID_PATTERN replaced with literal example}.
  3. After 3–5 delivered tickets, run /learn to grow the patterns.
  4. Re-run /bootstrap any time to upgrade in place.

Want to share this setup? See .claude/README.md (added if missing) for distribution notes.
```

</process>

---

<templates>

## CLAUDE.md (generic — no domain flavor)

```markdown
# {Project Name}

## Overview
{One-paragraph description from package.json / README. If neither, leave as a TODO with a marker.}

## Commands
| Command | What it does |
|---|---|
| `{DEV_COMMAND}` | Start the dev server |
| `{TEST_COMMAND}` | Run tests |
| `{LINT_COMMAND}` | Run the linter |
| `{BUILD_COMMAND}` | Build for production |
| `{CI_COMMAND}` | Full CI pipeline (lint + type-check + test) |

**Always run `{CI_COMMAND}` before pushing or opening a PR.**

## Architecture
{Describe top-level structure observed in step 3b. List key directories with one-line descriptions.}

## Conventions
{Extracted from linter config and observed test patterns. Mark each rule's source — `linter`, `code-observation`, or `convention`.}

## Slash commands
All commands live in `.claude/commands/` and are invoked as `/<name>`. See `.claude/commands/README.md` for the full catalog. Common ones:

| Command | Purpose |
|---|---|
| `/ticket <ID>` | Implement a ticket end-to-end |
| `/clarify <ID>` | Pre-flight investigation for a ticket |
| `/verify` | AC verification on the current branch |
| `/pr` | Generate PR title/body and run CI locally |
| `/learn` | Extract patterns from delivered tickets |
| `/refactor [scope]` | Scan code against codebase-patterns.md |
| `/project-debug [issue]` | Systematic debugging with persisted state |
| `/qa [ID]` | Generate a manual QA guide |

Ticket IDs follow `{TICKET_ID_PATTERN}` (detected from this repo's git log).

## Reference files
- `.claude/codebase-patterns.md` — coding conventions, grown by `/learn`
- `.claude/testing-patterns.md` — test conventions, grown by `/learn`
- `.claude/ticket-checklist.md` — 5-phase ticket workflow with Definition of Done
- `.claude/pr-template.md` — PR description format
- `.claude/state-file-schema.md` — schema for state files written by `/ticket`, `/project-debug`, etc.
- `.claude/agents/` — specialized subagents

## Active work check
At the start of every session:

```bash
ls .claude/tickets/*.md 2>/dev/null   # Active tickets
ls .claude/debug/*.md 2>/dev/null     # Active debug sessions
```

If state files exist, surface them and suggest `/resume-ticket`.
```

## codebase-patterns.md (seed)

```markdown
# Codebase patterns

> **Seed file.** These rules came from the linter and observed code. Run `/learn` after delivering tickets to grow this with battle-tested lessons.

## Rules
- _(none yet — extracted on first `/learn` run)_

## Source markers
- `source: linter` — enforced by the linter config
- `source: code-observation` — observed in 3+ files at bootstrap
- `source: ticket:{ID}` — learned from a delivered ticket
```

## testing-patterns.md (seed)

```markdown
# Testing patterns

> **Seed file.** Generated from {N} test files observed at bootstrap.

## Framework
{e.g., Vitest 1.x with @testing-library/react}

## File naming
{e.g., `__tests__/<mirror-of-source>/<name>.test.tsx`}

## Mocking
{e.g., vi.mock for module mocks, MSW for HTTP}

## Coverage target
{from CI config if present, else "not enforced"}
```

## ticket-checklist.md

```markdown
# Ticket checklist (5 phases)

## Phase 1 — Plan
- Read the ticket; capture ACs verbatim into `.claude/tickets/<ID>.md`.
- Investigate the codebase. Use `/clarify` for non-trivial tickets.
- Write a 3-step plan and confirm with the user.

## Phase 2 — Implement
- Follow `.claude/codebase-patterns.md`.
- Match patterns observed in similar features.

## Phase 3 — Test
- Add unit tests per `.claude/testing-patterns.md`.
- E2E tests if the ticket touches user flows.

## Phase 4 — Verify
- Run `/verify` to walk every AC and confirm it's met.
- Reflexion: list assumptions, then check each.

## Phase 5 — Deliver
- Run `{CI_COMMAND}` locally and confirm green.
- `/pr` generates title + body and pushes.

## Definition of Done
- [ ] Each AC verified against actual code (not just "looks right").
- [ ] Unit tests written and passing.
- [ ] `{CI_COMMAND}` passes locally.
- [ ] No debug prints, hardcoded values, or `any` types (or language equivalent).
- [ ] Follows `.claude/codebase-patterns.md`.
- [ ] PR title + body generated by `/pr`, not freehand.
```

## pr-template.md

```markdown
## Summary
{1–3 sentences explaining WHY, not just WHAT.}

## Ticket
{TICKET_ID} — {link if available}

## Changes
- {bullet}
- {bullet}

## Tests
- {what was added or run}

## Definition of Done
- [ ] AC1 verified
- [ ] AC2 verified
- [ ] {CI_COMMAND} passes
```

## state-file-schema.md

```markdown
# State file schema

Every file under `.claude/{tickets,debug,builds,refactors,e2e}/` follows this schema. The state-index hook reads it; commands like `/status`, `/resume-ticket`, `/learn` depend on it.

## Frontmatter (required)
```yaml
---
id: <ticket-id-or-slug>
type: ticket | debug | build | refactor | e2e
status: planning | implementing | verifying | pr-generated | delivered | abandoned
created: YYYY-MM-DD
updated: YYYY-MM-DD
repos: [list of repo names touched]
---
```

## Body sections (recommended order)
1. `## Acceptance Criteria` — verbatim from the ticket
2. `## Plan` — the 3-step plan from Phase 1
3. `## Event Log` — timestamped progress notes
4. `## Verification` — output from `/verify`
5. `## Retrospective` — answered during `/pr`

## Status transitions
- `planning → implementing` — when first code change lands
- `implementing → verifying` — when `/verify` is invoked
- `verifying → pr-generated` — when `/pr` runs
- `pr-generated → delivered` — when CI is green and PR is merged
- `* → abandoned` — explicit user action only
```

## state/index.json (seed)

```json
{"version":1,"generated":"","entries":[]}
```

## repo-profiles/_schema.yaml

```yaml
# Repo profile — fill one per repo under WORKSPACE_ROOT
name: <repo-dir-name>           # required
type: frontend | backend | bff | mobile | infra | shared-lib
base_branch: main               # the branch PRs target
ci_command: ""                  # exact local CI command, e.g. "yarn ci"
test_command: ""
lint_command: ""
build_command: ""
component_organization: atomic | hybrid | feature-based | flat   # only meaningful for UI repos
prototype_branches: []          # branches that are reference-only (never merge)
api_swagger: ""                 # path to swagger/openapi if any
notes: ""
```

## scripts/state-index-upsert.sh

Minimal portable script. Real implementations may extend it.

```bash
#!/usr/bin/env bash
# Upsert a state file into .claude/state/index.json
set -euo pipefail
file="${1:?usage: state-index-upsert.sh <path-to-state-file>}"
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
index="$root/.claude/state/index.json"
[ -f "$index" ] || echo '{"version":1,"generated":"","entries":[]}' > "$index"

# Read frontmatter into vars
id=$(awk '/^id:/{print $2; exit}' "$file" 2>/dev/null || echo "")
type=$(awk '/^type:/{print $2; exit}' "$file" 2>/dev/null || echo "")
status=$(awk '/^status:/{print $2; exit}' "$file" 2>/dev/null || echo "")
[ -z "$id" ] && exit 0   # not a state file we care about

# Use jq for safe JSON edit
tmp=$(mktemp)
jq --arg id "$id" --arg t "$type" --arg s "$status" --arg p "$file" --arg now "$(date -u +%FT%TZ)" '
  .generated = $now
  | .entries = (
      (.entries // []) | map(select(.id != $id))
      + [{"id":$id,"type":$t,"status":$s,"path":$p,"updated":$now}]
    )
' "$index" > "$tmp" && mv "$tmp" "$index"
```

## scripts/state-index-scan.sh

```bash
#!/usr/bin/env bash
# Rebuild .claude/state/index.json from scratch by scanning state dirs
set -euo pipefail
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
index="$root/.claude/state/index.json"
echo '{"version":1,"generated":"","entries":[]}' > "$index"
for dir in tickets debug builds refactors e2e; do
  for f in "$root/.claude/$dir"/*.md; do
    [ -f "$f" ] && "$root/.claude/scripts/state-index-upsert.sh" "$f"
  done
done
```

## scripts/audit_metrics.py

Deterministic Sigrid-style snapshot of `.claude` self-learning health. Drives the `/learn` add/retire ratio target, `/do` routing coverage, and pattern-file specificity tracking. Output: `$WORKSPACE_ROOT/.claude/metrics/YYYY-MM-DD[-suffix].json`. Append-only on disk; the directory listing IS the trend history.

Portable: every path derives from `$CLAUDE_PROJECT_DIR` (set by the harness) or `__file__` (when run from launchd / cron / pre-push). No hardcoded user paths.

```python
#!/usr/bin/env python3
"""Deterministic .claude self-learning metrics. Snapshot mode + diff mode."""
import argparse, json, os, re, subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Resolve workspace root: env var wins; else walk up from this file to find .claude/
def _resolve_root() -> Path:
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return Path(env)
    here = Path(__file__).resolve()
    for parent in [here.parent] + list(here.parents):
        if (parent / ".claude" / "commands").is_dir():
            return parent
    return Path.cwd()

WORKSPACE = _resolve_root()
OUT_DIR = WORKSPACE / ".claude" / "metrics"

SPECIFIC = re.compile(
    r"\.(ts|tsx|js|jsx|go|py|md|sh|json|yaml|yml)\b"
    r"|#\d+\b|\b[A-Z][A-Z0-9]+-\d+\b|\b[0-9a-f]{8,40}\b|PR\s*#?\d+|`[a-zA-Z_]\w*\("
)

def detect_repos() -> list[Path]:
    """Sub-directories of WORKSPACE that are git repos with their own .claude/."""
    out = []
    for child in sorted(WORKSPACE.iterdir()):
        if child.is_dir() and (child / ".git").exists() and (child / ".claude").is_dir():
            out.append(child)
    return out

def pattern_specificity():
    results = []
    targets = [WORKSPACE] + detect_repos()
    for r in targets:
        f = r / ".claude" / "codebase-patterns.md"
        e = {"repo": r.name, "total": 0, "specific": 0, "ratio": 0.0, "lines": 0}
        if f.exists():
            text = f.read_text(encoding="utf-8", errors="replace")
            sections = re.split(r"^## ", text, flags=re.M)[1:]
            e["total"] = len(sections)
            e["specific"] = sum(1 for s in sections if SPECIFIC.search(s))
            e["lines"] = text.count("\n")
            e["ratio"] = round(e["specific"] / e["total"], 3) if e["total"] else 0.0
        results.append(e)
    return results

def learn_churn():
    sizes = {}
    for r in [WORKSPACE] + detect_repos():
        f = r / ".claude" / "codebase-patterns.md"
        if not f.exists():
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        sizes[r.name] = {
            "lines": text.count("\n"),
            "bytes": f.stat().st_size,
            "h2_sections": len(re.findall(r"^## ", text, re.M)),
        }
    return sizes

def stale_and_integrity():
    claude = WORKSPACE / ".claude"
    cutoff = datetime.now() - timedelta(days=60)
    stale = []
    if claude.exists():
        for f in claude.rglob("*"):
            if not f.is_file():
                continue
            if any(p.startswith(".") for p in f.relative_to(claude).parts):
                continue
            mtime = datetime.fromtimestamp(f.stat().st_mtime)
            if mtime < cutoff:
                stale.append({"file": str(f.relative_to(WORKSPACE)),
                              "age_days": (datetime.now() - mtime).days})
    stale.sort(key=lambda x: -x["age_days"])

    do_md = claude / "commands" / "do.md"
    cmd_dir = claude / "commands"
    routing = None
    if do_md.exists() and cmd_dir.exists():
        text = do_md.read_text(encoding="utf-8", errors="replace")
        non_cmd = {"do", "README", "readme"}
        all_cmds = sorted(f.stem for f in cmd_dir.glob("*.md") if f.stem not in non_cmd)
        seen = [c for c in all_cmds if re.search(rf"/{c}\b", text)]
        missing = sorted(set(all_cmds) - set(seen))
        routing = {
            "total_commands": len(all_cmds),
            "referenced_in_do": len(seen),
            "missing": missing,
            "coverage_pct": round(len(seen) / len(all_cmds) * 100, 1) if all_cmds else 0.0,
        }

    return {"stale_files_60d_count": len(stale), "stale_files_60d_top": stale[:15],
            "do_routing": routing}

def rule_violations():
    """Best-effort 30-day window across detected repos. Returns 0s if git is unavailable."""
    since = (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d")
    co = fl = 0
    per_repo = {}
    for r in detect_repos():
        try:
            out_co = subprocess.run(
                ["git", "-C", str(r), "log", "--all", f"--since={since}",
                 "--pretty=format:%H", "--grep=Co-Authored-By", "--grep=Generated with Claude"],
                capture_output=True, text=True, timeout=10).stdout
            out_fl = subprocess.run(
                ["git", "-C", str(r), "log", "--all", f"--since={since}",
                 "--pretty=format:%s", "-i", "--grep=fix lint", "--grep=fix prettier",
                 "--grep=fix ci", "--grep=fix format", "--grep=address review"],
                capture_output=True, text=True, timeout=10).stdout
            rco = len([x for x in out_co.split("\n") if x])
            rfl = len([x for x in out_fl.split("\n") if x])
            per_repo[r.name] = {"coauthor": rco, "fix_lint_followups": rfl}
            co += rco; fl += rfl
        except Exception:
            per_repo[r.name] = {"error": "git failed"}
    return {"window_days": 30, "since": since,
            "totals": {"coauthor": co, "fix_lint_followups": fl}, "per_repo": per_repo}

def ticket_cycle_time():
    """Outcome metric: mean/median hours from /ticket state-file create to PR merge.

    Joins state/index.json ticket entries with `gh pr list --state merged` per repo,
    by head branch name. 30-day window. This is the single number that answers
    'is .claude/ paying rent?' — if it doesn't trend down over a month, the workflow
    apparatus isn't translating into faster shipping.
    """
    idx_path = WORKSPACE / ".claude" / "state" / "index.json"
    if not idx_path.exists():
        return {"error": "state/index.json missing"}
    try:
        idx = json.loads(idx_path.read_text(encoding="utf-8", errors="replace"))
    except Exception as e:
        return {"error": f"index.json parse failed: {e}"}

    by_branch = {}
    for entry in idx.get("entries", []):
        if entry.get("kind") != "ticket":
            continue
        repo = entry.get("repo"); branch = entry.get("branch"); created = entry.get("created")
        if not (repo and branch and created):
            continue
        if branch in ("(to be determined)", "TBD", "main", "develop", "master"):
            continue
        by_branch.setdefault(repo, {})[branch] = created

    cutoff = datetime.now(timezone.utc) - timedelta(days=30)
    per_repo, all_hours = {}, []
    for repo_name, branches in by_branch.items():
        repo_path = WORKSPACE / repo_name
        if not (repo_path / ".git").exists():
            continue
        try:
            r = subprocess.run(
                ["gh", "pr", "list", "--state", "merged", "--limit", "200",
                 "--json", "mergedAt,headRefName"],
                cwd=str(repo_path), capture_output=True, text=True, timeout=20)
            prs = json.loads(r.stdout) if r.stdout else []
        except Exception:
            prs = []
        merged = {p["headRefName"]: p["mergedAt"]
                  for p in prs if p.get("mergedAt") and p.get("headRefName")}
        hours_list = []
        for branch, created_iso in branches.items():
            merged_iso = merged.get(branch)
            if not merged_iso:
                continue
            try:
                c = datetime.fromisoformat(created_iso.replace("Z", "+00:00"))
                m = datetime.fromisoformat(merged_iso.replace("Z", "+00:00"))
            except Exception:
                continue
            if m < cutoff:
                continue
            h = (m - c).total_seconds() / 3600.0
            if h >= 0:
                hours_list.append(h)
        if hours_list:
            hours_list.sort()
            n = len(hours_list)
            med = hours_list[n // 2] if n % 2 else (hours_list[n // 2 - 1] + hours_list[n // 2]) / 2
            per_repo[repo_name] = {
                "ticket_pr_pairs_30d": n,
                "mean_hours_to_merge": round(sum(hours_list) / n, 1),
                "median_hours_to_merge": round(med, 1),
                "min_hours": round(min(hours_list), 1),
                "max_hours": round(max(hours_list), 1),
            }
            all_hours.extend(hours_list)
        else:
            per_repo[repo_name] = {"ticket_pr_pairs_30d": 0}

    overall = {}
    if all_hours:
        all_hours.sort()
        n = len(all_hours)
        med = all_hours[n // 2] if n % 2 else (all_hours[n // 2 - 1] + all_hours[n // 2]) / 2
        overall = {
            "ticket_pr_pairs_30d": n,
            "mean_hours_to_merge": round(sum(all_hours) / n, 1),
            "median_hours_to_merge": round(med, 1),
        }
    return {"window_days": 30, "per_repo": per_repo, "overall": overall}

def snapshot():
    return {
        "date": datetime.now().strftime("%Y-%m-%d"),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "schema_version": 2,
        "workspace": str(WORKSPACE),
        "metrics": {
            "pattern_specificity": pattern_specificity(),
            "learn_churn": learn_churn(),
            "rule_violations_30d": rule_violations(),
            "ticket_cycle_time": ticket_cycle_time(),
            "stale_and_integrity": stale_and_integrity(),
        },
    }

def diff(a_path, b_path):
    a = json.loads(Path(a_path).read_text())
    b = json.loads(Path(b_path).read_text())
    print(f"=== Diff: {a['date']} -> {b['date']} ===")
    a_sp = {x["repo"]: x for x in a["metrics"]["pattern_specificity"]}
    b_sp = {x["repo"]: x for x in b["metrics"]["pattern_specificity"]}
    for repo in sorted(set(a_sp) | set(b_sp)):
        ra, rb = a_sp.get(repo, {}).get("ratio", 0), b_sp.get(repo, {}).get("ratio", 0)
        arrow = "→" if abs(rb - ra) < 0.005 else ("↑" if rb > ra else "↓")
        print(f"  spec[{repo}] {ra:.2f} {arrow} {rb:.2f}")
    av = a["metrics"]["rule_violations_30d"]["totals"]
    bv = b["metrics"]["rule_violations_30d"]["totals"]
    for k in ("coauthor", "fix_lint_followups"):
        print(f"  violations.{k}: {av.get(k, 0)} -> {bv.get(k, 0)}")
    act = a["metrics"].get("ticket_cycle_time", {}).get("overall", {})
    bct = b["metrics"].get("ticket_cycle_time", {}).get("overall", {})
    if act.get("ticket_pr_pairs_30d") or bct.get("ticket_pr_pairs_30d"):
        am_h, bm_h = act.get("mean_hours_to_merge", 0), bct.get("mean_hours_to_merge", 0)
        d = bm_h - am_h
        arrow = "→" if abs(d) < 0.5 else ("↓" if d < 0 else "↑")
        print(f"  cycle.mean_hours: {am_h} {arrow} {bm_h}  (Δ {d:+.1f}h, n {act.get('ticket_pr_pairs_30d', 0)}→{bct.get('ticket_pr_pairs_30d', 0)})")
    asi, bsi = a["metrics"]["stale_and_integrity"], b["metrics"]["stale_and_integrity"]
    print(f"  stale_files_60d: {asi['stale_files_60d_count']} -> {bsi['stale_files_60d_count']}")
    if asi.get("do_routing") and bsi.get("do_routing"):
        print(f"  /do coverage: {asi['do_routing']['coverage_pct']}% -> {bsi['do_routing']['coverage_pct']}%")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--suffix", default="")
    p.add_argument("--diff", nargs=2, metavar=("A", "B"))
    args = p.parse_args()
    if args.diff:
        diff(*args.diff); return
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    snap = snapshot()
    fname = f"{snap['date']}{('-' + args.suffix) if args.suffix else ''}.json"
    out = OUT_DIR / fname
    out.write_text(json.dumps(snap, indent=2))
    print(f"Wrote {out}")

if __name__ == "__main__":
    main()
```

Make executable: `chmod +x .claude/scripts/audit_metrics.py`. The script auto-detects sub-repos (any direct child of `WORKSPACE_ROOT` that is a git repo with its own `.claude/`). Multi-repo workspaces get cross-repo metrics for free; single-repo installs see only their own repo. No configuration required.

## scripts/run_audit.sh (optional — only if launchd opt-in)

Wrapper for the launchd LaunchAgent (Section 10.5 option 2). Skip this template entirely if the user chose the pre-push hook (default).

```bash
#!/bin/bash
# Weekly wrapper around audit_metrics.py — invoked by launchd.
set -uo pipefail
WORKSPACE="{PLACEMENT_DIR}"
SCRIPT="$WORKSPACE/.claude/scripts/audit_metrics.py"
METRICS_DIR="$WORKSPACE/.claude/metrics"
LOG="$METRICS_DIR/.run.log"
TS="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY="$METRICS_DIR/$(date '+%Y-%m-%d').json"
mkdir -p "$METRICS_DIR"
{
  echo "===== $TS ====="
  if /usr/bin/python3 "$SCRIPT"; then
    echo "[$TS] OK -> $TODAY"
    PREV=$(ls -1t "$METRICS_DIR"/*.json 2>/dev/null | grep -v "$(basename "$TODAY")" | head -1 || true)
    if [ -n "${PREV:-}" ] && [ -f "$TODAY" ]; then
      echo "--- delta vs $(basename "$PREV") ---"
      /usr/bin/python3 "$SCRIPT" --diff "$PREV" "$TODAY" || true
    fi
  else
    echo "[$TS] FAILED rc=$?"
  fi
  echo
} >> "$LOG" 2>&1
exit 0
```

`{PLACEMENT_DIR}` is substituted at install time. The launchd plist that calls this lives at `~/Library/LaunchAgents/com.<git-user>.claude-audit.plist` (also generated only on opt-in) and fires Mondays 09:00 local. **macOS caveat:** if `PLACEMENT_DIR` is under `~/Documents/`, `~/Desktop/`, or `~/Downloads/`, launchd needs Full Disk Access on `/usr/bin/python3` (System Settings → Privacy & Security). Bootstrap warns the user about this before generating the plist; if they don't want to grant FDA, fall back to the pre-push hook.

## workflow-version.md (seed at TARGET_VERSION)

```markdown
---
version: {TARGET_VERSION}
last-updated: {YYYY-MM-DD}
maintainer: {git user.email | "unknown"}
placement: {workspace-root | inside-repo}
---

# Claude Code workflow — version log

Tracks the slash-command workflow in `{relative-path-to-commands}`. Every command's frontmatter carries a matching `version:`. Bump via `/bootstrap --bump <patch|minor>`.

## Versioning rules
- **MAJOR (x.0.0)** — declare the workflow stable / repo-agnostic.
- **MINOR (0.x.0)** — add, delete, or reshape commands.
- **PATCH (0.0.x)** — refinements that don't change the surface.

## Changelog

### {TARGET_VERSION} — {YYYY-MM-DD}
{Initial bootstrap | Upgraded from {ACTUAL} → {TARGET}; added: ...}

## Command inventory at this version
{auto-generated table}

## Hash Ledger (auto-managed)
{auto-generated}
```

</templates>

---

<command-specs>

Each spec below is the kernel of a command — a brief detailed enough for Claude to render a full command file. The generated file MUST include frontmatter (`name`, `version: {TARGET_VERSION}`, `description`, `argument-hint`, `allowed-tools`) plus the structural sections the spec lists. **Spec depth = command quality.** Load-bearing commands (verify, ticket, pr, clarify, learn, review-pr) are spec'd deeply; lighter commands get briefer specs because they're simpler.

### ticket
End-to-end ticket implementation. Five phases. Stops at PR generation — does NOT push, commit, or open PRs (that's `/pr`'s job, so the project's PR template is honored).

**0. Detect repo + load config.** From CWD if inside a repo, else ask. Read repo profile (`.claude/repo-profiles/<repo>.yaml`) for `base_branch`, `ci_command`, `test_command`. Required for downstream steps.

**1. Parse input + create state file.** `$ARGUMENTS` is a ticket ID matching `{TICKET_ID_PATTERN}`. Create `.claude/tickets/<ID>.md` per `state-file-schema.md`. Initial frontmatter: `status: planning`, `created: today`, `repos: [<repo>]`.

**1.1 Classify ticket type** to load only the context that matters. Tiers:
- **Tier 1 (minimal):** deps update, typo fix, lockfile bump, single-line config tweak.
- **Tier 2 (focused):** simple bug fix, single-component change, test-only addition.
- **Tier 3 (full):** new feature, refactor, multi-file change, API integration.
- **Tier 4 (everything):** epic-level work, cross-repo change, breaking API change.
Each tier reads a different subset of `codebase-patterns.md`, prior tickets, and API docs. Save the tier in state frontmatter so `/resume-ticket` knows what context to reload.

**1.5 Business context (Tier 3+ only).** If a wiki integration is configured (e.g. a Confluence space in the repo profile), search for the feature area. Surface page titles + 1-line summaries; user opens what's relevant. Skip on Tier 1/2 — overhead for low-stakes work.

**2. Plan mode + investigate.** Enter `EnterPlanMode`. Use the `codebase-investigator` agent in parallel for: similar features (3 closest matches), reusable components/hooks/utilities, API endpoints touched, permission/auth patterns, existing tests for the surrounding area. Surface findings, not raw search output.

**3. Create implementation plan.** 3–5 numbered steps. Each step: file(s) touched, what changes, tests added, AC(s) it satisfies. User must approve before exiting plan mode.

**4. Update state file** with plan, AC list verbatim, classification tier, event log entry.

**4.5 Transition ticket** in the source system if applicable. For Jira: status → "In Progress" via the transition id in the repo profile (`jira_transition_inprogress` in `repo-profiles/<repo>.yaml` — the single home for tracker config). Skip if assignee isn't the user, or if `tracker_system: none`.

**5. Implement.** Follow the plan. After each step: update event log, run unit tests for the touched area only (NOT full suite), capture before/after screenshots for UI changes if Playwright is wired. DO NOT commit between steps.

**6. Verify.** Invoke `/verify` as a subroutine. Use its confidence rating to decide go/no-go. If LOW confidence, loop back to step 5. Never exit `/ticket` with a known-failed AC.

**7. Stop here.** `/ticket` does NOT: run `git commit`, push to remote, open a PR, or transition the ticket past "In Progress". These belong to `/pr`. Exit state: `status: verifying`, all ACs VERIFIED, local CI green.

**8. Hand-off message.** "Ready for `/pr`. Retro questions happen there while context is fresh."

Allowed-tools: `Read, Bash, Glob, Grep, Edit, Write, Task, EnterPlanMode, AskUserQuestion`.

### verify
Goal-backward AC verification on the active branch. Confidence-rated, evidence-cited, never claims something passed without showing where.

**0. Detect repo + load config.** Read repo profile for `ci_command`, `test_command`, `lint_command`, `base_branch`. Required.

**1. Gather ACs** in priority order: active state file at `.claude/tickets/<ID>.md` → `{TICKET_CLI}` fetch from ticket system → PR body if branch is pushed → user paste as last resort.

**2. Identify modified files.** `git diff <base>...HEAD --name-only`, where `<base>` comes from the repo profile. Filter to source files (skip lockfiles, generated code, snapshots, `.gitignore`).

**2.1 Tests-for-every-source enforcement.** For each net-new source file, find a matching test file IN the diff. Missing-test on new source is a CRITICAL finding — auto-downgrades confidence to LOW.

**2.2 Surface command proposals.** Read `.claude/command-proposals.md`. If any proposal mentions `/verify`, surface it — the user might want to apply it before running.

**2.5 Reflexion (BEFORE checking ACs).** Self-critique three questions:
1. What am I assuming about how this code is reached?
2. What's the most likely way this could be subtly wrong?
3. Have I confirmed each AC by reading code, or am I recalling from memory?
Reflexion prevents the most common verify failure: pattern-matching "looks right" instead of tracing actual call paths.

**3. Run verification per-AC.** For each AC:
- Derive ONE crisp truth that must hold.
- Find the file/lines that implement it.
- **Substance check (anti-false-positive):** is the code real (not stub/TODO/empty handler)? Is it wired (imported, called, rendered, reachable)? Walk one end-to-end path.
- Status: **VERIFIED / PARTIAL / FAILED / NEEDS_MANUAL_CHECK**.

**3.2 Quality gates.** Run in order, stop on first failure unless `--all-gates`:
1. `{LINT_COMMAND}` — fast feedback first.
2. `{TEST_COMMAND}` — affected tests first; full suite if any related tests touched.
3. Type check (if separate from lint).
4. `{BUILD_COMMAND}` — only on `--full` flag (slow).

**3.3 Simplify check.** Scan changed code for: dead branches, unused imports, redundant null checks, code that exists "just in case." Surface as nits. Never auto-fix.

**4. Live URL/UI check (UI tickets, optional).** If the diff touches frontend files AND a dev server is running: capture before/after screenshots via Playwright if available; check changed routes load without console errors; compare against ACs that mention specific UI states.

**5. Contract smoke test (API tickets).** If diff touches API surface: detect endpoints in the diff, check `.claude/api-reference/*.json` for the swagger, run `swagger-cli validate` or invoke the `contract-verifier` agent.

**6. Security quick-scan.** Always. Look for: hardcoded secrets, missing auth checks on new endpoints, dangerous SQL string concat, unescaped user input in templates.

**7. Confidence calibration.**
- **HIGH:** every AC verified with file:line + tests pass + lint clean + reflexion answered + (if API) contract clean.
- **MEDIUM:** ACs verified but tests thin OR one quality gate has a documented skip OR reflexion surfaced unresolved doubts.
- **LOW:** any AC FAILED, any new source without a test, any quality gate failing.

**8. Output structure.** Per-AC table with status + file:line evidence. Quality gate results. Findings bucketed CRITICAL / WARNING / NIT. Confidence + recommendation: "ready for `/pr`" / "fix these before `/pr`" / "needs manual verification." Update state file: `status: verifying` until user confirms ready.

**Output is a worksheet, not a verdict.** The user makes the call. `/verify` provides evidence.

Allowed-tools: `Read, Bash, Glob, Grep, Task` (Task for `verifier` and `contract-verifier` agents).

### pr
Generate PR deliverables (commit message + PR description) from current changes. Runs CI before showing anything. Branch-aware (suggests names, refuses to push from base branches).

**0. Detect repo.** Same as `/verify`.

**1. Branch sanity check.** If current branch is a base branch (`main`/`master`/`develop` or anything in repo profile's `base_branch`): refuse to commit; suggest a feature branch (`feature/<TICKET_ID>-<slug>` or `fix/`, `refactor/`, `chore/` based on ticket type); ask user to confirm name; create the branch; move uncommitted changes onto it.

**1.5 Determine base branch.** From repo profile `base_branch`. Critical: many repos have a non-default base (`develop`, `develop-v2`, `release/N`) recorded in the repo profile. Never assume `main`.

**1.5b Profile-vs-reality sanity check.** Run `gh pr list --state merged --limit 5 --json baseRefName` and compare modal recent base to the repo profile's `base_branch`. If they differ, warn — the profile may be stale or the user is about to target the wrong branch.

**2. Gather context.** Read: active state file (ACs, plan, retro answers), `git diff <base>...HEAD`, `git log <base>...HEAD --oneline`, `.claude/pr-template.md`.

**3. Generate commit message** via the `commit-drafter` agent if available, else inline. Conventional Commits format unless repo prefers otherwise. Subject ≤72 chars. **NO AI attribution** (`Co-Authored-By: Claude`, `Generated with Claude Code`, etc.) — strict rule.

**4. Generate PR description** from `pr-template.md` + state file context. Substitute: summary (from plan + diff), ticket link, changes (bullets from `git log`), tests (from state file's Tests section), DoD checklist with each AC pre-marked if `/verify` said VERIFIED.

**5. PR branch reviewer pass (optional).** If a `pr-branch-reviewer` agent exists, run it: a quick read-only review of the diff for obvious things to fix before opening.

**5.5 Pre-PR checklist.** Auto-check what was done vs skipped:
- `[ ] /verify run with HIGH confidence` (warn if MEDIUM, block if LOW)
- `[ ] Tests added for new source files`
- `[ ] State file Retrospective filled` (if not, ask now)
- `[ ] CI run locally` (next step)
Surface skipped items; ask user to confirm or fix.

**6. Run CI locally.** Two-step gate:
- **6a. Workflow-keyword discovery.** Grep `.github/workflows/*.yml` for `format:check|prettier|lint|typecheck|tsc|test|build` to see what CI actually runs. The baseline `{CI_COMMAND}` may not cover every step (e.g. a separate Prettier `format:check`). Run each discovered keyword command that the baseline does not cover.
- **6b. Run baseline `{CI_COMMAND}`.** Block on failure. The user's preference rule: never push without local CI green. If CI fails, print failure summary and stop — do NOT show PR deliverables yet.

**7. Present deliverables.** Show: commit message (full), PR title (≤70 chars), PR body, branch name + base branch, host-specific PR command:
- GitHub → `gh pr create --title "..." --body "..." --assignee "@me"` (always assign self)
- GitLab → `glab mr create --title "..." --description "..."`
- Azure DevOps → `az repos pr create --title "..." --description "..."`
- Bitbucket / other → print and ask user to create manually
Wait for explicit user approval before pushing. Never auto-push.

**8. Update state file:** `status: pr-generated`. Append PR URL once known.

**8.5 Transition ticket** to "Code Review" in the source system. **Assignee gate:** fetch `fields.assignee.emailAddress` from the ticket FIRST; skip the transition (with a logged reason) when the assignee isn't the user. This prevents claiming workflow ownership of someone else's ticket.

**9. Quick retro + learn suggestion.** Ask 3 questions while context is fresh: what surprised you / what went well / what would you do differently? Append to state file Retrospective. If 3+ tickets are now `delivered` since last `/learn`, suggest running it.

**Hard rules:** never push to a base branch; never auto-merge; never create a PR without showing deliverables for approval first.

Allowed-tools: `Read, Bash, Glob, Grep, Edit, Write, Task, AskUserQuestion`.

### learn
Two modes — argument-driven.

**Default (ticket mode)** — `$ARGUMENTS` is empty or names a repo:

1. **Scan state index** (`.claude/state/index.json`) for `status: delivered` entries. Multi-repo workspaces scan all repos unless a repo name is given.
2. **Collect retrospectives.** For each ticket, read the `## Retrospective` section. If missing or empty, prompt the user with the 3 retro questions inline (what surprised you / what went well / what would you do differently). Skip the ticket if user declines.
3. **Cluster lessons** by theme:
   - **Pitfalls** — gotchas, broken assumptions, things that cost time.
   - **Patterns to reinforce** — approaches that worked, worth codifying.
   - **Undocumented knowledge** — internal behaviors not in any doc.
   - **Precedents** — first-time decisions that establish a convention.
4. **Tag every extracted entry** `_Source: ticket:<ID>_` so future readers know provenance.
5. **Draft updates** to `codebase-patterns.md`, `testing-patterns.md`, or repo-specific pattern files. Each draft entry: rule, **Why:**, **How to apply:** (matches the patterns-file convention).
6. **Present diffs for approval.** Show every proposed addition. User can accept, edit inline, or reject. NEVER auto-write.
7. **Apply approved changes.** Append to pattern files. Update each contributing ticket's state file: add a `## Lessons applied` section linking to the rule(s) extracted.
8. **Cross-link related tickets.** If multiple tickets contributed to the same lesson, note it in each ticket's state file: "_See also: TICKET-XXX, TICKET-YYY for related insight._"

**Session mode** — `$ARGUMENTS` contains `--session`:
- Skip ticket scanning. Pull lessons from the active conversation instead.
- Trigger contexts: QA runs, debug sessions, exploration chats, anything that produced insights without a delivered ticket.
- Ask 4 prompts (skip empty answers):
  1. Patterns or gotchas discovered? (→ `codebase-patterns.md`)
  2. Codebase surprises or undocumented behavior? (→ architecture notes)
  3. Testing insights — tools, automation limits, strategies? (→ `testing-patterns.md`)
  4. Anything else worth remembering? (catch-all)
- Tag entries `_Source: session YYYY-MM-DD_` so future `/learn` runs can distinguish them from ticket-derived rules.

**Always (both modes)** — scan the conversation for command-underuse signals:
- Long manual debug with no `/project-debug` invocation
- Repeated mistakes that a pattern rule would have caught
- Missed automation (e.g., didn't run `/qa` before delivery)
- If the same gap recurs in 3+ sessions/tickets, triage it like any other improvement signal (below) — mechanical fixes land at capture; only design-shaped gaps get filed as proposals.

**Proposal lifecycle (v0.3.1 — `learn.md` §0.3 + §5.6 is the source of truth; this is the install-time summary):**
- Proposals are **modifications to existing commands, never new commands**. Every entry carries `**Target:** <command>.md §<section>`, `**Occurrences:**`, and `**Status:**` ∈ `OPEN` | `ADDRESSED YYYY-MM-DD — <command>§<section>` | `STALE YYYY-MM-DD — <reason>` (STALE is reversible — a recurrence flips it back to OPEN).
- **Capture-time triage** decides each signal's form immediately: **APPLY-NOW** (mechanical ≤15-line single-file diff → applied in-session behind a shown-diff approval, filed pre-ADDRESSED) / **COMPILE-TO-CHECK** (mechanically-checkable lessons become /verify battery lines, hooks, or lint rules — never prose-only) / **BATCH-ASSIGN** (design-shaped → filed OPEN) / **DROP** (one-off speculation — not filed; recurrence is the filing trigger).
- **Dedupe before append:** key = `(Target command, failure-class)` — not signal text. Bump `**Last seen:**` + `**Occurrences:**` instead of appending. Cap 5 NEW proposals per run (bumps don't count). **WIP cap: 20 OPEN**, one-in-one-out above it.
- **Aging gate (`learn.md` §0.3)** runs FIRST on every write-capable run — it replaced the old "every 5th run / >50 proposals" reconciliation (that trigger was dead: no run counter exists). Sweeps entries aged 21d+ (statusless counts as aged-OPEN) to: LAND (already implemented → ADDRESSED) / LAND-NOW (apply a ≤15-line diff in-run, max 3/run) / KILL (superseded or never recurred → STALE) / DEFER (stamp `**Reviewed:**`, max 2 times — then land-or-kill is forced).

**Approval rule**: every write (pattern files, command files via APPLY-NOW / LAND-NOW, command-proposals) requires explicit user approval. Show the diff first.

### build
- Same context-loading as `/ticket` but without a ticket fetch.
- Write state at `.claude/builds/<slug>.md`.
- Phases 2–5 only.

### debug
- Gather symptoms, form hypotheses, test in order of likelihood.
- Persist to `.claude/debug/<slug>.md` with hypothesis log.
- Run quality gates after each fix attempt.

### resume
- Read `.claude/state/index.json` to find recent active state files.
- Reconstruct context (ACs, plan, last event-log entry) and ask the user how to proceed.

### refactor
- Scan code against `codebase-patterns.md`. Categorize hits as critical / warning / info.
- Plan-mode the fix list. Apply only with approval.

### review-pr
Reviews someone else's PR. Three things checked in parallel: pattern compliance, AC compliance, evidence quality. Bimodal confidence + decision-tree verdict + copy-paste comment. Never auto-posts.

**0. PR fetch.** Argument is PR number, URL, or branch ref. Use `gh pr view <N> --json title,body,headRefName,baseRefName,files,additions,deletions,author,state,mergeable,labels` plus `gh pr checks <N>`. Without `gh`, fall back to `git diff base...head` and ask the user to paste the PR body — warn that AC verification is weaker.

**1. Ticket ID extraction (ordered fallback).** Branch name → PR title → PR body → labels → linked issues (`gh pr view --json closingIssuesReferences`). If multiple, branch-name ID is primary; rest are "related." If none, switch to **Stated Intent Review** — use the PR body's stated goal as the success criterion (covers Dependabot, tooling PRs).

**2. AC sourcing.** Fetch ACs via `jira-context-loader` agent (or `{TICKET_CLI}` direct). Merge three sources: ticket-system custom field (authoritative), description checklist, PR body `## Acceptance Criteria`. Dedupe + flag divergences:
- AC in PR body but not ticket → **scope creep**
- AC in ticket but not PR body → **missed work**
- Ticket `updated > PR createdAt` → **stale AC drift**

**3. Strategy selection.** Pick based on PR shape:

| Condition | Strategy |
|---|---|
| Author is a bot (dependabot, renovate) | **diff-only** — trust CI; lockfile sanity only |
| Docs-only (all `*.md`) | **diff-only** |
| Branch already deleted (merged) | **fetch-ref** — `git fetch origin pull/<N>/head:review-<N>` |
| Changed files > 500 OR free disk < 2GB | **diff-only** — recommend splitting |
| Default | **worktree** — `git worktree add /tmp/review-pr-<N> origin/<head>`; cleanup via `trap` on exit |

Worktree is non-disruptive (reviewer's index/working tree untouched). Diff-only is the floor. Fetch-ref is the merged-branch escape hatch.

**4. Pattern compliance** (changed files only). Universal: console/debug left in, TODO/FIXME added in this PR. Stack-specific from `codebase-patterns.md` (e.g. `: any`, hex colors, native HTML for JS/TS; `fmt.Print`, `panic(` for Go). Skip rules irrelevant to the changed file types.

**5. AC verification** (per-AC). For each AC: derive what MUST be true → find the diff hunk that implements it → confirm it's real (not a stub/TODO) AND wired (imported, called, rendered). Status: **PASS / PARTIAL / FAIL / NEEDS_MANUAL**.

**5a. Tests-for-every-source.** For each net-new source file in the diff, look for a matching test file IN the diff. Missing test on a new source is a trump signal (forces REQUEST_CHANGES).

**5b. Contract smoke test.** If the diff touches API surface, invoke a `contract-verifier` subagent (or run `swagger-cli validate` / equivalent) to flag breaking changes.

**6. CI quality gate.** Always read `gh pr checks <N>`. If green AND new tests added → run just those locally (worktree mode only). If red → reproduce locally for specifics. If pending → skip local run; recommend re-running `/review-pr` when CI finishes.

**7. Bimodal confidence.**
- **Author Confidence (AC):** HIGH = CI green + every AC mapped to a hunk + new sources have tests + contract changes have evidence. MEDIUM = CI green + ACs covered but tests thin OR contract change with no evidence. LOW = CI red/pending OR ACs missing OR new source with zero tests.
- **Reviewer Confidence (RC):** HIGH = worktree + ran tests locally + read every changed file + traced one end-to-end path. MEDIUM = read all files + spot-checked one path. LOW = skim only.
- **Headline = min(AC, RC).** Render both: `MEDIUM (Author: HIGH · Reviewer: MEDIUM — diff-only)`.
- **Gaming guards:** diff-only structurally caps RC at MEDIUM. HIGH RC with empty evidence fields (commands run / files read / minutes spent) auto-downgrades. Author seniority/trust does NOT modify AC.

**8. Verdict decision tree.**
1. **Trump layer (any → REQUEST_CHANGES):** CI red, critical pattern violation, new source without test, headline=LOW.
2. **Discuss layer:** architectural disagreement, simpler path available, MEDIUM headline + ≥3 warnings, CI pending.
3. **Approve layer:** HIGH headline + 0 critical + ≤2 warnings + CI green + tests present → APPROVE. MEDIUM same → APPROVE_WITH_COMMENTS.
4. Default → DISCUSS (safe).

**8a. Gut-check gotcha.** If the tree says APPROVE but reviewer's intuition disagrees, ask once: *"Tree says APPROVE. Anything bugging you? One sentence."* If user types a concern, scan the diff for supporting evidence (cyclomatic complexity, assertion counts, ambiguous identifiers). Include findings in the review. If no evidence surfaces, say so — let the user decide.

**9. Two outputs.**
- **Full report** (≤80 lines, for the reviewer's worksheet): confidence banner, AC table, pattern violations bucketed CRITICAL/WARNING/NIT, CI status, AC source divergences, "what's done well" (≥1 positive observation, always), verdict with 1–3-sentence reasoning.
- **Copy-paste comment** (≤15 lines, for the PR): one-line confidence+verdict, one positive sentence, ≤3 numbered blockers with `file:line`, optional non-blocking grouped sentence, optional discuss question.

**10. Approval gate (never auto-posts).** Honors the never-post-without-approval rule. Ask: `approve` (submit as approval) / `request changes` / `comment` / `edit` (open draft, wait for edits) / `skip` (keep private). Only post on explicit choice via `gh pr review --approve|--request-changes|--comment --body "$(cat draft.md)"`.

**11. Review log → `/learn` feedback loop.** Write `.claude/tickets/<TICKET_ID>-review.md` with frontmatter: `kind: review`, `pr`, `reviewed_by`, `author`, `strategy`, `confidence_author`, `confidence_reviewer`, `confidence_headline`, `verdict`, `findings_critical`, `findings_warning`, `tests_run_locally`, `time_spent_minutes`. `/learn` later correlates these against outcomes (reverts, follow-up bugfix PRs) to surface reviewer calibration drift.

**Always include at least one positive observation.** Every PR has something done well — name it specifically with a `file:line`.

Allowed-tools for the generated command: `Read, Bash, Glob, Grep, AskUserQuestion, Task` (Task for `jira-context-loader` and `contract-verifier`).

### qa
- Read ACs from the state file.
- Generate step-by-step manual test cases with URLs, setup steps, edge cases.

### clarify
Pre-flight investigation BEFORE `/ticket`. Output: file placement recommendation, similar code to mirror, atomic-design layer classification, list of questions ONLY the user can answer (skip anything Claude can derive).

**0. Detect repo + setup.** Same as `/verify`.

**0.5 Setup auditor (optional).** As we investigate, also note workflow-improvement opportunities for this repo (missing pattern rule, unclear setup step). If anything substantive surfaces, append to `.claude/command-proposals.md`.

**1. Fetch ticket** via `{TICKET_CLI}`. If `jira-context-loader` agent exists, use it for: primary issue, linked issues, epic siblings, subtasks, parent, blockers — in parallel.

**1.5 Related tickets.** Find tickets in the same epic / area / linked-via-jira. Surface 3 closest. (This is the merged-in `/related` functionality from earlier workflow versions.)

**1.5b Prior art lookup.** Search `.claude/state/index.json` for delivered tickets touching similar files / feature area. If any, summarize what they did — saves the user from re-deriving solutions.

**1.8 Design reference classification.** If the ticket has a Figma link or design URL, classify:
- Static spec → straightforward implementation.
- Live design → check repo profile `prototype_branches:` — if matches, this is REFERENCE ONLY (do NOT cherry-pick from prototype branch).
- New design language → flag as Tier 4, needs design system audit first.

**2. Parse implementation claims.** From the ticket body, extract any "the implementation should…" or "we'll use X library" claims. Each is a hypothesis to verify or refute during investigation.

**2.5 Prototype-aware investigation.** If a prototype branch is referenced:
- Pull its interaction code as REFERENCE CONTEXT (not import-from).
- Banner the output: "do NOT copy code from prototype — rebuild against current main with real API/auth/types/tests."

**3. Deep codebase investigation** via the `codebase-investigator` agent in parallel:
- Existing similar features (3 closest matches with file:line citations)
- Reusable components/hooks/utilities (atomic-aware: which atoms exist that could compose this molecule?)
- API endpoints already calling related backends
- Permission/auth patterns relevant to the ticket
- Test patterns for this area

**4. Draw conclusions.**

**4a. File placement.** Where should new files live? Based on observed convention:
- Component organization from repo profile: `atomic | hybrid | feature-based | flat`.
- Domain folder: which existing top-level folder does this belong in?
- Atom-first rebuild plan: list atoms → molecules → organism → page assembly.

**4b. Pattern recommendations.** Atomic-design lens (skip if repo profile says `component_organization: flat`):
- Classify each file in the plan as atom / molecule / organism / template / page.
- Ticket scope: `atom-new | molecule-new | organism-new | page-assembly | mixed-layer`.
- **Mixed-layer = flag for split.** Don't ship a ticket that introduces 3 atoms + 2 molecules + 1 page in one PR.

**4b.2 Build order.** Always atomic-first: atoms → molecules → organisms → page. Each tested in isolation before composing up.

**4c. API contract analysis.** For each API call the ticket needs, confirm the endpoint exists in `.claude/api-reference/*.json`. Flag missing endpoints — they're a backend dependency the ticket needs.

**4d. Dependency check.** New libs needed? List with bundle-size impact for FE, license check for backend.

**5. Identify ambiguities.** Anything still unresolved AFTER investigation. If Claude can derive it, derive it — don't ask.

**6. Generate questions** (only for genuine unknowns):
- "Which date format does the design use?" — derivable from Figma → don't ask.
- "Should this respect the current user's locale?" — NOT derivable → ask.
- Cap at 5 questions. If more, the ticket isn't ready.

**7. Output** as a structured worksheet:
- Summary (1 paragraph)
- File placement table
- Atomic-design classification + scope verdict
- Build order
- API surface needed (✓ exists / ✗ missing)
- Dependencies needed
- Open questions for the user (numbered, ≤5)
- Recommended next: `/ticket <ID>` (if green) | "split first" (if mixed-layer) | "answer questions then re-run `/clarify`" (if blockers)

Allowed-tools: `Read, Bash, Glob, Grep, Task, AskUserQuestion`.

### ci-check (gate: gh present)
- Watch the open PR. Poll `gh pr checks <N>` until green or red.
- On green, prompt to merge. On red, summarize the failure and suggest next steps.
- Update state status to `delivered` after merge.

### review-comments (gate: gh present)
- Fetch unresolved review comments via `gh api`. Save valid feedback to the active state file. Triage: actionable / nit / discussion.

### e2e (gate: Playwright/Cypress)
- Use the repo's e2e patterns. Generate a spec covering the ticket's user flows.

### screenshot (gate: Playwright)
- Capture a screenshot of a given URL or component using a temporary Playwright script.

### security
- Secret scan (AWS/API tokens, private keys). OWASP Top 10 checks. `npm audit` / `yarn audit` / `pip-audit` / `gosec` per stack.

### project-context (gate: ≥2 repos)
- Build a connection map across repos. FE → BFF → backend edges. Loose ends. Type drift.
- Cache per-repo HEAD hashes for incremental rescans.

### status (gate: ≥2 repos)
- Read `state/index.json` and present a dashboard: active tickets, open debug sessions, blocked items.

### retro (gate: ≥2 repos)
- Sprint-level retrospective across all repos. Surface team patterns and command underperformance.

### do (optional)
- Single-entry router. Reads the user's plain-English request and dispatches to the right command.

### queue (optional)
- Queue tickets for off-peak automated implementation.

### docs (optional)
- Search/create/update wiki documentation. Implementation depends on the wiki provider.

</command-specs>

---

<agent-specs>

> **Model policy (applies to every agent below):** every generated agent's frontmatter MUST include `model: opus`. Subagents run isolated from the parent session and only their final report comes back, so quality on the lookup pass matters — Opus's stronger reasoning is worth the extra cost on the agent leg, especially for codebase-investigator and contract-verifier where bad coverage silently corrupts downstream answers. If the bootstrap is being invoked for a cost-constrained project, the user can opt into Sonnet per-agent after install; the default ships Opus.

### verifier (always)
- For each AC: derive what must be true → check it IS true in code.
- Confirm code is real (no stubs/TODOs) and wired (imported/called/rendered).
- Run quality gates. Per-AC verdict: VERIFIED / FAILED / NEEDS_MANUAL_CHECK.
- Tools: Read, Grep, Glob, Bash.
- Frontmatter: `model: opus`.

### codebase-investigator (always)
- Parallel investigation for a feature area. Find similar features, reusable components/hooks, API endpoints, BFF routes, permission patterns, existing UI patterns.
- Used by `/clarify`, `/ticket`, `/build`, `/refactor`, `/review-pr`.
- Tools: Read, Glob, Grep, Bash.
- Frontmatter: `model: opus`.

### jira-context-loader (gate: TICKET_SYSTEM=jira)
- Load full Jira context for a ticket in parallel — primary issue, linked issues, epic siblings, subtasks, parent, blockers.
- Normalize MCP vs CLI output.
- Tools: Read, Bash, Grep, Glob.
- Frontmatter: `model: opus`.

### commit-drafter (always)
- Draft conventional commit message + PR title from a git diff plus optional ticket context.
- Normalize across Story / Bug / Task / chore types. Subject ≤72 chars. Respect repo's no-AI-attribution rule.
- Used by `/pr`, `/queue`.
- Tools: Read, Bash, Grep.
- Frontmatter: `model: opus`.

### contract-verifier (gate: project has API types AND a swagger/OpenAPI spec OR a live API endpoint)
- Compare TS / Zod / Go type definitions against a spec OR a live response.
- Catches FE/BFF/backend drift: snake_case vs camelCase, null vs undefined, missing fields, type-shape mismatches.
- Used by `/verify` step 6, `/clarify` step 4c.
- Tools: Read, Bash, Grep, Glob.
- Frontmatter: `model: opus`.

### pr-branch-reviewer (optional — install if user opts in)
- Read-only branch review before `/pr` opens the PR. Verifies branch-naming convention (`type/PROJ-NNNN`), checks the ticket-checklist (no hex, no `console.log`, no `: any`, tests exist, scope controlled).
- Reference: `.claude/codebase-patterns.md` and `.claude/ticket-checklist.md` if present.
- Tools: Read, Bash, Grep, Glob.
- Frontmatter: `model: opus`.

### Workspace-fallback pattern for agents
When a repo has its own `.claude/agents/<name>.md` AND a workspace-level `/<WORKSPACE_ROOT>/.claude/agents/<name>.md` exists, **the repo copy wins**. The workspace copy is the cross-repo fallback used when the repo has no override. Bootstrap should generate the workspace copies with a header explaining the precedence and noting that the inline commands assume the bootstrap user's primary stack — when invoked in a non-primary repo, translate stack-specific commands via `CLAUDE.md` + the repo profile.

</agent-specs>

---

<guidelines>

## Critical rules

1. **Verify, don't guess.** If you can't find the test command from `package.json` / `Makefile` / `gradle tasks`, ask. Don't write `npm test` into a yarn project.
2. **Use exact commands.** `{CI_COMMAND}` must be the literal command, not a placeholder.
3. **Patterns come from code, not best practices.** Read 2–3 existing tests before generating `testing-patterns.md`.
4. **Definition of Done is project-specific.** It must reference the actual CI command for THIS project.
5. **Gitignore state files when `.claude/` is tracked.** Tickets and debug sessions are per-developer.
6. **No hardcoded paths.** Every absolute path must derive from `$WORKSPACE_ROOT` or `$PLACEMENT_DIR`. Bootstrap.md must be portable.
7. **No domain flavor in the default templates.** If a project needs atomic-design lenses, Jira-specific transitions, or company-specific workflows, that lives in a `--flavor` pack — never in the generic templates.
8. **Don't create commands you can't wire.** If `gh` is missing, skip `/ci-check` and `/review-comments` — note them in the summary.
9. **Don't blow away user edits.** On upgrade, diff against the prior template; if the user has modified a file, ask before overwriting.
10. **Ask before creating.** Present the install plan and wait for `yes`.

Release notes for what each version changed live in the workspace's `workflow-version.md`, not here. This file is the executable installer; the version log is the historical record.

</guidelines>

<success_criteria>
- [ ] `WORKSPACE_ROOT` resolved at runtime; no hardcoded user-specific paths in this file or in any generated file.
- [ ] Canonical inventory tables at the top are the single source of truth.
- [ ] Fresh-install flow: writes all `core` items + tier-gated items the project qualifies for.
- [ ] Upgrade flow: detects `ACTUAL_VERSION`, installs only what's new since.
- [ ] User-modified files are diffed before overwrite; user is asked per file.
- [ ] All paths in generated files use relative or runtime-resolved roots.
- [ ] PostToolUse hook uses `$CLAUDE_PROJECT_DIR` (not a hardcoded path).
- [ ] `repo-profiles/_schema.yaml`, `state-file-schema.md`, `state/index.json`, and the two scripts are written from inline templates (not copied from a path that may not exist).
- [ ] No domain flavor (atomic-design, prototype-branches, company-specific ticket prefixes, Obsidian, Confluence-by-default) in the generic templates.
- [ ] `--flavor <name>` overlay path documented; missing flavor errors clearly.
- [ ] `--bump` and `--check` both use `$WORKSPACE_ROOT`.
- [ ] Plan is presented and approved before any file write.
- [ ] Summary lists what was installed, upgraded, skipped, and the next-step commands.
</success_criteria>
