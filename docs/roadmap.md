# Roadmap — deferred designs

Each item below was designed during the Phase 2 investigation (reports in the owner's session scratchpad; the
sections named here are the design pointers) and deferred by owner decision on 2026-10-11, after the Phase 2 plan,
so 0.8.0 ships the smallest set that is actually used. Nothing here is a command; the README lists none of them.
An item is promoted when the named evidence shows up — not before.

Standing rules that apply to every item: fold into an existing command before adding one; mechanical over prose;
state files are never deleted; project-owned files are never overwritten.

## `/gaps` scoring model

- **What:** a ranked list of untested app surfaces, scored `critical-flow flag × git churn × interactive-element count × auth-gated × incidents × skip density`.
- **Why deferred:** `/cover` with no argument already produces the unscored list (routes the app serves ⟂ `page.goto` targets and helper navigators in the suite, sorted by path). A score needs incident and churn data that a fresh install does not have, so the model would be fitted to one deployment.
- **Promote when:** two installs report that the unscored list is too long to pick from (≥40 rows) and have a flaky/incident ledger to feed the score.
- **Design:** report C (SDET lane) §"gaps"; `roles/sdet/README.md` → Deferred.

## `/stabilize`

- **What:** a measured flaky-test protocol — rate before (`--repeat N`), fix, rate after, quarantine with expiry, ledger row with both rates.
- **Why deferred:** the MVP keeps flaky tests running with a `flaky-ledger.md` row (`FLAKY FL-n`) and classifies them in `/triage`; the rate-before/after loop is a `/triage` sub-mode, not a command, and needs the ledger to have history first.
- **Promote when:** `flaky-ledger.md` in a real install has ≥10 rows and `/learn`'s flaky target shows the same test re-entering the ledger.
- **Design:** report C §"stabilize"; `roles/sdet/commands/triage.md` (class `flaky`).

## `sdet-seed.sh`

- **What:** the SDET twin of `mine-history.sh` — mine `playwright.config.*`, scripts, env var names, `data-testid`s and helper modules into `selectors.md`, `test-data.md`, `environments.md`; `gh run list` into `flaky-ledger.md`.
- **Why deferred:** the four templates ship empty and `/cover` reads the live suite at run time, so the seed would duplicate what `/cover` §0.4 already loads. `harvest-profile.py` collects the same aggregates read-only; the write side waits for evidence that the templates stay empty too long.
- **Promote when:** two sdet installs still have an empty `selectors.md ## Conventions` after five `/cover` runs.
- **Design:** report D §5 ("SDET equivalent"); `core/scripts/mine-history.sh` for the collection shape.

## Guard sentinel escape hatch + assertion-count check

- **What:** a 10-minute sentinel file that lets `guard-test-integrity.sh` admit an assertion-moving refactor (every use logged), and a check that a spec edit does not reduce `expect(` count without a receipt.
- **Why deferred:** the MVP hook blocks exactly `.only(` and unkeyed `.skip/.fixme/.fail`; every extra rule is a false-positive source on legitimate refactors, and none has a recorded incident yet.
- **Promote when:** the hook blocks a legitimate edit twice in one install (the user has to disable it), or a merged PR removes assertions that a later bug needed.
- **Design:** report C §"hook"; `roles/sdet/scripts/guard-test-integrity.sh` header.

## Quarantine expiry + `/status` bucket

- **What:** `test.fail(true, 'BUG KEY-n')` rows expire after 14 days without a linked ticket update; `/status` shows a "quarantine expiring" bucket.
- **Why deferred:** `quarantined` is not a state in the 0.8.0 schema (`state-file-schema.md`); the four-number report already keeps known failures visible on every run, which is the mechanism the expiry would duplicate.
- **Promote when:** a real install carries ≥5 `test.fail` quarantines older than 14 days.
- **Design:** plan §5 (decision 5 enforcement); `core/docs/state-file-schema.md` → Kinds.

## `cluster-investigator` agent

- **What:** parallel per-cluster reading in `/triage --batch` (cap 5 agents, inline fallback), returning cause class + evidence per cluster.
- **Why deferred:** the MVP processes clusters sequentially inline; a fan-out is an optimization whose win depends on cluster counts no install has reported yet.
- **Promote when:** a `/triage --batch` run reports ≥6 clusters and the inline pass exceeds one context window.
- **Design:** report C §"triage agents"; `core/agents/README.md` → Deferred.

## SDET `pr-branch-reviewer` override

