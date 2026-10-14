---
name: triage
version: 0.10.1
description: Turn a red test run into causes. Single mode fixes one failing test behind the cause-known gate; batch mode runs or ingests a JSON report, clusters failures by shared helper → selector → endpoint → file (triage-cluster.py), classifies each cluster (broken-test / env-or-data / flaky / real-app-bug) and fixes cluster-first. Real app bugs stay red; quarantine only as test.fail(true, 'BUG KEY-n'); every summary lists known failures separately from passes.
argument-hint: "[--batch [report.json | --run]] | <spec>[:line] | \"<test title>\" [--newman] [--env <name>]"
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
> **Model floor: opus** — clustering red runs by shared cause. This is guidance, not a pin: the command inherits the session model. If you are a smaller model than the floor, say so in one line at the start and continue.

<objective>
A red run is a list of symptoms; the fix is almost always one cause behind several of them — a shared
helper, one renamed selector, one endpoint returning 500. `/triage` makes the model work at the cause
level: cluster first, classify each cluster, fix the cluster's root once, re-run only its tests.

The hard rule this command exists to enforce: **a real application bug keeps its test red.** Never
delete, never `.skip`. The only sanctioned quarantine is `test.fail(true, 'BUG <KEY>-<n>: …')` — it
keeps executing and fails the suite the day the bug is fixed — and `test.fixme` only when the failure
is a hang whose wall-clock cost blocks the tier. Every summary prints four numbers
(passed / failed / known-failures-with-bug / skipped); known failures are never passes. The
known-failures-with-bug count holds only `test.fail` tests with a `BUG` key — `triage-cluster.py` prints
the unkeyed ones next to it as `known-failures-unkeyed` (the violations count), never as passes nor as
known failures with bug.

Stops after the state table. `/pr-creation` is the user's next step; bug drafts hand off to `/log --bug`.
</objective>

<principles>
1. **Cluster before you read a single trace.** Three failures with one helper frame are one problem.
2. **Cause-known gate** (from `routing.md`): can you name the cause in one sentence? If not, you are
   guessing — max 2 rounds, then `/project-debug`.
3. **Reproduce locally before iterating through CI.** A red CI job is a report, not a repro.
4. **Red is signal.** Making a run green by silencing tests is the one outcome worse than red.
5. **Report faithfully.** Known failures, env blocks and unresolved clusters are listed as such, never
   folded into "passed" or dropped.
</principles>

<process>

## 0. Detect repo, mode, load context

**0.1 Repo** — the `/ticket` §0 contract (argument hint → CWD one level below the workspace root →
ask). Load `CLAUDE.md`, the profile's `e2e:` block (`spec_dir`, `run_command`, `config`,
`sideload_only`), `jira_project`, and the role files `environments.md` (targets, deploy-check,
flags), `test-data.md` (shared-data hazards), `selectors.md ## Conventions`, `flaky-ledger.md` (tests
already known flaky are pre-classified). Missing role files are skipped silently.
`RUN_CMD` = `e2e.run_command` or `npx playwright test`. `KEY` = `jira_project` (fallback: any
`[A-Z][A-Z0-9]+`).

**0.2 Mode.** `--batch` → §2. A spec path, `spec:line`, or a quoted title → §1 (single). Nothing →
ask which (AskUserQuestion: "One failing test, or a whole red run?").

**0.3 State file.** `{REPO_ROOT}/.claude/tickets/triage--<run-id>.md`, where `run-id` =
`YYYYMMDD-HHMM` for local runs, the CI run id for ingested reports, or the spec slug in single mode.
```yaml
---
kind: triage
slug: 20260101-1030
ticket: null                  # bugs get keys via /log --bug; written into cluster rows, not here
repo: web-app
branch: fix/triage-20260101-1030
base_branch: main
status: investigating         # investigating → in-progress → ready-for-pr | env-blocked
source: local-run | ci-run:<id> | report:<path> | single:<spec>
env: dev                      # target the run hit; deployed sha when known (environments.md deploy-check)
created: …
updated: …
pr_number: null
---
```
Sections: `## Clusters` (the table below), `## Known failures with bug`, `## Violations`,
`## Bug drafts`, `## Files Modified`, `## Event Log`, `## Evidence`. Artifacts
(`report.json`, `clusters.json`, `clusters.md`, traces) live in the sibling dir
`{REPO_ROOT}/.claude/tickets/triage--<run-id>/`.

