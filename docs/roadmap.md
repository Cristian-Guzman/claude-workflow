# Roadmap — deferred designs

Each item below was designed during the 0.8.0 planning pass and deferred by owner decision on 2026-10-11, after
the plan was approved, so 0.8.0 ships the smallest set that is actually used. Every item carries enough of its
design to stand alone plus a pointer to the shipped file it would extend. Nothing here is a command; the README
lists none of them. An item is promoted when the named evidence shows up — not before.

Standing rules that apply to every item: fold into an existing command before adding one; mechanical over prose;
state files are never deleted; project-owned files are never overwritten.

## `/gaps` scoring model

- **What:** a ranked list of untested app surfaces, scored `critical-flow flag × git churn × interactive-element count × auth-gated × incidents × skip density`.
- **Why deferred:** `/cover` with no argument already produces the unscored list (routes the app serves ⟂ `page.goto` targets and helper navigators in the suite, sorted by path). A score needs incident and churn data that a fresh install does not have, so the model would be fitted to one deployment.
- **Promote when:** two installs report that the unscored list is too long to pick from (≥40 rows) and have a flaky/incident ledger to feed the score.
- **Design:** `roles/sdet/commands/cover.md` §0-alt is the unscored list this would rank; `roles/sdet/README.md` → Deferred. Each factor is a per-surface number the install already has or can derive: the critical-flow flag from the repo profile, git churn of the files behind the route, the interactive-element count from the bounded explore, whether the route sits behind auth, incidents from `flaky-ledger.md` and delivered triage files, and skip density in the specs that already visit the route. Surfaces with no covering spec sort first; ties break on churn.

## `/stabilize`

- **What:** a measured flaky-test protocol — rate before (`--repeat N`), fix, rate after, quarantine with expiry, ledger row with both rates.
- **Why deferred:** the MVP keeps flaky tests running with a `flaky-ledger.md` row (`FLAKY FL-n`) and classifies them in `/triage`; the rate-before/after loop is a `/triage` sub-mode, not a command, and needs the ledger to have history first.
- **Promote when:** `flaky-ledger.md` in a real install has ≥10 rows and `/learn`'s flaky target shows the same test re-entering the ledger.
- **Design:** `roles/sdet/commands/triage.md` §2.3 (class `flaky`: fix the obvious race, else a ledger row and the test keeps running) and `roles/sdet/templates/repo/flaky-ledger.md`. The protocol adds one measurement on each side of the fix — the same repeat count before and after — and lets a quarantine exist only with an expiry date and a ledger row that records both rates; the flaky target in `roles/sdet/learn-targets.yaml` is where the re-entry evidence shows up.

## `sdet-seed.sh`

- **What:** the SDET twin of `mine-history.sh` — mine `playwright.config.*`, scripts, env var names, `data-testid`s and helper modules into `selectors.md`, `test-data.md`, `environments.md`; `gh run list` into `flaky-ledger.md`.
- **Why deferred:** the four templates ship empty and `/cover` reads the live suite at run time, so the seed would duplicate what `/cover` §0.4 already loads. `harvest-profile.py` collects the same aggregates read-only; the write side waits for evidence that the templates stay empty too long.
- **Promote when:** two sdet installs still have an empty `selectors.md ## Conventions` after five `/cover` runs.
- **Design:** `core/scripts/mine-history.sh` is the collection shape to mirror — read-only sources (`gh`, the Playwright config, the suite) into one candidates file, each source degrading independently when absent; `core/scripts/harvest-profile.py` already computes the read-only aggregates (selector-strategy frequencies, skip density, config shape without URLs). The seed would write candidate rows into each template's `## AUTO:*-LOG` region and the ledger, never into the lesson sections, which stay `/learn`'s to promote.

## Guard sentinel escape hatch + assertion-count check

