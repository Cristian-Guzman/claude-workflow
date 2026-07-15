# Slash Commands

Slash commands are structured workflows for Claude Code. Type `/command` in any conversation to run one.

## Architecture

Commands live in exactly ONE place: the workspace root. Repos hold **context**, not commands.

- **Commands (single source of truth)** — `$WORKSPACE_ROOT/.claude/commands/`. Repo-agnostic. Detect the target repo from arguments, CWD, or ask you.
- **Repo-level context** — `{repo}/.claude/`:
  - `codebase-patterns.md`, `testing-patterns.md`, `ticket-checklist.md`, `pr-template.md` — coding/testing/PR conventions per repo
  - `agents/*.md` — repo-specialized subagents (verifier, pr-branch-reviewer, a11y, ux-reviewer, etc.). Workspace commands invoke these optionally via `if {REPO_ROOT}/.claude/agents/<name>.md exists`.
  - `hooks/*.sh` — CI/git hooks specific to that repo's build
  - `scripts/*.js` — repo-specific tooling (e.g. Playwright capture)
  - `tickets/`, `debug/`, `builds/`, `refactors/`, `e2e/` — state files tracked by the state registry

No repo should contain a `commands/` directory. If one appears, it's a drift/staleness bug — delete it and rely on the workspace command.

## Command Reference

> **Archived commands (2026-07-02):** `/do`, `/retro`, `/queue`, `/docs`, `/e2e` moved to `.claude/_archived-commands/` (see `capability-manifest.md`; `/e2e` folded into `/ticket` §5.1a). Reversible: `mv` back to `commands/`.
>
> **Core pipeline principle:** `/clarify` → `/ticket` → `/verify` → `/qa` → `/pr` → `/learn` are THE per-ticket commands — each runs ONCE per ticket. Bugs route to `/project-debug` or get handled inside `/ticket` (§5.1b gate). New capabilities fold into these six, they don't become new commands.

### Ticket Lifecycle

These commands form a pipeline: `/clarify` -> `/ticket` -> `/verify` -> `/pr` -> `/review-comments` -> `/learn`

| Command | Args | Description |
|---------|------|-------------|
| `/clarify` | `PROJ-XXXX` | Pre-flight analysis. Investigates the codebase to recommend file placement and patterns, only surfaces questions that code can't answer. Run BEFORE `/ticket`. |
| `/ticket` | `PROJ-XXXX [ACs]` | Fetch ticket from Jira, investigate codebase, create plan, implement with state tracking. Creates `.claude/tickets/PROJ-XXXX.md` for resumability. |
| `/resume-ticket` | `[PROJ-XXXX or slug]` | Resume any interrupted session (ticket, debug, build, refactor, e2e). Scans all repos for active state files. Renamed from `/resume` to avoid collision with Claude Code's built-in `/resume` (conversation history). |
| `/verify` | — | Goal-backward verification: checks each AC against actual code, not just "I implemented it." Uses the verifier agent if available. |
| `/pr` | — | Generates commit message + PR description from changes. Runs CI first. Suggests branch names if on main/develop. |
| `/review-comments` | `[PR#]` | Fetch and triage PR review comments. Saves valid feedback to the ticket state file so `/learn` can extract patterns from it. |
| `/learn` | `[repo-name] or [--session]` | Extracts lessons from delivered tickets' retrospectives and updates `codebase-patterns.md` / `testing-patterns.md`. Marks tickets as `learned`. |

### Development

| Command | Args | Description |
|---------|------|-------------|
| `/build` | `[description]` | Implement a feature without a Jira ticket. Investigates codebase, plans, gets approval, then builds. Creates `.claude/builds/{slug}.md`. |
| `/refactor` | `[scope]` | Scans existing code against `codebase-patterns.md`, finds violations, categorizes by severity, plans fixes. Creates `.claude/refactors/{slug}.md`. |
| `/project-debug` | `[issue description]` | Systematic debugging with hypothesis tracking and evidence logging. Creates `.claude/debug/{slug}.md`. |

### Investigation & QA

| Command | Args | Description |
|---------|------|-------------|
| `/qa` | `[PROJ-XXXX]` | Generates a manual QA guide. Auto-detects surface: UI tickets get URLs/steps/edge cases (+ optional Playwright/preview harness); backend tickets get a runtime-evidence guide (deploy confirmation, trigger, jq/SQL assertions, logs). |
| `/ui-fidelity` | `[PROJ-XXXX]` | Surface-aware design-fidelity check (Word add-in / GDocs / iOS / web): translates a design reference into this surface's idiom, diffs the impl, hardens for live-data shapes, and emits a per-surface manual QA checklist. Auto-invoked by `/clarify` (contract), `/verify` (visual_compare), `/qa` (checklist). |
| `/screenshot` | `[/url-path]` | Captures a screenshot of any page in the running app for visual review. |
| `/review-pr` | `[PR# or branch]` | Review someone else's PR against repo conventions, codebase patterns, and quality standards. Never auto-posts comments — always awaits approval. |

### Automation & Setup

