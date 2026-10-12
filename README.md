# claude-workflow

A portable slash-command workflow for [Claude Code](https://claude.com/claude-code). Install it into any project;
every completed ticket feeds patterns back into the project's own knowledge files, so the commands get sharper the
more you work — see [a pattern file after 20 tickets](docs/examples/codebase-patterns.after-20-tickets.md) and
[one ticket's full trace](docs/examples/walkthrough-standard-ticket.md) rather than taking the claim on faith.

Built on **Jira + GitHub** (`jira` CLI or Atlassian MCP; `gh` for PRs, CI and reviews). Without Jira, run the no-tracker
lane: `/build` replaces `/clarify`+`/ticket` and the ticket-transition steps no-op (`tracker_system: none`). Without GitHub,
`/pr` still produces the commit message and PR text but cannot open the PR, and `/ci-check`, `/review-pr`, `/review-comments`
are not usable. GitHub Issues and Linear are accepted profile values but **not implemented** — they degrade to "paste the
acceptance criteria". The compatibility table under *Configuration points* is the honest status per cell.

## Install

```bash
git clone <this-repo> && cd claude-workflow
./install.sh /path/to/your/project                     # role defaults to dev
./install.sh /path/to/your/project --role sdet         # test-engineering lane
./install.sh /path/to/your/project --roles dev,sdet    # both (also: --role dev --role sdet)
./install.sh /path/to/your/project --stack frontend-web   # + a stack seed pack (once)
```

Multi-repo workspace? Install once at the root, then `./install.sh <workspace>/repo-a --repo-only` per repo.
**Updating:** `git pull` here, re-run `install.sh`. Core and role files refresh in place; anything the project
owns (patterns, settings, checklists) is never overwritten. Roles are remembered in the tracked `.claude/workflow-manifest.json`
(flag → manifest → inferred from installed commands → `dev`); a dropped role's commands are archived to `.claude/_archived-commands/`,
never deleted. The first run on a pre-0.7.0 install copies what it finds to `.claude/.upstream-prior/<date>/` (MANIFEST.md +
SHA256SUMS) before touching anything, and on later upgrades any core file you edited locally (plus the old baseline) is copied there before the refresh, so local edits are never lost; a 0.6.0 install's retired `test-plan.md` stays as an orphan that `/bootstrap --check` reports.

## Start here

**Setup (once):** `install.sh`, then copy `.claude/repo-profiles/_schema.yaml` → `repo-profiles/<repo>.yaml` and fill `base_branch` + `ci_command`.

| Developer | SDET |
|---|---|
| `/ticket PROJ-123` — implement the ticket phase by phase (no tracker? `/build "…"`) | `/cover <feature \| URL>` — explore, propose, write tests, break each one on purpose, gate table |
| `/pr` — CI, commit message, PR description | `/pr` — same command; finds the sidecar by branch, skips the tracker step |
| `/learn` — turn the delivered work into pattern entries | `/learn` — same; scans `cover`/`triage` sidecars via the role's learn-targets |

Each step runs on its own — nothing auto-chains. One ticket through the whole pipeline: [docs/examples/walkthrough-standard-ticket.md](docs/examples/walkthrough-standard-ticket.md).

## The full pipeline (when you want it)

```
/clarify ──▶ /ticket ──▶ /verify ──▶ /qa ──▶ /pr ──▶ /ci-check ──▶ /learn
 investigate   implement    AC-check     QA guide   PR gen    CI watch     extract
 + blueprint   in phases    w/ evidence  or live    + commit  + merge      patterns
                                                                              │
                    ┌─────────────────────────────────────────────────────────┘
                    ▼
        .claude/codebase-patterns.md, testing-patterns.md, process-ledger.md
        (every future /ticket reads these — the system gets smarter per project)
```

Each command runs **once per ticket**, discretely. State persists in `.claude/tickets/<ID>.md` (SDET sidecars in `tickets/<kind>--<slug>.md`) so any session, or `/resume-ticket`, picks up where the last one stopped.

## All commands (advanced)

- **core (15, every role):** `/pr` `/ci-check` `/learn` `/qa` `/review-pr` `/review-comments` `/resume-ticket` `/status` `/project-debug` `/project-context` `/screenshot` `/demo-summary` `/memory-lint` `/bootstrap` `/upstream`
- **dev (6):** `/clarify` `/ticket` `/build` `/refactor` `/verify` `/ui-fidelity`
- **sdet (3):** `/cover` `/triage` (one red test, or a whole red run clustered by shared cause) `/log` (mint the ticket *from* the work)

Full matrix: [core/commands/README.md](core/commands/README.md). Deferred designs (`/gaps`, `/stabilize`, plugin packaging, …): [docs/roadmap.md](docs/roadmap.md).

## What gets installed where

| Path in target | Contents | Owned by |
|---|---|---|
| `.claude/commands/` | 15 core + 6 dev + 3 sdet slash commands, per the roles selected | upstream (refreshed on update) |
| `.claude/agents/`, `scripts/`, `routing.md`, `state-file-schema.md`, `*-shared.md` | 7 subagents (same set for every role), hooks + scripts (sdet adds `guard-test-integrity.sh`, `triage-cluster.py`), system docs | upstream |
| `.claude/learn-targets/<role>.yaml`, `workflow-manifest.json` | what `/learn` scans per role; which roles are installed (tracked) | upstream / install.sh |
| `.claude/settings.json` | hooks + permissions (from template; sdet merges its hook fragment on first seed) | **your project** |
| `.claude/codebase-patterns.md`, `testing-patterns.md`, `ticket-checklist.md`, `pr-template.md` | patterns, test idioms, pre-PR checklist, PR format | **your project** (grown by /learn) |
| `.claude/selectors.md`, `test-data.md`, `environments.md`, `flaky-ledger.md` | sdet knowledge files (seeded once) | **your project** |
| `.claude/repo-profiles/<repo>.yaml` | base branch, CI cmd, tracker, dev server — **hand-copied from `_schema.yaml`** | **your project** |
| `.claude/tickets/`, `state/`, `debug/`, `qa/` | runtime state (gitignored) | machine-local |

## Specializing to a new project — what actually matters

Four project-owned files carry the intelligence; how fast they get real content is how fast the workflow gets good ([docs/specialization.md](docs/specialization.md)):

1. **`repo-profiles/<repo>.yaml`** — copy `_schema.yaml`, fill `base_branch` + `ci_command`. Without it, commands ask every time.
2. **`codebase-patterns.md`** — "how code is written here." Seed 2-3 entries or let `/learn` extract them. Most-read file in the system.
3. **`testing-patterns.md`** — framework, where tests live, mock idioms.
4. **`ticket-checklist.md`** — what must be true before a PR; the pr-branch-reviewer agent enforces it verbatim.

Everything else (`process-ledger.md`, `ui-fidelity-ledger.md`, debug files) is created by the commands when first needed.

## Cold start

A repo with history but empty pattern files: `.claude/scripts/mine-history.sh` (needs `gh`, ≥10 merged PRs) writes `candidates.json`;
`/learn --mine` lands only what recurred in 2+ PRs. A fresh repo: `install.sh --stack <flavor>` appends a stack seed pack (`frontend-web`,
`backend-api`, `fullstack-monorepo`, `cli-tool`, `library`; sub-packs like `frontend-web/nextjs`, `testing/playwright`). `/learn` retires seeded or mined entries that nothing ever cites.

## Configuration points

- **Ticket system** — Jira via MCP (Atlassian) → `jira` CLI → paste; `tracker_system: none` is a first-class mode (`/build`). Transition ids live in `repo-profiles/<repo>.yaml` (`_schema.yaml` says how to look them up).
- **Base branch** — per repo in its profile; `guard-base-branch.sh` derives the protected list from the profiles.
- **Single repo vs workspace** — default layout is a workspace with repos inside; for a single repo set `"env": {"WORKFLOW_LAYOUT": "single-repo"}` in `.claude/settings.json`.
- **Tooling** — hooks and the settings merge need `jq`; `triage-cluster.py`, `verify-score.py`, `harvest-profile.py` need `python3`;
  `mine-history.sh` is GitHub-only (`gh` + `jq`, degrades to an empty `candidates.json` elsewhere). `/pr` and `/ci-check` use `gh`; **no host detection**.

| Tracker ↓ / Host → | GitHub | GitLab / Bitbucket |
|---|---|---|
| Jira | **Full** — fetch, transitions, QA-bounce Closeout, `/pr`, `/ci-check`, reviews | **Partial** — Jira side full; `/pr` prints text only; no `/ci-check` / review commands |
| GitHub Issues, Linear | **Paste-only** — enum values; no fetch or transition path | **Paste-only** + text-only `/pr` |
| none | **Supported** — `/build` lane + full `gh` pipeline | **Supported** — `/build` + text-only `/pr`, no CI watch |

## Contributing learnings back from a confidential project

`/learn` makes a project smarter; `/upstream` carries the part that was never project-specific back here, along a path where
nothing confidential leaves the company machine and nothing public says where a learning came from. It diffs the installed core
against the baseline `install.sh` recorded, collects landed proposals, process lessons and feedback memories, drops what stops making
sense once the proper nouns are gone, redacts the rest with the denylist in `.claude/upstream.json`, and fails closed on any residual
hit or credential. The bundle goes, as an issue, to a **private inbox repo** you own; `/upstream --intake inbox` on your own machine
merges a month of bundles into **one** PR here under a scoped personal git identity. `scripts/harvest-profile.py` emits an aggregates-only
profile ([core/docs/profile.schema.md](core/docs/profile.schema.md)) to compare a mature install against the public defaults without moving a single file.

[docs/lessons.md](docs/lessons.md) collects the field-tested judgment calls that shaped these commands.