**0.4 Branch.** Edits need a branch: `fix/triage-<run-id>` (or `fix/<spec-slug>` in single mode) off
the profile's base. Ask before switching if the tree is dirty.

## 1. Single mode — one red test

1. **Reproduce locally**: `${RUN_CMD} <spec> [-g '<title>'] --retries 0 --workers 1 --trace on --reporter=line`.
   Target = the environment where it failed (`environments.md`); if it failed only in CI, say so and
   run against the CI target's env vars.
2. **Read the failure** (message, call log, trace via `npx playwright show-trace` if needed) and
   **apply the cause-known gate**. One sentence or `/project-debug` — do not "try something to see".
3. **Classify** with the table in §3 and act accordingly. Fix attempts: max 2 rounds; a third red on
   the same test → stop, hand to `/project-debug` with the evidence collected.
4. **Prove the fix** by re-running only that test (`--retries 0`), then **break-to-validate once**
   (one mutation from `/cover` §5's menu for the test's type; receipt in the state file) — a repaired
   test that can no longer fail was neutered, not fixed.
5. Record the single-row cluster table and the four numbers (`passed=0|1 failed=… known=… skipped=0`),
   log, stop.

## 2. Batch mode — a red run

### 2.1 Get a JSON report

- **`--run`**: `${RUN_CMD} --reporter=json --trace on --retries 0 > .claude/tickets/triage--<run-id>/report.json`
  (`--workers` as configured; `--retries 0` so flakiness shows as failure, not as a quiet pass).
  Respect `sideload_only: true` → never run; ask for a report instead.
- **`report.json` path**: use it as-is.
- **CI blobs**: `gh run download <run-id> -n <blob-artifact>` → `npx playwright merge-reports --reporter json <dir> > report.json`.
  Record `source: ci-run:<id>` and the deployed sha the run hit (`environments.md` deploy-check —
  merged ≠ deployed).
- **API collections (`--newman`)**: `npx newman run <collection.json> -e <env.json> -r json --reporter-json-export report.json`
  for IN-REPO collections only; clustering below uses `--newman`.

### 2.2 Cluster (deterministic)

```bash
python3 $WORKSPACE_ROOT/.claude/scripts/triage-cluster.py .claude/tickets/triage--<run-id>/report.json \
  --spec-dir {spec_dir} --key-pattern {KEY} [--newman]
```
It writes `clusters.json` + `clusters.md` next to the report and prints the four numbers. Read
`clusters.md`: clusters sorted by size, key level (K1 helper frame, K2 selector, K3 class+endpoint+status,
K4 class+file), class hint, representative test, attachments. **Fallback without python3**: run with
`--reporter=line`, group failures by hand by the first stack frame under `{spec_dir}`, and label the
state file `clustering: manual (degraded)`.

Copy the script's **Known failures with bug** and **Violations** sections into the state file
verbatim. A violation (a `test.fail` without a `BUG <KEY>-<n>` key) is itself a work item: find the
bug (or file it via `/log --bug`) and add the key, or if the bug is gone, remove the `test.fail`.
A known failure reported as **now passing** means the bug was fixed → remove the `test.fail` in this
branch and say so.

### 2.3 Classify, largest cluster first

Work sequentially, one cluster at a time (no agent fan-out in this version). For each: open the
representative's trace/screenshot, read the key frame or selector, and classify:

