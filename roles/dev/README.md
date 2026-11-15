# Role: dev

The implementation lane. Installed by default (`./install.sh <target>` with no `--role` flag resolves to `dev`); combine with other roles via `--roles dev,sdet`.

## What the role adds

Seven commands on top of core, all installed flat into `.claude/commands/` next to the core set:

| Command | What it does |
|---|---|
| `/clarify` | Investigate a ticket, pick placement + patterns, plan phases, persist a blueprint for `/ticket`. |
| `/ticket` | Implement a tracked ticket phase-by-phase from the blueprint; stops at local CI green. |
| `/build` | Implement a change without a ticket (replaces `/clarify` + `/ticket` when there is no tracker). |
| `/refactor` | Scan a scope against `codebase-patterns.md`, list violations, fix them with pattern enforcement. |
| `/verify` | Goal-backward verification that acceptance criteria are met in the code; scored gate table. |
| `/ui-fidelity` | Ad-hoc design-fidelity check for one UI surface; reports, never edits. |
| `/reverse` | Reverse-engineer a feature from an app with no source (REA) into an evidence-backed behavior contract `/clarify` plans against. Specification, never a port. Installed only where REA is present. |

Start here: `/ticket` (or `/build` with no tracker) → `/pr-creation` → `/learn`. Everything else is advanced and discoverable from `.claude/commands/README.md`.

## Start from zero

An empty repo has no code to investigate, only decisions to make — so the lane starts one step earlier:

0. `mkdir <dir> && cd <dir> && git init` then `install.sh <dir> --role dev` — slash commands live in
   `.claude/commands/`, so the workflow must be installed before any of them exists. Set
   `"WORKFLOW_LAYOUT": "single-repo"` in `.claude/settings.json` (one app, one repo).
1. `/new-project "<one line>" --here` — three rounds of questions (platform, users, data, auth,
   integrations, relation to what you already have, constraints, non-goals), then a guide you **read
   and decide on**: one recommended architecture, two alternatives, a "not for this project" list, a
   stack with a **stable/LTS versions policy**, repo layout, testing strategy, CI/deploy. Writes
   `.claude/project-brief.md`, nothing else. `--sibling-of <path>` when it sits next to an app you have.
2. `install.sh <dir> --role dev --stack <flavor>` — re-run with the flavor the brief chose; the seed
   pack gives the first patterns from the flavor, not from history. Re-runs never touch your files.
3. `/build --from-brief` — Phase 0 scaffolds with the framework's own generator on the pinned stable
   line, writes `CLAUDE.md`, the repo profile and decision-sourced pattern entries, proves it runs,
   commits; Phase 1+ is the first feature.
4. `/bootstrap` — on a day-zero repo it prunes nothing (`KEEP(too-early)`) and configures the basics
   from the brief instead; re-run after the first build.

Then the normal loop: `/ticket` or `/build` → `/pr-creation` → `/learn`.

## Seeds

`templates/repo/` is intentionally empty today: the dev role's project-owned files are the core seeds (`codebase-patterns.md`, `testing-patterns.md`, `ticket-checklist.md`, `pr-template.md`, `CLAUDE.md`). A file placed here is seeded into `.claude/` once and never overwritten; its basename must not collide with a core template.

## Learn targets

`learn-targets.yaml` makes explicit what `/learn` already does for this role: the two files it grows (`codebase-patterns.md`, `testing-patterns.md`), where it logs, where it promotes, and the signal kinds it scans. `install.sh` copies it to `.claude/learn-targets/dev.yaml`; `/learn` reads every file in that directory and falls back to its built-in scan when the directory is absent.

## Cold start

A repo with history but no pattern files: run `scripts/mine-history.sh` to produce `.claude/state/mine/<date>/candidates.json` from merged PRs, then `/learn --mine` to review and land the candidates that occurred at least twice.
