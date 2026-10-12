<!--
  selectors.md — per-repo selector contract for automated tests.
  READ by: /cover (before writing any locator), /triage (to classify selector drift).
  WRITTEN by: /cover and /triage (one AUTO:SELECTOR-LOG row per incident), /learn (promotes a
  lesson at the SECOND occurrence of the same class; a mechanically checkable lesson may become a
  hook/lint rule on the first).
  Seeding: replace the EXAMPLE conventions with the repo's own, fill the testid inventory and the
  helpers table from the suite; keep every entry sourced.
-->
<!-- last-updated: YYYY-MM-DD -->

# Selectors — {repo-name}

> Which locators are allowed here, which are banned, and what the suite already relies on.
> `/cover` reads `## Conventions` first; `/learn` grows `## Selector lessons` from the log.

## Conventions
<!-- EXAMPLE — replace with the repo's own order and bans. The shape (ordered list + bans) stays. -->

**Priority order — the first that yields a stable, unique match wins:**
1. `getByRole(role, { name: /accessible name/i })` — role + accessible name (an `aria-label` replaces visible text as the name).
2. `getByLabel(…)` for form fields.
3. `getByTestId(…)` — when no semantic hook exists. A testid is a contract: renaming it is a breaking change for the suite.
4. `locator(<stable css hook>)` — last resort, never a presentational class.

**Banned:**
- Presentational class selectors (`[class*=…]`, framework `*-root` classes, hashed module classes) — presentation is not contract.
- Copy as the primary hook for an element whose copy is incidental — assert copy separately when the copy is the thing under test.
- `waitForLoadState('networkidle')` — hangs for the full timeout under load; a web-first assertion is the readiness signal.
- Blanket `waitForTimeout(ms)` as readiness — tolerable only for a non-observable settle, with a comment saying why.
- `.first()` / `.nth(n)` into a server-ordered list — search by the unique name the test created, then assert on the single match.
- `isVisible().catch(() => false)` → `test.skip()` — a missing element is a LOUD failure; skips are for deterministic flag reads only.

_Source: code-observation (seed) — replace with `[[PROJ-XXXX]]` / `cover--<slug>` citations as rules are confirmed here._

## data-testid inventory
<!-- Mechanical: testids the app exposes vs testids the suite uses. Refresh from grep, not memory.
     app:   grep -rhoE 'data-testid=["'"'"'][^"'"'"']+' <feature dirs> | sort -u
     suite: grep -rhoE 'getByTestId\(["'"'"'][^"'"'"']+' <spec_dir>   | sort -u -->

| testid | component / route | used by specs | status |
|---|---|---|---|
| `items-list` | `/items` list | `e2e/<area>/<flow>.spec.ts` | used |
| `item-save` | item editor | — | unused |

_Source: code-observation_

## Helpers / page objects
<!-- One row per helper module the suite shares: what it exports and which routes it drives.
     A helper that fails takes every caller down with it — /triage clusters on these frames. -->

| module | exports | routes driven | notes |
|---|---|---|---|
| `<spec_dir>/utils/<area>-helpers.ts` | `createItem`, `openItem`, `archiveItem` | `/items`, `/items/[id]` | owns cleanup for what it creates |

_Source: code-observation_

## AUTO:SELECTOR-LOG
<!-- Append-only, one line per incident. Written by /cover (dead-selector mutation exit 0, banned
     form replaced) and /triage (broken-test clusters of subclass selector|copy). Dedupe by slug+spec.
     Format:
     - YYYY-MM-DD <cover--slug|triage--run-id> class=<copy|class-selector|testid-missing|testid-renamed|not-load-bearing|strict-mode> spec=<path> from=<old> to=<new> -->

## Selector lessons
<!-- Written by /learn when a class in the log recurs (promote_at: 2). One `### ` entry per lesson:
     imperative rule, why, provenance (the log rows / slugs). Mechanically checkable lessons are
     compiled into the hook or an eslint rule instead of staying prose. -->
