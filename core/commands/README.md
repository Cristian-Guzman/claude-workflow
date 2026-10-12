# Slash Commands

Slash commands are structured workflows for Claude Code. Type `/command` in any conversation to run one.

Three commands cover a piece of work end-to-end; the rest are opt-in. Developer: `/ticket` (or `/build` with no
tracker) → `/pr` → `/learn`. SDET: `/cover` → `/pr` → `/learn`. See the repo README's *Start here*.

## Architecture

Commands live in exactly ONE place. In the default multi-repo layout that is the workspace root
(`$WORKSPACE_ROOT/.claude/commands/`); in a single-repo install (`WORKFLOW_LAYOUT=single-repo`) the repo root
IS the workspace root. Repos hold **context**, not commands.

- **Commands (single source of truth)** — `.claude/commands/`, installed flat from `core/commands/` plus the
  selected `roles/<role>/commands/`. Repo-agnostic: detect the target repo from arguments, CWD, or ask you.
- **Repo-level context** — `{repo}/.claude/`: `codebase-patterns.md`, `testing-patterns.md`, `ticket-checklist.md`,
  `pr-template.md` (plus the sdet files `selectors.md`, `test-data.md`, `environments.md`, `flaky-ledger.md`);
  optional `agents/*.md` overrides of a core agent; state files under `tickets/`, `debug/`, `builds/`, `refactors/`.
- **Role plumbing** — `.claude/learn-targets/<role>.yaml` tells `/learn` which state kinds and files each role
  owns; `.claude/workflow-manifest.json` records which roles are installed.

No repo should contain a `commands/` directory. If one appears, it's a drift/staleness bug — delete it.

> **Core pipeline principle:** `/clarify` → `/ticket` → `/verify` → `/qa` → `/pr` → `/learn` are THE per-ticket
> commands — each runs ONCE per ticket. Bugs route to `/project-debug` or get handled inside `/ticket` (§5.1b gate).
> New capabilities fold into these, they don't become new commands.

## Command Reference

### Ticket Lifecycle

| Command | Role | Args | Description |
|---------|------|------|-------------|
| `/clarify` | dev | `PROJ-XXXX` | Pre-flight analysis. Investigates the codebase to recommend file placement and patterns, only surfaces questions that code can't answer. Run BEFORE `/ticket`. |
| `/ticket` | dev | `PROJ-XXXX [ACs]` | Fetch ticket from Jira, investigate codebase, create plan, implement with state tracking. Creates `.claude/tickets/PROJ-XXXX.md` for resumability. |
| `/resume-ticket` | core | `[PROJ-XXXX or slug]` | Resume any interrupted session (ticket, debug, build, refactor, cover, triage). Scans all repos for active state files. |
| `/verify` | dev | — | Goal-backward verification: checks each AC against actual code with a computed confidence score, not "I implemented it." Uses the verifier agent if available. |
| `/pr` | core | — | Generates commit message + PR description from changes. Runs CI first. Resolves the branch's state file via the index for any kind — ticket-less `cover`/`triage` sidecars included; skips the tracker step on `ticket: null`. |
| `/review-comments` | core | `[PR#]` | Fetch and triage PR review comments. Saves valid feedback to the ticket state file so `/learn` can extract patterns from it. |
| `/learn` | core | `[repo-name] [--mine]` | Extracts lessons from delivered work (kinds from `learn-targets/*.yaml`) and the conversation; one log → cluster → lesson routine per target. `--mine` ingests `mine-history.sh` candidates for a cold start. Marks work `learned`. |

### Development

| Command | Role | Args | Description |
|---------|------|------|-------------|
| `/build` | dev | `[description]` | Implement a feature without a ticket. Investigates codebase, plans, gets approval, then builds. Creates `.claude/builds/{slug}.md`. |
| `/refactor` | dev | `[scope]` | Scans existing code against `codebase-patterns.md`, finds violations, categorizes by severity, plans fixes. Creates `.claude/refactors/{slug}.md`. |
| `/project-debug` | core | `[issue description]` | Systematic debugging with hypothesis tracking and evidence logging. Creates `.claude/debug/{slug}.md`. |

### Investigation & QA

