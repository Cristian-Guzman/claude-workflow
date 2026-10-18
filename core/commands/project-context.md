---
name: project-context
version: 0.10.4
description: Map dependencies across all repos — which FE calls which BFF, which BFF calls which Go lambda, plus business-logic signals. Also runs a sprint ticket-activity pass that writes team-ticket dossiers (teammates' work you didn't touch) for cross-team learning. Incremental cache after first run.
argument-hint: "[--full | --incremental | --stale] [--weeks N | --month | --days N] [--no-activity]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Agent
  - Write
  - Edit
  - AskUserQuestion
---
> **Model floor: sonnet** — see inventory.yaml. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
Build a connection map across every repo in the workspace. Unlike `/clarify` (single-ticket scope) or `/related` (single Jira graph), this command answers structural questions:

- Which BFF routes does the frontend actually call?
- Which Go lambdas does the BFF proxy to?
- What business domains live in which repos?
- What has been added, removed, or renamed since the last scan?
- Where are the loose ends — FE calls to endpoints the BFF no longer exposes, duplicated utilities, drift between TS types and Go handler responses?

**First run is expensive** (full scan of every repo). **Subsequent runs are fast** — only re-scans repos whose HEAD hash changed.

Output: `$WORKSPACE_ROOT/.claude/project-map.md` — a living document all other commands (especially `/clarify`, `/ticket`, `/status`) can read.
</objective>

<process>

## 0. Mode Selection

Parse $ARGUMENTS:
- `--full` — ignore cache, rescan everything. Slow but thorough.
- `--incremental` (default) — only rescan repos whose git HEAD hash changed since the last scan.
- `--stale` — only report staleness; don't rescan. Fast sanity check.

**Activity-pass window** (Step 7 — the sprint ticket-activity / team-dossier pass):
- default — **14 days** (one sprint)
- `--weeks N` → N×7 days · `--month` → 30 days · `--days N` → N days
- `--no-activity` — skip Step 7 entirely (structural scan only)

The structural scan (Steps 1–6) and the activity pass (Step 7) are independent: the structural scan is HEAD-cached and all-time; the activity pass is sprint-windowed and runs on `--full`/`--incremental` (skipped on `--stale` and with `--no-activity`).

If no prior scan exists (no `project-map.md`), treat as `--full`.

## 1. Load Prior Map (if any)

Check for existing artifacts:
```bash
MAP=$WORKSPACE_ROOT/.claude/project-map.md
CACHE=$WORKSPACE_ROOT/.claude/project-map-cache.json
```

The cache is a JSON file with per-repo metadata — HEAD hashes, last-scanned timestamps, file counts. It's the key to incremental scanning:

```json
{
  "scanned_at": "2026-04-17T10:00:00Z",
  "repos": {
    "addin-fe":   { "head": "abc123...", "scanned_at": "2026-04-17T10:00:00Z", "files": 1234 },
    "api-bff":    { "head": "def456...", "scanned_at": "2026-04-17T10:00:00Z", "files": 567 },
    "backend-services": { "head": "ghi789...", "scanned_at": "2026-04-17T10:00:00Z", "files": 210 }
  }
}
```

## 2. Detect What Needs Rescanning

For each repo in `$WORKSPACE_ROOT/*/`:

```bash
for dir in $WORKSPACE_ROOT/*/; do
  repo=$(basename "$dir")
  [ -d "$dir/.git" ] || continue
  current_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  # Compare current_head against cache[repo].head
  # If different → mark for rescan
  # If same → keep cached entry
done
```

In `--full` mode, rescan everything.
In `--stale` mode, just report which repos would be rescanned and stop.

## 3. Per-Repo Deep Scan (parallelizable)

For each repo that needs rescanning, spawn work **in parallel** — each repo is independent. Use general-purpose subagents (one per repo); there is no dedicated repo-mapper agent. Collect these signals:

### 3a. Repo profile
Read `.claude/repo-profiles/{repo}.yaml` (if exists) for declared type and dependencies.