| Class | Tell-tales | Action |
|---|---|---|
| **broken-test** | strict-mode violation, locator timeout on a renamed testid/copy, route literal moved, mock registered after the request fired, `.first()` into a grown list, false-green guard that finally went red | Fix the SHARED thing once (helper, selector, mock timing, route const); make the assertion loud; one `selectors.md ## AUTO:SELECTOR-LOG` row when the subclass is selector/copy |
| **env-or-data** | 5xx / `net::ERR_*` / navigation timeout / auth redirect across unrelated specs; a seeded account missing; rate limit | No spec edit. Record in `environments.md ## Known drift` or `test-data.md`; cluster `env-blocked`; re-run when the env is back. `contract-verifier` (if present, read-only) or one `curl` against the endpoint settles "env vs bug" for API-status clusters |
| **flaky** | `flaky_ratio ≥ 0.5`, pass-after-fail, timing/`waitForTimeout`/race | Fix the race if the cause is obvious (web-first assertion instead of a sleep; register the mock before navigation); otherwise append a row to `flaky-ledger.md` (`status: open`) and leave the test running. No stabilisation protocol in this version — the ledger is a log |
| **real-app-bug** | the test is right, the app is wrong (expected/actual match the spec/design; reproduces by hand) | **Test stays red.** Write the bug draft (§2.5). Quarantine ONLY if the test gates PRs: `test.fail(true, 'BUG <KEY>-<n>: <one line>')` once the key exists; `test.fixme(true, 'BUG <KEY>-<n>')` only for hangs/timeouts. Nightly-only suites: leave red |
| **bug-or-copy-drift** (script hint) | assertion mismatch on text | Decide: did the product deliberately change the copy (broken-test → update assertion, log a copy row) or did it regress (real-app-bug)? `git log -S'<old copy>' -- <app dir>` answers it |

The classification is the model's call; the script's `class_hint` is a hint. Record the evidence that
decided it (a frame, a trace step, a curl output) in the table — never "looks flaky".

### 2.4 Fix cluster-first, re-run only the cluster

For broken-test clusters: fix the shared cause, then
`${RUN_CMD} <the cluster's spec files> -g '<titles>' --retries 0 --workers 1 --reporter=line` —
the whole cluster should collapse. One repaired test per cluster gets a break-to-validate receipt
(`/cover` §5 menu; a repaired test that cannot fail was neutered). Max 2 rounds per cluster; a third
red → `/project-debug`, cluster `status: handed-off`. Never widen a timeout without a ledger reason.

### 2.5 Bug drafts (plain language — PM and support read them)

For each real-app-bug cluster, write under `## Bug drafts` — no code paths, no selectors:
```
### Bug draft B1 — <one-line title in product language>
Repro (from the test's steps): 1. … 2. … 3. …
Expected: <from the assertion, in words>
Actual: <from the received value, in words>
Environment: <env> · deployed sha <sha or "unknown — deploy-check not run"> · browser/project <name>
Evidence: trace .claude/tickets/triage--<id>/…/trace.zip · screenshot …
Affected tests: <N> (listed in cluster C<k>)
```
Hand-off: `/log --bug triage--<run-id>:C<k>` creates the tracker record and writes the key back into
the cluster row (and into the `test.fail` annotation if quarantined). Never create the ticket here.

### 2.6 State table

Under `## Clusters`, one row per cluster, kept current:

| id | size | key | class | evidence | action | status |
|---|---|---|---|---|---|---|
| C1 | 3 | K1 `e2e/utils/item-helpers.ts:42` | broken-test | strict-mode: 2 buttons named "Add" after the toolbar change (trace step 7) | scoped the helper's locator to the dialog; re-ran 3/3 green; b2v receipt #1 | fixed |
| C2 | 2 | K3 `network GET /items -> 503` | env-or-data | curl returns 503 from dev; deploy-check shows image 2 behind | environments.md drift row; re-run when deployed | env-blocked |
| C3 | 1 | K4 `assertion-mismatch in e2e/orders/total.spec.ts` | real-app-bug | total omits tax; reproduced by hand on dev | bug draft B1 → /log --bug; test stays red | open |

