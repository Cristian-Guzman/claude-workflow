<!--
  codebase-patterns.md — per-repo pattern catalog.
  READ by: /ticket, /build, /refactor (loaded before writing code).
  WRITTEN by: /learn (appends battle-tested entries after delivered tickets).
  Seeding: fill 3-10 entries manually at install time from code observation,
  then let /learn grow it. Keep entries short, concrete, and sourced.
-->
<!-- last-updated: YYYY-MM-DD -->
<!-- last-run: YYYY-MM-DD: +N added -N removed -->

# Codebase Patterns — {repo-name}

**Shared rules:** [[codebase-patterns-shared.md]] — read first (minimalism ladder, comment hygiene, dependency / contract / flag rules).
This file holds only what is specific to THIS repo.

> **Seed file** — Initial patterns observed from codebase structure, not learned
> from delivered tickets. Run `/learn` after completing tickets to grow this file.

## Index
<!-- One line per entry: anchor link + source. Keep in sync when adding entries. -->
- [Feature modules own their components](#pattern-feature-modules-own-their-components) — Source: code-observation
- [Retry wrapper swallows 4xx errors](#gotcha-retry-wrapper-swallows-4xx-errors) — Source: [[PROJ-123]]

## Architecture & Layering
<!-- Group entries under topic H2s (Architecture, Dependencies, Testing, CI, ...).
     Add/rename H2s freely as entries accumulate — the groups emerge from the work. -->

### [Pattern]: Feature modules own their components
<!-- EXAMPLE — replace with your project's pattern -->
- **Rule**: New UI lives in the feature module that renders it (`src/features/<name>/`), not in `src/shared/`. Promote to shared only on the second consumer.
- **Why**: Keeps blast radius small; shared code accretes an implicit API that is hard to change later.
- **Source**: code-observation (`src/features/billing/`)

### [Gotcha]: Retry wrapper swallows 4xx errors
<!-- EXAMPLE — replace with your project's gotcha -->
The `withRetry()` helper in `src/http/retry.ts` retries ALL non-2xx responses, including 400s, so a validation error surfaces as a timeout after 3 attempts. Pass `{ retryOn: [502, 503] }` explicitly for any new call site.
_Source: [[PROJ-123]] — surfaced when a bad payload looked like an outage in QA._

## Testing & CI

### [Build/CI]: Local test runner needs an explicit config flag
<!-- EXAMPLE — replace with your project's CI quirk -->
- **Rule**: `npx jest <path>` fails with "multiple configurations found" — always run `npx jest --config jest.config.ts <path>`. The `yarn test` wrapper already handles this.
- **Source**: session learning (cost ~5 min the first time)

## Code comment hygiene

Default to no comment. The full rule and the gate that enforces it (`/verify` §3.4, `/pr-creation` §5e) live in [[codebase-patterns-shared.md]] — do not copy them here.

<!--
  ENTRY FORMAT (what /learn appends):
  ### [Tag]: Short imperative title        <- Tag: Pattern | Gotcha | Pitfall | Anti-pattern | Build/CI | Workflow
  Rule (what to do), Why (the mechanism), file/path references when concrete.
  _Source: [[PROJ-123]] or code-observation or session YYYY-MM-DD_
  Then add the matching line to the Index above.
-->