### 3b. API surface
- **Backend repos** (Go/Node): list exported handler paths
  ```bash
  # Go: find `http.HandleFunc`, `router.GET`, `mux.HandleFunc`, `echo.GET`, chi
  grep -rn 'HandleFunc\|router\.\(GET\|POST\|PUT\|DELETE\)\|\.Handle(' {dir}/internal {dir}/lambdas {dir}/cmd 2>/dev/null
  # Node BFF: look at src/routes/*
  grep -rn 'router\.\(get\|post\|put\|delete\|patch\)\|app\.\(get\|post\)' {dir}/src 2>/dev/null
  ```
- **Frontend repos**: find API call sites
  ```bash
  grep -rEn 'useQuery\|useMutation\|fetch\("/bff/' {dir}/app 2>/dev/null
  ```

### 3c. Type/schema exports
- **Go**: public types in `internal/` and `pkg/`
- **Node BFF**: types in `src/types/`, `src/schemas/`
- **Frontend**: types in `app/_lib/*/types.ts`

### 3d. DB / persistence signals
- **Go**: DynamoDB table names (grep `dynamodb.*Table`, `TableName:`), SQL files
- **Node**: ORM models, migration directories
- **Confluence cache**: reference to table names in `$WORKSPACE_ROOT/specs/confluence/`

### 3e. Cross-repo calls (connection evidence)
- **FE → BFF**: map each `/bff/api/*` call-site to the BFF's route file
- **BFF → Go**: map each upstream URL the BFF calls to a Go handler
- **iOS → BFF**: mobile API calls
- **Docs reference**: grep swaggers in `.claude/api-reference/*.json` for each endpoint

### 3f. What's new since last scan
If this repo had a cached entry, diff:
```bash
git -C {dir} diff --name-status <cached_head> HEAD
```
Classify additions as: new routes, new types, new components, removed files, renames.

### 3g. Business-logic signals (best-effort)
These are approximations — a pure function tells you nothing, but patterns do:
- Handler names and route paths hint at domain language
- Error messages and log strings hint at constraints
- DB table names anchor the domain
- Ticket state files (`.claude/tickets/*.md`) explicitly mention business concepts

Pull the 20 most-common nouns/verbs across the repo's route names, handler names, and type names. Those are your business-logic signals.

## 4. Build the Connection Graph

After all per-repo scans, cross-reference:

### Edges: FE → BFF
For every `/bff/api/{path}` call in a frontend, find the matching route in api-bff. Flag unmatched:
> "FE calls `/bff/api/orders/:id/duplicate` but no such route found in api-bff. Stale call? Pending BFF work? Wrong URL?"

### Edges: BFF → Go
For every upstream URL the BFF calls, find the matching Go handler. Flag unmatched:
> "BFF proxies to `https://services.internal/items/:id/versions` but no backend-services handler matches. Deleted? Renamed? Missing service?"

### Edges: cross-domain type drift
For shared concepts (Order, Item, Document), compare type definitions:
- TS interface in addin-fe
- Zod schema in api-bff
- Go struct in backend-services
Flag field-level drift (snake_case vs camelCase mismatches, nullability differences, type shape drift).

### Edges: duplicated utilities
Find utilities with similar signatures across repos. Candidates for extraction into shared packages.

## 5. Write the Map

Overwrite `$WORKSPACE_ROOT/.claude/project-map.md`:

