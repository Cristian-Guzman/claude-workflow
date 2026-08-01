# Repo Profiles

One YAML file per repo. Every command reads the profile for the current repo instead of hardcoding branch names, CI commands, or paths.

## Why this exists

Before profiles, `/pr` and `/verify` contained hardcoded tables like:
```
api-bff        → develop-v2
web-app        → develop-v2
addin-fe       → develop
```
Two places to update, easy to drift. Now that data lives once in `.claude/repo-profiles/<repo>.yaml`.

## How commands use it

```bash
# Resolve the profile path for the current repo
REPO_NAME=$(basename {REPO_ROOT})
PROFILE=$WORKSPACE_ROOT/.claude/repo-profiles/${REPO_NAME}.yaml

# Read a field (no yq dependency — grep is enough for flat keys)
BASE_BRANCH=$(grep '^base_branch:' "$PROFILE" | awk '{print $2}' | tr -d '"')
CI_COMMAND=$(grep '^ci_command:' "$PROFILE" | cut -d: -f2- | sed 's/^ *"\?//;s/"\?$//')
```

If the profile file doesn't exist, the command falls back to defaults and warns:
> "No repo profile for {REPO_NAME}. Using defaults. Create `.claude/repo-profiles/{REPO_NAME}.yaml` to silence this warning."

## Schema

See `_schema.yaml` for the full field list. Required fields:

- `name` — repo name (must match directory name)
- `type` — one of: `frontend-ui`, `backend-bff`, `backend-go`, `backend-service`, `mobile-ios`, `google-workspace-addin`
- `base_branch` — PR target branch

Optional fields:
- `ci_command` — command to run before declaring CI passes
- `lint_command`, `typecheck_command`, `test_command` — individual quality gates
- `patterns_file` — path to codebase-patterns.md (default: `.claude/codebase-patterns.md`)
- `testing_patterns_file` — path to testing-patterns.md (default: `.claude/testing-patterns.md`)
- `dev_server_url` — URL where the dev server runs (e.g. `https://localhost:3002` — record your dev server in the repo profile)
- `bff_depends_on` — list of repos this one depends on (e.g. a frontend depends on a BFF)
- `confluence_space` — Confluence space key for docs lookups

Tracker fields — **the profile is the SINGLE home for tracker config** (commands
and `/bootstrap` read transitions from here, never from settings.json):
- `tracker_system` — `jira | github | linear | none` (`none` = no-tracker lane: `/build` replaces `/clarify`+`/ticket`, transition steps no-op)
- `jira_project` — ticket project key
- `jira_transition_inprogress` / `_codereview` / `_qa` / `_done` — numeric transition ids (`_schema.yaml` documents how to look them up)

Analytics / UI fields:
- `default_feature_area` — fallback feature area for `tag-tickets.sh` when heuristics find nothing
- `ui_surface` — free-form surface label (`web | word-addin | gas-addin | swiftui`) for the ui-fidelity agent
- `visual_qa_notes` — the only honest way to verify this surface visually (dev-server URL, sideload steps, ImageRenderer recipe)
- `notes` — free-form notes about the repo (gotchas, conventions)

## Maintenance

When you add a new repo:
1. Copy `_schema.yaml` to `<new-repo>.yaml`
2. Fill in the fields you know
3. Run `/bootstrap --check` to confirm everything resolves

When a repo's base branch changes (e.g. api-bff migrates off develop-v2 — some repos use a non-default base branch, and the profile is the single source of truth for it):
1. Update just this file — no command edits needed
