---
id: PROJ-1131
summary: "Orders: show a collapsed 'Resolved items' group under the open-issues list"
repo: web-app
branch: feature/PROJ-1131-resolved-items-group
base_branch: main
status: learned
created: 2026-09-18T09:02:00Z
updated: 2026-09-26T17:40:00Z
classification:
  tier: Standard
  initial_tier: Standard
  context_loaded: [CLAUDE.md, codebase-patterns.md, testing-patterns.md]
  reason: "new component group inside one feature module; extends the existing summary hook; no API change"
  verification_depth: standard
design_case: spec
origin: ticket
pr_number: 412
merged_at: 2026-09-18T16:10:00Z
learned_date: 2026-09-26T17:40:00Z
outcome:
  merged_at: 2026-09-18T16:10:00Z
  jira_status: Code Review
  qa_bounces: 0
  timeline: "To Do → In Progress → Code Review (merged; QA pending on the deployed environment)"
tags:
  layer: ui
  kind: feature
  feature_area: [orders]
tagged_by: heuristic
tag_confidence: high
tags_verified: true
---

## Acceptance Criteria
- [x] AC1: On an order with at least one item that has no open issue, a "Resolved items" group appears below the open-issues list.
- [x] AC2: Resolution is evaluated per (item, check) pair — an item with one open check and one passed check contributes the passed check as a resolved card.
- [x] AC3: A pair is unresolved if it appears in any open issue regardless of issue type.
- [x] AC4: The group and each card inside it are collapsed by default.
- [x] AC5: Each card shows `{item.name}: {check.name}` with a green "Passed" pill.
- [x] AC6: An expanded card shows the matched rule only; no issue-specific detail blocks.
- [x] AC7: Ordering inside the group mirrors the open-issues list (API order; uncategorized last).
- [x] AC8: The order summary shows a "N resolved" count next to the existing issue counts.
- [x] AC9: When every pair has an open issue, the group does not render.
- [x] AC10: The collapsed group matches the design at the narrow breakpoint (human: in-app QA).

## Classification
- Tier: Standard
- Context loaded: CLAUDE.md, codebase-patterns.md (Index, 22 entries), testing-patterns.md, orders feature module + tests, design reference
- Reason: 5 story points, 7 new + 6 modified files, extends existing primitives (`Card`, `Pill`, `useOrderSummary`), no backend work, no blockers
- Verification depth: standard — unit + e2e (mocked) + one human visual gate

## Plan Summary
Add a collapsible "Resolved items" group at the bottom of `OrderItemsList`. One card per (item, check) pair from the order's rule set that does NOT appear in any open issue, computed client-side by a pure utility. `OrderSummary` gets a "N resolved" row. Blueprint from `/clarify` carried four file-map corrections against the ticket text: the canonical types file, which summary component owns the count, the prop that must be threaded, and the e2e tag convention.

## Implementation Progress
| Phase | Scope | Status |
|---|---|---|
| 1 | Pure utility + unit tests (TDD) | DONE |
| 2 | Summary hook + i18n keys + icon | DONE |
| 3 | Card + group components + tests | DONE |
| 4 | List wiring, prop threading, e2e spec | DONE |
| 5 | Quality gates + /verify | DONE |

## Files Modified
### NEW (7)
- `src/features/orders/utils/computeResolvedItems.ts` — pure (item, check) resolution
- `src/features/orders/utils/computeResolvedItems.test.ts` — 8 cases
- `src/features/orders/components/ResolvedItemCard.tsx` — card with pill + expand
- `src/features/orders/components/ResolvedItemCard.test.tsx` — 7 cases
- `src/features/orders/components/ResolvedItemsGroup.tsx` — collapsed group
- `src/features/orders/components/ResolvedItemsGroup.test.tsx` — 6 cases
- `e2e/orders/resolved-items.spec.ts` — 5 cases, `@e2e`
### MODIFIED (6)
- `src/shared/types.ts` — `ResolvedItem` type
- `src/features/orders/hooks/useOrderSummary.ts` — `resolvedCount`; shared memo extracted
- `src/features/orders/components/OrderItemsList.tsx` — renders the group; empty-state gate widened
- `src/features/orders/components/OrderDetails.tsx` — threads `order`
- `src/locales/en.json` — 7 keys
- `vitest.config.ts`, `jest.config.js` — include / ignore lists

## Decisions Made
- Count lives in `OrderSummary`, not `IssueSummary` — the latter is per-issue-type; a resolved count is an order-level fact.
- Compute resolution client-side from data already fetched — no new endpoint; the api-bff response already carries the rule set.
- Empty state gates on BOTH lists being empty — a fully-resolved order must still render the group (AC1, AC9 together).

## Current Focus
Delivered. Learned 2026-09-26.

## Blockers / Questions Resolved
- Does the summary hook return the rule set? No — threaded as a prop from `OrderDetails` (caught by /clarify).