```markdown
---
scanned_at: YYYY-MM-DDTHH:MM:SSZ
mode: full | incremental
repos_scanned: 3 of 9
workflow_version: {current from workflow-version.md}
---

# Project Map

## Repos

### addin-fe (frontend-ui)
HEAD: abc1234  |  Last scan: 2026-04-17T10:00Z  |  Files: 1234
Calls: api-bff (237 endpoints), Confluence links (42)
Routes owned: n/a (frontend)
Top domain terms: order, item, document, review, contract

### api-bff (backend-bff)
HEAD: def5678  |  Last scan: 2026-04-17T10:00Z  |  Files: 567
Exposes: 89 routes
Depends on: backend-services (54 upstream calls)
Top domain terms: orders-v2, item, version, pin, document

...

## Dependency Graph

addin-fe ──(237 calls)──▶ api-bff ──(54 calls)──▶ backend-services
ios-app ──(18 calls)──▶ api-bff
api-bff ──────────────────(8 calls)────────────────▶ billing-service

## Loose Ends

### FE calls with no BFF route (potential stale calls)
- addin-fe: `/bff/api/orders/:id/duplicate` — no match in api-bff

### BFF upstream calls with no Go handler
- api-bff → `https://services.internal/items/:id/versions` — no match

### Type drift across repos
- `Order.isPublic` (FE) vs `Order.is_public` (BFF) vs `Order.IsPublic` (Go) — casing drift
- `Item.onMissing` — string in FE, object in Go — needs normalizer

### Duplicated utilities
- `formatDate` implementations in addin-fe, api-bff, billing-service — consider extracting to a shared utility library

## New Since Last Scan (incremental mode only)

### api-bff (2026-04-15 → 2026-04-17)
+ src/routes/items-v2/delete.ts
~ src/schemas/order.ts (added `archivedAt` field)

### backend-services (2026-04-16 → 2026-04-17)
+ lambdas/ms-orders/order/archive-order/main.go

## Business-Logic Snapshot

### Orders V2 domain
Present in: addin-fe, api-bff, backend-services
Key concepts: order, item, version, pin, onFound, onMissing
Confluence reference: the domain wiki page
Open questions (from command-proposals.md): snake_case vs camelCase attribute bug

### Billing domain
Present in: billing-service (primary), api-bff (proxy routes)
Key concepts: subscription, invoice, credit, trial
Stripe integration: yes

...
```

## 5b. Refresh stack-connections.md domain tables (backend repos only)

Run this step ONLY if `api-bff` or `backend-services` was re-scanned. Skip on `--stale`. Skip if `$WORKSPACE_ROOT/.claude/stack-connections.md` doesn't exist (it was built during the backend-docs-investigation initiative and is the structural FE↔BFF↔Go map `/clarify` relies on).

The file has marked auto-regenerated regions. Everything between `<!-- AUTO:* START -->` and `<!-- AUTO:* END -->` is owned by this command. Everything outside is human-curated and must NEVER be touched.

### 5b.1 Domain registry

The marker IDs follow this convention: `AUTO:<DOMAIN>_<KIND>` where:
- `<DOMAIN>` ∈ `ORDERS_V2 | INVENTORY | BILLING | DOCUMENTS | COMMON` (example registry — use your own domain names)
- `<KIND>` ∈ `ENDPOINTS` (the BFF Service.method → Go lambda table) or `ORPHANS` (Go lambdas without BFF caller, plus optional BFF methods without Go lambda)

Example marked domains in `stack-connections.md`: `ORDERS_V2`, `INVENTORY`, `BILLING`. To add a new domain, mark its endpoint table with `<!-- AUTO:<NEW_DOMAIN>_ENDPOINTS START -->` / `END` first, then run this step.

### 5b.2 Per-domain refresh algorithm

For each marked domain, regenerate the endpoint table from live code:

**Orders V2 (`ORDERS_V2`)**
- BFF Service: `api-bff/src/rest-v2/services/OrdersService.ts`
- Go lambda group: `backend-services/lambdas/ms-orders/order/`
- Method extraction: parse the Service file for `public async <name>(...): Promise<...>` declarations. For each method:
  - URL template = the literal passed to `this.get/post/patch/put/del({ url: ... })`; the base is `${this.apiV1}` = `/orders/v1`
  - HTTP verb = the Service base method called (`get`/`post`/`patch`/`put`/`del`)
- Lambda matching: for each Service method's URL path, walk the lambda group dir and match by URL suffix → lambda folder name. Convention: kebab-case operation. Examples: `/orders` POST → `create-order`, `/orders/:id` PATCH → `update-order`. If no obvious match, mark `**NO lambda — orphan**` (human review).
- Composite/private methods that don't map to a single lambda: include with a parenthetical note (see the `presignAndUpload` row pattern).
- Orphan detection: list all sub-lambdas under the Go group dir; any that didn't match a Service method goes into `AUTO:ORDERS_V2_ORPHANS`.

**Inventory (`INVENTORY`)**
- BFF Service: `api-bff/src/rest-v2/services/InventoryService.ts`
- Go lambda group: `backend-services/lambdas/ms-orders/inventory/`
- Same algorithm.

**Billing (`BILLING`)**
- BFF Service: `api-bff/src/rest-v2/services/BillingService.ts` + `PresignService.ts`
- Go lambda group: `backend-services/lambdas/billing/`
- Plus `PresignService` → `common/create-presigned-url` (cross-group; preserve manually if encountered).

### 5b.3 Replace between markers (atomic write)

For each refreshed table:
```bash
# Pseudo — actual implementation uses sed -i or python read/write to be safe
awk -v start="<!-- AUTO:${DOMAIN}_ENDPOINTS START" \
    -v end="<!-- AUTO:${DOMAIN}_ENDPOINTS END" \
    'NR==FNR{a=a $0 ORS; next} /start/{print a; skip=1} /end/{skip=0} !skip' \
    new_table.md stack-connections.md > tmp && mv tmp stack-connections.md
