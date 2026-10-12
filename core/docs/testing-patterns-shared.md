<!-- last-updated: 2026-10-12 -->
# Shared Testing Patterns (cross-repo)

Workspace-level test-writing rules that hold in every repo, referenced by each repo's `testing-patterns.md`. `/ticket`, `/verify` and `/cover` honor these alongside the repo-specific file; the repo file holds frameworks, mock idioms and placement — the things that differ per codebase. Each rule below recurred in at least two independent repos before it was promoted here.

## Unit & integration

1. **Never mock the unit under test.** Mock external dependencies (network, clock, storage, other modules); the code the test names runs for real. Test behavior — inputs → observable outputs — not implementation details. One test file per module; test the journeys a caller takes, not every branch in isolation. A test that passes because the subject was replaced proves nothing.

2. **Mock the module, not the method.** Mock the whole dependency module at the top of the file, before any `describe`, and type the mock. Per-method spies drift from the module's real export surface: a new export the subject starts using is silently real in one test and mocked in the next. Audit every mock site when a widely-mocked module gains an export.

3. **Fixtures must match the production read path.** Build fixture data by tracing what the consuming code actually reads, and give it exactly that shape — never add a field "to be safe" or copy a payload from a different endpoint. When one test mocks two coupled responses, define the shared ID set once and reference it from both; prefer count assertions over bare visibility checks so a half-rendered list fails.

4. **Test the cache wrapper, not the cache utilities.** Hit, miss, and *error-is-not-cached* are the behaviors a caller depends on; the key-building helpers are implementation. A green suite over `buildKey()` with no test of the wrapper is how a poisoned entry ships.

5. **Registry vs. manifest: write the set-diff test.** When a runtime discovers callables from a build artifact (a global registry, a plugin list, a generated allow-list, an event-name table), unit mocks hide registration gaps — the code works in the test and is never registered in the build. Add one test that set-diffs the source registry against the build manifest; emitted-but-unregistered is a failure. This is the canonical compile-to-check example: a prose pattern entry on the same bug recurred within a week; the set-diff test did not.

6. **Multi-fix bug: full state-matrix test before the next fix.** When a bug has survived more than one fix, stop fixing. Enumerate every state the surface can be in (empty / loading / error / disabled / mixed data / each flag value) and write the matrix as tests first; then fix. Each earlier fix moved the bug to a state nobody had enumerated.

## Accessibility

7. **`role="alert"` already implies an assertive live region.** Do not add `aria-live="polite"` (or `assertive`) to an element with `role="alert"` — the implicit value is `assertive`, and the explicit attribute either duplicates it or contradicts it. Assert on the role in tests; grep for the pair in review.

## How this file is used

- Repo `testing-patterns.md` files point here in their header ("Shared rules: … — read first") and hold only what is specific to that repo.
- `/learn` promotes a repo-level testing lesson here only on its **second** independent occurrence (two repos, or two tickets in repos with different stacks). A rule that names a framework, a file path or a product noun stays in the repo file.
- Seed packs (`templates/seed-packs/*/testing-patterns.seed.md`) carry stack-specific testing defaults; they are retired by `/learn` when uncited, these rules are not.