Statuses: `fixed` · `env-blocked` · `open` (red by design, bug pending) · `quarantined (BUG KEY-n)` ·
`ledger (FL-n)` · `handed-off (/project-debug)`.

### 2.7 Wrap

- Append `- [HH:MM] /triage run={run-id} clusters=N fixed=A env-blocked=B bugs=C flaky=D passed=P failed=F known-failures-with-bug=K skipped=S`
  (`/pr-creation` §5.5a reads a `/triage` event as the verification evidence for `kind: triage`).
- `status`: `ready-for-pr` when every non-env cluster is fixed/open-by-design; `env-blocked` when the
  remaining work waits on the environment; else `in-progress`.
- Skip-guard scan on the diff as in `/cover` §6.4 — the hook already blocked unkeyed quarantines at
  edit time; this is the belt to its braces.

## 3. Stop

Print the summary. Do not commit, do not open a PR, do not run `/log`. Next: `/pr-creation` for the fixes;
`/log --bug triage--<run-id>:C<k>` per real bug.

</process>

<output_format>
```
/triage {single <spec> | --batch source=<local-run|ci-run:id|report>} — {REPO_NAME} env={env} sha={sha|unknown}
State: {REPO_ROOT}/.claude/tickets/triage--<run-id>.md

Run: passed={P} failed={F} known-failures-with-bug={K} skipped={S}      ← known failures are not passes
Violations: {V} test.fail without a BUG key  (listed in the state file)

| id | size | key | class | evidence | action | status |
| … |

Fixed: {A} clusters ({n} tests) · env-blocked: {B} · real bugs (red, drafts ready): {C} · flaky → ledger: {D}
Re-run after fixes: passed={P'} failed={F'} known-failures-with-bug={K} skipped={S'}  (cluster-scoped)
Next: /pr-creation for the fixes · /log --bug triage--<run-id>:C<k> for each bug draft. Nothing committed.
```
</output_format>

<guidelines>
- Cluster first; classify largest-first; fix the shared cause once; re-run only the cluster.
- Real app bugs stay red. Never delete a test. Never `.skip` a bug. `test.fail(true, 'BUG KEY-n')` is
  the only quarantine; `test.fixme` only for hangs. The hook refuses anything else.
- A `test.fail` without a key is a violation row, not a known failure. A known failure that now passes
  means "remove the `test.fail`" — say it.
- Four numbers in every summary; known failures listed separately; `--retries 0` on every run.
- Max 2 repair rounds per cluster or test, then `/project-debug`. Reproduce locally before touching CI.
- Flaky clusters get a ledger row and keep running; there is no stabilisation protocol here.
- Bug drafts are plain language: repro steps, expected/actual, env + sha, evidence paths. No code paths.
- Only in-repo collections for newman; never author in a cloud workspace.
- Aliases and neutral examples in shared files; no product nouns.
</guidelines>

<success_criteria>
- [ ] A JSON report exists under `tickets/triage--<run-id>/` and `triage-cluster.py` ran (or manual clustering is labelled degraded)
- [ ] Known failures and violations copied into the state file; none counted as passes
- [ ] Every cluster has class + evidence + action + status; largest handled first
- [ ] Broken-test fixes were re-run cluster-scoped with `--retries 0`; one b2v receipt per repaired cluster
- [ ] No test deleted; no unkeyed `.skip`/`.fixme`/`.fail` added (diff scan clean)
- [ ] Real-app-bug clusters have a plain-language draft and their tests are still red (or `test.fail` with a key)
- [ ] Flaky clusters have a `flaky-ledger.md` row
- [ ] `/triage` event line written with the four numbers; status set honestly (`env-blocked` when waiting on env)
- [ ] Stopped after the table — nothing committed, no PR, no tracker record created
</success_criteria>