| Command | Args | Description |
|---------|------|-------------|
| `/bootstrap` | `[--bump minor|patch] [--check]` | Two modes: set up the .claude system in a new project, OR manage the workflow version (propagates to all commands, updates changelog, refreshes hash ledger). |
| `/project-context` | `[--full|--incremental]` | Map dependencies across all repos: which FE calls which BFF, which BFF calls which Go lambda, business-logic signals. Cached for speed. |
| `/status` | `[--days N]` | Cross-repo dashboard. Active tickets, open debug sessions, unresolved PRs, blocked items. Defaults to last 7 days. |
| `/demo-summary` | `[--sprint\|--week] [--audience team\|stakeholders] [--artifact]` | Turns delivered work into a demo runbook: user-journey story, talking points, setup checklist, risks, ownership guard. |
| `/ci-check` | `[PR#]` | Post-`/pr`: watches CI, prompts merge when green, auto-runs `/learn` after merge. Closes the pipeline loop. |

## State Files

Commands that track progress create state files in `.claude/` subdirectories:

```
.claude/
  tickets/PROJ-XXXX.md      # /ticket, /resume-ticket
  debug/{slug}.md           # /project-debug
  builds/{slug}.md          # /build
  refactors/{slug}.md       # /refactor
  e2e/{slug}.md             # /e2e
```

State files use YAML frontmatter (`status`, `repo`, `branch`, timestamps) and markdown body (plan, progress, files modified, decisions). `/resume-ticket` reads these to continue exactly where work stopped.

### State Lifecycle

```
/ticket → planning → in-progress → ready-for-pr → /pr → pr-generated → /ci-check → delivered → /learn → learned
/build  → planning → in-progress → ready-for-pr → pr-generated → delivered
/project-debug  → investigating → root-cause-found → fixed
```

> `delivered` is set by `/ci-check` only, after the PR actually merges — never by `/ticket` or `/pr`. State files are never deleted.

## How Commands Connect

```
/clarify PROJ-XXXX   (pre-flight: resolve ambiguity before starting)
    |
    v
/ticket PROJ-XXXX
    |
    v
[investigate → plan → implement → test]
    |
    v
/verify          (check ACs against code)
    |
    v
/pr              (CI + commit msg + PR desc)
    |
    v
[merge PR]
    |
    v
/review-comments (triage reviewer feedback into state file)
    |
    v
/learn           (extract patterns from retro + review feedback)
```

Side workflows:
- `/project-debug` can be started anytime something breaks
- `/build` is for work without a Jira ticket
- `/refactor` is for cleaning up existing code against patterns
- `/clarify` investigates related tickets automatically (Step 1.5 absorbed the former `/related`)
- `/qa` generates manual test guides after implementation
- `/resume-ticket` picks up any interrupted session
- `/review-pr` is for reviewing someone else's PR (never auto-posts)
- security scanning is always-on inside `/verify` (§6 quick-scan — absorbed the deleted `/security`)

## Pattern Files

Commands load these files (when available) to enforce conventions:

| File | Purpose | Used By |
|------|---------|---------|
| `CLAUDE.md` | Repo conventions, architecture, CI commands | All commands |
| `.claude/codebase-patterns.md` | Coding standards and pitfalls | `/ticket`, `/build`, `/refactor`, `/verify` |
| `.claude/testing-patterns.md` | Test writing conventions | `/ticket`, `/build`, `/e2e`, `/qa` |
| `.claude/ticket-checklist.md` | Full ticket workflow (5 phases) | `/ticket`, `/pr`, `/resume-ticket`, `/verify` |
| `.claude/pr-template.md` | PR description format | `/pr` |

## Jira Access

Commands that need Jira data try in order:
1. `jira` CLI (assumed on PATH)
2. Ask you to paste ticket details

## Repo Context Files

**No repo has a `commands/` directory** — commands live only at the workspace root (addin-fe's 12 repo-level commands were deleted in v0.1.1). What repos DO carry, as of 2026-06-12 (example inventory — replace with your own repos):

| Repo | CLAUDE.md | codebase-patterns | testing-patterns | ticket-checklist | pr-template | agents |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| addin-fe | ✓ | ✓ (+ index) | ✓ | ✓ | ✓ | 6 |
| api-bff | ✓ | ✓ | ✓ | ✓ | — | — |
| web-app | ✓ | ✓ | ✓ | ✓ | — | — |
| ios-app | ✓ | ✓ | ✓ | ✓ | — | — |
| gdocs-addin | ✓ | ✓ | ✓ | — | — | — |
| backend-services | ✓ | ✓ | — | — | — | 3 skills |
| shared-go-lib | ✓ | ✓ | ✓ | ✓ | — | — |
| mail-service | ✓ | ✓ | ✓ | ✓ | — | — |
| billing-service | ✓ | ✓ | ✓ | ✓ | — | — |
| chat-service | ✓ | ✓ | — | ✓ | — | — |
| legacy-editor | ✓ | — | — | ✓ | — | — |

Root-level commands work in all repos and load whichever of these context files exist (every reference is `if exists`-guarded).
