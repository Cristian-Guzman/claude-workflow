<!--
  testing-patterns.md — per-repo catalog of test-writing patterns (frameworks, mock
  idioms, test placement, QA gotchas). Read by /ticket and /verify to write tests the
  way THIS repo does; grown over time by /learn after each completed ticket.
  Seed it at install: fill "Framework & Config" and "File Naming & Location" from the
  repo's real config, delete the EXAMPLE entries, and keep one entry per hard-won lesson.
-->
<!-- last-updated: YYYY-MM-DD -->

# Testing Patterns — {repo-name}

**Shared rules:** [[testing-patterns-shared.md]] — read first (never mock the unit under test, fixtures match the production read path, set-diff registry tests, …).
This file holds only what is specific to THIS repo: framework, mock idioms, placement, QA gotchas.

> Test-writing patterns learned from real ticket work. Run `/learn` to grow this file.

## Index
<!-- One line per entry below: anchor link + source ticket. Keep in sync as entries are added. -->
- [Mock the HTTP client module, not individual methods](#mock-the-http-client-module-not-individual-methods) — Source: [[PROJ-123]]

## Framework & Config
<!-- Seeded from the repo's real config at install time. -->

- **Framework**: <!-- e.g. Jest 29 + ts-jest / Vitest / Swift Testing / pytest -->
- **Run command**: <!-- e.g. `yarn test`, incl. any required env vars -->
- **Coverage command / threshold**: <!-- e.g. `yarn test:coverage`, 80% enforced -->
- **Source**: code-observation (config file path)

## File Naming & Location

- **Convention**: <!-- e.g. `*.test.ts`, never `.spec.ts` -->
- **Location**: <!-- e.g. `test/` mirrors `src/`; or colocated next to source -->
- **Source**: code-observation

## Mock Patterns

### Mock the HTTP client module, not individual methods
<!-- EXAMPLE — replace with your project's pattern -->
- **Rule**: Mock the whole client module at the top of the file, before any `describe()`; typing the mock keeps call assertions safe.
```ts
jest.mock('@app/services/UsersService');
const MockedUsersService = UsersService as jest.MockedClass<typeof UsersService>;
```
- **Source**: code-observation (`test/users/providers/UsersProvider.test.ts`)

## Test Structure

### Provider tests assert delegation, return value, and error propagation
<!-- EXAMPLE — replace with your project's pattern -->
- **Rule**: One `describe` per method. Verify (1) the service was called with the right args, (2) the return value matches the service response, (3) errors propagate via `rejects.toThrow()`.
- **Source**: [[PROJ-123]]

## Test Fixtures

- **Location**: <!-- e.g. `test/fixtures/` for canned API responses; factory functions for inline data -->
- **Source**: code-observation

## Manual / Visual QA

### Role-gated UI can't be screenshot-QA'd with one login
<!-- EXAMPLE — replace with your project's pattern -->
A change that only alters visibility for a specific role proves nothing under an admin login. Real before/after needs a second account with the restricted role; the unit test asserting the permission args is the dev-side proof.
_Source: [[PROJ-456]]_

## E2E drift taxonomy
<!-- /learn §2.6 appends one-line, spec-anchored drift lessons here under bucket sub-headings (route/path versioning · copy drift · transport migration · mock timing · selector/markup drift · data-scale assumption · false-green skip guard). Leave empty until this repo has an e2e suite; never re-create a second copy elsewhere. -->

## E2E suite health
<!-- /learn §2.6 stamps one HTML comment per pass: <!-- e2e-suite-health: repo=… date=… specs=N skips=N soft-guards=N failed-last-run=N|n/a --> — a diffable trend; a skip-rate that climbs while failures drop is drift being hidden, not fixed. -->