```

In practice: read `stack-connections.md`, locate the start+end markers, splice the regenerated content between them, write back. Markers themselves stay intact.

### 5b.4 What to flag in the summary

After refresh, compute the deltas vs. the prior table content (you can diff against the stored last-scan output or git-blame the table block):

- **New lambda in Go that has no BFF Service method** → "🆕 Go lambda `ms-orders/order/<verb>-order` exists but no BFF method calls it. Add to `OrdersService.ts` or document as direct-invoke / mobile-only / legacy."
- **New BFF Service method with no Go lambda** → "🆕 BFF `OrdersService.<method>` calls `/orders/v1/<path>` but no matching lambda exists. Add the lambda or fix the URL."
- **Renamed lambda or BFF method** → "🔁 `<old>` → `<new>` detected; verify type-drift notes downstream."
- **HTTP verb change on existing endpoint** → "⚠ `OrdersService.createOverride` changed from POST to PUT. Confirm Go lambda was updated too."

Surface these as a "## Stack-connection deltas" section in the user-facing summary (Step 8), separately from the regular cross-repo edges.

### 5b.5 Hands-off invariants

- NEVER touch content outside `AUTO:*` markers — that's curated narrative + recipes.
- NEVER remove a marker pair, even if a domain currently has zero endpoints. Empty table between markers is fine.
- If a Service file or lambda group dir doesn't exist (domain was removed), preserve the markers but write `<!-- domain not present in current scan -->` between them — don't delete the section.
- The "Adding a new operation" recipes in each domain are HUMAN-CURATED. Don't paraphrase or regenerate them.

### 5b.6 Obsidian wiki-link convention

The workspace `.claude/` folder IS an Obsidian vault. When this command writes ANY content (project-map.md sections, stack-connections.md auto regions, the user-facing summary), follow the existing vault convention so the graph view stays useful:

- **Ticket IDs**: every `PROJ-XXXX` reference must be wrapped as `[[PROJ-XXXX]]`. Applies in tables, prose, summary blocks, and the "## Stack-connection deltas" section. The retrofit pass already covered the historical files; from now on, any new write uses this format.
- **Cross-references to other vault files** (`project-map.md`, `stack-connections.md`, `business-context.md`, etc.): when referencing them in prose, prefer `[[filename.md]]` over absolute paths. Absolute paths are fine for tool-execution context (`Read` operations), but in narrative prose use wiki-links.
- **Don't touch wiki-links inside fenced code blocks** — Obsidian doesn't render them there, and they clutter copy-paste. The retrofit script left them as-is.
- **Don't wrap repo-internal file paths with line numbers** (e.g. `lambdas/ms-orders/order/create-order/main.go:21-40`) — those are code-navigation references for the IDE, not graph nodes.

The negative-lookahead/lookbehind regex used in the retrofit (`(?<!\[\[)PROJ-\d+(?!\]\])`) is the canonical wrap pattern — apply it idempotently on every write.

## 6. Update the JSON Cache

Write `$WORKSPACE_ROOT/.claude/project-map-cache.json` with current per-repo HEAD hashes so the next `--incremental` run is fast.

## 7. Sprint Ticket-Activity Pass & Team-Ticket Dossiers

A different question than the structural scan above: **across the current sprint window, what did the team work on, how did it go, and what can we learn from the tickets that aren't yours?** This pass is **read-only with respect to all existing state** — `index.json` and per-repo `.claude/tickets/` are never touched. Its only output is the dossier folder + a summary block.

Skip this whole section on `--stale` or `--no-activity`.

### 7.0 Window

Default **14 days**. Override from `$ARGUMENTS`: `--weeks N` → N×7, `--month` → 30, `--days N` → N. Resolve `WINDOW_START` (a date) and `TODAY`; all mining below is scoped to commits/PRs on or after `WINDOW_START`.

### 7.1 Repos in scope (hard exclusions)

Mine only your org's team repos. **Always exclude:**
- Vendored/third-party repos (e.g. a vendored tooling repo with 1500+ commits, 90+ authors, **zero** PROJ ids); including one destroys every aggregate.
- Docs-only or empty repos with no PROJ commit convention (e.g. `product-specifications`, shared template repos).

A repo qualifies if `git -C "$dir" remote get-url origin` is under `github.com[:/]your-org/` **and** it shows ≥1 `PROJ-\d+` commit in the window. Skip silently otherwise.

### 7.2 Collect activity per ticket (parallelizable — one subagent per repo)

**Commits** (all refs, window-scoped):
```bash
git -C "$dir" log --since="$WINDOW_START" --all --pretty='%H|%ae|%s' 2>/dev/null
```
Extract `PROJ-\d+` (case-insensitive) from the subject. The convention is `fix(PROJ-NNNN):` / `feat(PROJ-NNNN):` (dominant), `fix/PROJ-NNNN`, bare `PROJ-NNNN`, `[PROJ-NNNN]`. Per ticket capture: commit count, distinct author-emails. (Subject only — body trailers aren't scanned.)

**PRs** (`--search` with `updated:` — not `created:` — so PRs opened before the window but re-pushed/re-reviewed in it are still caught, and it dodges the `--limit 200` truncation):
```bash
gh pr list -R your-org/$repo --state all \
  --search "updated:>=$WINDOW_START" --limit 400 \
  --json number,title,headRefName,author,state,createdAt,mergedAt,closedAt,reviewDecision
