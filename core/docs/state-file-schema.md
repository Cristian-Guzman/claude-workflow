# Ticket State-File Schema Contract

**Applies to:** `{repo}/.claude/tickets/PROJ-XXXX.md` and every other state file the index knows about (see Kinds)
**Read/write by:** `/ticket`, `/verify`, `/pr-creation`, `/ci-check`, `/learn`, `/resume-ticket`, `/review-comments`, `/status`, and the role commands that write sidecars (`/cover`, `/triage`, `/log`)

Every ticket state file follows this contract. Commands that violate it silently corrupt downstream consumers. If you add a new field, document it here first.

## Kinds (closed enum)

`state-index-upsert.sh` and `/status`'s no-index fallback read the two comment lines below — keep them on one line each and in sync with the table.

<!-- kind-enum: ticket debug build refactor e2e review blueprint cover triage test-plan -->
<!-- kind-dirs: tickets debug builds refactors e2e -->

| kind | Directory | Filename | Status vocabulary | Notes |
|------|-----------|----------|-------------------|-------|
| `ticket` | `tickets/` | `PROJ-XXXX.md` | Status Lifecycle below | the primary lifecycle entry |
| `debug` | `debug/` | `<slug>.md` | `investigating` → `root-cause-found` → `fixed` | written by `/project-debug` |
| `build` | `builds/` | `<slug>.md` | Status Lifecycle below | written by `/build`; ticket-less |
| `refactor` | `refactors/` | `<slug>.md` | Status Lifecycle below | written by `/refactor` |
| `e2e` | `e2e/` | `<slug>.md` | Status Lifecycle below | legacy directory, kept for old installs |
| `review` | `tickets/` | `PROJ-XXXX-review[-N].md` | `reviewed` (terminal) | `/review-pr` log; archived at upsert |
| `blueprint` | `tickets/` | `PROJ-XXXX-clarify[-N].md` | `blueprint` (terminal) | `/clarify` investigation artifact; archived at upsert |
| `cover` | `tickets/` | `cover--<slug>.md` | Status Lifecycle below + `env-blocked` | ticket-less sidecar, keyed by branch — see Sidecars |
| `triage` | `tickets/` | `triage--<slug>.md` | Status Lifecycle below + `env-blocked` | ticket-less sidecar, keyed by branch — see Sidecars |
| `qa` | `tickets/` | `qa--<key>.md` | `in-progress` → `delivered` (+ `bounced`) | manual-QA results sidecar written by the tester from the `/qa` guide; `<key>` = ticket id or slug — see `roles/qa/README.md` |
| `test-plan` | `tickets/` | `PROJ-XXXX-test-plan.md` | `blueprint` (terminal) | legacy sidecar of the retired `/test-plan`; archived at upsert; never written by a current command |

**Kind resolution order in the index:** a declared `kind:` frontmatter value that is in the enum wins; else the filename suffix rules (`-review`, `-clarify`, `-test-plan`) apply; else the kind is derived from the directory. A declared `kind:` outside the enum is ignored (directory kind wins) and logged to `state/schema-drift.log`.

### Sidecars (`cover`, `triage`, `qa`)

Role commands that start work without a ticket write a sidecar into `tickets/` named `tickets/<kind>--<slug>.md`. Frontmatter:

```yaml
---
kind: cover                    # cover | triage — REQUIRED, this is what the index keys on
slug: orders-v2-checkout       # kebab-case; the index key and the id's last segment
ticket: null                   # null until /log creates or links a tracker issue, then the KEY (e.g. PROJ-1234)
branch: test/orders-v2-checkout
status: in-progress            # ticket vocabulary (Status Lifecycle) + env-blocked
created: 2026-04-21T10:00:00Z
updated: 2026-04-21T15:30:00Z
pr_number: null                # set by /pr-creation §8 — the same join key /ci-check uses for tickets
---
```