- **What:** a 10-minute sentinel file that lets `guard-test-integrity.sh` admit an assertion-moving refactor (every use logged), and a check that a spec edit does not reduce `expect(` count without a receipt.
- **Why deferred:** the MVP hook blocks exactly `.only(` and unkeyed `.skip/.fixme/.fail`; every extra rule is a false-positive source on legitimate refactors, and none has a recorded incident yet.
- **Promote when:** the hook blocks a legitimate edit twice in one install (the user has to disable it), or a merged PR removes assertions that a later bug needed.
- **Design:** the header of `roles/sdet/scripts/guard-test-integrity.sh` lists the two rules this would extend and states, deliberately, that no escape hatch or assertion counting exists yet. The sentinel is a presence-plus-age check on a file under `.claude/` in the same script, with every admission written as a log row; the assertion check is a before/after count of `expect(` on the edited spec, blocking a drop that carries no receipt line in the same edit.

## Quarantine expiry + `/status` bucket

- **What:** `test.fail(true, 'BUG KEY-n')` rows expire after 14 days without a linked ticket update; `/status` shows a "quarantine expiring" bucket.
- **Why deferred:** `quarantined` is not a state in the 0.8.0 schema (`state-file-schema.md`); the four-number report already keeps known failures visible on every run, which is the mechanism the expiry would duplicate.
- **Promote when:** a real install carries ≥5 `test.fail` quarantines older than 14 days.
- **Design:** `core/docs/state-file-schema.md` → Kinds and the closed status vocabulary (a `quarantined` status would be added there and to `state-index-upsert.sh` together); `roles/sdet/README.md` → "Four numbers, always" is the mechanism the expiry would duplicate; `core/commands/status.md` is where the bucket would render.

## `cluster-investigator` agent

- **What:** parallel per-cluster reading in `/triage --batch` (cap 5 agents, inline fallback), returning cause class + evidence per cluster.
- **Why deferred:** the MVP processes clusters sequentially inline; a fan-out is an optimization whose win depends on cluster counts no install has reported yet.
- **Promote when:** a `/triage --batch` run reports ≥6 clusters and the inline pass exceeds one context window.
- **Design:** `core/agents/README.md` → Deferred; `roles/sdet/commands/triage.md` §2.3 is the sequential, largest-first pass this would parallelize. Each agent takes one cluster from `triage-cluster.py`'s output and returns the same class, tell-tale evidence and action that §2.3 records inline, so the §2.6 state table keeps its shape whether the fan-out is on or off.

## SDET `pr-branch-reviewer` override

- **What:** `roles/sdet/agents/pr-branch-reviewer.md` with test-specific rules — no new skip/only/fixme without a link, no `.catch(() => false)`, no `networkidle`, no `[class*=`, a break-to-validate receipt per new test, `--no-ignore` lint.
- **Why deferred:** every rule except the receipt check is already enforced earlier (hook, `/cover` write rules, lint); the override would re-check at PR time what `/cover`'s gate table already scored.
- **Promote when:** a cover PR merges with a test that has no receipt, i.e. the gate was bypassed.
- **Design:** `core/agents/pr-branch-reviewer.md` holds the base rules an override would extend; `install.sh` already installs `roles/<role>/agents/*.md`, so no installer change is needed; `roles/sdet/commands/cover.md` §6 is the gate table whose rows the override would re-check at PR time.

## Custom Playwright "known failures" reporter

- **What:** a ~30-line reporter printing `passed / failed / known-failures-with-bug / skipped` in CI logs, so the four numbers appear where native reporters would otherwise fold expected failures into passes.
- **Why deferred:** `triage-cluster.py` already derives the four numbers from the JSON report; the reporter is the same arithmetic placed in CI, and needs a repo to adopt it in `playwright.config`.
- **Promote when:** one install's CI summary misleads a reviewer (a `test.fail` counted green) — the exact failure the four-number rule guards against.
- **Design:** `roles/sdet/README.md` → "Four numbers, always" (what the line must say and why native reporters cannot be trusted for it); the four-number summary in `roles/sdet/scripts/triage-cluster.py` is the arithmetic to port — expected-failure results count as known failures, never as passes.