```
Extract the ticket id from `headRefName` first, then `title`. Per ticket capture: PR numbers, states, `reviewDecision`, closed-unmerged count. **`CHANGES_REQUESTED` is the review-quality signal — inline diff comments are 0 org-wide, do NOT try to use them.**

**Build the ticket→activity map, then dedupe cross-repo:** a ticket in >1 repo is **one** logical ticket spanning repos (`repos: [...]`), not N tickets. Cross-repo is **context, never a penalty** — full-stack work (BFF+FE+Go) legitimately needs one PR per repo.

### 7.3 Jira join (outcome + bounce signal)

MCP Atlassian is not running — use the `jira` CLI + REST. For the distinct ticket set:

**Sprint snapshot** (status, assignee, story points):
```bash
jira issue list -q "project = PROJ AND sprint in openSprints()" --plain \
  --columns key,status,assignee,summary
```
Story points live in a Jira-instance-specific custom field (e.g. `customfield_10080` — look up your instance's field id; null if unestimated); fetch via REST when needed. Null assignee → `unassigned`.

**Status timeline + QA bounces:** compute per **[[ticket-outcome-spec.md]] → Outcome** — the canonical Jira-changelog recipe + `qa_bounces` formula, shared with `/learn` so the math never drifts between teammate dossiers and your own Closeouts. These tickets are **teammates'**, so the derived lessons are inferred (§7.6).

### 7.4 Mine vs not-mine

A ticket is **yours** if ANY of: a state file exists at `{repo}/.claude/tickets/PROJ-XXXX.md` or `{workspace}/.claude/tickets/PROJ-XXXX.md` (authoritative); OR the majority of its in-window commits are authored by your git author email (`git config user.email`); OR its Jira assignee is you. Yours keep flowing through `/tickets` + `/learn` — **no dossier**. Everything else is a **teammate ticket → dossier** (§7.6).

### 7.5 Health score (rate the work, never the person)

Compute per **[[ticket-outcome-spec.md]] → Health score** — the canonical additive model + bands, shared with `/learn` so teammate dossiers and your own Closeouts score identically (bar the window-only cycle-time component, which only the windowed caller applies). Key guardrails it encodes: QA bounces + `CHANGES_REQUESTED` dominate; FE/Add-in multi-PR scores **0** (micro-PR is the norm); cross-repo is context, not a penalty. The "why" line must name the signals that scored.

### 7.6 Write the dossier (incremental, non-destructive)

For each teammate ticket with window activity, write/update `{workspace}/.claude/team-tickets/PROJ-XXXX.md` — sibling to your `tickets/`, **never mixed**. Everything between `<!-- AUTO:FACTS START -->` / `<!-- AUTO:FACTS END -->` is regenerated each run; the `## Notes (human)` section below is **never touched** (same convention as `stack-connections.md`):