| Command | Role | Args | Description |
|---------|------|------|-------------|
| `/qa` | core | `[PROJ-XXXX]` | Generates a manual QA guide. UI tickets get URLs/steps/edge cases; backend tickets get a runtime-evidence guide (deploy confirmation, trigger, jq/SQL assertions, logs). |
| `/ui-fidelity` | dev | `[PROJ-XXXX]` | Surface-aware design-fidelity check: translates a design reference into this surface's idiom, diffs the impl, hardens for live-data shapes, emits a manual QA checklist. Auto-invoked by `/clarify`, `/verify`, `/qa`. |
| `/screenshot` | core | `[/url-path]` | Captures a screenshot of any page in the running app for visual review. |
| `/review-pr` | core | `[PR# or branch]` | Review someone else's PR against repo conventions, codebase patterns, and quality standards. Never auto-posts comments — always awaits approval. |

### SDET (role `sdet`)

Output is **tests**, not features; the tracker record is optional output. `/cover` → `/pr` is the two-step
case; `/triage --batch` → `/pr` for a red run. Shared `/pr`, `/ci-check`, `/learn` resolve the branch's
sidecar for any `kind:`. Details, counts and the break-to-validate protocol: `roles/sdet/README.md`.

| Command | Role | Args | Description |
|---------|------|------|-------------|
| `/cover` | sdet | `[<feature> \| /route \| "GET /path" \| collection.json] [--tier smoke\|feature\|cross] [--mcp]` | Classifies the tier first, explores ≤4 routes with the repo's own Playwright, proposes scenarios, writes them, **breaks every test on purpose** and keeps only the ones that fail for the mutated reason, runs `--workers 1 --retries 0 --trace on`, grades a gate table. No argument → unscored list of routes no spec visits. Writes `tickets/cover--<slug>.md`. |
| `/triage` | sdet | `<spec>[:line] \| --batch [report.json \| --run]` | One red test behind the cause-known gate (max 2 rounds, then `/project-debug`), or a whole run clustered by shared cause (`triage-cluster.py`: helper frame → selector → endpoint/status → file). Classes: broken-test / env-or-data / flaky / real-app-bug. Writes `tickets/triage--<run-id>.md`. |
| `/log` | sdet | `[--bug] <slug \| triage--<run>:C<k>>` | Mints the tracker record FROM the work: Story/Task for a cover file, Bug for a triage cluster. Dedupe → draft → your approval → MCP → CLI → local file when `tracker_system: none`. Writes `ticket:` into the state file, never renames it. |

**The hard rule:** real application bugs keep their tests red. The only sanctioned quarantine is
`test.fail(true, 'BUG PROJ-n: …')`; `scripts/guard-test-integrity.sh` (PreToolUse) blocks `.only(` and any
`.skip/.fixme/.fail` added without a `BUG <KEY>-n` / `FLAKY FL-n` key or a deterministic flag read.
**Four numbers, always:** every `/cover` and `/triage` summary prints `passed / failed / known-failures-with-bug / skipped`;
known failures are never folded into passes (native reporters count them as expected — the command reports are authoritative).
Deferred (`/gaps` scoring, `/stabilize`, quarantine expiry, reporter, …): `docs/roadmap.md`.

### Automation & Setup

| Command | Role | Args | Description |
|---------|------|------|-------------|
| `/upstream` | core | `[--since DATE] [--dry-run] [--publish] \| --intake <dir\|inbox>` | The return path of `/learn`. Harvests the GENERIC learnings a confidential project produced into a redacted, provenance-free bundle (`scripts/upstream.py` sanitizer + leak check + secrets scan). Publishes only as an issue to a PRIVATE inbox repo; `--intake` (personal machine) merges a month of bundles into ONE public PR under a scoped git identity. |
| `/bootstrap` | core | `[--root <path>] [--dry-run]` | Adapt the installed set to this project after `install.sh`: `capability-probe.sh` → `inventory.yaml` gates via `adapt-plan.py` → KEEP / PRUNE / UN-ARCHIVE / MISSING / ORPHAN → approval → archive moves + `capability-manifest.md`. Never writes command files; no version logic (that is `scripts/release.py`, maintainer side). |
| `/update` | core | `[--check] [--upstream <path\|owner/repo>] [--dry-run]` | Installed side of versioning: changelog entries newer than your version, local core edits surfaced BEFORE any copy (harvest with `/upstream` or keep via 3-way against `.upstream-base/`), new template keys to merge by hand, then `install.sh` + `/bootstrap`. |
| `/project-context` | core | `[--full\|--incremental]` | Map dependencies across repos (multi-repo only): which FE calls which BFF, which BFF calls which backend handler. Writes `project-map.md`; it does **not** generate repo profiles. |
| `/status` | core | `[--days N]` | Cross-repo dashboard. Active work of every kind, open debug sessions, unresolved PRs, blocked items. |
| `/demo-summary` | core | `[--sprint\|--week] [--audience team\|stakeholders]` | Turns delivered work into a demo runbook: user-journey story, talking points, setup checklist, risks. |
| `/ci-check` | core | `[PR#]` | Post-`/pr`: watches CI, prompts merge when green, sets `delivered` by branch for any kind, offers the post-deploy re-check of the specs a cover file wrote, routes a red e2e job to `/triage`. |
| `/memory-lint` | core | `[--fix]` | Audits the assistant's persistent-memory directory for drift. Reports only unless `--fix`. Requires a host with a memory dir. |

