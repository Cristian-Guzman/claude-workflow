# Role: SDET

Commands, scripts and knowledge files for people whose output is **tests**, not features. Installed
with `install.sh <target> --role sdet` (combine with `--role dev` when one person does both). The dev
pipeline takes a ticket in and produces code; this role runs the other way — the work comes first, a
tracker record is optional output.

## Pipeline

```
WRITE   /cover <feature | /route | "GET /path" | collection.json>  ──▶  /pr  ──▶  /ci-check  ──▶  /learn
          explore (bounded) → propose → pick → write → BREAK-TO-VALIDATE → run → gate table
                └──▶ /log            (optional: mint the Story/Task FROM the state file)

RED RUN /triage --batch [report.json | --run]   or   /triage <spec>[:line]  ──▶  fix cluster-first  ──▶  /pr
                └──▶ real-app-bug → plain-language bug draft ──▶ /log --bug triage--<run>:C<k>

NO ARG  /cover            → unscored list of app routes no spec visits, offered as picks
```

Every step runs discretely — nothing chains. `/pr`, `/ci-check` and `/learn` are the shared core
commands; they resolve the branch's state file by `branch:` for any `kind:`.

| Case | Steps | Count |
|---|---|---|
| Tests for one feature, no tracker record | `/cover` → `/pr` | **2** |
| … with a tracker record | `/cover` → `/log` → `/pr` | 3 |
| A red run | `/triage --batch` → `/pr` | **2** (+ `/log --bug` per real bug) |
| One failing test | `/triage <spec>` → `/pr` | 2 |

## Commands

| Command | Does | Writes |
|---|---|---|
| `/cover` | Classifies the tier (smoke / feature / cross) FIRST, explores ≤4 routes with the repo's own Playwright (MCP only on `--mcp`; static fallback), proposes scenarios with the four harvested principles (mechanism-first, adversarial, regression-class guard, boundaries out loud), writes them, **breaks every test on purpose** and keeps only the ones that fail for the mutated reason, runs `--workers 1 --retries 0 --trace on`, lints with `--no-ignore`, grades a gate table with `verify-score.py`. | `tickets/cover--<slug>.md`, branch `test/<slug>` |
| `/triage` | Single mode: one red test behind the cause-known gate (max 2 rounds, then `/project-debug`). Batch: run or ingest a JSON report → `triage-cluster.py` → clusters by helper frame → selector → (class, endpoint, status) → (class, file) → classify largest-first → fix the shared cause → re-run only the cluster. newman adapter for in-repo API collections. | `tickets/triage--<run-id>.md` + `report.json` / `clusters.{json,md}` |
| `/log` | Mints the tracker record from the work: Story/Task for a cover file, Bug for a triage cluster. Dedupe → plain-language draft → AskUserQuestion → MCP → CLI → local file (`tracker_system: none`). Writes `ticket:` into the state file (no rename), offers `gh pr edit`, transitions through the assignee gate. | frontmatter `ticket:`; `tickets/<slug>-ticket.md` when no tracker |

## The hard rule

**Real application bugs keep their tests red.** Never delete a test. Never `.skip` a bug. The only
sanctioned quarantine is

```ts
test.fail(true, 'BUG PROJ-123: totals omit tax');   // keeps running; fails the suite the day the bug is fixed
```

`test.fixme(true, 'BUG PROJ-123')` only when the failure is a hang whose wall-clock cost blocks the
tier. Flaky tests get a `flaky-ledger.md` row (`FLAKY FL-n`) and keep running. Deterministic flag
gating (`test.skip(!flag, 'reason')`) is the one legitimate skip — the flag's value decides, never
whether an element happened to render.

`scripts/guard-test-integrity.sh` (PreToolUse on Edit/Write/MultiEdit, wired by
`templates/workspace/settings.sdet.fragment.json`) enforces exactly this and nothing more: it blocks an
added `.only(` and an added `.skip( .fixme( .fail(` that carries neither `BUG <KEY>-n` (KEY from the
profile's `jira_project`), nor `FLAKY FL-n`, nor the deterministic-flag shape. Throwaway
`.cover-explore-*` / `.cover-b2v-*` files are exempt. `Write` is judged on the delta against the
on-disk file.

## Four numbers, always

Every `/cover` and `/triage` summary prints

```
passed=A failed=B known-failures-with-bug=C skipped=D
```

**Why the command reports are authoritative and native reporters are not:** Playwright records a
`test.fail(...)` test as `expectedStatus: "failed"`; when its body fails, the outcome is *expected* and
the built-in reporters count it as a success — the suite looks greener than the product is.
`triage-cluster.py` reads `expectedStatus` and the annotation from the JSON report, lists those tests
under **"Known failures with bug (expected-fail, not passes)"**, never folds them into `passed`, and
lists any `test.fail` whose annotation lacks a `BUG <KEY>-n` key under **"Violations"**. A known
failure whose body now passes is reported as "bug fixed — remove the `test.fail`". The `/cover` gate
table carries a `known-failures-linked` row that fails on any violation.

## Break-to-validate

Verifying tests with tests is circular. A test earns its commit by failing — for the mutated reason —
under at least one mutation from its type's menu (UI: expected-text, route-500, dead-selector,
no-persist · API: status-code, schema-drop, wrong-body · component: expected-text, error-shape,
prop-removed), with the revert proven by `git diff --exit-code` (or `cmp` for untracked files). The
receipt `{test, mutation, cmd, exit, failure, reverted}` goes into the state file and feeds the
`b2v-fails-when-broken [BLOCKING]` gate. A test green under every applicable mutation is rejected.

## Files

```
roles/sdet/
  commands/cover.md  triage.md  log.md
  scripts/triage-cluster.py          # stdlib; Playwright JSON (or --newman) → clusters.{json,md} + four numbers
  scripts/guard-test-integrity.sh    # PreToolUse hook — the hard rule, mechanically
  templates/repo/selectors.md  test-data.md  environments.md  flaky-ledger.md   # seeded into {repo}/.claude/, project-owned
  templates/workspace/settings.sdet.fragment.json                                # merged into settings.json only when it is first seeded
  learn-targets.yaml                 # /learn's targets for this role (kinds cover, triage)
```

State lives in `{repo}/.claude/tickets/` as sidecars with `kind: cover|triage` frontmatter (indexed by
the shared `state-index-upsert.sh`); run artifacts live in a sibling dir `tickets/<kind>--<slug>/`.
The knowledge files are project-owned: the installer seeds them once and never overwrites them.

Tests: `python3 tests/b3-triage-cluster.test.py` · `bash tests/b3-guard-test-integrity.test.sh`.

## Deferred (see `docs/roadmap.md`)

`/gaps` as a command with its scoring model (churn × interactive elements × incidents) · `/stabilize`
with the measured rate-before/after protocol · `sdet-seed.sh` cold-start mining of the Playwright
config and suite · a sentinel escape hatch for the hook · quarantine expiry and a `/status` bucket ·
a `cluster-investigator` agent for parallel per-cluster reading · an SDET override of
`pr-branch-reviewer` · a custom Playwright reporter printing the four numbers in CI logs.
