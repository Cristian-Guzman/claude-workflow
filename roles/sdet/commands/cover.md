---
name: cover
version: 0.10.3
description: Write automated coverage for one feature, URL, endpoint or API collection — explore (bounded), propose scenarios, pick, write, BREAK-TO-VALIDATE every test, run, grade. The SDET fold of /clarify + /ticket + /verify; a test that cannot fail is rejected, never committed. With no argument, lists uncovered routes as picks.
argument-hint: "[<feature> | <URL or /route> | \"GET /path\" | <collection.json>] [--tier smoke|feature|cross] [--mode ui|api|component] [--mcp] [--static] [--env <name>]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - Task
  - AskUserQuestion
---
> **Model floor: opus** — test design that must fail for the right reason. This is guidance, not a pin: the command inherits the session model. If you are a smaller model than the floor, say so in one line at the start and continue.

<objective>
Turn one target — a feature name, a route, an endpoint, or an in-repo API collection — into committed,
proven tests on a `test/<slug>` branch, in ONE command. "Proven" has a precise meaning here: each
test was broken on purpose and failed for the mutated reason, then the revert was shown. A test that
stays green under every applicable mutation is rejected and not committed. Verifying tests with tests
is circular; break-to-validate is the receipt that is not.

Stops after the gate table. The next step is `/pr-creation` (or `/log` to mint a tracker record). Nothing chains.
With no argument, `/cover` prints the unscored list of app routes no spec visits and offers them as picks.
</objective>

<principles>
Harvested from the retired `/test-plan`; apply every one to every scenario:
1. **Mechanism-first.** Read what the code path actually does before choosing a test. A debounce the
   code does not have is not worth a fake-timer test. Verify the mechanism, then pick the assertion.
2. **Adversarial by default.** The target describes the happy path. You add the edge it omits — empty,
   null, overflow, unknown enum, concurrent, permission-denied, wrong order. Regressions live there.
3. **Name the regression-class risk.** When a change could silently undo shipped behaviour (a control
   going read-only, a reset wiping persisted state), pin it as a named guard test, not a generic case.
4. **State coverage boundaries out loud.** What this surface cannot automate is reported as a manual
   remainder, never faked green. An honest "manual" beats a mocked test pretending to prove the real thing.
Plus the role's own rules: own your data (create what you assert on, under a name you control); the
cheapest honest level the repo's own tags define; deterministic flag gating only — never infer a flag
from whether an element rendered.
</principles>

<process>

## 0. Detect repo, classify tier, load the role's context

**0.1 Repo.** Reuse the `/ticket` §0 contract: repo hint in `$ARGUMENTS` → CWD one level below the
workspace root → list `*/CLAUDE.md` and ask via AskUserQuestion. Store `REPO_ROOT`, `REPO_NAME`.
Load `{REPO_ROOT}/CLAUDE.md` (warn if absent) and the repo profile
`$WORKSPACE_ROOT/.claude/repo-profiles/{REPO_NAME}.yaml`, in particular the `e2e:` block
(`enabled`, `spec_dir`, `run_command`, `config`, `sideload_only`; `local_base_url`, `feature_map`,
`smoke_specs` when present) and `jira_project`. Never hardcode `e2e/` or `yarn test:e2e`. If the
profile is silent, auto-detect: a `playwright.config.*` AND a `test:e2e`-style script AND a spec dir.
`RUN_CMD` = `e2e.run_command` or `npx playwright test`.

**0.2 Mode.** `--mode` wins; else: argument looks like `GET|POST|… /path` or names a
`*.postman_collection.json` / `openapi*.{json,yaml}` → `api`; the profile `type` is `backend-*` →
`api`; the argument names a component file or the repo has no e2e → `component`; otherwise `ui`.

**0.3 Tier — classify FIRST, before loading anything else** (the `routing.md` discipline: right-size
the ceremony, never start heavy "to be safe"). First matching row wins:

