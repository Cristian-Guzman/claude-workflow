# Batch 2 → requests for other batches and Wave 2

Batch 2 touched only: `core/commands/{pr,ci-check,learn,resume-ticket,status}.md`, `core/scripts/state-index-upsert.sh`, `core/docs/state-file-schema.md`, `tests/b2-upsert.test.sh`. Everything below is an edit Batch 2 needs but does NOT own.

## Wave 2 — hub files

### `core/docs/workflow-version.md`
- Add a 0.8.0 entry covering Batch 2:
  - `state-file-schema.md` → new `## Kinds (closed enum)` table + two machine-readable lines `<!-- kind-enum: … -->` / `<!-- kind-dirs: … -->`; sidecar contract `tickets/<kind>--<slug>.md` (kind, slug, ticket null|KEY, branch, status); `env-blocked` status; `-test-plan` legacy sidecar rule (kind `test-plan`, status `blueprint`, archived).
  - `state-index-upsert.sh` → generic `kind:` passthrough (enum wins over directory), `-test-plan` suffix rule, slug-keyed id for cover/triage (`<repo>:<kind>:<slug>`, immutable across `/log` re-keying), `null`/`~` ticket → null, **missing status now logs `missing status` to `schema-drift.log`** (previously `unknown` was silently in-vocabulary), declared kind outside the enum logs `non-schema kind`.
  - `/pr` → §2 resolves the branch's state file via `state/index.json` for any kind; `test/<slug>` branch row; §5.5a accepts `/cover: gate score=NN` / `/triage:` events; §8 writes `pr_number` into whichever file matched; §8.5 no-ops on `ticket: null`.
  - `/ci-check` → ticket-from-branch optional; §5.1 branch-keyed `delivered` for any kind; §5.1b cover spec list = `## Files Modified` specs; §3b item 5 → `/triage <spec>` on a red e2e job; Jira snapshot skipped on `ticket: null`.
  - `/learn` → §0 kinds from `learn-targets/*.yaml` (merged; fallback = today's grep); §2.7 is ONE parameterised routine (log → cluster by key → lesson at `promote_at`) with built-in `ui` + `process` targets — **§2.7b is kept as the process target's sub-heading so existing `§2.7b` citations in clarify.md / verify.md / workflow-version.md:67 stay valid**; §0.7 `--mine`; §2.5 criterion 6; §5 mark-learned for non-ticket kinds.
  - `/resume-ticket` → cover resumes at the first scenario without a break-to-validate receipt, triage at the first unresolved cluster. `/status` → fallback kind dirs read from the schema's `kind-dirs` line.
- Refresh the Hash Ledger lines for the 7 Batch-2 files (`shasum -a 256 <file> | cut -c1-8`).
- Line 67 (`/learn §2.7b Process Synthesis (new, PRIMARY output)`) still resolves; optionally reword to "§2.7 Target Synthesis — process target (§2.7b)".

### `core/commands/README.md`
- Bump the `pr`, `ci-check`, `learn`, `resume-ticket`, `status` rows to 0.8.0.
- `/learn` description: add `--mine` and "kinds from `learn-targets/*.yaml`".
- `/pr` + `/ci-check`: note "state file resolved by branch via the index — ticket-less `cover`/`triage` sidecars included".

### `README.md`
- Start-here SDET trio `/cover → /pr → /learn` is now true end-to-end: `/pr` finds the sidecar by branch and skips the tracker step on `ticket: null`; `/learn` scans delivered sidecars when the SDET `learn-targets` file declares `kinds: [cover, triage]`.
- Mention `/learn --mine` next to `scripts/mine-history.sh` in the install / cold-start section.

### `core/commands/bootstrap.md`
- Nothing required by Batch 2. (If the inlined `<command-specs>` carry a `/learn` or `/pr` spec, they are now stale vs 0.8.0 — Wave 2's reconcile item.)

### `templates/workspace/repo-profiles/_schema.yaml`
- No new field. `ci-check.md` §5.1b (cover spec list) uses the existing `e2e.run_command` + `e2e.spec_dir`.

### Product-noun sweep (Wave 2)
- `core/commands/resume-ticket.md` §1 table rows 2–3 and `status.md` examples still carry pre-existing product-domain slugs (`playbooks-v2*`); Batch 2 added only neutral rows (`orders-v2-checkout`, `nightly-2026-04-21`). Sweep as planned.

## Batch 1 — `install.sh`
- Install role learn-targets as a **directory**, not a single file: `roles/<role>/learn-targets.yaml` → `$CLAUDE_DIR/learn-targets/<role>.yaml` via `copy_core` (upstream-owned, drift-tracked). `/learn` §0 reads `$WORKSPACE_ROOT/.claude/learn-targets/*.yaml` plus `{REPO}/.claude/learn-targets/*.yaml` and merges all files (kinds unioned, targets appended). `roles/dev/learn-targets.yaml` should declare the two built-ins in the §0 contract shape (`file`, `log_section`, `lesson_section`, `promote_at`, `signals`) with `kinds: []` — `/learn` already has them built in, so the file is documentation + override seed, not a behaviour change.
- Also mirror `learn-targets/` into `.upstream-base/` in the same loop so `/upstream drift` covers it.
- No `.gitignore` change needed: `.claude/state/` already covers `state/mine/`.
- `tests/` directory now exists (Batch 2 added `tests/b2-upsert.test.sh`); `tests/install.sh.test` can assume it.

## Batch 3 — `roles/sdet/`
Contracts Batch 2 encoded that `/cover`, `/triage`, `/log` must honour:
- Sidecar file: `{repo}/.claude/tickets/<kind>--<slug>.md` with frontmatter `kind: cover|triage`, `slug:`, `ticket: null` (until `/log`), `branch:` (the `test/<slug>` branch — **this is the join key `/pr` and `/ci-check` use**), `status:` (ticket vocabulary + `env-blocked`), `created`, `updated`, `pr_number: null`. **`/log` writes `ticket: KEY` into the frontmatter and never renames the file** (index id `<repo>:<kind>:<slug>` is immutable).
- Event lines `/pr` §5.5a greps as verification evidence: `- [HH:MM] /cover: gate score=NN …` (optionally `sha=<short>`), and `- [HH:MM] /triage: …` for triage outcomes.
- `## Files Modified` must list every spec written (`- e2e/<area>/<flow>.spec.ts — …`): `/ci-check` §5.1b builds the post-deploy re-check list from the `*.spec.*` entries there.
- Scenario table (cover): one row per test; the break-to-validate receipt carries `reverted: yes|no` — `/resume-ticket` resumes at the first row without a receipt and `/learn` §5's integrity gate requires every row receipted before `learned`.
- Cluster table (triage): columns include class (`broken-test | env-or-data | flaky | real-app-bug`) and a resolution column; `/resume-ticket` resumes at the first row without a resolution; a `real-app-bug` row is "resolved" for the gate once its `/log --bug` draft/key is recorded (it stays red).
- `roles/sdet/learn-targets.yaml` must use the §0 contract: `kinds: [cover, triage]` (inline list form — the sed parser only reads that form), `targets[].file` repo-relative (`.claude/selectors.md`), `log_section`/`lesson_section` as literal `## …` headings, `promote_at` ≥ 2, `log_only: true` for the flaky ledger.
- Status `env-blocked` is in the schema vocabulary; `quarantined` is NOT (MVP has no quarantine state — roadmap).

## Batch 4 — `mine-history.sh`, shared docs, settings
- `candidates.json` location: `{REPO}/.claude/state/mine/<YYYY-MM-DD>/candidates.json` (workspace-level `$WORKSPACE_ROOT/.claude/state/mine/` is the fallback `/learn` reads). Shape: `[{id, title, kind: pattern|gotcha|testing|checklist, occurrences, evidence: [{pr, path, excerpt}], files_hint}]`, `occurrences >= 2` enforced by the producer (`/learn` drops and counts anything below).
- `/learn --mine` dedupes by **`###` heading title** (case-insensitive) against `codebase-patterns-shared.md` / `testing-patterns-shared.md` — keep one `###` heading per entry in those files.
- `_Source: seed-pack:<flavor>_` is the tag `/learn` §2.5 criterion 6 ages (90 d / 10 learned tickets); seed-pack templates should write it exactly so and may add the file-level `<!-- seeded-by: seed-pack:<flavor> YYYY-MM-DD -->` marker next to `last-updated`.
- `templates/workspace/settings.template.json:64` hook regex needs **no change** — cover/triage sidecars live in `tickets/`.

## Batch 5 — `render-walkthrough.py`
- State files now have kinds other than `ticket`; `ticket:` may be `null`; `kind: cover|triage` files have a scenario/cluster table instead of ACs. Degrade to "no tracker" in the Closeout when `ticket: null`.

## Not owned by any batch (follow-ups, non-blocking)
- `core/scripts/state-index-scan.sh:25,37,129` hardcode `tickets debug builds refactors e2e`; could read the schema's `kind-dirs` line like `/status` now does. Not required: the scan calls the upsert per file, so the `kind:` passthrough already applies.
- `core/scripts/audit_metrics.py` cycle-time joins `kind=ticket` only; cover PRs are invisible to that metric until extended.
