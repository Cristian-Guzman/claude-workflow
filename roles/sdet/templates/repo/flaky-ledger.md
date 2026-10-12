<!--
  flaky-ledger.md — per-repo LOG of flaky tests. Log-only: every incident gets a row, no lessons
  are written here (/learn promotes recurring cause classes into selectors.md / test-data.md /
  environments.md instead).
  READ by: /triage (pre-classifies tests already known flaky), /cover (avoid building on a flaky
  helper).
  WRITTEN by: /triage (one row per flaky cluster), /log --bug (adds the key to `fix`).
  Ids are FL-<n>, sequential; a `test.fixme(true, 'FLAKY FL-<n>')` quarantine must cite one.
-->
<!-- last-updated: YYYY-MM-DD -->

# Flaky ledger — {repo-name}

> One row per flaky incident. `rate_before`/`rate_after` are pass counts over N runs when measured
> (`k/N`), or `unmeasured`. Status: `open` · `fixed` · `quarantined (FL-n)` · `recurred` · `env-blocked`.

## Ledger

| id | test | first_seen | last_seen | rate_before | rate_after | cause_class | fix | status |
|---|---|---|---|---|---|---|---|---|
| FL-1 | `e2e/<area>/<flow>.spec.ts › <title>` | YYYY-MM-DD | YYYY-MM-DD | 7/10 | unmeasured | timing | replaced `waitForTimeout` with `expect(...).toBeVisible()` — PR #<n> | fixed |

<!-- cause_class vocabulary: timing · selector · data · order · env · unknown -->