| Signal | Tier | What it changes |
|---|---|---|
| `--tier smoke`; one URL + one verb; a `feature_map` row with ≤2 interactive elements; "smoke" in the argument | **smoke** | 1 route explored, 1 scenario presented as a single confirm, 1 mutation, no agents |
| default; one feature or endpoint inside one repo | **feature** | bounded explore (≤4 routes), 3–8 scenarios, multi-pick, one mutation per test |
| needs a new helper/page object, a role switch, data seeding, or UI + API together; `--tier cross` | **cross** | phase plan (helpers → tests → b2v + run) with a pause between phases; `codebase-investigator` allowed; ≥2 mutation kinds across the set |

Log `- [HH:MM] /cover: tier={tier} mode={mode}` in the state file (§0.5). Re-tier out loud if the
work turns out bigger; never silently.

**0.4 Role context (load per tier).** Always: `$WORKSPACE_ROOT/.claude/testing-patterns-shared.md` if it exists (shared rules, first), then `{REPO_ROOT}/.claude/testing-patterns.md` (the level
policy — what `@smoke` / `@integration` / `@e2e` mean HERE), `selectors.md` (`## Conventions` first),
`test-data.md`, `environments.md`, `flaky-ledger.md` (skip silently when a file is absent — the
templates are seeded by the role install and may be empty). Feature + cross: the nearest specs and the
helper modules under `{spec_dir}/utils/` (or wherever `selectors.md ## Helpers / page objects` points).
Cross only: `codebase-patterns.md` sections whose index matches the feature area.

**0.5 State file.** Create `{REPO_ROOT}/.claude/tickets/cover--<slug>.md` (slug from the target:
`items-create`, `get-items`, `orders-collection`). Frontmatter:
```yaml
---
kind: cover
slug: items-create
ticket: null                 # set later by /log, never by this command
repo: web-app
branch: test/items-create
base_branch: main            # from the profile
status: planning             # planning → in-progress → ready-for-pr (then /pr-creation, /ci-check, /learn)
tier: feature                # smoke | feature | cross
mode: ui                     # ui | api | component
exploration: pending         # live-pw | mcp | static — set in §1
created: 2026-01-01T10:00:00Z
updated: 2026-01-01T10:00:00Z
pr_number: null
---
```
Body sections, in order: `## Scenarios`, `## Break-to-validate receipts`, `## Gate table`,
`## Files Modified`, `## Event Log`, `## Evidence`, `## Retrospective`. Event lines follow the schema
(`- [HH:MM] /cover: …`, append-only). Artifacts (explore screenshots, b2v originals, JSON reports) go
to the sibling dir `{REPO_ROOT}/.claude/tickets/cover--<slug>/` — under `.claude/tickets/`, so they
are git-ignored and never indexed.