Rules:
- **Index id = `<repo>:<kind>:<slug>`, immutable.** The ticket is NOT part of the id, so `/log` can key the work to a tracker issue later by writing `ticket: PROJ-1234` into the frontmatter **without renaming the file** — the PostToolUse upsert re-derives `ticket` (frontmatter first) and the entry keeps its id.
- `ticket: null`, `~`, or an absent field all mean "no ticket" and index as `ticket: null`.
- `branch` is the join key `/pr-creation` and `/ci-check` use to find the sidecar for the current branch (any kind, `archived != true`). Keep it current.
- `env-blocked` = the work is sound but the target environment is not (deploy not landed, data missing, auth down). Resolves back onto the lifecycle line; it is not terminal.
- Body sections follow the ticket contract where they apply (`## Files Modified`, `## Event Log`, `## Retrospective`); `/cover` adds a scenario table with one break-to-validate receipt per test, `/triage` adds a cluster table. `/resume-ticket` reads those tables to find the resume point.

### Legacy `-test-plan` sidecar

`PROJ-XXXX-test-plan.md` files were written by the retired `/test-plan` command. They index as `kind: test-plan`, `status: blueprint` when the file carries no status, `archived: true` (terminal). No current command writes or reads them beyond prior-art lookup; do not delete them.

## Frontmatter (YAML)

```yaml
---
id: PROJ-XXXX
summary: "one-line ticket summary"
repo: addin-fe                           # repo name; must match a file in .claude/repo-profiles/
branch: feature/PROJ-XXXX-short-desc      # current feature branch, may be "" before /ticket creates one
base_branch: develop                       # resolved from repo profile; recorded for audit
status: planning                           # see Status Lifecycle below
created: 2026-04-21T10:00:00Z              # ISO 8601 UTC, never changes
updated: 2026-04-21T15:30:00Z              # ISO 8601 UTC, bumped on every write
classification:
  tier: Bugfix                             # Trivial | Bugfix | Standard | Complex
  initial_tier: Bugfix                     # set by /ticket, NEVER overwritten — /learn reads this to detect misclassification
  context_loaded: [CLAUDE.md, codebase-patterns.md]
  reason: "API mapper issue; isolated surface"
  verification_depth: standard             # minimal | standard | deep
design_case: none                          # prototype | spec | none — set by /clarify Step 1.8
origin: ticket                             # ticket | prototype-spec | build | debug
pr_number: 790                             # set by /pr-creation or /ci-check; null until PR is open
merged_at: null                            # ISO 8601 UTC, set by /ci-check on successful merge
learned_date: null                         # ISO 8601 UTC, set by /learn after patterns extracted
---
```

### Field rules

- **id** — immutable once set
- **status** — single source of truth for lifecycle; see Status Lifecycle
- **updated** — bumped by every command that edits the file; never stale
- **classification.tier** — may be updated (e.g. if verification reveals higher complexity)
- **classification.initial_tier** — set once by `/ticket`, **never** overwritten. `/learn` uses `tier ≠ initial_tier` to detect misclassification and emit a proposal
- **design_case** — used by `/clarify` Step 2.5 (prototype-aware investigation) and Step 4b.3 (case-specific guidance)
- **pr_number** — `/pr-creation` sets it at PR open, `/ci-check` reads it; one ticket can have at most one PR in flight

## Status Lifecycle

```
planning → in-progress → ready-for-pr → pr-generated → delivered → learned
               ↑________________/ (if reviews force changes or /verify fails)
```

A ticket may also exit at any point to **`abandoned`** — terminal, explicitly closed without delivery (set manually when work is dropped; the registry auto-archives it). The file is never deleted.

| Status | Set by | Meaning |
|--------|--------|---------|
| `planning` | `/ticket` Step 0 / `/clarify` | Investigation + plan being drafted |
| `in-progress` | `/ticket` Step 5 (start) | Code being written, tests + /verify running |
| `ready-for-pr` | `/ticket` completion | Implementation + verification done, handed off to `/pr-creation` |
| `pr-generated` | `/pr-creation` Step 8 | PR deliverables ready, PR open |
| `delivered` | `/ci-check` Step 5.1 on successful merge | Merged to base branch |
| `learned` | `/learn` Step 5 | Patterns extracted; ticket dropped from active lists (file kept on disk) |

**Auxiliary (non-linear) statuses** seen in real state files, set ad hoc when the happy path stalls:
`in-review` (PR open, awaiting reviewer), `rework-pushed-awaiting-rereview` (changes pushed after review), `blocked-on-backend` (waiting on a dependency), `env-blocked` (sidecars: target environment unavailable — see Sidecars). All resolve back onto the line above. Of these only `env-blocked` is in the closed vocabulary below; the other three are tolerated, not schema — the next paragraph says exactly what happens to them.