```markdown
---
ticket: PROJ-XXXX
assignee: {displayName | unassigned}
sprint: {sprint name}
jira_status: {current status}
repos: [api-bff, addin-fe]
health: 🔴 rough            # 🟢 healthy | 🟠 watch | 🔴 rough
qa_bounces: 1
cross_repo: true
first_seen: {date}          # preserved across runs
last_activity: {date}
---

# [[PROJ-XXXX]] — {summary}

<!-- AUTO:FACTS START -->
## Activity
- PRs: api-bff#400, #403, #404 · addin-fe#867, #868  (cross-repo, deduped)
- Commits: 14 across 2 authors
- reviewDecision: CHANGES_REQUESTED (api-bff#403)

## Outcome
- Status timeline: To Do → In Progress → Code Review → QA → Code Review → QA  (entered QA 2× → 1 bounce)
- Current: QA · Story points: 3

## Health
🔴 rough (score 5): +3 (1 QA bounce) +2 (CHANGES_REQUESTED). Multi-PR not penalized — within FE norm; cross-repo is context, 0 points.

## Lessons
- ⚠ inferred — verify: re-entered QA after the BFF contract PR landed; possible FE/BFF shape drift. Cross-check against the type-drift loose ends in project-map.md.
<!-- AUTO:FACTS END -->

## Notes (human)
_Anything written here is preserved across runs._
```

**Lessons rules (facts + flagged inferences):** always list the structured facts. Add an auto-observation **only when a signal is strong** (`qa_bounces ≥ 2`, `CHANGES_REQUESTED`, or backend multi-PR), and **always prefix it `⚠ inferred — verify`** — you have no firsthand context on a teammate's ticket, so never assert cause as fact. No strong signal → facts only, empty Notes block.

**Incremental:** skip rewriting a dossier whose ticket had no new commit / PR / status-change since `activity.tickets[PROJ-XXXX]` in the cache (§7.7). Wrap every `PROJ-\d+` in dossier prose (and the title) as `[[PROJ-XXXX]]` — but never inside fenced code blocks.

### 7.7 Activity cache

