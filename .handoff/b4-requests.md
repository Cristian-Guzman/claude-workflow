# Batch 4 → requests for files Batch 4 does not own

Each item names the file, the location, and the exact edit. Nothing here was applied by Batch 4.

## Wave 2 — hub files

### `core/commands/bootstrap.md` §3a.1 "Stack-flavored seed rules for `codebase-patterns.md`" (lines ~362-400)
- **Old:** the inline `**frontend-web seed:** … **library seed:** …` bullet lists, the "Stack-flavored DoD additions" list, and the prose instruction "Write 3–5 starter rules into `codebase-patterns.md`".
- **New:** one paragraph: "Seed entries live in `templates/seed-packs/<flavor>/{codebase-patterns.seed.md,testing-patterns.seed.md,ticket-checklist.dod.md}` (sub-packs `frontend-web/nextjs`, `backend-api/express`, `testing/playwright`). Append them with the convention in `templates/seed-packs/README.md` (`## Seed pack: <flavor>` + marker, only if absent; `fullstack-monorepo` composes `frontend-web` + `backend-api` first). `install.sh --stack <flavor>` does the same mechanically — prefer it." Keep the detection table (:343-349) and the downstream-gating table (:352-360). Keep the "Stack-flavored simplify checklist for `/verify` step 3.3" table (:402-419) — it is consumed by `/verify`, not by the packs; the packs carry a `[Checklist]: Simplify smells` entry that mirrors it per flavor.
- §12 `--flavor <name>` (:864-868): add "resolves `$PLACEMENT_DIR/.claude/flavors/<name>/` first, then `templates/seed-packs/<name>/`".
- Rule 7 (:1939) stands; the packs are stack flavor, not domain flavor.

### `README.md`
- Compatibility table: add a row `mine-history.sh (cold-start mining) — GitHub only (gh + jq); degrades to an empty candidates.json elsewhere`.
- Install / next steps: mention `scripts/mine-history.sh` then `/learn --mine` for repos with ≥10 merged PRs, and `install.sh --stack <flavor>` for a fresh repo.
- Under the confidential-project paragraph (the `/upstream` one): one sentence — "`scripts/harvest-profile.py` emits an aggregates-only profile (`core/docs/profile.schema.md`) when you want to compare a mature install against the public defaults without moving a single file."

### `core/commands/README.md`
- Scripts/tooling list: add `mine-history.sh`, `harvest-profile.py` (one line each, as above).

### `core/docs/workflow-version.md` — 0.8.0 entry
- New: `core/scripts/mine-history.sh`, `core/scripts/harvest-profile.py`, `core/docs/testing-patterns-shared.md`, `core/docs/profile.schema.md`, `templates/seed-packs/**`, `tests/b4-mine-history.test.sh`, `tests/b4-harvest-profile.test.py`.
- Changed: `core/docs/codebase-patterns-shared.md` (+3 H2: Dependencies & advisories, Contracts & failure handling, Feature flags), `docs/lessons.md` (+10 bullets), `templates/repo/{codebase-patterns,testing-patterns}.md` (shared-doc pointers, two E2E H2s, one-line comment-hygiene pointer), `templates/workspace/settings.template.json` (+`Bash(gh api:*)`).

### Load lines for the shared docs (`roles/dev/commands/*` after Batch 1's move)
- `clarify.md`, `ticket.md`, `build.md`, `refactor.md` — where the repo `codebase-patterns.md` is loaded: "If `$WORKSPACE_ROOT/.claude/codebase-patterns-shared.md` exists, load it before the repo file (Trivial tier: skip both)."
- `ticket.md` (test-writing step), `verify.md` §2.1 — where `testing-patterns.md` is loaded: "If `$WORKSPACE_ROOT/.claude/testing-patterns-shared.md` exists, load it first."
- `roles/sdet/commands/cover.md` (Batch 3 file; Wave 2 reconciles): same `testing-patterns-shared.md` load line.

### `core/commands/upstream.md`
- Add a short "Findings, not files" subsection: `python3 .claude/scripts/harvest-profile.py --workspace .claude --config .claude/upstream.json --out .claude/upstream/profile [--ci-runs runs.json] [--public-core .claude/.upstream-base]`; exit codes 0/1/2; the output is safe to attach to a bundle because the pipeline is collect → sanitize → `check` fail-closed; field list in `profile.schema.md`.

### `docs/specialization.md`
- Where it describes the cold start ("noticeably tuned by ticket 5"): one sentence pointing at `--stack` seed packs and `mine-history.sh` + `/learn --mine` as the two ways to shorten it.