- **What:** `roles/sdet/agents/pr-branch-reviewer.md` with test-specific rules — no new skip/only/fixme without a link, no `.catch(() => false)`, no `networkidle`, no `[class*=`, a break-to-validate receipt per new test, `--no-ignore` lint.
- **Why deferred:** every rule except the receipt check is already enforced earlier (hook, `/cover` write rules, lint); the override would re-check at PR time what `/cover`'s gate table already scored.
- **Promote when:** a cover PR merges with a test that has no receipt, i.e. the gate was bypassed.
- **Design:** report C §"review"; the role-agent install path is in `install.sh` already.

## Custom Playwright "known failures" reporter

- **What:** a ~30-line reporter printing `passed / failed / known-failures-with-bug / skipped` in CI logs, so the four numbers appear where native reporters would otherwise fold expected failures into passes.
- **Why deferred:** `triage-cluster.py` already derives the four numbers from the JSON report; the reporter is the same arithmetic placed in CI, and needs a repo to adopt it in `playwright.config`.
- **Promote when:** one install's CI summary misleads a reviewer (a `test.fail` counted green) — the exact failure decision 5 guards against.
- **Design:** plan §5; `roles/sdet/README.md` → "Four numbers, always".

## Eval harness (`evals/`)

- **What:** fresh-install vs mature-install arms replaying the same solved ticket; outputs diffed (files touched, AC gate ratio, tests written, patterns cited, question count, CI exit) into a **knowledge-gap report**. Layout follows `claude plugin eval`'s case shape — `evals/**/case.yaml` + `prompt.md` + `graders/*.md` — so the built-in runner can replace a custom one.
- **Why deferred:** it pays off only once seed packs, mining and shared docs give it something to measure; runs cost money and n=3 is noisy.
- **Promote when:** two consecutive releases change `templates/seed-packs/` or `core/docs/*-shared.md` and nobody can say whether the change helped.
- **Seed case (do not build twice):** `docs/examples/walkthrough-standard-ticket.state.md` rendered through `core/scripts/render-walkthrough.py`; the grader asserts the step count, the derived Process Summary and a clean `upstream.py check`.
- **Design:** report D §8.

## Plugin packaging

- **What:** `core`, `dev`, `sdet` as Claude Code plugins (`.claude-plugin/plugin.json`, `commands/`, `agents/`, `hooks/hooks.json`), with `dev`/`sdet` depending on `core`.
- **Why deferred:** the value is in project-owned files a plugin cannot place (patterns, checklists, settings, profiles); every command reads docs by `.claude/<name>.md` path, so packaging needs a path indirection across all command files first; plugin namespacing would rename the *Start here* trio; plugin dependencies are unverified; and there is no install lifecycle hook, so `install.sh` stays for seeds either way. A plugin-installed core would also remove the local-edit drift signal `/upstream` relies on.
- **Promote when:** `--role` has been in use for a release, a single docs-path indirection exists in all commands, and the eval harness can prove parity. Cheap experiment first: `claude --plugin-dir ./core` smoke test, written up as findings only.
- **Design:** report D §3.

## `/bootstrap` deep cut and `<command-specs>` reconcile

- **What:** cut `core/commands/bootstrap.md` (~1950 lines, flagged for ~40% since 0.2.1) and either regenerate the inlined `<command-specs>` from the shipped command files or delete the single-file fallback.
- **Why deferred:** `/bootstrap` is itself an installer; refactoring it in the same release as the role split risks the install path. 0.8.0 marks the specs as a stale fork (names `security`/`debug`/`resume`, no SDET specs, `glab` fallback only there) and leaves them.
- **Promote when:** the role split has survived one real upgrade cycle (`install.sh` 0.7.0 → 0.8.0 on a live workspace) without a `/bootstrap` regression.
- **Design:** fact-check D "Missed" (two-installer drift); `core/commands/bootstrap.md` header note at `<command-specs>`.

## Optional history rewrite

- **What:** remove the product-domain vocabulary that the 0.8.0 noun sweep replaced from every past commit: `git filter-repo --replace-text <map>` over all refs (map = the Wave 2 replacement table) → verify with `git grep` across `git rev-list --all` → force-push `main` → delete the stale remote branch → re-clone every local checkout.
- **Why deferred:** owner's call on whether the vocabulary is confidential; the sweep is fix-forward and complete, the repo has 0 forks, and a rewrite changes every commit hash (any install's `.upstream-manifest.json` `source_commit` would dangle).
- **Promote when:** the owner decides the vocabulary must not remain in history. Do it once, after the sweep, never incrementally.
- **Design:** plan §6.