Extend `project-map-cache.json` (this command's own cache — **not** `index.json`) with an `activity` block so the next run is incremental:
```json
"activity": {
  "scanned_at": "…",
  "window_days": 14,
  "tickets": { "PROJ-XXXX": { "last_commit": "sha", "last_pr": 404, "jira_status": "QA", "qa_bounces": 2 } }
}
```

## 8. Summary for the User

```
✓ Scanned {N} of {total} repos ({skipped} unchanged, skipped)
✓ {E} cross-repo edges mapped
⚠ {L} loose ends detected (see ## Loose Ends in project-map.md)
🔄 {NEW} changes since last scan

## Stack-connection deltas (backend repos only — Step 5b)
🆕 {NEW_LAMBDAS} new Go lambdas (lacking BFF caller)
🆕 {NEW_BFF_METHODS} new BFF Service methods (lacking Go lambda)
🔁 {RENAMED} renamed endpoints
⚠ {VERB_CHANGES} HTTP verb changes on existing endpoints
(stack-connections.md tables refreshed: {DOMAIN_LIST})

## Sprint ticket-activity (Step 7 — window: {WINDOW_DAYS}d)
📋 {D} team-ticket dossiers written/updated in .claude/team-tickets/ (teammates' work)
🔴 {ROUGH} rough · 🟠 {WATCH} watch · 🟢 {HEALTHY} healthy
🔁 {BOUNCED} tickets bounced QA (re-entered ≥1×) — top: {TOP_ROUGH}
(your own tickets routed to /tickets + /learn as usual — not dossiered)

Runtime: {seconds}s  (full scan {eta}s, your incremental: {seconds}s)

Next recommended run: when any repo's HEAD changes, or after a sprint.
```

</process>

<success_criteria>
- [ ] `project-map.md` written at workspace root
- [ ] `project-map-cache.json` written with per-repo HEAD hashes
- [ ] Loose ends section lists at least: unmatched FE calls, unmatched BFF upstreams, type drift
- [ ] Incremental mode skips unchanged repos (measurably faster than full)
- [ ] Business-logic snapshot groups repos by domain (not just by tech stack)
- [ ] If `api-bff` or `backend-services` was rescanned: `stack-connections.md` AUTO regions are refreshed; deltas reported in summary (Step 5b)
- [ ] No content outside `AUTO:*` markers in `stack-connections.md` was modified
- [ ] Activity pass (unless `--stale`/`--no-activity`): vendored/third-party and docs/empty repos excluded; cross-repo tickets deduped to one logical ticket
- [ ] A `.claude/team-tickets/PROJ-XXXX.md` dossier exists for each teammate ticket with window activity; none written for your own tickets
- [ ] Each dossier's `## Notes (human)` section is preserved across re-runs (only `AUTO:FACTS` regenerated); auto-inferences are prefixed `⚠ inferred — verify`
- [ ] Health scores never add multi-PR points for FE/Add-in repos; QA-bounce + CHANGES_REQUESTED drive the band
- [ ] `index.json` and per-repo `.claude/tickets/` are untouched (activity pass is read-only w.r.t. existing state)
</success_criteria>

## Related Commands
- Consumers: `/clarify` (reads project-map AND stack-connections.md to recommend cross-repo impact + per-domain implementation recipes), `/status` (reads loose ends), `/ticket` (warns if ticket scope touches a loose end), `/learn` (can mine teammate dossiers — `.claude/team-tickets/` — for cross-team patterns, not just your own tickets)
- Companion file: `$WORKSPACE_ROOT/.claude/stack-connections.md` — backend-domain FE↔BFF↔Go map; Step 5b refreshes its endpoint tables on every backend-touching scan
- Output folder: `$WORKSPACE_ROOT/.claude/team-tickets/` — per-ticket dossiers for teammates' work (Step 7); sibling to your `tickets/`, never mixed
- Data sources: `.claude/repo-profiles/*.yaml`, each repo's git + .claude/ content, `gh` PRs, the `jira` CLI + REST changelog (sprint status + QA-bounce timeline)
