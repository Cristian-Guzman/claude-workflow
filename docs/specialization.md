# Specializing the workflow to a new project

The commands are project-agnostic; the intelligence lives in a small set of
project-owned files. This guide is ordered by payoff — do step 1 and 2 on day one,
let the rest accumulate. The three-command loop that drives it is in the README's
*Start here*; what the files look like after real use is in `docs/examples/`.

## Day one (15 minutes)

### 1. Repo profile — `.claude/repo-profiles/<repo>.yaml`

Copy `_schema.yaml` to `<repo>.yaml` by hand (no command generates it) and fill:

- `base_branch` — where feature branches fork from and PRs target. **The single
  highest-value line in the whole system**: it drives branch creation in /ticket,
  PR targets in /pr, diff scoping in /verify and /review-pr, and the
  guard-base-branch hook.
- `ci_command` — what /ticket runs before declaring done (`yarn ci`, `make test`, ...).
- `test_command`, `lint_command` — if different from CI.
- `dev_server` — URL + start command; /qa and /screenshot use it.

### 2. Settings — `.claude/settings.json`

The template ships with the hooks wired (base-branch guard, state index) and
generic permissions. Adjust:

- Layout: installing into a single product repo (not a multi-repo workspace)?
  Set `"env": {"WORKFLOW_LAYOUT": "single-repo"}` so the branch guard treats
  the root as a product repo.
- Ticket system: if Jira, confirm the Atlassian MCP or `jira` CLI works, then
  record `tracker_system` and the numeric `jira_transition_*` ids in the repo
  profile (`.claude/repo-profiles/<repo>.yaml` — the single home for tracker
  config; look ids up with `getTransitionsForJiraIssue` or `jira issue move
  <ISSUE> --debug`). If no ticket system, set `tracker_system: none` and use
  `/build` instead of `/ticket`.
- Permissions: add your package manager / build tools to the allowlist so command
  runs don't prompt constantly.

## First week

### 3. `codebase-patterns.md` — seed 2-3 entries, then let /learn own it

The most-read file (`codebase-patterns` is named ~120 times across 14 command files). Good first entries:

- Where does a new feature's code go? (folder structure, feature-local vs shared)
- How is state managed? (store pattern, hooks, DI, ...)
- How are errors handled / logged?

Don't write an essay. One entry = name + 3-5 lines + a `file:line` example.
After each merged ticket, `/learn` proposes new entries from what actually happened
— accept the ones that will recur. Patterns need a second occurrence to be real;
resist adding one-off observations.

Two ways to shorten the cold start: `install.sh --stack <flavor>` appends a stack
seed pack, and on a repo with ≥10 merged PRs `scripts/mine-history.sh` then
`/learn --mine` lands only what recurred in 2+ PRs. Both are tagged (`seed-pack:`,
`mined:`) and `/learn` retires them if nothing ever cites them.

### 4. `testing-patterns.md`

Framework, test file placement (`__tests__/` vs co-located vs `*_test.go`), the
mock/fixture idiom, and any "always/never" rules (e.g. "never mock the store,
mock the API layer"). /ticket reads this before writing tests; /verify checks
tests exist for new behavior.

### 5. `ticket-checklist.md`

The pre-PR gate the pr-branch-reviewer agent enforces mechanically. Keep it short
and binary (checkable). Typical: lint clean, tests pass, no leftover debug logging,
no unrelated formatting churn, branch named `feature|fix/PROJ-XXXX-desc`.

### SDET role

`install.sh --role sdet` seeds four more project-owned files — `selectors.md`
(selector priority and bans), `test-data.md`, `environments.md`, `flaky-ledger.md`
(log-only) — and installs `learn-targets/sdet.yaml`, which tells `/learn` to scan
`cover`/`triage` sidecars and which of those files each lesson kind grows. Fill
`selectors.md ## Conventions` first; `/cover` reads it before writing a test.

## Grows by itself — do not seed

| File | Created by | Purpose |
|---|---|---|
| `process-ledger.md` | /learn | "how we work here" process lessons |
| `ui-fidelity-ledger.md` | /learn (UI repos) | recurring visual-correction classes, per surface |
| `tickets/<ID>.md`, `tickets/<kind>--<slug>.md` | /ticket, /cover, /triage | per-piece-of-work state: events, progress, decisions |
| `debug/*.md` | /project-debug | persistent debug session state |
| `qa/*.md` | /qa | generated QA guides |
| `workflow-manifest.json` | install.sh | which roles are installed (install-owned, tracked) |
| `learn-targets/<role>.yaml` | install.sh | what /learn scans per role (upstream-owned, refreshed) |
| `.upstream-prior/<date>/` | install.sh (first run on a pre-0.7.0 install) | your pre-upgrade files; local, delete after review | On later upgrades, any core file you edited locally (and the old baseline) is copied there too before the refresh, so local edits are never lost.
| `_archived-commands/` | install.sh (role dropped / command retired), /bootstrap (gate false) | archived, never deleted |

## Power features (when you need them)

- **Agent overrides** — drop a repo-specific `agents/verifier.md` or
  `agents/pr-branch-reviewer.md` into a repo's `.claude/agents/` and it takes
  precedence over the workspace one (useful when one repo has stricter rules).
- **`codebase-patterns-index.md`** — when the patterns file outgrows ~300 lines,
  split by domain and keep an index so commands load only the relevant slice.
- **Multi-repo routing** — `routing.md` + `repo-profiles/feature-areas.yaml` let
  /clarify infer which repo a ticket touches from its text.

## The flywheel

The system is deliberately a loop: work produces state files, `/learn` distills
state + conversation into patterns, patterns make the next `/ticket` better.
A new project feels generic for the first few tickets and tunes itself only
**if** `/learn` runs after each one — that habit is the whole trick. For the shape
after 20 tickets, and how real files drift from it, see
`docs/examples/codebase-patterns.after-20-tickets.md` and its closing sidebar.