## Eval harness (`evals/`)

- **What:** fresh-install vs mature-install arms replaying the same solved ticket; outputs diffed (files touched, AC gate ratio, tests written, patterns cited, question count, CI exit) into a **knowledge-gap report**. Layout follows `claude plugin eval`'s case shape — `evals/**/case.yaml` + `prompt.md` + `graders/*.md` — so the built-in runner can replace a custom one.
- **Why deferred:** it pays off only once seed packs, mining and shared docs give it something to measure; runs cost money and n=3 is noisy.
- **Promote when:** two consecutive releases change `templates/seed-packs/` or `core/docs/*-shared.md` and nobody can say whether the change helped.
- **Seed case (do not build twice):** `docs/examples/walkthrough-standard-ticket.state.md` rendered through `core/scripts/render-walkthrough.py`; the grader asserts the step count, the derived Process Summary and a clean `upstream.py check`.
- **Design:** the seed case above is the first case; `core/scripts/audit_metrics.py` already snapshots the workspace-level learning metrics the two arms would be compared on. Both arms replay the same ticket from the same commit — a fresh install, and one that has been through `/learn` on real work — and the grader diffs the six measures named above; a measure where the mature arm is not better is a gap in `templates/seed-packs/` or `core/docs/*-shared.md`.

## Plugin packaging

- **What:** `core`, `dev`, `sdet` as Claude Code plugins (`.claude-plugin/plugin.json`, `commands/`, `agents/`, `hooks/hooks.json`), with `dev`/`sdet` depending on `core`.
- **Why deferred:** the value is in project-owned files a plugin cannot place (patterns, checklists, settings, profiles); every command reads docs by `.claude/<name>.md` path, so packaging needs a path indirection across all command files first; plugin namespacing would rename the *Start here* trio; plugin dependencies are unverified; and there is no install lifecycle hook, so `install.sh` stays for seeds either way. A plugin-installed core would also remove the local-edit drift signal `/upstream` relies on.
- **Promote when:** `--role` has been in use for a release, a single docs-path indirection exists in all commands, and the eval harness can prove parity. Cheap experiment first: `claude --plugin-dir ./core` smoke test, written up as findings only.
- **Design:** `install.sh` (`seed()`, the settings merge and `.upstream-base/` are what a plugin cannot place) and `core/commands/upstream.md` (the local-edit drift signal a plugin-installed core would remove). The three-plugin shape in **What** is the whole design; the open questions are the docs-path indirection and plugin dependencies, both named above.

## `/bootstrap` deep cut and `<command-specs>` reconcile

- **Landed in 0.9.0.** `bootstrap.md` is the adapter only (probe → gates → archive moves → manifest); `<command-specs>`, `<templates>`, `<agent-specs>` and the release-manager mode are deleted. Inventory → `core/docs/inventory.yaml`; probe → `core/scripts/capability-probe.sh`; decisions → `core/scripts/adapt-plan.py`; versioning → `scripts/release.py` (maintainer) + `/update` (installed). See the 0.9.0 changelog.

## Optional history rewrite

- **What:** remove the product-domain vocabulary that the 0.8.0 noun sweep replaced from every past commit: `git filter-repo --replace-text <map>` over all refs (map = the sweep's replacement table) → verify with `git grep` across `git rev-list --all` → force-push `main` → delete the stale remote branch → re-clone every local checkout.
- **Why deferred:** owner's call on whether the vocabulary is confidential; the sweep is fix-forward and complete, the repo has 0 forks, and a rewrite changes every commit hash (any install's `.upstream-manifest.json` `source_commit` would dangle).
- **Promote when:** the owner decides the vocabulary must not remain in history. Do it once, after the sweep, never incrementally.
- **Design:** `core/docs/workflow-version.md` → 0.8.0, "Product-noun sweep": its replacement list is the `--replace-text` map, and that changelog entry is the one shipped file that keeps the old words by decision — it would need the same call. The procedure in **What** is complete; nothing else is designed.