**Closed status vocabulary** (what `state-index-upsert.sh` accepts without logging drift): the six lifecycle statuses, `abandoned`, the debug trio (`investigating`, `root-cause-found`, `fixed`), the terminal kind markers (`reviewed`, `blueprint`), `env-blocked`, and `unknown`. A file with **no `status:` at all** indexes as `unknown` AND writes a `missing status` line to `state/schema-drift.log`. Any other status — the three auxiliary ones above included — is **tolerated**: the entry indexes with the status as written AND a `non-schema status` line goes to the drift log; nothing refuses the file. Fix the file, not the log.

**Critical rule:** `/pr-creation` sets `pr-generated`, NOT `delivered`. Only `/ci-check` transitions to `delivered` after confirmed merge. If `/pr-creation` sets `delivered` prematurely, `/ci-check`'s event-log entry gets overwritten and `/learn` can't tell whether verification happened.

## Required Body Sections

In this order:

### `## Classification`
Mirror of frontmatter.classification as human-readable. Do not diverge from frontmatter.

### `## Plan`
Implementation plan. Written by `/ticket` or `/clarify`. Static after ticket starts.

### `## Files Modified`
Auto-maintained by commands that touch the filesystem. Each entry: `- path/to/file — one-line why`.

### `## Decisions Made`
Append-only log of design decisions with rationale. `/learn` extracts these as architectural precedents.

### `## Event Log`
Append-only chronological log. Each entry: `- [HH:MM] <actor>: <one-line summary>`.
- `<actor>`: `/ticket`, `/verify`, `/pr-creation`, `/ci-check`, `/learn`, `user`, or agent name
- Examples:
  - `- [10:23] /ticket: Plan approved, implementation started`
  - `- [14:05] /verify: 7/7 ACs verified, confidence HIGH`
  - `- [15:30] /pr-creation: PR #790 opened targeting develop`
  - `- [17:12] /ci-check: Merged via PR #790 to develop`
  - `- [16:40] /verify: ui-iteration rounds=4 correction=per-state-contract source=screenshot surface=word-addin` (UI tickets only; written once by `/verify` §8.5, read by `/learn` §2.7; `rounds=unrecorded` when the user skips the prompt — never fabricated)

**Never rewrite or truncate existing event-log entries.** Append only.

### `## Retrospective` (filled at delivery)
Four subsections: What went well / What went wrong / Surprises / Decisions.
`/pr-creation` prompts the user; `/learn` reads and clusters across tickets.

### `## Review Feedback` (optional, from `/review-comments`)
Per-comment triage: `kept` (applied), `disagreed` (with reason), `unresolved`.

### `## Obsidian Links` (optional)
Wiki-style `[[PROJ-YYYY]]` cross-links and topic tags. Used by `/learn` for graph building.

## Contract violations to watch for

| Violation | Consequence | Detected by |
|-----------|-------------|-------------|
| Missing `classification.initial_tier` | `/learn` can't detect misclassification | `/learn` Step 5.6 |
| `/pr-creation` sets `status: delivered` | `/ci-check`'s event-log entry lost | `/ci-check` Step 5.1 warning |
| Missing `pr_number` after `/pr-creation` ran | `/ci-check` can't identify the PR | `/ci-check` Step 1 |
| Event-log entry rewritten (not appended) | Audit trail broken | `/retro` sees timeline holes |
| `updated` timestamp not bumped | `/status` shows stale work as active | `/status` aging filter |
| State file has no `status:` | Indexed as `unknown`; invisible to `/learn` and `/status` buckets | `state/schema-drift.log` (`missing status`) |
| Sidecar renamed after `/log` keyed it | Index id changes; history splits across two entries | never rename — write `ticket:` into the frontmatter |

## Migration

Existing ticket state files that predate this schema (before 2026-04-21) may be missing fields. Commands should tolerate absence gracefully — treat `classification.initial_tier` as equal to `classification.tier` if absent. New tickets MUST follow the schema in full.
