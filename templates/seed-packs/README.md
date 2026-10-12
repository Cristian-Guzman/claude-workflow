# Seed packs

Stack-flavored starter entries for a fresh install, so the first tickets are not run against an empty `codebase-patterns.md`. One directory per flavor; each file is a list of entries in the exact shape `/learn` appends (`### [Tag]: title` · Rule · Why · `_Source: seed-pack:<flavor>_`), **≤8 non-blank lines per entry, ≤10 entries per file**. Packs carry conventions, not product knowledge — nothing here names a domain, a company or a repo.

| Flavor | Files | Notes |
|---|---|---|
| `frontend-web` | `codebase-patterns.seed.md`, `testing-patterns.seed.md`, `ticket-checklist.dod.md` | sub-pack `frontend-web/nextjs` |
| `backend-api` | same three | sub-pack `backend-api/express` |
| `fullstack-monorepo` | same three | **composes** `frontend-web` + `backend-api` first, then its own entries |
| `cli-tool` | same three | |
| `library` | same three | |
| `testing/playwright` | `testing-patterns.seed.md` only | standalone; applies to any flavor with a Playwright suite |

Flavor detection signals live in `/bootstrap` §3a.1 (manifest + layout); the user can always override.

## The append convention (`install.sh --stack <flavor>[/<framework>]`)

Seed files contain **entries only** — no title, no frontmatter. The installer owns the wrapper:

1. Destination per file: `codebase-patterns.seed.md → .claude/codebase-patterns.md`, `testing-patterns.seed.md → .claude/testing-patterns.md`, `ticket-checklist.dod.md → .claude/ticket-checklist.md`.
2. For the two pattern files, append the pack under an H2 named exactly `## Seed pack: <flavor>` preceded by the marker `<!-- seed-pack: <flavor> YYYY-MM-DD -->`. **Append only if that H2 is absent** — re-running the installer is idempotent, and `/learn` can tell seed from learned by the H2 and the `_Source:` line.
3. A framework sub-pack appends under its own H2 (`## Seed pack: frontend-web/nextjs`) after the flavor pack. `fullstack-monorepo` appends `frontend-web`, `backend-api`, then `fullstack-monorepo`, each under its own H2. `testing/playwright` appends to `testing-patterns.md` under `## Seed pack: testing/playwright`.
4. `ticket-checklist.dod.md` lines are appended at the **end** of `ticket-checklist.md` (the `## Definition of Done` list), preceded by one marker `<!-- seed-pack: <flavor> DoD -->`; the marker is the idempotency check.
5. Project-local overlays win: `/bootstrap --flavor <name>` resolves `<repo>/.claude/flavors/<name>/` first, then `templates/seed-packs/<name>/` — one overlay mechanism, two sources.

## Precedence and retirement

- **Mined beats pack.** When `/learn --mine` turns `.claude/state/mine/<date>/candidates.json` into entries, a pack entry whose normalised title matches a mined entry is dropped; the pack fills only the topics mining left empty.
- **Uncited pack entries retire.** `/learn` §2.5 criterion 6: a `seed-pack:` (or `mined:`) entry with no `Following pattern from` Event Log hit and no second citation after 90 days or 10 learned tickets is proposed for retirement — shown for approval like every other retirement, never deleted silently.
- Shared, stack-independent rules do not live here; they are in `core/docs/codebase-patterns-shared.md` and `core/docs/testing-patterns-shared.md`, which every repo file points to.

## Adding a pack

Copy an existing flavor directory, keep the entry shape, keep every entry noun-free (would the rule still make sense with the product name deleted?), and list it in the table above. A pack entry is a placeholder — the second real occurrence of a lesson replaces it.
