# Batch 3 → requests for other batches / Wave 2

Batch 3 owns only `roles/sdet/**` (minus Batch 1's skeleton files) and `tests/b3-*`. Everything below
is a change another owner must make for the SDET MVP to be reachable.

## Batch 1 — install.sh (confirm, do not assume)

1. `roles/sdet/scripts/*` must land in `.claude/scripts/` (same place as core scripts) — the fragment
   and the commands reference `$CLAUDE_PROJECT_DIR/.claude/scripts/guard-test-integrity.sh` and
   `$WORKSPACE_ROOT/.claude/scripts/triage-cluster.py`. Executable bit preserved.
2. `roles/sdet/templates/repo/*.md` → seeded into `{repo}/.claude/` by `seed()` (copy only if missing).
3. `roles/sdet/templates/workspace/settings.sdet.fragment.json` → jq-merged into `settings.json`
   ONLY when `settings.json` is being seeded; otherwise print the fragment with a one-line "add this
   PreToolUse entry" note (settings.json is project-owned).
4. `roles/sdet/learn-targets.yaml` → `.claude/learn-targets/sdet.yaml` (the path Batch 2's `/learn`
   scans).
5. Wave 2 deletes `roles/sdet/_harvest/` — Batch 3 has harvested `/test-plan`'s four principles,
   the tiering read, the surface-testability and the existing-coverage check into `/cover`.

## Batch 2 — core patches (exact contract Batch 3 relies on)

1. `core/scripts/state-index-upsert.sh`: generic `kind:` passthrough so `tickets/cover--<slug>.md`
   (`kind: cover`) and `tickets/triage--<run-id>.md` (`kind: triage`) index as `repo:cover:<slug>` /
   `repo:triage:<run-id>`; add `env-blocked` to the closed status vocabulary (used by `/triage`);
   statuses `investigating`, `in-progress`, `ready-for-pr` already exist. Nested artifact dirs
   `tickets/cover--<slug>/…` must NOT be indexed (the existing `[^/]+\.md$` regex already excludes them).
2. `core/commands/pr.md` §5.5a — accept these exact event-line shapes as verification evidence:
   - cover: `- [HH:MM] /cover gate score=NN sha=<short> passed=A failed=B known-failures-with-bug=C skipped=D`
   - triage: `- [HH:MM] /triage run=<id> clusters=N fixed=A env-blocked=B bugs=C flaky=D passed=P failed=F known-failures-with-bug=K skipped=S`
   Grep suggestion: `grep -E '^\- \[[0-9:]{4,5}\] /(cover gate score=|triage run=)'`.
   Branch-table row: `test/<slug>` (cover) and `fix/triage-<run-id>` (triage).
3. `core/commands/ci-check.md` §5.1b — for `kind: cover`, the post-deploy re-check list = the spec
   paths under `## Files Modified`; §3b — "failing check is the e2e job → `/triage <spec>` (or
   `/triage --batch` with the run's blob report)".
4. `core/commands/learn.md` — reads `.claude/learn-targets/*.yaml`; the SDET file's `signals[].where`
   strings are documentation-grade expressions (model-evaluated), not a DSL the script must parse.
   `log_only: true` targets (flaky-ledger) get no lesson section.
5. `core/commands/resume-ticket.md` — cover: resume at the first scenario in `## Scenarios` without a
   receipt in `## Break-to-validate receipts`; triage: first cluster row whose status ∉ {fixed,
   env-blocked, quarantined, ledger, handed-off}.
6. `core/docs/state-file-schema.md` — add the `cover` and `triage` frontmatter shapes used in
   `roles/sdet/commands/{cover,triage}.md` §0.5/§0.3 (kind, slug, ticket, branch, status, tier, mode,
   exploration / source, env, pr_number).

## Wave 2 — hub files

1. `README.md` — Start here (SDET): `/cover → /pr → /learn`; per-role install table row for `sdet`;
   remove the "planned SDET lane" line; compatibility table: hooks need `jq`, clustering needs `python3`.
2. `core/commands/README.md` — SDET section = the MVP pipeline (`/cover`, `/triage`, `/log`), the hard
   rule, the four-number rule; drop the `/test-plan` row and the `_(planned)_` `/automate`,
   `/verify-coverage` rows.
3. `core/commands/bootstrap.md` — remove the `test-plan` row; add Role column rows for the three SDET
   commands; `role ∈ roles AND gate` on the SDET rows (gate: `e2e.enabled` or an API collection present).
4. `core/docs/workflow-version.md` — 0.8.0 entry: "roles/sdet MVP: /cover (break-to-validate), /triage
   (triage-cluster.py), /log, guard-test-integrity.sh; /test-plan retired (principles folded into /cover)".
5. `core/agents/README.md` — callers column: `codebase-investigator` (+ `/cover` cross tier),
   `contract-verifier` (+ `/cover` api mode, `/triage` env-vs-bug), `jira-context-loader` (+ `/log`).
6. `templates/workspace/repo-profiles/_schema.yaml` — document the optional `e2e.local_base_url`,
   `e2e.feature_map`, `e2e.smoke_specs` keys `/cover` reads when present (degrades without them).
7. `docs/specialization.md` — one paragraph on the SDET role's knowledge files and `learn-targets.yaml`.
8. `docs/roadmap.md` — deferred items from Batch 3 (do NOT build): `/gaps` as a command + scoring model
   (critical-flow flag × git churn × interactive-element count × auth-gated × incidents × skip density);
   `/stabilize` (rate before/after protocol, `--repeat`, quarantine with expiry); `sdet-seed.sh`
   (mine playwright config, scripts, env var names, testids, helpers into the four templates);
   hook sentinel escape hatch (10-min file, every use logged) for assertion-moving refactors;
   quarantine expiry (14 d) + `/status` "quarantine expiring" bucket; `cluster-investigator` agent
   (parallel per-cluster reading, cap 5, inline fallback); SDET `pr-branch-reviewer` override (no new
   skip/only/fixme without link, no `.catch(()=>false)`, no `networkidle`, no `[class*=`, b2v receipt
   per new test, `--no-ignore` lint); custom Playwright reporter (~30 lines) printing the four numbers
   in CI logs.
9. Sanitization sweep: Batch 3 files use only `web-app`, `PROJ-XXXX`, `<feature>`, `orders-v2`,
   `GET /items`, `e2e/<area>/<flow>.spec.ts`, `FL-n`; nothing further expected, but include
   `roles/sdet/**` in the grep.

## Open questions surfaced while building

- `/cover` writes run artifacts to `{repo}/.claude/tickets/cover--<slug>/` (gitignored via
  `.claude/tickets/`). If Batch 1/2 prefer a dedicated artifacts dir, only the two command files need
  the path changed.
- `triage-cluster.py` treats a test as flaky when a retry passed after a failure; with `--retries 0`
  (the commands' default) flakiness instead appears as plain failures across runs — the ledger row is
  the model's call from the `flaky_ratio` hint plus `flaky-ledger.md` history.
