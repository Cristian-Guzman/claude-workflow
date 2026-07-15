# Ticket State-File Schema Contract

**Applies to:** `{repo}/.claude/tickets/PROJ-XXXX.md`
**Read/write by:** `/ticket`, `/verify`, `/pr`, `/ci-check`, `/learn`, `/resume`, `/review-comments`, `/status`, `/retro`

Every ticket state file follows this contract. Commands that violate it silently corrupt downstream consumers. If you add a new field, document it here first.

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
pr_number: 790                             # set by /pr or /ci-check; null until PR is open
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
- **pr_number** — `/pr` sets it at PR open, `/ci-check` reads it; one ticket can have at most one PR in flight

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
| `ready-for-pr` | `/ticket` completion | Implementation + verification done, handed off to `/pr` |
| `pr-generated` | `/pr` Step 8 | PR deliverables ready, PR open |
| `delivered` | `/ci-check` Step 5.1 on successful merge | Merged to base branch |
| `learned` | `/learn` Step 5 | Patterns extracted; ticket dropped from active lists (file kept on disk) |

**Auxiliary (non-linear) statuses** seen in real state files — valid, set ad hoc when the happy path stalls:
`in-review` (PR open, awaiting reviewer), `rework-pushed-awaiting-rereview` (changes pushed after review), `blocked-on-backend` (waiting on a dependency). All resolve back onto the line above.

**Critical rule:** `/pr` sets `pr-generated`, NOT `delivered`. Only `/ci-check` transitions to `delivered` after confirmed merge. If `/pr` sets `delivered` prematurely, `/ci-check`'s event-log entry gets overwritten and `/learn` can't tell whether verification happened.

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
- `<actor>`: `/ticket`, `/verify`, `/pr`, `/ci-check`, `/learn`, `user`, or agent name
- Examples:
  - `- [10:23] /ticket: Plan approved, implementation started`
  - `- [14:05] /verify: 7/7 ACs verified, confidence HIGH`
  - `- [15:30] /pr: PR #790 opened targeting develop`
  - `- [17:12] /ci-check: Merged via PR #790 to develop`
  - `- [16:40] /verify: ui-iteration rounds=4 correction=per-state-contract source=screenshot surface=word-addin` (UI tickets only; written once by `/verify` §8.5, read by `/learn` §2.7; `rounds=unrecorded` when the user skips the prompt — never fabricated)

**Never rewrite or truncate existing event-log entries.** Append only.

### `## Retrospective` (filled at delivery)
Four subsections: What went well / What went wrong / Surprises / Decisions.
`/pr` prompts the user; `/learn` reads and clusters across tickets.

### `## Review Feedback` (optional, from `/review-comments`)
Per-comment triage: `kept` (applied), `disagreed` (with reason), `unresolved`.

### `## Obsidian Links` (optional)
Wiki-style `[[PROJ-YYYY]]` cross-links and topic tags. Used by `/learn` for graph building.

## Contract violations to watch for

| Violation | Consequence | Detected by |
|-----------|-------------|-------------|
| Missing `classification.initial_tier` | `/learn` can't detect misclassification | `/learn` Step 5.6 |
| `/pr` sets `status: delivered` | `/ci-check`'s event-log entry lost | `/ci-check` Step 5.1 warning |
| Missing `pr_number` after `/pr` ran | `/ci-check` can't identify the PR | `/ci-check` Step 1 |
| Event-log entry rewritten (not appended) | Audit trail broken | `/retro` sees timeline holes |
| `updated` timestamp not bumped | `/status` shows stale work as active | `/status` aging filter |

## Migration

Existing ticket state files that predate this schema (before 2026-04-21) may be missing fields. Commands should tolerate absence gracefully — treat `classification.initial_tier` as equal to `classification.tier` if absent. New tickets MUST follow the schema in full.
