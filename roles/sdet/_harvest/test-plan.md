---
name: test-plan
version: 0.8.0
model: "opus[1m]"
description: Turn a ticket's acceptance criteria into an adversarial, level-classified test coverage matrix. Picks the cheapest honest test level per AC, adds the edges the ACs don't state, checks against existing tests, and — for surfaces you can't run locally — emits the minimal manual-QA remainder. Read-only on source; writes a test-plan state file for /automate and /verify-coverage.
argument-hint: "PROJ-XXXX [focus: unit|integration|e2e]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Task
  - AskUserQuestion
---

<objective>
Produce a goal-backward test plan for ticket $ARGUMENTS.
Every AC must be provable by a test that fails for the RIGHT reason, at the CHEAPEST level that can
observe it, asserting behavior a user sees — never implementation. Surface the adversarial edges the
ACs omit. For surfaces that can't run locally/in CI (add-ins, mobile), maximize what the mocked tiers
cover and emit a tight, named manual-QA remainder. Persist the plan so /automate and /verify-coverage
can consume it. This command does NOT write tests — that is /automate.
</objective>

<principles>
The four judgment moves that separate a test plan from a checklist. Apply every one, every AC:
1. **Mechanism-first.** Read what the AC actually does in code before choosing a test. An AC that says
   "updates within 300ms" may describe a synchronous render with no debounce — don't script a fake-timer
   test for behavior that doesn't exist. Verify the mechanism, then pick the test.
2. **Adversarial by default.** The AC states the happy path. You state the edge it omits — empty, null,
   overflow, unknown-enum, concurrent, permission-denied, wrong-order. That's where regressions live.
3. **Name the regression-class risk.** When changing an AC's behavior could silently undo shipped work
   (a control going read-only, a reset wiping persisted state), pin it as a named guard, not a generic case.
4. **State coverage boundaries out loud.** What can't be automated on this surface is reported, never
   faked green. An honest "manual-QA-backed" beats a mocked test pretending to prove the real thing.
</principles>

<process>

## 0. Detect target repo & load baseline
Reuse the repo-detection contract from `/ticket` (§0): parse $ARGUMENTS for a repo hint, else infer from
CWD (must be one level below the workspace root, never the root itself), else list `CLAUDE.md` repos and
ask via AskUserQuestion. Store **REPO_ROOT** / **REPO_NAME**. Load `{REPO_ROOT}/CLAUDE.md` (warn if absent).

## 1. Load the acceptance criteria
Resolve ACs in priority order: (a) `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md` state file, (b)
`PROJ-XXXX-clarify.md` blueprint, (c) Jira via MCP or the `jira` CLI, (d) ACs pasted in $ARGUMENTS.
Normalize to a numbered list. If none found, stop and ask.

## 2. Load the TEST-convention layer (this is the primary read — not codebase-patterns)
- `{REPO_ROOT}/.claude/testing-patterns.md` — the most-read file for this command.
- The repo's **tiering table** — usually in CLAUDE.md (test scripts + Playwright tags) and/or the
  repo-profile. This is your **level policy**: it tells you what `unit` / `@smoke` / `@integration` /
  `@e2e` mean *here*, what runs in CI, and the coverage gate. Do not invent levels — read the repo's.

## 3. Detect surface & testability constraints  ← the step a normal-repo plan skips
Determine whether the real product can run locally/in CI at all:
- Read the repo-profile / CLAUDE.md for surface type (web · Word add-in · GDocs add-in · iOS · Go service).
- Set **LOCAL_TESTABLE** (can Playwright/dev-server drive the real thing?) and **E2E_BOUNDARY**
  (in-CI real-API, nightly-only, or sideload_only/manual).
- Add-ins (Apps Script `google.script.run`, Office.js) and iOS are typically **not** locally drivable →
  the mocked tiers (`unit`, mocked `@integration`) are the ONLY automated gate; the real surface becomes
  a **manual remainder**. Push maximum coverage down; keep the remainder small and named.

## 4. Map existing coverage
Delegate to `codebase-investigator` (or grep the test dirs) to find, per AC, which test files already
assert it. Mark each AC covered / partial / missing. Flag `.skip`/`.todo`/stubbed assertions as NOT covered.

## 5. Build the matrix — one row per AC
For each AC apply the four principles and record:
`AC | behavior | level | assert (observable) | adversarial/unstated edge | already covered?`
Choose the **cheapest level that can observe the behavior**: pure logic/helpers/one component → `unit`;
real DOM gestures or multi-component wiring → mocked `@integration`; true data/permission projection →
`@e2e` (respect E2E_BOUNDARY — if sideload_only, it routes to the manual remainder in §7).

## 6. Cross-cutting checks (not one AC, but required if the repo gates them)
- **a11y**: jest-axe on any new interactive component if the repo enforces WCAG.
- **Visual/compiled-CSS contract**: if styling is token/utility-based, assert the classes actually
  generate CSS (guards the "green unit test, wrong pixels" trap on `@layer`/emotion-override repos).
- **Contract drift**: if the ticket touches an API shape, run `contract-verifier` (types vs swagger vs
  live response) — snake/camel, null/undefined, projection drops.

## 7. Coverage boundaries & manual remainder
List what CANNOT be automated on this surface and why (server-side enforcement, sideload_only e2e, real
gestures). For each, give the **minimal manual step** that proves it in the live product. On a not-
LOCAL_TESTABLE surface this section is first-class and routes into `/qa` (use the surface's real viewport,
e.g. GDocs sidebar 320×820). Keep it short: if the manual list is long, more should have moved to §5.

## 8. Verdict & hand-off to /verify-coverage
State `N/total fully automatable`, and list the gaps /verify-coverage must key on (missing assertions,
untested regression-class risks, un-automatable ACs to accept-as-manual or promote to a nightly @e2e).

## 9. Persist the plan
Write `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-test-plan.md` with frontmatter
(`ticket, repo, artifact: test-plan, source_acs, test_stack, coverage_gate, e2e_tier`) + the matrix +
boundaries + verdict. This is the contract `/automate` implements and `/verify-coverage` audits.

## 10. Stop
Report the matrix summary and the file path. Do NOT author tests — that's `/automate PROJ-XXXX`.

</process>

<handoff>
Downstream: `/automate` reads this plan and writes the tests level-by-level in phases; `/verify-coverage`
audits that every AC has a real, passing, non-skipped test at the planned level; `/learn` harvests new
test traps into `testing-patterns.md` so the next run starts smarter.
</handoff>
