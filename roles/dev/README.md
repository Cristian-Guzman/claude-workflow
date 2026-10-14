# Role: dev

The implementation lane. Installed by default (`./install.sh <target>` with no `--role` flag resolves to `dev`); combine with other roles via `--roles dev,sdet`.

## What the role adds

Six commands on top of core, all installed flat into `.claude/commands/` next to the core set:

| Command | What it does |
|---|---|
| `/clarify` | Investigate a ticket, pick placement + patterns, plan phases, persist a blueprint for `/ticket`. |
| `/ticket` | Implement a tracked ticket phase-by-phase from the blueprint; stops at local CI green. |
| `/build` | Implement a change without a ticket (replaces `/clarify` + `/ticket` when there is no tracker). |
| `/refactor` | Scan a scope against `codebase-patterns.md`, list violations, fix them with pattern enforcement. |
| `/verify` | Goal-backward verification that acceptance criteria are met in the code; scored gate table. |
| `/ui-fidelity` | Ad-hoc design-fidelity check for one UI surface; reports, never edits. |

Start here: `/ticket` (or `/build` with no tracker) → `/pr-creation` → `/learn`. Everything else is advanced and discoverable from `.claude/commands/README.md`.

## Seeds

`templates/repo/` is intentionally empty today: the dev role's project-owned files are the core seeds (`codebase-patterns.md`, `testing-patterns.md`, `ticket-checklist.md`, `pr-template.md`, `CLAUDE.md`). A file placed here is seeded into `.claude/` once and never overwritten; its basename must not collide with a core template.

## Learn targets

`learn-targets.yaml` makes explicit what `/learn` already does for this role: the two files it grows (`codebase-patterns.md`, `testing-patterns.md`), where it logs, where it promotes, and the signal kinds it scans. `install.sh` copies it to `.claude/learn-targets/dev.yaml`; `/learn` reads every file in that directory and falls back to its built-in scan when the directory is absent.

## Cold start

A repo with history but no pattern files: run `scripts/mine-history.sh` to produce `.claude/state/mine/<date>/candidates.json` from merged PRs, then `/learn --mine` to review and land the candidates that occurred at least twice.