## Event Log
- [09:02] Classified as Standard — loaded CLAUDE.md, codebase-patterns (Index, 22 entries), testing-patterns, orders module + tests; blueprint from /clarify applied (4 file-map corrections)
- [09:04] Plan approved — 7 new + 6 modify files
- [09:05] Branched off main → feature/PROJ-1131-resolved-items-group
- [09:08] Following pattern from codebase-patterns.md — "Feature modules own their components" (`src/features/orders/`)
- [09:12] Added `ResolvedItem` to `src/shared/types.ts` (the ticket's file map named `src/client/types.ts`, which does not exist — corrected in the blueprint)
- [09:25] TDD: `src/features/orders/utils/computeResolvedItems.ts` + 8 unit cases — all pass
- [09:27] Hit issue: `vitest.config.ts` uses an explicit `include` allow-list; the new test file was not collected — fixed: added the path, mirroring the sibling entry
- [09:40] Extended `useOrderSummary` with `resolvedCount`; extracted the `itemIdsWithIssues` memo so the new count and the existing classification share it
- [09:48] Added 7 i18n keys to `src/locales/en.json`; `CheckIcon` added to `src/shared/icons/index.ts`
- [10:10] Built `ResolvedItemCard.tsx` + 7 unit cases — all pass
- [10:22] Hit issue: `ResolvedItemsGroup` test asserted on the visible text "4 resolved"; the unit i18n mock echoes `key {"count":4}` — fixed: assert on the mock's echo format
- [10:35] Built `ResolvedItemsGroup.tsx` + 6 unit cases — all pass
- [10:50] Hit issue: `OrderItemsList` returned the empty state when `issues.length === 0`, hiding the new group on fully-resolved orders (AC1) — fixed: gate on both lists being empty
- [11:05] Wired `order` through `OrderDetails` → `OrderItemsList`; 3 new cases (partial / full / zero resolved)
- [11:12] Hit issue: jest collected `computeResolvedItems.test.ts` by extension and failed on vitest globals — fixed: added it to `jest.config.js` testPathIgnorePatterns
- [11:30] Wrote `e2e/orders/resolved-items.spec.ts` (5 cases); tag corrected `@integration` → `@e2e` to match the directory convention from the blueprint
- [11:32] Pattern confirmed: specs under `e2e/` run on the e2e config whether or not they mock with `page.route` — the tag follows the directory, not the mock usage
- [11:40] Tests written — 5 files
- [11:45] `npm run ci` — passed: format ✓ lint ✓ typecheck ✓ unit 418/418 ✓
- [11:58] /verify: 9/10 ACs VERIFIED; AC10 UNVERIFIED (human: collapsed group at the narrow breakpoint, in-app QA) — confidence 70% (cap: human confirmation pending; the model does not flip human gates)
- [13:20] user: [qa-confirmed via in-app QA] AC10 collapsed group at the narrow breakpoint
- [13:24] /verify: re-run — 10/10 ACs, confidence 92% (machine gates unchanged; the human gate lifted by the recorded confirmation, not by re-reading the code)
- [13:40] /pr: PR #412 opened against main — 3 commits (head 3f9c2a1); Process Summary written
- [15:05] /ci-check: CI 9/9 green; base moved 4 commits — merged main into the branch (no force-push on a reviewed PR), one conflict in `OrderItemsList.tsx` resolved, gates re-run 424/424
- [16:10] /ci-check: Merged via PR #412 to main (squash 9b1e7d4) — outcome snapshotted (qa_bounces=0, QA pending on the deployed environment)

## Process Summary
- sessions: 1 (single continuous session 2026-09-18)
- phases: 5
- fix_iterations: 4 (four `Hit issue:` lines, all fixed in-flow — no debug session)
- debug_sessions: none
- commits: 3 (git rev-list --count origin/main..HEAD at PR time)
- first_event_to_pr_days: 0
- ui_iteration: n/a (no visual-spec; the one visual check was a human gate)

## Retrospective

**What went well:**
- TDD on the pure utility: 8 cases pinned the contract before any component existed; the components passed against it first time.
- Reused `Card`, `Pill`, `Chevron`, `useOrderSummary` — no new primitives, no new tokens.
- The `/clarify` blueprint paid for itself: all four file-map corrections (types file, summary component, prop threading, e2e tag) were caught before coding, not in review.
- Extracting `itemIdsWithIssues` into its own memo made the new count free — `allPairs.length - itemIdsWithIssues.size`.

**What went wrong:**
- Assumed the unit runner would auto-collect the new `.test.ts` file; the config has an explicit allow-list. One-line fix, found by running, not by reading the config first.
- The same file then got picked up by the second runner by extension — the mirror-image fix.
- First assertion on the group used the English string instead of the i18n mock's echo format.
- The e2e spec was first tagged by its mocking style, not by its directory.

**Surprises:**
- The summary hook does not return the rule set the ticket text said it did — the blueprint had already flagged this, and the prop was threaded as planned.
- `src/shared/types.ts` is the canonical types file; the ticket's `src/client/types.ts` does not exist.
- Two test runners share the `*.test.ts` extension; each has its own list.

**Decisions:**
- Kept the count in `OrderSummary` (order-level fact) rather than `IssueSummary` (per-type).

## Closeout
<!-- AUTO:CLOSEOUT START -->
- Outcome: To Do → In Progress → Code Review → QA → Done  (entered QA 1× → 0 bounces) · cycle 1.3d · 5 pts
- Health: 🟢 healthy (score 0): no QA bounce, no CHANGES_REQUESTED, single PR. The one open gate was a human visual check, confirmed in-app before /pr; the base-branch conflict was resolved by merge-into-branch, not a force-push.
<!-- AUTO:CLOSEOUT END -->

## Obsidian Links
- Branch: feature/PROJ-1131-resolved-items-group
- PR: #412
- Patterns updated: [[codebase-patterns]] (2 entries, both second-occurrence — see [[PROJ-1103]], [[PROJ-1088]])
- Related: [[PROJ-1117]] (sibling ticket — order summary rows)
- Learned date: 2026-09-26
