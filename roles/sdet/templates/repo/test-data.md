<!--
  test-data.md — per-repo catalog of the data automated tests depend on: accounts (as env-var
  NAMES only — never values), seeds and fixtures, reset/cleanup helpers, and the ownership rule.
  READ by: /cover (own-your-data rule, seeders to call), /triage (env-or-data classification).
  WRITTEN by: /cover and /triage (one AUTO:DATA-LOG row per incident), /learn (lessons at the
  second occurrence).
  Seeding: list the env var names the suite reads (grep process.env in the config and setup files),
  the seed/cleanup helpers the suite exports, and the shared fixtures. No secrets, ever.
-->
<!-- last-updated: YYYY-MM-DD -->

# Test data — {repo-name}

> What tests may use, what they must create for themselves, and how they clean up.

## Accounts and roles (env-var names only)
<!-- Values live in .env / the CI secret store. This file names the variables and what each unlocks. -->

| env var | role / purpose | shared? | notes |
|---|---|---|---|
| `TEST_USER_EMAIL` / `TEST_USER_PASSWORD` | default signed-in user | yes — rate-limited; do not log in per test, reuse the auth setup project | |
| `TEST_ADMIN_EMAIL` / `TEST_ADMIN_PASSWORD` | admin-only screens | yes | |
| `TEST_ORG_ID` | the org the seeded data belongs to | yes | |

_Source: code-observation (auth setup + config)_

## Seeds / fixtures
<!-- Helpers that create data, where they live, what they return, who cleans up. -->

| helper | creates | cleanup | location |
|---|---|---|---|
| `createItem(page, name)` | one item named `name` | `archiveItem` in `afterEach` | `<spec_dir>/utils/<area>-helpers.ts` |
| `fixtures/<entity>.json` | canned API responses for mocked tiers | n/a | `<spec_dir>/fixtures/` |

_Source: code-observation_

## Reset / cleanup
<!-- How a test (or a run) returns the environment to a known state. Say what is NOT possible too. -->

- Per test: delete/archive what the test created, by the unique name it generated.
- Per run: <reset script or "none — the shared org accumulates; search by name, never by position">.
- Never reset shared data another team seeds.

_Source: code-observation_

## Data-ownership rule
- **Create what you assert on.** Name it `e2e-<slug>-<timestamp>` so it is unique and recognisable.
- **Never assert on list position** in a shared, server-ordered list — search by the name you own.
- **Never mutate shared seed records** (the default org's baseline items) — create your own copy.
- A test that depends on data it did not create documents that dependency here, in `## Seeds / fixtures`.

## AUTO:DATA-LOG
<!-- Append-only. One line per data-related incident, written by /cover (new seeder/cleanup) and
     /triage (env-or-data clusters of subclass data). Format:
     - YYYY-MM-DD <slug> class=<shared-mutated|missing-seed|list-size|stale-fixture|cleanup-leak> detail=<one line> -->

## Data lessons
<!-- Written by /learn at the second occurrence of a class (promote_at: 2). -->
