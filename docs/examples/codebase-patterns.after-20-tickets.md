<!-- last-updated: 2026-09-26 -->
<!-- last-run: 2026-09-26: +2 -1 -->

# Codebase Patterns — web-app

## Minimalism ladder (lazy-senior default)

Full ladder + carve-outs: **[[codebase-patterns-shared.md]]**. Before writing code, stop at the first rung that holds: YAGNI → reuse what is already here → stdlib/native → installed dep → one line → minimum. **Hard overrides:** tests are always required; keep at most a non-obvious WHY comment.

## Index
- [Feature modules own their components](#pattern-feature-modules-own-their-components) — Source: code-observation
- [Pages compose, hooks fetch](#pattern-pages-compose-hooks-fetch) — Source: [[PROJ-1047]], [[PROJ-1063]]
- [Three prop hops means a missing context](#pitfall-three-prop-hops-means-a-missing-context) — Source: [[PROJ-1072]], [[PROJ-1116]]
- [Every browser call goes through api-bff](#pattern-every-browser-call-goes-through-api-bff) — Source: code-observation; [[PROJ-1072]]
- [withRetry retries 4xx by default](#pitfall-withretry-retries-4xx-by-default) — Source: [[PROJ-1051]]
- [Read totalCount from the envelope, never items.length](#pattern-read-totalcount-from-the-envelope-never-itemslength) — Source: [[PROJ-1066]], [[PROJ-1109]]
- [An any-typed response leaks into components](#pitfall-an-any-typed-response-leaks-into-components) — Source: session 2026-07-14
- [A control that scopes a modal action lives inside the modal](#pattern-a-control-that-scopes-a-modal-action-lives-inside-the-modal) — Source: [[PROJ-1095]]
- [Select stores the option object, not the scalar](#pitfall-select-stores-the-option-object-not-the-scalar) — Source: [[PROJ-1095]]
- [Count-aware labels even when the number renders separately](#pattern-count-aware-labels-even-when-the-number-renders-separately) — Source: [[PROJ-1095]], [[PROJ-1117]]
- [The CI test job does not enforce the coverage threshold](#buildci-the-ci-test-job-does-not-enforce-the-coverage-threshold) — Source: session 2026-08-02
- [Own your e2e data](#pattern-own-your-e2e-data) — Source: [[PROJ-1077]], [[PROJ-1109]]
- [A spec's tag follows its directory, not its mocking style](#pitfall-a-specs-tag-follows-its-directory-not-its-mocking-style) — Source: [[PROJ-1077]]; confirmed [[PROJ-1131]]
- [Pin transitive CVE fixes with a glob resolution](#pattern-pin-transitive-cve-fixes-with-a-glob-resolution) — Source: session 2026-06-03
- [packages/ui builds before apps/web](#pitfall-packagesui-builds-before-appsweb) — Source: session 2026-07-30
- [Commit scope is the ticket key](#workflow-commit-scope-is-the-ticket-key) — Source: session 2026-06-03
- [A wrapper around a gated component stacks gates](#pitfall-a-wrapper-around-a-gated-component-stacks-gates) — Source: [[PROJ-1083]]
- [Flags are read at the route boundary and passed down](#pattern-flags-are-read-at-the-route-boundary-and-passed-down) — Source: code-observation; [[PROJ-1120]]
- [A missing flag key evaluates to false silently](#pitfall-a-missing-flag-key-evaluates-to-false-silently) — Source: [[PROJ-1099]], [[PROJ-1120]]
- [Two test runners share the .test.ts extension](#buildci-two-test-runners-share-the-testts-extension) — Source: [[PROJ-1103]], [[PROJ-1131]]
- [An early-return empty state hides siblings added later](#pitfall-an-early-return-empty-state-hides-siblings-added-later) — Source: [[PROJ-1088]], [[PROJ-1131]]
- [Base moved under a reviewed PR — merge into the branch, do not rebase](#workflow-base-moved-under-a-reviewed-pr--merge-into-the-branch-do-not-rebase) — Source: [[PROJ-1116]], [[PROJ-1131]]

## Architecture & Layering

### [Pattern]: Feature modules own their components
- **Rule**: New UI lives in the feature module that renders it (`src/features/<name>/`), never in `src/shared/` on day one. Promote on the second consumer, not the first.
- **Why**: Shared code grows an implicit API that is hard to change; a feature folder keeps the blast radius to one route.
_Source: code-observation (seed 2026-05-02)_

### [Pattern]: Pages compose, hooks fetch
- **Rule**: Data loading lives in `src/features/<name>/api/use<Thing>.ts`; page components only assemble. A page that calls the HTTP client directly is a review blocker.
- **Why**: Two tickets each added a second fetch to a page and broke the loading and error states the hook already handled.
_Source: [[PROJ-1047]], [[PROJ-1063]]_

### [Pitfall]: Three prop hops means a missing context
- **Rule**: When a value is threaded through three components that do not use it, stop and add a feature-local context (`src/features/<name>/context/`). Do not reach for the global store.
- **Why**: Both occurrences started as "just one more prop" and ended as a 9-file diff for a one-field change.
_Source: [[PROJ-1072]], [[PROJ-1116]]_

## Data Fetching & API Client

### [Pattern]: Every browser call goes through api-bff
- **Rule**: The web app calls `api-bff` only — never an upstream service directly, even for a read-only endpoint that already exists there.
- **Why**: Auth, rate limits and response shaping live in the BFF; a direct call bypasses all three and breaks the moment the upstream contract moves.
_Source: code-observation (seed 2026-05-02); reinforced [[PROJ-1072]]_

### [Pitfall]: withRetry retries 4xx by default
- **Rule**: `withRetry()` in `src/http/retry.ts` retries every non-2xx. Pass `{ retryOn: [502, 503] }` on every new call site; a 400 must fail fast.
- **Why**: A validation error surfaced in QA as a 9-second timeout after three attempts and was triaged as an outage.
_Source: [[PROJ-1051]]_

### [Pattern]: Read totalCount from the envelope, never items.length
- **Rule**: Paginated BFF responses are `{ items, totalCount, nextCursor }` and pages are capped at 50. Counts, "N results" labels and empty-state decisions read `totalCount`.
- **Why**: Two summary rows showed "50" for orders with hundreds of items.
_Source: [[PROJ-1066]], [[PROJ-1109]]_

### [Pitfall]: An any-typed response leaks into components
- **Rule**: When a BFF client method returns `Promise<any>`, the consuming hook declares a local interface and guards the shape at the boundary; components never see `any`.
- **Why**: A renamed upstream field passed typecheck and failed at runtime in three components at once.
_Source: session 2026-07-14 (PR #388 review)_

## Forms & i18n

### [Pattern]: A control that scopes a modal action lives inside the modal
- **Rule**: If a selector exists only to choose what the modal's primary action does, it is a form field inside the modal — not a page-level toggle that gates the buttons.
- **Why**: Page-level gating adds button-state logic and clutter; in-modal lets the form own validation and defaults.
_Source: [[PROJ-1095]]_

### [Pitfall]: Select stores the option object, not the scalar
- **Rule**: `src/shared/forms/Select` writes `{ value, label }` into form state. Initial values are option objects; validation and submit read `values.field?.value`.
- **Why**: A custom `onChange` that stored the scalar broke the displayed selection on change.
_Source: [[PROJ-1095]]_

### [Pattern]: Count-aware labels even when the number renders separately
- **Rule**: Define `label_one` / `label_other` without `{{count}}` and call `t(key, { count })`; i18n still picks the plural form. Never hardcode a singular.
- **Why**: Two tickets shipped "1 items" in a big-number tile where the word sat under the digit.
_Source: [[PROJ-1095]], [[PROJ-1117]]_

## Testing & CI

### [Build/CI]: The CI test job does not enforce the coverage threshold
- **Rule**: CI runs `npm test`; the 80% threshold in the config is applied only by `npm run test:coverage`. Run it locally before a PR that adds source files.
- **Why**: A PR adding three untested modules went green; the gap was found by a reviewer, not a check.
_Source: session 2026-08-02 (PR #401 review)_

### [Pattern]: Own your e2e data
- **Rule**: Every spec under `e2e/` creates its order through the API fixture in `beforeEach` and deletes it in `afterEach`. Never assert on seeded rows or on another spec's leftovers.
- **Why**: Two flaky weeks traced to specs sharing one seeded order whose state depended on run order.
_Source: [[PROJ-1077]], [[PROJ-1109]]_

### [Pitfall]: A spec's tag follows its directory, not its mocking style
- **Rule**: Files under `e2e/` run on the e2e config and carry `@e2e`, even when they mock with `page.route`. `@integration` is reserved for `test/integration/`, which uses a different harness.
- **Why**: An `@integration`-tagged spec under `e2e/` was silently skipped by the CI job that should have run it.
_Source: [[PROJ-1077]]; confirmed [[PROJ-1131]]_

## Dependencies & Tooling

### [Pattern]: Pin transitive CVE fixes with a glob resolution
- **Rule**: For a vulnerable transitive dependency use `"**/<pkg>": "<safe>"` in `resolutions`; a bare name only works when the package is hoisted to the top level. Run `yarn why <pkg>` first — if no caller reaches the vulnerable code path, document the no-op instead of bumping.
_Source: session 2026-06-03 (PR #351)_

### [Pitfall]: packages/ui builds before apps/web
- **Rule**: After changing a type in `packages/ui`, run `npm run build -w packages/ui` before typechecking `apps/web`; the app resolves the built `dist/`, not the source. CI does this implicitly, local does not.
- **Why**: A green CI and a red local typecheck on the same commit cost an afternoon.
_Source: session 2026-07-30_

### [Workflow]: Commit scope is the ticket key
- **Rule**: `fix(PROJ-1180): bump <pkg> to <version>` — one commit per package, one branch and PR per batch. Never `(deps)` or `chore(deps)`: release notes group by scope and those entries fall out.
_Source: session 2026-06-03 (PR #351)_

## Permissions & Feature Flags

### [Pitfall]: A wrapper around a gated component stacks gates
- **Rule**: When a wrapper renders a shared component that already checks a permission, the wrapper gates on the same scope (or an intentional superset) — never on a sibling wrapper's scope copied over.
- **Why**: An Approve button required two scopes where the shared child needed one; a whole role lost the control.
_Source: [[PROJ-1083]]_

### [Pattern]: Flags are read at the route boundary and passed down
- **Rule**: One `useFlag()` call per route-level component; children receive booleans as props. No component below the route reads the flag client.
- **Why**: Keeps the flag removable with one deletion and testable with one prop.
_Source: code-observation (seed 2026-05-02); reinforced [[PROJ-1120]]_

### [Pitfall]: A missing flag key evaluates to false silently
- **Rule**: Create (or rename) the key in the flag service before the code that reads it merges. The client returns `false` for an unknown key with no warning.
- **Why**: Two launches "did nothing" on the deployed environment because the key was created after the deploy.
_Source: [[PROJ-1099]], [[PROJ-1120]]_

## Code comment hygiene

A comment states a non-obvious constraint a future reader cannot infer — nothing else. Default to none; names, types and the commit message carry intent. No reasoning-to-the-reviewer, no restating the code, no ticket keys or "used to be" history. Full rule and examples: **[[codebase-patterns-shared.md]]**.

## Lessons Learned

### [Build/CI]: Two test runners share the .test.ts extension
- **Rule**: A new standalone `*.test.ts` unit file goes into the vitest `include` list AND the jest `testPathIgnorePatterns`. `.test.tsx` is auto-collected by vitest and ignored by jest by default.
- **Why**: Both tickets lost the same twenty minutes: first the file was not collected, then the other runner collected it and failed on foreign globals.
_Source: [[PROJ-1103]], [[PROJ-1131]]_

### [Pitfall]: An early-return empty state hides siblings added later
- **Rule**: A list component that returns `<EmptyState>` on `items.length === 0` must gate on every list it renders, not the first one. Add the new group's emptiness to the condition in the same commit.
- **Why**: A second group rendered below the first was invisible on exactly the orders it was built for.
_Source: [[PROJ-1088]], [[PROJ-1131]]_

### [Workflow]: Base moved under a reviewed PR — merge into the branch, do not rebase
- **Rule**: When the base branch advances after approval, `git merge origin/main` into the branch and re-run the gates. A rebase and force-push invalidates the review and the CI history.
_Source: [[PROJ-1116]], [[PROJ-1131]]_

---

## What real files drift toward

This file is held at the shape `/learn` is told to produce. Six real files measured for this example (157 to 5,876 lines; 6 to 243 entries) drift from it in the same four ways, and this is what to expect from your own after a year:

1. **The `last-run` marker becomes a stack** — one line per run, oldest at the bottom, free text appended after the counts. Three to eight lines before the title.
2. **The Index stops being complete** — "entries added from <date> onward" footnotes appear; older entries are found by scrolling, not through the Index downstream commands actually read.
3. **Entries outgrow eight lines** — the mean drifts to 6–24 lines, the longest past 400; the ticket link was supposed to carry the war story, and does not.
4. **The seed banner never leaves** — "observed from the codebase structure, not learned from delivered tickets" still sits above twenty learned entries.

Also seen: three tag spellings in one file (`[Pattern]`, `Pattern:`, numbered `§14`), a 12-line comment-hygiene block pasted verbatim into every repo instead of the one-line pointer above, and `_Source:` lines that pick up raw PR URLs and teammate first names — which is what `upstream.py check` exists to catch. `/learn` §2.5 (retire) and §5 (Index, marker) are the countermeasures; they work only when run.