## Scripts (`.claude/scripts/`, no command wraps them)

- `mine-history.sh` — merged PRs + review comments + test survey → `state/mine/<date>/candidates.json` (≥2-PR groups only; GitHub-only); input to `/learn --mine`.
- `harvest-profile.py` — aggregates-only profile of a mature install for comparison against the public defaults (`profile.schema.md`); sanitize → check fail-closed.
- `render-walkthrough.py` — state file → sanitized step table + Process Summary (derived vs recorded) + Closeout; exit 1 and no output on a leak hit.
- `verify-score.py`, `state-index-upsert.sh`, `state-index-scan.sh`, `guard-base-branch.sh`, `upstream.py`, `audit_metrics.py`, `tag-tickets.sh`, `archive-learned-tickets.sh` — called by the commands and hooks.

## State Files

```
.claude/
  tickets/PROJ-XXXX.md           # /ticket, /resume-ticket            kind: ticket
  tickets/cover--<slug>.md       # /cover   (ticket-less sidecar)     kind: cover
  tickets/triage--<run-id>.md    # /triage  (ticket-less sidecar)     kind: triage
  debug/{slug}.md                # /project-debug                     kind: debug
  builds/{slug}.md               # /build                             kind: build
  refactors/{slug}.md            # /refactor                          kind: refactor
```

Frontmatter (`kind`, `status`, `repo`, `branch`, `ticket` — `null` for sidecars, timestamps) + markdown body.
The closed `kind` and `status` vocabularies live in `state-file-schema.md`; `state-index-upsert.sh` keys
sidecars by slug and logs anything outside the vocabulary to `state/schema-drift.log`.

```
/ticket → planning → in-progress → ready-for-pr → /pr → pr-generated → /ci-check → delivered → /learn → learned
/cover  → planning → in-progress (+ env-blocked) → ready-for-pr → pr-generated → delivered → learned
/project-debug → investigating → root-cause-found → fixed
```

> `delivered` is set by `/ci-check` only, after the PR actually merges. State files are never deleted.

## Pattern Files

| File | Purpose | Used By |
|------|---------|---------|
| `CLAUDE.md` | Repo conventions, architecture, CI commands | All commands |
| `.claude/codebase-patterns-shared.md` (workspace) | Cross-repo rules — loaded before the repo file when present | `/clarify`, `/ticket`, `/build`, `/refactor` |
| `.claude/codebase-patterns.md` | Coding standards and pitfalls | `/ticket`, `/build`, `/refactor`, `/verify`, `/cover` (cross tier) |
| `.claude/testing-patterns-shared.md` (workspace) | Cross-repo test rules — loaded before the repo file when present | `/ticket`, `/verify`, `/cover` |
| `.claude/testing-patterns.md` | Test writing conventions | `/ticket`, `/build`, `/qa`, `/cover` (primary read) |
| `.claude/ticket-checklist.md` | Pre-PR gate | `/ticket`, `/pr`, `/resume-ticket`, `/verify` |
| `.claude/pr-template.md` | PR description format | `/pr` |

## Jira Access

Commands that need Jira data try in order: Atlassian MCP → `jira` CLI on PATH → ask you to paste the ticket
details. `tracker_system: none` skips all three.
