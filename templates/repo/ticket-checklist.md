<!--
  ticket-checklist.md — per-repo pre-PR compliance checklist.
  Read by: /ticket (drives phases), /verify (AC gate), /pr-creation + the pr-branch-reviewer agent (enforcement).
  Filled: seeded manually at install with your repo's real commands/patterns, then grown by /learn.
  Every "EXAMPLE" entry shows the FORMAT — replace with your project's specifics.
-->

# Ticket Implementation Checklist

**Purpose:** Enable autonomous ticket completion — Claude investigates, plans, implements, verifies, delivers.

## Workflow Overview

```
USER PROVIDES: ticket id (PROJ-123), acceptance criteria, design link / API contract, extra context
CLAUDE EXECUTES: 1. PLAN -> 2. USER APPROVES -> 3. IMPLEMENT -> 4. VERIFY (full CI) -> 5. DELIVER
```

## Ticket State Persistence

Every ticket gets a state file at `.claude/tickets/PROJ-123.md`. Update it on: ticket start, plan approval, each AC completed, decisions made, context-low warnings, delivery. Resume via `/resume`.

## Phase 1: Plan Mode (Investigation)

> Enter plan mode for every non-trivial ticket. Investigate before proposing.

1. **Search for existing similar implementations** — `grep -r "SimilarFeature" src/features/` <!-- EXAMPLE — replace with your project's search pattern -->
2. **Check the API layer / sibling repo contract** (e.g., how web-app calls api-bff) <!-- EXAMPLE — replace with your cross-repo check -->

Then identify files to modify/create and patterns to follow; write the plan (summary, findings, files, ordered steps, testing plan, open questions, complexity) to the ticket state file.

### CRITICAL: Don't Guess — Ask

| Undefined Thing | Action |
|-----------------|--------|
| <!-- EXAMPLE --> UI choices not in the design (colors, labels, layout) | **ASK** the user |
| <!-- EXAMPLE --> API contract details (response shape, error codes) | **ASK** the user |

## Phase 2: Implementation

> Only start after plan is approved. Reference: [codebase-patterns.md](./codebase-patterns.md)

| Rule | Requirement |
|------|-------------|
| <!-- EXAMPLE — replace with your architecture rule --> Layering | Router -> Controller -> Service; controllers stay thin |
| <!-- EXAMPLE — replace with your lint/style rule --> Types | Proper interfaces, no `any`; ESLint `no-console` enforced |

### Scope Control

**ONLY modify files directly related to the ticket.** No unrelated "improvements", no refactors outside scope, no touching shared/core code unless the ticket requires it.

## Phase 3: Testing

- **Framework:** Jest + Testing Library. Tests live in `tests/` mirroring `src/`. <!-- EXAMPLE — replace with your framework + location convention -->
- **Run:** `npm test` for the touched paths; coverage threshold enforced by CI. <!-- EXAMPLE — replace with your run command -->

## Phase 4: Verification

> CRITICAL: Run ALL checks. Do NOT skip.

### Step 4.0: AC Achievement Verification

For EACH acceptance criterion: what must be TRUE, which file(s) implement it, is the code real (not stub/TODO/empty handler), is it wired (imported, registered, rendered)?

| AC | Truth | Code Location | Substance | Wired | Status |
|----|-------|---------------|-----------|-------|--------|
| AC1 | [what must be true] | [file:line] | [real/stub] | [yes/no] | VERIFIED / FAILED |

If any AC FAILED, fix before quality checks — `/verify` automates this step.

### Final Checklist

| Check | Status |
|-------|--------|
| <!-- EXAMPLE — replace with your full CI gate --> Full CI passes (`npm run ci`), incl. unit tests | [ ] Pass |
| <!-- EXAMPLE — replace with your quality gates --> Lint clean, no debug code, no `any` | [ ] Pass |
| Scope control followed | [ ] Pass |

## Phase 5: Delivery

**DO NOT** run `git commit`, `git push`, or `gh pr create` from this checklist — that is `/pr-creation`'s job.

**DO provide:** commit message (`feat|fix|refactor(PROJ-123): brief description`), PR description (summary, ticket link, key changes, tests added, definition of done), files-changed list.

## Common Patterns

1. **Bug fix:** reproduce -> trace the data flow -> minimal fix -> add a test covering the bug -> verify. <!-- EXAMPLE — replace with a recurring recipe in this repo -->

## Related Files

| File | Purpose |
|------|---------|
| [codebase-patterns.md](./codebase-patterns.md) | Coding standards and patterns |
| <!-- EXAMPLE --> `src/routes.ts` | Route registration — touch when adding endpoints/pages |

## Definition of Done

- [ ] Each AC verified against actual code (not just "I implemented it")
- [ ] No stubs; code wired end-to-end; unit tests written and passing
- [ ] Full CI passes; repo patterns followed; scope control maintained; commit message + PR description provided; state file `delivered`