**0.6 Branch.** `git -C {REPO_ROOT} status --porcelain` — a dirty tree means ask before switching
(never lose someone's work). Then `git checkout -b test/<slug>` from the profile's `base_branch`
(pull `--ff-only` first). The base-branch guard blocks every edit until this is done; do it now.

## 0-alt. No argument → the gap list (unscored)

When `$ARGUMENTS` carries no target, do NOT explore or crawl. Compute two sets mechanically and print
the difference, sorted by path:

**App routes** (first that applies, union when several exist):
- Next App Router: `find {app_dir} -name 'page.tsx' -o -name 'page.jsx' -o -name 'page.ts'` → strip
  the app dir, strip `/page.*`, drop route-group segments `(…)`, keep `[param]` segments. `app/` and
  `src/app/` are both tried.
- React Router: `grep -rhoE '<Route[^>]*path=["'"'"'][^"'"'"']+'` and `path:\s*["'][^"']+` in router
  files → the path literals.
- Profile `e2e.feature_map` keys (route prefixes) are added as Tier-0 rows.

**Routes the suite already visits:**
- `page.goto(` literals: `grep -rhoE 'goto\(\s*[`"'"'"'][^`"'"'"']+' {spec_dir}` → path part only.
- Helper navigators: constants the suite imports from the app (`grep -rhoE 'import \{[^}]*\} from ["'"'"'][^"'"'"']*(routes|paths|urls)[^"'"'"']*' {spec_dir}`), then resolve each constant's string
  value in the app source (`grep -rhoE 'export const <Name>\s*=\s*["'"'"'][^"'"'"']+'`). A route reached
  only through a navigator counts as visited.
- Parametrised matching: `[id]` and `:id` match any single segment.

Output (no scores, no ranking — the roadmap owns the scoring model):
```
Routes with no spec visit (N of M) — sorted by path
  /items
  /items/[id]/edit
  /orders-v2/review
  …
Visited: K routes · unresolvable navigators: J (listed)
```
Then AskUserQuestion: "Cover which one?" with up to 4 options (the first alphabetical, plus "another —
I'll type it"). The pick becomes `$ARGUMENTS`; continue at §0.2 with the chosen route. Record
`- [HH:MM] /cover: gap list routes={M} uncovered={N} picked=<route>` once a state file exists.

## 1. Explore (bounded) — know the surface before proposing

Smoke: 1 route. Feature: ≤4 routes. Cross: ≤4 per phase. Never the whole app — that is the roadmap's
`/gaps`. Record `exploration:` in the frontmatter.

**1.1 Pre-flight.** `curl -sk --max-time 3 -o /dev/null -w '%{http_code}' {e2e.local_base_url or dev_server_url}`.
Not 2xx/3xx → tell the user the server is down and continue with the **static** path (1.4) unless they
start it. `--static` forces 1.4. `sideload_only: true` → static only; the real surface is a manual
remainder by definition.

**1.2 Default driver — the repo's own Playwright, not MCP.** The Playwright MCP has a history of
hanging mid-session in this workflow; the repo's runner reuses its auth `setup` project, storageState
and baseURL for free and bounds every hang to one test timeout. Write a throwaway spec
`{spec_dir}/.cover-explore-<slug>.spec.ts` (the hook exempts this name) with ONE `test()` per route:
```ts
import { test } from '@playwright/test';
const routes = ['/items', '/items/new'];           // ≤4
for (const route of routes) {
  test(`explore ${route}`, async ({ page }, info) => {
    const calls: string[] = [];
    page.on('request', r => { const u = new URL(r.url()); if (u.origin === new URL(page.url() || r.url()).origin) calls.push(`${r.method()} ${u.pathname}`); });
    await page.goto(route);
    const snapshot = await page.locator('body').ariaSnapshot();
    const testids = await page.$$eval('[data-testid]', els => els.map(e => e.getAttribute('data-testid')));
    await info.attach('explore', { body: JSON.stringify({ route, snapshot, testids, calls: [...new Set(calls)] }), contentType: 'application/json' });
    await page.screenshot({ path: `.claude/tickets/cover--<slug>/explore-${route.replace(/\W+/g, '_')}.png`, fullPage: true });
  });
}
```
Run: `${RUN_CMD} {spec_dir}/.cover-explore-<slug>.spec.ts --timeout 20000 --workers 1 --retries 0 --reporter=json > .claude/tickets/cover--<slug>/explore.json`.
Read the attachments (roles + accessible names, testids, same-origin request paths) and `open` one
screenshot for the user. **Always delete the throwaway spec afterwards** (`rm`), even on failure, and
confirm with `git -C {REPO_ROOT} status --porcelain {spec_dir}` showing nothing new. `exploration: live-pw`.

**1.3 `--mcp` (opt-in only).** When the user passes `--mcp` and the Playwright MCP tools are present:
≤12 calls total (`browser_navigate`, `browser_snapshot`, `browser_network_requests`, one
`browser_take_screenshot` per route). Stop at 12 and fall back to 1.4 for the rest. `exploration: mcp`.

**1.4 Static fallback.** Routes: `find … -name page.tsx` / `<Route path=` (as in §0-alt). Interactive
inventory: `grep -rhoE 'aria-label=["'"'"'][^"'"'"']+|data-testid=["'"'"'][^"'"'"']+' {feature_dir}` plus
button/link text literals in the feature's components. Endpoints: `grep -rhoE '(fetch|axios\.[a-z]+|useQuery|useMutation)\([^)]*' {feature_dir}` and the BFF/API client module. `exploration: static` — say so in
the summary; static scenarios get one extra mutation (route-500 or dead-selector) in §5 because nothing
was observed live.

**1.5 API mode.** Source of truth is in-repo: the collection JSON, the OpenAPI/swagger file, or the
route handlers. Enumerate requests → `METHOD /path`, required params, auth, documented statuses.
If `$WORKSPACE_ROOT/.claude/agents/contract-verifier.md` exists and the tier is feature/cross, run it in
read-only mode (it never executes mutations) for the schema-vs-live diff; **inline fallback**: read the
spec file and `curl -sk` ONE idempotent `GET` per endpoint with the env's auth header from
`environments.md`, diff the keys against the documented schema by hand.

**1.6 Cross tier only — `codebase-investigator`.** If the agent file exists:
`Task(subagent_type: "codebase-investigator", focus: "reuse", prompt: "helpers, fixtures, page objects and seeders under {spec_dir} relevant to <feature>; role/permission gates on its routes")`.
**Inline fallback**: `grep -rlE 'export (async )?function|export const' {spec_dir}/utils` + read the
exports' names; `grep -rn 'storageState\|role' {e2e.config}` for role projects. Smoke and feature tiers
never fan out.

## 2. Propose scenarios

Build the table, one row per scenario, applying the four principles + the role rules:

| # | scenario | level | selector plan | data needs | mutation plan | auto/manual |
|---|---|---|---|---|---|---|

- **Level** = the cheapest honest tier from the repo's own tags in `testing-patterns.md` / CLAUDE.md
  (e.g. `@smoke` < `@integration` < `@e2e`; `unit` for pure logic; component for one component's DOM).
  Do not invent tiers the repo lacks.
- **Live-data edge shapes** (borrowed from the ui-fidelity agent): empty/missing field, long text /
  unbroken token overflow, inactive/disabled state, mixed item types/versions, very long lists (never
  `.first()` into a server-ordered list — search by the unique name you created). Add the applicable
  ones as scenarios or as assertions inside one.
- **Mechanism-first check**: for each row, name the code path (file) you read that makes the assertion
  observable. "Not read" is not an option at feature/cross tier.
- **Regression-class guards**: anything the feature's `git log --since 90d` shows was recently changed
  or removed gets a named guard row.
- **Manual remainder**: `sideload_only: true` surfaces, real gestures, server-side-only enforcement →
  `manual` column with the minimal manual step (the surface's real viewport). Never a mocked test
  pretending to prove it. Keep the remainder short; if it is long, more should move up.
- Already covered: grep `{spec_dir}` for the route/testid/copy before proposing; a scenario an existing
  spec asserts is listed as `covered by <spec>` and dropped from the pick, unless it is `.skip`-gated
  or guarded by `isVisible().catch(() => false)` — that is NOT covered; propose the un-skip as a row.

Smoke tier: exactly one row. Feature: 3–8. Cross: grouped by phase.

## 3. Pick

AskUserQuestion, multi-select, the table as options (smoke: a single confirm — "write this one?").
Once picked, execute — do not re-open the choice or re-rank. Write the picked rows into
`## Scenarios` with `status: pending`. Set `status: in-progress`, log the event.

## 4. Write

For each picked scenario, in order:
- **File**: `e2e.feature_map` entry for the route if one exists → extend that spec; else
  `{spec_dir}/<area>/<feature>-<action>.spec.ts` following the suite's own naming (look at siblings).
  Component tests go next to the component the repo's way (`testing-patterns.md ## File Naming`).
- **Selectors**: the priority order and bans in `selectors.md ## Conventions` (default order if the file
  is empty: role + accessible name → label → testid → stable CSS hook; banned: presentational
  class selectors, copy-as-selector for incidental copy, `waitForLoadState('networkidle')`, blanket
  `waitForTimeout`). Readiness = a web-first assertion, never a sleep.
- **Data**: create what you assert on, named `e2e-<slug>-<Date.now()>`, through the seeders in
  `test-data.md`; clean up in `afterEach`/`afterAll` or via the suite's reset helper. Accounts come from
  env var NAMES listed in `test-data.md`, never literals.
- **Flag gating**: `test.skip(!flag.isOn('X'), 'X off in this environment')` with a deterministic read
  (flag client / env var / documented fixture) — never a DOM probe. Past the gate, every assertion is
  hard. The hook enforces this shape.
- **Tags**: the level tag from §2 (`@smoke` etc.) so the repo's projects pick it up.
- If `{REPO_ROOT}/.claude/agents/e2e-writer.md` exists, you may delegate the drafting with the row +
  rules above as the prompt; **inline fallback** = write it yourself by these rules. Lint before b2v:
  `npx eslint --no-ignore <new specs>` (the suite dir is often eslint-ignored; `--no-ignore` is the
  only honest lint).
- Append each file to `## Files Modified` as `- path — one-line why`.

## 5. BREAK-TO-VALIDATE — mandatory, per test

A test earns its place by failing for the right reason when the thing it claims to check is broken.
No test is committed without a receipt. Apply in place, run only that test, require `exit ≠ 0` AND a
failure message that names the mutated expectation, then prove the revert.

**Mutation menu** (pick ≥1 per test; cross tier: ≥2 different kinds across the set; static-explored
scenarios: ≥2 per test):

| Mode | Mutation | How | Proves |
|---|---|---|---|
| UI | `expected-text` | flip the asserted text / role name in the spec | the assertion is load-bearing |
| UI | `route-500` | in a sibling `.cover-b2v-<slug>.spec.ts` that imports the test body, `page.route('**/<flow endpoint>', r => r.fulfill({ status: 500 }))` before navigation | the test observes the backend, not a cached render |
| UI | `dead-selector` | swap the locator to a testid that does not exist | a missing element fails LOUDLY — catches `isVisible()` without `expect` and `.catch(() => false)` guards |
| UI | `no-persist` | fulfil the mutation request with 2xx but do not persist (route to an echo) | the test checks post-mutation state, not just the click |
| API | `status-code` | expected `200` → `201` | status assertion is real |
| API | `schema-drop` | remove a required field from the asserted shape / fixture | shape assertion is real |
| API | `wrong-body` | point the env var at an echo/mock server for one run | the test reads the body |
| Component | `expected-text` | flip the asserted text | — |
| Component | `error-shape` | mock the hook/service to return an error or empty | error/empty branches are asserted |
| Component | `prop-removed` | drop the prop the test claims to exercise | the prop is load-bearing |

**Mechanics per mutation:**
```bash
# 1. snapshot (new, untracked spec) — tracked specs use git instead
cp {spec} .claude/tickets/cover--<slug>/b2v/{basename}.orig
# 2. mutate (Edit), then run ONLY this test
${RUN_CMD} {spec} -g '<title>' --retries 0 --workers 1 --reporter=line; echo "EXIT=$?"
# 3. revert and PROVE it
git -C {REPO_ROOT} checkout -- {spec} && git -C {REPO_ROOT} diff --exit-code -- {spec}   # tracked → 0
cp .claude/tickets/cover--<slug>/b2v/{basename}.orig {spec} && cmp {spec} .claude/tickets/cover--<slug>/b2v/{basename}.orig   # untracked → 0
rm -f {spec_dir}/.cover-b2v-<slug>.spec.ts
```
Never run the whole suite for b2v. Never leave a mutation in place — the revert proof is part of the
receipt.

**Receipt** — appended under `## Break-to-validate receipts`, one block per mutation:
```yaml
- test: "e2e/items/items-create.spec.ts › creates an item"
  mutation: expected-text
  cmd: "npx playwright test e2e/items/items-create.spec.ts -g 'creates an item' --retries 0 --workers 1 --reporter=line"
  exit: 1
  failure: "toHaveText … Expected: 'Add itemz' Received: 'Add item'"
  reverted: "git diff --exit-code -- e2e/items/items-create.spec.ts → 0"
```
**Verdicts:** `exit ≠ 0` with the named failure → receipt `PASS`. `exit 0` under a mutation → that
mutation did not bite; try another applicable one. **A test that passes under every applicable
mutation is REJECTED**: delete it, mark the scenario `rejected: cannot fail` in `## Scenarios`, and say
so in the summary. A `dead-selector` mutation that exits 0 is also a `selectors.md` log row (§7).
Failure for an unrelated reason (syntax error, auth) is not a pass — fix and re-run.

## 6. Run, lint, grade

**6.1 Run** the new/changed specs against the branch's local server when the tests assert behaviour
this branch introduces (deployed dev serves the code without it): `PLAYWRIGHT_BASE_URL={e2e.local_base_url} ${RUN_CMD} <specs> --workers 1 --retries 0 --trace on --reporter=json > .claude/tickets/cover--<slug>/run.json`
(and `--reporter=line` to the terminal — never pipe a gate through `tail`/`head`; check `$?`).
If the local server is down, run against the configured default and SAY which target was used.
Component/API: the repo's `test_command` scoped to the new files.

**6.2 Count four numbers** with `python3 $WORKSPACE_ROOT/.claude/scripts/triage-cluster.py .claude/tickets/cover--<slug>/run.json --spec-dir {spec_dir} --key-pattern {jira_project}` —
it prints `passed= failed= known-failures-with-bug= skipped=` followed by `known-failures-unkeyed=`. Known
failures (`test.fail(true,'BUG …')`) are never passes; a known failure without a key is a violation — counted
only under `known-failures-unkeyed`, never under `known-failures-with-bug` — and fails the `known-failures-linked` gate.

**6.3 Lint**: `npx eslint --no-ignore <new specs>`; `exit 0` required.

**6.4 Skip-guard scan** on the diff: `git diff {base}...HEAD -- {spec_dir} | grep -nE '^\+.*(\.(skip|fixme|only)\(|isVisible\(\)\.catch\(\(\)\s*=>\s*false\)|waitForLoadState\(.networkidle.\)|\[class\*=)'`
→ any hit without a `BUG`/`FLAKY` key or a deterministic flag read fails `no-skip-guard`.

**6.5 Gate table** — written under `## Gate table`, graded by the shared scorer, never hand-scored:

```markdown
| Gate | State | Receipt |
|------|-------|---------|
| passes [BLOCKING] | PASS | exit 0 — passed=4 failed=0 known-failures-with-bug=0 skipped=0 (local, sha abc1234) |
| b2v-fails-when-broken [BLOCKING] | PASS | 4/4 tests have a receipt with exit≠0 + named failure + revert 0 (see receipts) |
| lint-clean | PASS | eslint --no-ignore exit 0 on 2 files |
| no-skip-guard | PASS | diff scan: 0 hits |
| known-failures-linked | PASS | 0 test.fail in run; 0 violations |
| observed-headed | UNVERIFIED | human: run `${RUN_CMD} <spec> --headed` against dev and confirm the flow visually |
```
`python3 $WORKSPACE_ROOT/.claude/scripts/verify-score.py {state file} --root {REPO_ROOT}`. A PASS
without a receipt scores FAIL; `UNVERIFIED` caps at 70% until the user confirms the headed run — then
append `- [HH:MM] user: [qa-confirmed via headed-run] <spec>` and flip the row to PASS with that event
as the receipt; re-run the scorer. Score < 70 → `status` stays `in-progress`; ≥ 70 → `ready-for-pr`.

**6.6 Event + evidence.** Append exactly:
`- [HH:MM] /cover gate score=NN sha=<short-sha> passed=A failed=B known-failures-with-bug=C skipped=D`
(`/pr-creation` §5.5a reads this line as the verification evidence for `kind: cover`). List under `## Evidence`:
explore screenshots, `run.json`, trace zips, the b2v originals dir.

## 7. Knowledge rows (log only — lessons are `/learn`'s job)

- `dead-selector` mutation with `exit 0`, or a selector you had to change from a banned form →
  one row in `{REPO_ROOT}/.claude/selectors.md ## AUTO:SELECTOR-LOG`:
  `- YYYY-MM-DD cover--<slug> class=<copy|class-selector|testid-missing|not-load-bearing> spec=<path> from=<old> to=<new>`
- A seeder/cleanup helper you wrote or discovered → `test-data.md ## Seeds / fixtures` row.
- A target or auth gotcha → `environments.md ## Known drift` row.
Never write a `## … lessons` entry here; patterns need a second occurrence and `/learn` promotes them.

## 8. Stop

Print the summary (format below), including the FOUR numbers and any rejected tests. Do not commit,
do not open a PR, do not run `/log` — the user paces those (`/pr-creation` next; `/log` if a tracker record
is wanted).

</process>

<output_format>
```
/cover <target> — tier={smoke|feature|cross} mode={ui|api|component} exploration={live-pw|mcp|static}
Branch: test/<slug>   State: {REPO_ROOT}/.claude/tickets/cover--<slug>.md

Scenarios: {picked}/{proposed} written · {rejected} rejected (cannot fail) · {manual} manual remainder
Break-to-validate: {receipts} receipts, {mutations} mutations, all reverts proven
Run: passed={A} failed={B} known-failures-with-bug={C} skipped={D}   (target: local branch | deployed {env})
Lint: eslint --no-ignore exit {0|N}

| Gate | State | Receipt |
| … (table as written to the state file) … |
Score: NN% ({p}/{n} gates) — {band}            ← from verify-score.py, never hand-written

Files: {list}
Manual remainder: {rows or none}
Next: /pr-creation (or /log to mint a tracker record). Nothing has been committed.
```
</output_format>

<guidelines>
- Classify the tier before loading anything; a smoke request must not fan out or explore 4 routes.
- The explore spec and the b2v sibling are throwaway: deleted every time, confirmed by `git status`.
- Never run the whole suite from this command — scoped runs only; the nightly owns full regression.
- Playwright MCP only on `--mcp`, ≤12 calls. Default is the repo's own runner.
- No test without a b2v receipt; no receipt without a proven revert; no "cannot fail" test committed.
- Known failures (`test.fail`) are never counted as passes — four numbers, always.
- Deterministic flag gating only; the `.catch(() => false) → skip` shape is a `no-skip-guard` failure.
- Pre-existing spec rot in files you did not touch is noted, not fixed here (`/triage` owns red runs).
- Aliases and neutral examples only in anything written to shared files — no product nouns, no people.
- The gate score is arithmetic from the scorer; receipts are the evidence, the model never grades itself.
</guidelines>

<success_criteria>
- [ ] Tier logged before context load; explore bounded (≤4 routes) and `exploration:` recorded
- [ ] Throwaway explore/b2v specs deleted; `git status` under `{spec_dir}` shows only intended files
- [ ] Every committed test has ≥1 b2v receipt with `exit ≠ 0`, a named failure and a proven revert
- [ ] Any test green under all applicable mutations was rejected and reported
- [ ] Run used `--workers 1 --retries 0 --trace on`; target named; eslint `--no-ignore` exit 0
- [ ] Gate table present, scored by `verify-score.py`; `observed-headed` UNVERIFIED until a `[qa-confirmed via headed-run]` event
- [ ] Summary prints passed / failed / known-failures-with-bug / skipped
- [ ] State file `tickets/cover--<slug>.md` has all seven sections and the `/cover gate score=` event
- [ ] Command stopped after the gate table — nothing committed, no PR, no `/log`
</success_criteria>
