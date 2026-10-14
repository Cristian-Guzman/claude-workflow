# One ticket through the pipeline — PROJ-1131 (Standard)

**What this is.** One Standard-tier ticket in `web-app`, from `/clarify` to `/learn`. Everything under "Generated transcript" was produced by `core/scripts/render-walkthrough.py` from the ticket's state file, which sits next to this page as [`walkthrough-standard-ticket.state.md`](walkthrough-standard-ticket.state.md) — re-render it with `python3 core/scripts/render-walkthrough.py docs/examples/walkthrough-standard-ticket.state.md`. The ticket is synthetic: modelled step for step on a real 25-event learned ticket, with every noun replaced, because a real state file cannot leave its repo.

**Where `/clarify` saved work.** The blueprint corrected the ticket's file map four times before any code existed: the canonical types file (step 5 — the ticket named a path that does not exist), which summary component owns the new count, a prop the ticket assumed a hook already returned (step 14), and the e2e tag convention (step 16). Each would otherwise have surfaced in review; the retrospective counts them as the single biggest saving.

**Which `Hit issue:` lines became pattern entries — and which did not.** Steps 7 + 15 (two test runners sharing one file extension) and step 13 (an early-return empty state hiding a sibling) had each happened once before in this repo, so `/learn` filed them citing both tickets — see the `## Lessons Learned` tail of [`codebase-patterns.after-20-tickets.md`](codebase-patterns.after-20-tickets.md). Step 11 (the i18n mock's echo format) was a first occurrence: it stays in the state file, findable through the ticket index, and becomes an entry only if it recurs. One incident is an anecdote.

**Where `/verify` refused to self-flip a human gate.** Step 20: nine ACs verified by machine, AC10 born `UNVERIFIED` because "matches the design at the narrow breakpoint" has no machine receipt — score capped at 70%. The model does not lift that cap by re-reading the code. Step 21 is the user's `[qa-confirmed via in-app QA]` line, recorded with its method; step 22 re-runs `/verify`, which lifts the cap only because that line now exists.

**What the renderer will not guess.** `—` in the actor column marks a line outside the logging vocabulary (free-form implementation notes — all written by `/ticket` here, but the script does not infer that). Step 5 lists a path the line mentions only to say it does not exist. `commits` and `first_event_to_pr_days` read `unrecorded` because an Event Log stamped `[HH:MM]` cannot yield them — `/pr-creation` records both from git and dates, shown in the right-hand column. A generated transcript cannot be prettified, which is the point.

## What the user typed

| when | command | what came back |
|---|---|---|
| before step 1 | `/clarify PROJ-1131` | a blueprint: tier, context profile, the four file-map corrections |
| steps 1–19 | `/ticket PROJ-1131` | plan → approval → branch → TDD → components → e2e → quality gates; four `Hit issue:` lines, all fixed in-flow |
| step 20 | `/verify PROJ-1131` | 9/10 ACs, one human gate, score capped at 70% |
| step 21 | `/qa PROJ-1131`, then the in-app check | the `[qa-confirmed via in-app QA]` line, with its method |
| step 22 | `/verify PROJ-1131` | 10/10 ACs, 92% |
| step 23 | `/pr-creation PROJ-1131` | PR #412 and the `## Process Summary` block |
| steps 24–25 | `/ci-check PROJ-1131` | CI, base-branch catch-up by merge, squash merge, outcome snapshot |
| eight days later | `/learn web-app` | two second-occurrence entries, the `## Closeout` block, `status: learned` |

Each command was run on its own and stopped there; nothing auto-chained.

---

## Generated transcript

<!-- python3 core/scripts/render-walkthrough.py docs/examples/walkthrough-standard-ticket.state.md -->

# Walkthrough — PROJ-1131 · Standard · web-app · status learned

_Rendered by `render-walkthrough.py` from `walkthrough-standard-ticket.state.md`. Every cell below is derived from the state file by the rules in the script header; nothing is hand-edited._

> Orders: show a collapsed 'Resolved items' group under the open-issues list

## Steps

| step | actor | event | artifact written |
|---|---|---|---|
| 1 | /ticket | [09:02] Classified as Standard — loaded CLAUDE.md, codebase-patterns (Index, 22 entries), testing-patterns, orders module + tests; blueprint from /clarify applied (4 file-map corrections) | ## Classification |
| 2 | /ticket | [09:04] Plan approved — 7 new + 6 modify files | ## Plan Summary |
| 3 | /ticket | [09:05] Branched off main → feature/PROJ-1131-resolved-items-group | branch `feature/PROJ-1131-resolved-items-group` |
| 4 | /ticket | [09:08] Following pattern from codebase-patterns.md — "Feature modules own their components" (`src/features/orders/`) | `src/features/orders/` |
| 5 | — | [09:12] Added `ResolvedItem` to `src/shared/types.ts` (the ticket's file map named `src/client/types.ts`, which does not exist — corrected in the blueprint) | `src/shared/types.ts`, `src/client/types.ts` |
| 6 | /ticket | [09:25] TDD: `src/features/orders/utils/computeResolvedItems.ts` + 8 unit cases — all pass | `src/features/orders/utils/computeResolvedItems.ts` |
| 7 | /ticket | [09:27] Hit issue: `vitest.config.ts` uses an explicit `include` allow-list; the new test file was not collected — fixed: added the path, mirroring the sibling entry | `vitest.config.ts` |
| 8 | — | [09:40] Extended `useOrderSummary` with `resolvedCount`; extracted the `itemIdsWithIssues` memo so the new count and the existing classification share it | — |
| 9 | — | [09:48] Added 7 i18n keys to `src/locales/en.json`; `CheckIcon` added to `src/shared/icons/index.ts` | `src/locales/en.json`, `src/shared/icons/index.ts` |
| 10 | — | [10:10] Built `ResolvedItemCard.tsx` + 7 unit cases — all pass | `ResolvedItemCard.tsx` |
| 11 | /ticket | [10:22] Hit issue: `ResolvedItemsGroup` test asserted on the visible text "4 resolved"; the unit i18n mock echoes `key {"count":4}` — fixed: assert on the mock's echo format | — |
| 12 | — | [10:35] Built `ResolvedItemsGroup.tsx` + 6 unit cases — all pass | `ResolvedItemsGroup.tsx` |
| 13 | /ticket | [10:50] Hit issue: `OrderItemsList` returned the empty state when `issues.length === 0`, hiding the new group on fully-resolved orders (AC1) — fixed: gate on both lists being empty | — |
| 14 | — | [11:05] Wired `order` through `OrderDetails` → `OrderItemsList`; 3 new cases (partial / full / zero resolved) | — |
| 15 | /ticket | [11:12] Hit issue: jest collected `computeResolvedItems.test.ts` by extension and failed on vitest globals — fixed: added it to `jest.config.js` testPathIgnorePatterns | `computeResolvedItems.test.ts`, `jest.config.js` |
| 16 | — | [11:30] Wrote `e2e/orders/resolved-items.spec.ts` (5 cases); tag corrected `@integration` → `@e2e` to match the directory convention from the blueprint | `e2e/orders/resolved-items.spec.ts` |
| 17 | /ticket | [11:32] Pattern confirmed: specs under `e2e/` run on the e2e config whether or not they mock with `page.route` — the tag follows the directory, not the mock usage | `e2e/` |
| 18 | /ticket | [11:40] Tests written — 5 files | tests |
| 19 | — | [11:45] `npm run ci` — passed: format ✓ lint ✓ typecheck ✓ unit 418/418 ✓ | — |
| 20 | /verify | [11:58] 9/10 ACs VERIFIED; AC10 UNVERIFIED (human: collapsed group at the narrow breakpoint, in-app QA) — confidence 70% (cap: human confirmation pending; the model does not flip human gates) | — |
| 21 | user | [13:20] [qa-confirmed via in-app QA] AC10 collapsed group at the narrow breakpoint | — |
| 22 | /verify | [13:24] re-run — 10/10 ACs, confidence 92% (machine gates unchanged; the human gate lifted by the recorded confirmation, not by re-reading the code) | — |
| 23 | /pr-creation | [13:40] PR #412 opened against main — 3 commits (head 3f9c2a1); Process Summary written | PR #412, commit 3f9c2a1, ## Process Summary |
| 24 | /ci-check | [15:05] CI 9/9 green; base moved 4 commits — merged main into the branch (no force-push on a reviewed PR), one conflict in `OrderItemsList.tsx` resolved, gates re-run 424/424 | `OrderItemsList.tsx`, frontmatter: merged_at · outcome |
| 25 | /ci-check | [16:10] Merged via PR #412 to main (squash 9b1e7d4) — outcome snapshotted (qa_bounces=0, QA pending on the deployed environment) | PR #412, frontmatter: merged_at · outcome |

## Process Summary

| field | derived from Event Log | recorded by /pr-creation |
|---|---|---|
| sessions | 1 | 1 (single continuous session 2026-09-18) |
| phases | 5 | 5 |
| fix_iterations | 4 | 4 (four `Hit issue:` lines, all fixed in-flow — no debug session) |
| debug_sessions | none | none |
| commits | unrecorded | 3 (git rev-list --count origin/main..HEAD at PR time) |
| first_event_to_pr_days | unrecorded | 0 |
| ui_iteration | n/a | n/a (no visual-spec; the one visual check was a human gate) |

_`commits` and `first_event_to_pr_days` need git and dates; an Event Log stamped only `[HH:MM]` cannot yield them, so they read `unrecorded` here and `/pr-creation` records them at PR time._

## Closeout

- Outcome: To Do → In Progress → Code Review → QA → Done  (entered QA 1× → 0 bounces) · cycle 1.3d · 5 pts
- Health: 🟢 healthy (score 0): no QA bounce, no CHANGES_REQUESTED, single PR. The one open gate was a human visual check, confirmed in-app before /pr-creation; the base-branch conflict was resolved by merge-into-branch, not a force-push.