### `templates/workspace/repo-profiles/_schema.yaml` (optional)
- Add `stack_flavor: ""  # frontend-web | backend-api | fullstack-monorepo | cli-tool | library — which seed pack was applied; read by /bootstrap §3a.1 and /learn §2.5 retirement` next to `type:`.

## Batch 1 — `install.sh --stack`

The seed files are **entries only** (no title, no frontmatter); the installer owns the wrapper. Contract (also in `templates/seed-packs/README.md`):
1. File → destination: `codebase-patterns.seed.md → $CLAUDE_DIR/codebase-patterns.md`, `testing-patterns.seed.md → $CLAUDE_DIR/testing-patterns.md`, `ticket-checklist.dod.md → $CLAUDE_DIR/ticket-checklist.md`.
2. Pattern files: append `\n<!-- seed-pack: <flavor> YYYY-MM-DD -->\n## Seed pack: <flavor>\n\n<file contents>` **only if `grep -qF '## Seed pack: <flavor>'` fails**.
3. `--stack <flavor>/<framework>` appends the flavor pack then the sub-pack under `## Seed pack: <flavor>/<framework>`. `--stack fullstack-monorepo` appends `frontend-web`, `backend-api`, `fullstack-monorepo` in that order, each under its own H2. `--stack testing/playwright` (combinable, e.g. `--stack frontend-web --stack testing/playwright`) appends only to `testing-patterns.md`.
4. `ticket-checklist.dod.md`: append the lines at the end of `ticket-checklist.md` preceded by `<!-- seed-pack: <flavor> DoD -->`; skip when that marker exists.
5. Next-steps text: "Existing repo with ≥10 merged PRs on GitHub? `.claude/scripts/mine-history.sh` then `/learn --mine`."

## Batch 2 — `learn.md`

- `--mine` reads `.claude/state/mine/<date>/candidates.json` (newest dir by default; `--mine <dir>` overrides). Contract: `[{id, title, kind: pattern|gotcha|testing|checklist, occurrences (≥2 enforced by the producer), evidence: [{pr, path, excerpt ≤200 chars}], files_hint: [paths]}]`. `id` prefixes: `topic--…` (directory + normalised comment stem) and `hotspot--…` (directory + file stem — recurring review attention on one module; usually a Gotcha or a Pattern about that module). `kind: testing` → `testing-patterns.md`; `checklist` → `ticket-checklist.md`; else `codebase-patterns.md`. Entry `_Source: mined:PR#<n>,#<m>_`. `tests.json` in the same dir fills the template's "Framework & Config" / "File Naming & Location" blocks with `Source: mined:tests`.
- **Mined beats pack:** before showing a mined entry, drop any `_Source: seed-pack:*_` entry whose normalised title matches it (lowercase, strip tag + punctuation, drop stopwords).
- §2.5 criterion 6: "`mined:` or `seed-pack:` entry with no `Following pattern from` Event Log hit and no second citation after 90 days or 10 learned tickets → retire (shown for approval like the others)."
- §2.6(d): the suite-health stamp now has a dedicated H2 — stamp under `## E2E suite health` (the templates ship both `## E2E drift taxonomy` and `## E2E suite health`); keep reading an existing stamp at the top of the taxonomy section for repos that predate the split. Replace the repo-specific citation (`addin-fe/.claude/testing-patterns.md → "## E2E repo-awareness…"`) with "the repo's testing-patterns canonical E2E section" — the alias of a specific company repo does not belong in a core command.
- Stale `_Source` classifier: `mined:` and `seed-pack:` are new source classes alongside `[[PROJ-n]]`, `session`, `code-observation`; §5's `last-run` line should count them (`+N (m mined, s seed)`).

## Unowned — `core/scripts/upstream.py` (optional, nobody's row)
- `harvest-profile.py` reuses `load_config`, `build_rules`, `apply_rules` directly and runs `cmd_check` through an `argparse.Namespace` with stdout captured to learn which leaves hit. A small refactor — `def check_patterns(cfg, root, generic)` returning the `[(name, rx)]` list that `cmd_check` builds inline — would let the harvester (and Batch 5's `render-walkthrough.py`) call the pattern list without parsing printed lines. Not required for 0.8.0.

## Wave 3 — things to re-run
- `bash tests/b4-mine-history.test.sh` (30 checks) and `python3 tests/b4-harvest-profile.test.py` (13 tests) — both offline.
- `N=5 core/scripts/mine-history.sh --dry-run` on any GitHub checkout with <10 merged PRs exercises the live degrade path (needs `gh auth`).
